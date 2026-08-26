const std = @import("std");
const library = @import("library.zig");
const okf = @import("okf.zig");
const playback = @import("playback.zig");
const record = @import("record.zig");
const transcribe = @import("transcribe.zig");
const tui = @import("tui.zig");

const usage =
    \\Usage: rec [command]
    \\
    \\Commands:
    \\  record [--duration <sec>]  Record audio to ~/recordings/
    \\  list                       List recordings in ~/recordings/
    \\  play <index|filename>      Play a recording
    \\  transcribe <index|filename>  Transcribe a recording to OKF markdown via Deepgram
    \\
    \\With no command, enters interactive mode.
    \\
;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;

    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(init.gpa);
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    defer args_it.deinit();
    while (args_it.next()) |arg| {
        args.append(init.gpa, arg) catch {
            printStderr(io, "out of memory\n");
            return 1;
        };
    }

    var recordings_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recordings_path = library.homeRecordingsPath(
        init.minimal.environ.getPosix("HOME") orelse "",
        &recordings_path_buf,
    ) orelse {
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
            .default => return record.recordOnce(io, init.gpa, null, false, recordings_path),
            .duration => |sec| return record.recordOnce(io, init.gpa, sec, false, recordings_path),
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
        // scope); transcribeSelection still orders its errors so a bad
        // selection is reported before a missing key.
        return transcribeSelection(io, init.gpa, rest, init.minimal.environ.getPosix("DEEPGRAM_API_KEY"), recordings_path);
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

/// Deepgram language used unless --language says otherwise.
const default_language = "pt-BR";

const TranscribeSelection = struct {
    selection: []const u8,
    language: []const u8,
    out: ?[]const u8,
};

const TranscribeArgs = union(enum) {
    invalid,
    ok: TranscribeSelection,
};

/// Pure argument parsing for `transcribe` (kept free of I/O so tests stay
/// offline): the first non-flag token is the selection, --language/--out
/// consume the following token and keep their last occurrence, and anything
/// else — unknown flags, missing values, extra positionals — is invalid.
fn parseTranscribeArgs(args: []const [:0]const u8) TranscribeArgs {
    var selection: ?[]const u8 = null;
    var language: []const u8 = default_language;
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--language")) {
            i += 1;
            if (i >= args.len) return .invalid;
            language = args[i];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) return .invalid;
            out = args[i];
        } else if (selection == null and !std.mem.startsWith(u8, args[i], "-")) {
            selection = args[i];
        } else {
            return .invalid;
        }
    }
    const sel = selection orelse return .invalid;
    return .{ .ok = .{ .selection = sel, .language = language, .out = out } };
}

