const std = @import("std");
const capture = @import("capture.zig");
const library = @import("library.zig");
const okf = @import("okf.zig");
const playback = @import("playback.zig");
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
            .default => return recordOnce(io, init.gpa, null, false, recordings_path),
            .duration => |sec| return recordOnce(io, init.gpa, sec, false, recordings_path),
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
/// selection against the library, send the WAV to Deepgram through
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

    // Default artifact sits beside the WAV in $HOME/recordings.
    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_len: usize = 0;
    if (ta.out) |p| {
        appendStr(&out_path_buf, &out_len, p);
    } else {
        const base = library.recordingPath(recordings_path, name[0 .. name.len - ".wav".len], &out_path_buf) orelse {
            printStderr(io, "transcribe: cannot write output path\n");
            return 1;
        };
        out_len = base.len;
        appendStr(&out_path_buf, &out_len, ".md");
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
        .title = name[0 .. name.len - ".wav".len],
        // The markdown is a sibling of the WAV, so this remains a valid
        // relative link regardless of the caller's current directory.
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

// libc time functions (libc is already linked for miniaudio): local-time
// naming without dragging in tz parsing.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn time(now: ?*i64) i64;
extern "c" fn localtime_r(now: *const i64, result: *Tm) ?*Tm;

/// "YYYYMMDD-HHMMSS" (15 bytes) from the local wall clock.
fn localTimestamp(out: *[15]u8) void {
    const now: i64 = time(null);
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) {
        @memcpy(out, "19700101-000000");
        return;
    }
    put4(out[0..4], @intCast(@max(tm.year + 1900, 0)));
    put2(out[4..6], @intCast(tm.mon + 1));
    put2(out[6..8], @intCast(tm.mday));
    out[8] = '-';
    put2(out[9..11], @intCast(tm.hour));
    put2(out[11..13], @intCast(tm.min));
    put2(out[13..15], @intCast(tm.sec));
}

fn put2(buf: []u8, v: u32) void {
    buf[0] = '0' + @as(u8, @intCast((v % 100) / 10));
    buf[1] = '0' + @as(u8, @intCast(v % 10));
}

fn put4(buf: []u8, v: u32) void {
    put2(buf[0..2], v / 100);
    put2(buf[2..4], v % 100);
}

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    capture.requestStop();
}

fn installSigintHandler() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// The record command body, shared by the CLI and the interactive 'r' key:
/// captures the microphone into $HOME/recordings/YYYYMMDD-HHMMSS.wav until the
/// duration elapses, Ctrl-C, or (when `key_stop`) any keypress. Returns the
/// exit code.
pub fn recordOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    duration_sec: ?f64,
    key_stop: bool,
    recordings_path: []const u8,
) u8 {
    // Before anything else, so an early Ctrl-C still finalizes a valid file.
    installSigintHandler();

    std.Io.Dir.cwd().createDirPath(io, recordings_path) catch {
        printStderr(io, "record: cannot create ~/recordings/ directory\n");
        return 1;
    };

    var name: [15]u8 = undefined;
    localTimestamp(&name);

    var filename_buf: [19]u8 = undefined;
    @memcpy(filename_buf[0..15], &name);
    @memcpy(filename_buf[15..19], ".wav");
    const filename = filename_buf[0..19];

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = library.recordingPath(recordings_path, filename, &path_buf) orelse {
        printStderr(io, "record: recording path is too long\n");
        return 1;
    };

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
        printStderr(io, "record: cannot open output file\n");
        return 1;
    };
    defer file.close(io);

    var rec = capture.Recorder.init(gpa);
    defer rec.deinit();
    rec.start(.{}) catch {
        printStderr(io, "record: cannot open the microphone (input permission?)\n");
        return 1;
    };

    printStderr(io, "Recording to ");
    printStderr(io, path);
    printStderr(io, if (key_stop) " (any key or Ctrl-C to stop)\n" else " (Ctrl-C to stop)\n");

    const started_at = std.Io.Timestamp.now(io, .awake);
    const deadline: ?std.Io.Timestamp = if (duration_sec) |sec|
        started_at.addDuration(.{ .nanoseconds = durationNanoseconds(sec) })
    else
        null;

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (capture.stopRequested()) break;
        if (deadline) |d| {
            if (now.nanoseconds >= d.nanoseconds) break;
        }
        if (key_stop and stdinKeyPending()) break;
        printElapsed(io, now.nanoseconds - started_at.nanoseconds);
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    rec.stop();
    const total = rec.writeWav(io, file) catch {
        printStderr(io, "\nrecord: failed to write WAV data\n");
        return 1;
    };

    // Summary numbers derived from the bytes actually written.
    const byte_rate: u64 = @as(u64, rec.sample_rate) * @as(u64, rec.channels) * 2;
    const dur_csec: u64 = total * 100 / byte_rate;
    printSaved(io, path, dur_csec, total);
    return 0;
}

/// Clamped so @intFromFloat cannot overflow i96 for any accepted
/// --duration value.
fn durationNanoseconds(sec: f64) i96 {
    const clamped = @min(sec, 3.2e9); // seconds in > 100 years
    return @intFromFloat(clamped * 1_000_000_000.0);
}

/// Single-line elapsed timer on stderr, refreshed with a carriage return;
/// called ~10x/s so it ticks at least once per second.
fn printElapsed(io: std.Io, elapsed_ns: i96) void {
    const secs: u32 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_s));
    var buf: [12]u8 = undefined;
    buf[0] = '\r';
    buf[1] = ' ';
    put2(buf[2..4], (secs / 3600) % 100);
    buf[4] = ':';
    put2(buf[5..7], (secs / 60) % 60);
    buf[7] = ':';
    put2(buf[8..10], secs % 60);
    buf[10] = ' ';
    buf[11] = ' ';
    printStderr(io, buf[0..]);
}

fn printSaved(io: std.Io, path: []const u8, dur_csec: u64, bytes: u64) void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    appendStr(&buf, &n, "\nSaved ");
    appendStr(&buf, &n, path);
    appendStr(&buf, &n, " (");
    appendUint(&buf, &n, dur_csec / 100);
    appendStr(&buf, &n, ".");
    append2(&buf, &n, dur_csec % 100);
    appendStr(&buf, &n, " s, ");
    appendUint(&buf, &n, bytes / 1024);
    appendStr(&buf, &n, " KiB)\n");
    printStderr(io, buf[0..n]);
}

fn append2(buf: []u8, n: *usize, v: u64) void {
    buf[n.*] = '0' + @as(u8, @intCast((v % 100) / 10));
    n.* += 1;
    buf[n.*] = '0' + @as(u8, @intCast(v % 10));
    n.* += 1;
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

fn appendUint(buf: []u8, n: *usize, v: u64) void {
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (x > 0) {
            tmp[len] = '0' + @as(u8, @intCast(x % 10));
            len += 1;
            x /= 10;
        }
    }
    while (len > 0) {
        len -= 1;
        buf[n.*] = tmp[len];
        n.* += 1;
    }
}

/// True when a keypress is already buffered on stdin (the key is consumed);
/// used to stop interactive recordings on any key.
fn stdinKeyPending() bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    if (ready == 0) return false;
    var buf: [1]u8 = undefined;
    _ = std.posix.read(0, &buf) catch return false;
    return true;
}

fn printStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

test {
    _ = @import("wav.zig");
    _ = @import("capture.zig");
    _ = @import("library.zig");
    _ = @import("playback.zig");
    _ = @import("tui.zig");
    _ = @import("transcribe.zig");
    _ = @import("okf.zig");
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
