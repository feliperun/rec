const std = @import("std");
const formatcmd = @import("formatcmd.zig");
const library = @import("library.zig");
const llm = @import("llm.zig");
const markdown = @import("markdown.zig");
const playback = @import("playback.zig");
const record = @import("record.zig");
const share = @import("sharecmd.zig");
const setupcmd = @import("setupcmd.zig");
const transcribecmd = @import("transcribecmd.zig");
const updater = @import("update.zig");

const usage =
    \\Usage: rec [command]
    \\
    \\Commands:
    \\  record [--duration <sec>]  Record audio to ~/recordings/ (the default:
    \\                             `rec` alone records, `rec --duration 5` too)
    \\  list                       List recordings in ~/recordings/
    \\  play [index|filename]      Play a recording (default: the latest)
    \\  transcribe [index|filename] [--language lg] [--out path]
    \\                             [--no-refine] [--context text]
    \\                             Transcribe via Deepgram and refine with the
    \\                             configured LLM (default: the latest recording)
    \\  format [index|path] [--template name] [--out path] [--context text]
    \\                             Restructure a transcript with a prompt template
    \\                             (default: meeting, on the latest recording)
    \\  share [index|path] [--to clipboard|chatgpt|claude|gemini]
    \\                             Copy or open a transcript in another app
    \\  view <path.md>             Read a Markdown document with scrolling
    \\  setup                      Choose which coding-agent LLM processes transcripts
    \\                             (alias: configure-llm)
    \\  about                      Show the project page and how to contribute
    \\  update                     Update rec from GitHub Releases (auto-checked daily)
    \\  help                       Show this message
    \\
;

// The single version source: build.zig.zon, embedded through build.zig's
// build_info options (bumped by release-please on every release).
const version = @import("build_info").version;

const about_text = std.fmt.comptimePrint(
    \\rec {s} — record. transcribe. understand.
    \\https://github.com/feliperun/rec
    \\
    \\rec is free software (MIT) built by its users. Bug reports, ideas
    \\and pull requests are welcome:
    \\https://github.com/feliperun/rec/issues
    \\
, .{version});

pub fn main(init: std.process.Init) u8 {
    const io = init.io;

    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(init.gpa);
    var args_it = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch {
        printStderr(io, "out of memory\n");
        return 1;
    };
    defer args_it.deinit();
    while (args_it.next()) |arg| {
        args.append(init.gpa, arg) catch {
            printStderr(io, "out of memory\n");
            return 1;
        };
    }

    // getAlloc works on every platform (USERPROFILE on Windows); a missing
    // or unreadable variable degrades to "" and the library path fails with
    // its own message. The value lives for the whole run and is released
    // when main returns — the debug allocator counts anything less.
    const home_var: []const u8 = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home_alloc: ?[]u8 = init.minimal.environ.getAlloc(init.gpa, home_var) catch null;
    defer if (home_alloc) |h| init.gpa.free(h);
    const home_dir: []const u8 = home_alloc orelse "";

    var recordings_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recordings_path = library.homeRecordingsPath(home_dir, &recordings_path_buf) orelse {
        printStderr(io, "rec: cannot determine HOME/recordings directory\n");
        return 1;
    };

    const command = splitCommand(args.items[1..]);
    const cmd = command.verb;
    const rest = command.rest;

    if (std.mem.eql(u8, cmd, "help")) {
        printStdout(io, usage);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "view")) {
        if (rest.len != 1) {
            printStderr(io, "Usage: rec view <path.md>\n");
            return 1;
        }
        return markdown.showFile(io, init.gpa, rest[0]);
    }

    // Silent self-update check: once a day, never during a recording or when
    // `update` itself is running, and mute on every failure path.
    if (!std.mem.eql(u8, cmd, "record") and !std.mem.eql(u8, cmd, "update")) {
        var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (llm.configDirPath(home_dir, llm.envValue("XDG_CONFIG_HOME"), &cfg_buf)) |config_dir| {
            updater.autoCheck(io, init.gpa, config_dir);
        }
    }

    if (std.mem.eql(u8, cmd, "record")) {
        const ra = parseRecordArgs(rest);
        // A terminal output is enough to open the follow-up player. stdin
        // may be a scripted pipe (for example a pty test feeding ESC then Q)
        // while the recorder still owns a visible terminal.
        const auto_play = std.Io.File.stderr().isTty(io) catch false;
        switch (ra) {
            .invalid => {
                printStderr(io, usage);
                return 1;
            },
            .default => {
                const code = record.recordOnce(io, init.gpa, null, recordings_path);
                if (code == 0 and auto_play and record.last_stop_was_interrupt) return playback.playSelection(io, init.gpa, library.latest_selection, recordings_path);
                return code;
            },
            .duration => |sec| {
                const code = record.recordOnce(io, init.gpa, sec, recordings_path);
                if (code == 0 and auto_play and record.last_stop_was_interrupt) return playback.playSelection(io, init.gpa, library.latest_selection, recordings_path);
                return code;
            },
        }
    }

    if (std.mem.eql(u8, cmd, "list")) {
        if (rest.len != 0) {
            printStderr(io, usage);
            return 1;
        }
        return library.listRecordings(io, init.gpa, recordings_path);
    }

    if (std.mem.eql(u8, cmd, "play")) {
        if (rest.len > 1) {
            printStderr(io, usage);
            return 1;
        }
        // No selection plays the latest recording: index 1 of the
        // newest-first library order.
        const selection: []const u8 = if (rest.len == 1) rest[0] else library.latest_selection;
        return playback.playSelection(io, init.gpa, selection, recordings_path);
    }

    if (std.mem.eql(u8, cmd, "transcribe")) {
        // One environment lookup here (the only place the raw environ is in
        // scope); transcribecmd still orders its errors so a bad selection
        // is reported before a missing key. main owns the key's memory.
        const api_key: ?[]u8 = init.minimal.environ.getAlloc(init.gpa, "DEEPGRAM_API_KEY") catch null;
        defer if (api_key) |k| init.gpa.free(k);
        return transcribecmd.run(
            io,
            init.gpa,
            rest,
            api_key,
            home_dir,
            recordings_path,
            .terminal,
        );
    }

    if (std.mem.eql(u8, cmd, "format")) {
        return formatcmd.run(io, init.gpa, rest, home_dir, recordings_path, .terminal);
    }

    if (std.mem.eql(u8, cmd, "share")) {
        return share.run(io, init.gpa, rest, recordings_path);
    }

    // The LLM choice lives behind two names: `setup` for first-run configure,
    // `configure-llm` for when the word is about changing it later.
    if (std.mem.eql(u8, cmd, "setup") or std.mem.eql(u8, cmd, "configure-llm")) {
        return setupcmd.run(io, init.gpa, home_dir);
    }

    if (std.mem.eql(u8, cmd, "about")) {
        if (rest.len != 0) {
            printStderr(io, usage);
            return 1;
        }
        printStdout(io, about_text);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "update")) {
        if (rest.len != 0) {
            printStderr(io, usage);
            return 1;
        }
        return updater.run(io, init.gpa);
    }

    printStderr(io, usage);
    return 1;
}