/// The transcribe command body, shaped like playSelection: resolve the
/// selection against the library, send the recording to Deepgram through
/// src/transcribe.zig, and write an OKF markdown transcript next to it.
/// Human messages go to stderr; stdout stays reserved for `list`. Returns
/// the exit code.
pub fn transcribeSelection(
    io: std.Io,
    gpa: std.mem.Allocator,
    args: []const [:0]const u8,
    api_key: ?[]const u8,
    recordings_path: []const u8,
) u8 {
    const ta = switch (parseTranscribeArgs(args)) {
        .invalid => {
            printStderr(io, usage);
            return 1;
        },
        .ok => |a| a,
    };

    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);

    library.scan(io, gpa, &entries, recordings_path) catch {
        printStderr(io, "transcribe: out of memory\n");
        return 1;
    };
    if (entries.items.len == 0) {
        printStderr(io, "No recordings yet.\n");
        return 1;
    }

    const name = library.resolveName(ta.selection, entries.items) orelse {
        printStderr(io, "transcribe: no recording matches '");
        printStderr(io, ta.selection);
        printStderr(io, "' (see `rec list`)\n");
        return 1;
    };

    const key = api_key orelse {
        printStderr(io, "transcribe: DEEPGRAM_API_KEY is not set\n");
        return 1;
    };
    if (key.len == 0) {
        printStderr(io, "transcribe: DEEPGRAM_API_KEY is not set\n");
        return 1;
    }

    // curl gets an absolute path so it never depends on our cwd.
    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recording_path = library.recordingPath(recordings_path, name, &rel_buf) orelse {
        printStderr(io, "transcribe: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, recording_path, &abs_buf) catch {
        printStderr(io, "transcribe: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    // Default artifact sits beside the recording in $HOME/recordings.
    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_len: usize = 0;
    if (ta.out) |p| {
        record.appendStr(&out_path_buf, &out_len, p);
    } else {
        const base = library.recordingPath(recordings_path, stripExt(name), &out_path_buf) orelse {
            printStderr(io, "transcribe: cannot write output path\n");
            return 1;
        };
        out_len = base.len;
        record.appendStr(&out_path_buf, &out_len, ".md");
    }
    const out_path: []const u8 = out_path_buf[0..out_len];

    var result: transcribe.TranscribeOutput = .{ .json = .empty };
    defer result.json.deinit(gpa);
    transcribe.transcribe(io, gpa, abs_buf[0..abs_len], key, ta.language, &result) catch |err| {
        switch (err) {
            error.CurlSpawnFailed => printStderr(io, "transcribe: cannot run curl\n"),
            error.RequestFailed => {
                printStderr(io, "transcribe: deepgram request failed (");
                printStderr(io, flattenTail(&result.err_tail, result.err_tail_len));
                printStderr(io, ")\n");
            },
            error.BadResponse => printStderr(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => printStderr(io, "transcribe: no speech found in recording\n"),
            error.OutOfMemory => printStderr(io, "transcribe: out of memory\n"),
        }
        return 1;
    };

    const utterances = transcribe.parseResponse(gpa, result.json.items) catch |err| {
        switch (err) {
            error.BadResponse => printStderr(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => printStderr(io, "transcribe: no speech found in recording\n"),
            error.OutOfMemory => printStderr(io, "transcribe: out of memory\n"),
        }
        return 1;
    };
    defer transcribe.freeUtterances(gpa, utterances);

    // The duration shown by `list` is already parsed from the header; reuse
    // it for the transcript's duration_sec frontmatter field.
    var duration_sec: ?f64 = null;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.name, name)) duration_sec = e.duration_sec;
    }

    var ts_buf: [20]u8 = undefined;
    okf.utcTimestamp(&ts_buf);

    const doc = okf.render(gpa, .{
        .title = stripExt(name),
        // The markdown is a sibling of the recording, so this remains a
        // valid relative link regardless of the caller's current directory.
        .resource = name,
        .timestamp = ts_buf[0..],
        .model = "nova-3",
        .language = ta.language,
        .duration_sec = duration_sec,
    }, utterances) catch {
        printStderr(io, "transcribe: out of memory\n");
        return 1;
    };
    defer gpa.free(doc);

    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch {
        printStderr(io, "transcribe: cannot write ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return 1;
    };
    defer file.close(io);
    file.writeStreamingAll(io, doc) catch {
        printStderr(io, "transcribe: cannot write ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return 1;
    };

    printStderr(io, "Transcript saved to ");
    printStderr(io, out_path);
    printStderr(io, "\n");
    return 0;
}

/// curl's stderr tail flattened to a single line — newlines become one
/// space, edges trimmed — so every `transcribe:` message stays one line.
fn flattenTail(tail: []u8, len: usize) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (tail[0..@min(len, tail.len)]) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            pending_space = n != 0;
            continue;
        }
        if (pending_space) {
            tail[n] = ' ';
            n += 1;
            pending_space = false;
        }
        tail[n] = ch;
        n += 1;
    }
    return tail[0..n];
}

fn printStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

test {
    _ = @import("m4a.zig");
    _ = @import("capture.zig");
    _ = @import("record.zig");
    _ = @import("library.zig");
    _ = @import("playback.zig");
    _ = @import("tui.zig");
    _ = @import("transcribe.zig");
    _ = @import("okf.zig");
}

