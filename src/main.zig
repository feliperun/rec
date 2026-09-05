const std = @import("std");
const formatcmd = @import("formatcmd.zig");
const library = @import("library.zig");
const playback = @import("playback.zig");
const record = @import("record.zig");
const setupcmd = @import("setupcmd.zig");
const transcribecmd = @import("transcribecmd.zig");
const tui = @import("tui.zig");

const usage =
    \\Usage: rec [command]
    \\
    \\Commands:
    \\  record [--duration <sec>]  Record audio to ~/recordings/
    \\  list                       List recordings in ~/recordings/
    \\  play <index|filename>      Play a recording
    \\  transcribe <index|filename> [--language lg] [--out path]
    \\                             [--no-refine] [--context text]
    \\                             Transcribe via Deepgram and refine with the configured LLM
    \\  format <index|path> [--template name] [--out path] [--context text]
    \\                             Restructure a transcript with a prompt template (default: meeting)
    \\  setup                      Choose which coding-agent LLM processes transcripts
    \\                             (alias: configure-llm)
    \\  about                      Show the project page and how to contribute
    \\
    \\With no command, enters interactive mode.
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

    if (args.items.len < 2) {
        return tui.runInteractive(io, init.gpa, recordings_path);
    }

    const cmd = args.items[1];
    const rest = args.items[2..];

    if (std.mem.eql(u8, cmd, "record")) {
        const ra = parseRecordArgs(rest);
        switch (ra) {
            .invalid => {
                printStderr(io, usage);
                return 1;
            },
            .default => return record.recordOnce(io, init.gpa, null, recordings_path),
            .duration => |sec| return record.recordOnce(io, init.gpa, sec, recordings_path),
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
        if (rest.len != 1) {
            printStderr(io, usage);
            return 1;
        }
        return playback.playSelection(io, init.gpa, rest[0], recordings_path);
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
        );
    }

    if (std.mem.eql(u8, cmd, "format")) {
        return formatcmd.run(io, init.gpa, rest, home_dir, recordings_path);
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

    printStderr(io, usage);
    return 1;
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
    _ = @import("prompts.zig");
    _ = @import("setupcmd.zig");
    _ = @import("style.zig");
    _ = @import("tui.zig");
    _ = @import("transcribecmd.zig");
    _ = @import("okf.zig");
    _ = @import("waveform.zig");
    _ = @import("cut.zig");
    _ = @import("keys.zig");
    _ = @import("wav.zig");
}