const Command = struct {
    verb: []const u8,
    rest: []const [:0]const u8,
};

/// The verb and its arguments from argv[1..]. Recording is the implied
/// verb: bare `rec` records, and so does `rec --duration 5` — a leading
/// flag belongs to record. `-h`/`--help` ask for the usage.
fn splitCommand(args: []const [:0]const u8) Command {
    if (args.len == 0) return .{ .verb = "record", .rest = args };
    const first = args[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        return .{ .verb = "help", .rest = args[1..] };
    }
    if (std.mem.startsWith(u8, first, "-")) return .{ .verb = "record", .rest = args };
    return .{ .verb = first, .rest = args[1..] };
}

const RecordArgs = union(enum) {
    invalid,
    default,
    duration: f64,
};

fn parseRecordArgs(args: []const [:0]const u8) RecordArgs {
    var result: RecordArgs = .default;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--duration")) return .invalid;
        i += 1;
        if (i >= args.len) return .invalid;
        const sec = std.fmt.parseFloat(f64, args[i]) catch return .invalid;
        if (sec != sec or sec < 0) return .invalid; // NaN or negative
        result = .{ .duration = sec };
    }
    return result;
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

fn printStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

test "bare rec and a leading flag imply the record verb" {
    const none = splitCommand(&.{});
    try std.testing.expectEqualStrings("record", none.verb);
    try std.testing.expectEqual(@as(usize, 0), none.rest.len);

    const timed = splitCommand(&.{ "--duration", "5" });
    try std.testing.expectEqualStrings("record", timed.verb);
    try std.testing.expectEqual(@as(usize, 2), timed.rest.len);
    try std.testing.expectEqualStrings("--duration", timed.rest[0]);

    // The explicit verb still works and keeps its own arguments.
    const explicit = splitCommand(&.{ "record", "--duration", "5" });
    try std.testing.expectEqualStrings("record", explicit.verb);
    try std.testing.expectEqual(@as(usize, 2), explicit.rest.len);
}

test "a verb takes the remaining arguments; help has two spellings" {
    const bare_play = splitCommand(&.{"play"});
    try std.testing.expectEqualStrings("play", bare_play.verb);
    try std.testing.expectEqual(@as(usize, 0), bare_play.rest.len);

    const play_two = splitCommand(&.{ "play", "2" });
    try std.testing.expectEqualStrings("play", play_two.verb);
    try std.testing.expectEqualStrings("2", play_two.rest[0]);

    try std.testing.expectEqualStrings("help", splitCommand(&.{"--help"}).verb);
    try std.testing.expectEqualStrings("help", splitCommand(&.{"-h"}).verb);
    try std.testing.expectEqualStrings("help", splitCommand(&.{"help"}).verb);
}

test "parseRecordArgs accepts a duration and rejects the rest" {
    try std.testing.expectEqual(RecordArgs.default, parseRecordArgs(&.{}));
    try std.testing.expectEqual(RecordArgs{ .duration = 2.5 }, parseRecordArgs(&.{ "--duration", "2.5" }));
    try std.testing.expectEqual(RecordArgs.invalid, parseRecordArgs(&.{"--duration"}));
    try std.testing.expectEqual(RecordArgs.invalid, parseRecordArgs(&.{ "--duration", "-1" }));
    try std.testing.expectEqual(RecordArgs.invalid, parseRecordArgs(&.{"--verbose"}));
}

test {
    if (@import("builtin").os.tag == .macos) _ = @import("m4a.zig");
    _ = @import("capture.zig");
    _ = @import("record.zig");
    _ = @import("formatcmd.zig");
    _ = @import("library.zig");
    _ = @import("live.zig");
    _ = @import("llm.zig");
    _ = @import("playback.zig");
    _ = @import("player.zig");
    _ = @import("spectrum_test.zig");
    _ = @import("prompts.zig");
    _ = @import("ruler.zig");
    _ = @import("setupcmd.zig");
    _ = @import("share.zig");
    _ = @import("sharecmd.zig");
    _ = @import("style.zig");
    _ = @import("transcribecmd.zig");
    _ = @import("update.zig");
    _ = @import("okf.zig");
    _ = @import("waveform.zig");
    _ = @import("cut.zig");
    _ = @import("keys.zig");
    _ = @import("markdown.zig");
    _ = @import("viewport.zig");
    _ = @import("wav.zig");
}