/// A recording's stem: the name without its .m4a/.wav extension, used for
/// the transcript's title and default output path.
fn stripExt(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".m4a")) return name[0 .. name.len - ".m4a".len];
    if (std.mem.endsWith(u8, name, ".wav")) return name[0 .. name.len - ".wav".len];
    return name;
}

test "stripExt removes recording extensions only" {
    try std.testing.expectEqualStrings("20260826-143000", stripExt("20260826-143000.m4a"));
    try std.testing.expectEqualStrings("20260826-143000", stripExt("20260826-143000.wav"));
    try std.testing.expectEqualStrings("notes", stripExt("notes"));
}

// Pure checks of the transcribe argument parser: no I/O, so they stay
// offline and deterministic.

fn transcribeArgsOk(args: []const [:0]const u8) !TranscribeSelection {
    return switch (parseTranscribeArgs(args)) {
        .ok => |a| a,
        .invalid => error.TestUnexpectedResult,
    };
}

fn transcribeArgsInvalid(args: []const [:0]const u8) !void {
    try std.testing.expect(switch (parseTranscribeArgs(args)) {
        .invalid => true,
        .ok => false,
    });
}

test "transcribe args: bare selection gets the default language and output" {
    const a = try transcribeArgsOk(&.{"3"});
    try std.testing.expectEqualStrings("3", a.selection);
    try std.testing.expectEqualStrings(default_language, a.language);
    try std.testing.expect(a.out == null);
}

test "transcribe args: custom language" {
    const a = try transcribeArgsOk(&.{ "1", "--language", "en-US" });
    try std.testing.expectEqualStrings("1", a.selection);
    try std.testing.expectEqualStrings("en-US", a.language);
    try std.testing.expect(a.out == null);
}

test "transcribe args: custom output path" {
    const a = try transcribeArgsOk(&.{ "1", "--out", "/tmp/notes.md" });
    try std.testing.expectEqualStrings("/tmp/notes.md", a.out.?);
}

test "transcribe args: both flags together, in any order" {
    const a = try transcribeArgsOk(&.{ "--language", "en-US", "2", "--out", "/tmp/x.md" });
    try std.testing.expectEqualStrings("2", a.selection);
    try std.testing.expectEqualStrings("en-US", a.language);
    try std.testing.expectEqualStrings("/tmp/x.md", a.out.?);
}

test "transcribe args: repeated flags keep the last occurrence" {
    const a = try transcribeArgsOk(&.{ "1", "--language", "en", "--language", "fr", "--out", "a.md", "--out", "b.md" });
    try std.testing.expectEqualStrings("fr", a.language);
    try std.testing.expectEqualStrings("b.md", a.out.?);
}

test "transcribe args: rejects unknown flags, missing values, and extra tokens" {
    try transcribeArgsInvalid(&.{"--bogus"}); // unknown flag, no selection
    try transcribeArgsInvalid(&.{ "1", "--bogus" });
    try transcribeArgsInvalid(&.{ "1", "-x" });
    try transcribeArgsInvalid(&.{ "1", "--language" }); // missing flag value
    try transcribeArgsInvalid(&.{ "1", "--out" }); // missing flag value
    try transcribeArgsInvalid(&.{ "1", "2" }); // extra positional
}

test "transcribe args: rejects a missing selection" {
    try transcribeArgsInvalid(&.{});
    try transcribeArgsInvalid(&.{ "--language", "en" });
}

test "flattenTail collapses curl's multiline stderr into one line" {
    const sample = "curl: (22) The requested URL returned error: 401\n\ncheck headers\n";
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..sample.len], sample);
    try std.testing.expectEqualStrings(
        "curl: (22) The requested URL returned error: 401 check headers",
        flattenTail(&buf, sample.len),
    );
    // An empty tail stays empty, not a stray space.
    var empty: [512]u8 = undefined;
    try std.testing.expectEqualStrings("", flattenTail(&empty, 0));
}
