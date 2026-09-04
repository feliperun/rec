const std = @import("std");
const capture = @import("capture.zig");
const library = @import("library.zig");
const live = @import("live.zig");
const m4a = @import("m4a.zig");
const style = @import("style.zig");
const waveform = @import("waveform.zig");

/// The record command body, shared by the CLI and the interactive 'r' key:
/// captures the microphone and encodes $HOME/recordings/YYYYMMDD-HHMMSS.m4a
/// (AAC) until the duration elapses, Ctrl-C, or (when `key_stop`) any
/// keypress. Returns the exit code.
pub fn recordOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    duration_sec: ?f64,
    key_stop: bool,
    recordings_path: []const u8,
) u8 {
    // Reset the per-recording flag before installing the handler, so a prior
    // Ctrl-C (for example from the interactive menu) cannot stop this run.
    capture.resetStop();
    installSigintHandler();

    std.Io.Dir.cwd().createDirPath(io, recordings_path) catch {
        printStderr(io, "record: cannot create ~/recordings/ directory\n");
        return 1;
    };

    var name: [15]u8 = undefined;
    localTimestamp(&name);

    var filename_buf: [19]u8 = undefined;
    @memcpy(filename_buf[0..15], &name);
    @memcpy(filename_buf[15..19], ".m4a");
    const filename = filename_buf[0..19];

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = library.recordingPath(recordings_path, filename, &path_buf) orelse {
        printStderr(io, "record: recording path is too long\n");
        return 1;
    };

    var temp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temp_path = std.fmt.bufPrint(&temp_path_buf, "{s}.part", .{path}) catch {
        printStderr(io, "record: recording path is too long\n");
        return 1;
    };
    // A killed process can only leave this private work file behind; never
    // expose it to the recording library as an M4A.
    std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    var rec = capture.Recorder.init(gpa);
    defer rec.deinit();
    rec.start(.{}) catch {
        printStderr(io, "record: cannot open the microphone (input permission?)\n");
        return 1;
    };

    const color = style.detect(io, .stderr());
    printStderr(io, "Recording to ");
    printStyledStderr(io, color, style.cyan, path);
    printStyledStderr(io, color, style.dim, if (key_stop) " (any key or Ctrl-C to stop)\n" else " (Ctrl-C to stop)\n");

    var encoder = m4a.Encoder.init(temp_path, rec.sample_rate, rec.channels) catch {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        printStderr(io, "record: failed to initialize M4A encoder\n");
        return 1;
    };
    var encoder_open = true;
    defer {
        if (encoder_open) {
            encoder.abort();
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        }
    }

    const started_at = std.Io.Timestamp.now(io, .awake);
    const deadline: ?std.Io.Timestamp = if (duration_sec) |sec|
        started_at.addDuration(.{ .nanoseconds = durationNanoseconds(sec) })
    else
        null;

    // The live view: peaks accumulate from whatever the audio thread has
    // appended since the last tick, and one line carries the timer and the
    // growing bar.
    const byte_rate: u64 = @as(u64, rec.sample_rate) * rec.channels * 2;
    var tracker = waveform.PeakTracker.init(gpa, waveform.peakBlockBytes(byte_rate));
    defer tracker.deinit();
    var new_pcm: std.ArrayList(u8) = .empty;
    defer new_pcm.deinit(gpa);
    var view: std.ArrayList(waveform.Peak) = .empty;
    defer view.deinit(gpa);
    var consumed: usize = 0;
    var screen = live.Block{}; // the live line currently on the terminal

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (capture.stopRequested()) break;
        if (deadline) |d| {
            if (now.nanoseconds >= d.nanoseconds) break;
        }
        if (key_stop and stdinKeyPending()) break;

        rec.takeNewPcm(&new_pcm, &consumed);
        encoder.write(new_pcm.items) catch {
            printStderr(io, "record: failed to encode M4A audio\n");
            return 1;
        };
        tracker.feed(new_pcm.items);
        const secs: u32 = @intCast(@divTrunc(now.nanoseconds - started_at.nanoseconds, std.time.ns_per_s));
        printLiveLine(io, secs, tracker.view(&view) catch &.{}, &screen, color);
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    rec.stop();
    // The final callback block may have arrived after the last 100 ms tick.
    rec.takeNewPcm(&new_pcm, &consumed);
    encoder.write(new_pcm.items) catch {
        printStderr(io, "record: failed to encode M4A audio\n");
        return 1;
    };
    // Clear the live line — every row it wrapped across after a resize —
    // for the summary below.
    var erase_buf: [64]u8 = undefined;
    printStderr(io, screen.erase(waveform.termWidth(), &erase_buf));

    // Dispose flushes the moov atom. The public name is exposed only after
    // that succeeds, so an interrupted run leaves no corrupt .m4a behind.
    encoder.finish() catch {
        printStderr(io, "record: failed to finalize M4A audio\n");
        return 1;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp_path, std.Io.Dir.cwd(), path, io) catch {
        printStderr(io, "record: failed to save M4A audio\n");
        return 1;
    };
    encoder_open = false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        printStderr(io, "record: failed to write M4A audio\n");
        return 1;
    };

    // Duration comes from the PCM actually captured; the size from the
    // encoded file on disk.
    const dur_csec: u64 = @as(u64, rec.pcm.items.len) * 100 / byte_rate;
    printSaved(io, path, dur_csec, stat.size, color);
    return 0;
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

/// Clamped so @intFromFloat cannot overflow i96 for any accepted
/// --duration value.
fn durationNanoseconds(sec: f64) i96 {
    const clamped = @min(sec, 3.2e9); // seconds in > 100 years
    return @intFromFloat(clamped * 1_000_000_000.0);
}

/// The live recording line: carriage return, a red ⏺, the bold timer, and
/// the growing VU-colored waveform bar filling the rest of `width`.
/// Composed in one pass for a single write per tick. `cols_out` receives
/// the line's display columns (everything but the `\r`; escapes have no
/// width) so the caller can erase it again after a resize wraps it.
fn composeLiveLine(buf: []u8, secs: u32, peaks: []const waveform.Peak, width: usize, color: bool, cols_out: *usize) []const u8 {
    var n: usize = 0;
    var cells: usize = 0;
    appendStr(buf, &n, "\r ");
    cells += 1;
    style.appendStyled(buf, &n, color, style.red, "⏺");
    cells += 1;
    appendStr(buf, &n, " ");
    cells += 1;
    const hours = secs / 3600;
    style.begin(buf, &n, color, style.bold);
    if (hours > 0) {
        appendUint(buf, &n, hours);
        cells += digitCount(hours);
        buf[n] = ':';
        n += 1;
        put2(buf[n..][0..2], (secs / 60) % 60);
        n += 2;
        cells += 3;
    } else {
        put2(buf[n..][0..2], (secs / 60) % 60);
        n += 2;
        cells += 2;
    }
    buf[n] = ':';
    n += 1;
    put2(buf[n..][0..2], secs % 60);
    n += 2;
    cells += 3;
    style.end(buf, &n, color);
    appendStr(buf, &n, " ");
    cells += 1;
    const bar_width = @min(width -| cells, 300);
    n += @intCast(waveform.renderBar(peaks, bar_width, bar_width, null, color, buf[n..]).len);
    cols_out.* = cells + bar_width;
    return buf[0..n];
}

/// Decimal digits of `v` (v > 0).
fn digitCount(v: u32) usize {
    var d: usize = 1;
    var x = v / 10;
    while (x > 0) : (x /= 10) d += 1;
    return d;
}

fn printLiveLine(io: std.Io, secs: u32, peaks: []const waveform.Peak, screen: *live.Block, color: bool) void {
    var erase_buf: [64]u8 = undefined;
    printStderr(io, screen.erase(waveform.termWidth(), &erase_buf));
    var cols: usize = 0;
    var buf: [4096]u8 = undefined;
    const line = composeLiveLine(&buf, secs, peaks, waveform.termWidth(), color, &cols);
    printStderr(io, line);
    screen.push(cols);
}

fn printStyledStderr(io: std.Io, color: bool, code: []const u8, text: []const u8) void {
    var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    var n: usize = 0;
    style.appendStyled(&buf, &n, color, code, text);
    printStderr(io, buf[0..n]);
}

fn printSaved(io: std.Io, path: []const u8, dur_csec: u64, bytes: u64, color: bool) void {
    var buf: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    var n: usize = 0;
    appendStr(&buf, &n, "\nSaved ");
    style.appendStyled(&buf, &n, color, style.cyan, path);
    style.begin(&buf, &n, color, style.dim);
    appendStr(&buf, &n, " (");
    appendUint(&buf, &n, dur_csec / 100);
    appendStr(&buf, &n, ".");
    append2(&buf, &n, dur_csec % 100);
    appendStr(&buf, &n, " s, ");
    appendUint(&buf, &n, bytes / 1024);
    appendStr(&buf, &n, " KiB)");
    style.end(&buf, &n, color);
    appendStr(&buf, &n, "\n");
    printStderr(io, buf[0..n]);
}

pub fn append2(buf: []u8, n: *usize, v: u64) void {
    buf[n.*] = '0' + @as(u8, @intCast((v % 100) / 10));
    n.* += 1;
    buf[n.*] = '0' + @as(u8, @intCast(v % 10));
    n.* += 1;
}

pub fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

pub fn appendUint(buf: []u8, n: *usize, v: u64) void {
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

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

test "composeLiveLine draws the timer and a growing bar" {
    var buf: [4096]u8 = undefined;
    // Levels 0,2,4,6,7 on the first five columns; the rest is silence.
    const peaks = [_]waveform.Peak{ 0, 8192, 16384, 24576, 32767 };
    var cols: usize = 0;
    const line = composeLiveLine(&buf, 5, &peaks, 20, false, &cols);
    try std.testing.expectEqualStrings("\r ⏺ 00:05 ▁▃▅▇█▁▁▁▁▁▁", line);
    // 3 cells of " ⏺ " + 5 timer + 1 space + 11 bar.
    try std.testing.expectEqual(@as(usize, 20), cols);
}

test "composeLiveLine switches to H:MM:SS past an hour" {
    var buf: [4096]u8 = undefined;
    var cols: usize = 0;
    // 40 - 11 cells of prefix/timer = 29 bar columns.
    const line = composeLiveLine(&buf, 3661, &.{}, 40, false, &cols);
    try std.testing.expectEqualStrings("\r ⏺ 1:01:01 " ++ ("▁" ** 29), line);
    try std.testing.expectEqual(@as(usize, 40), cols);
}

test "composeLiveLine clamps the bar on a narrow terminal" {
    var buf: [64]u8 = undefined;
    var cols: usize = 0;
    const line = composeLiveLine(&buf, 5, &.{}, 8, false, &cols);
    try std.testing.expectEqualStrings("\r ⏺ 00:05 ", line);
    try std.testing.expectEqual(@as(usize, 9), cols);
}

test "composeLiveLine colors the dot, timer, and levels" {
    var buf: [4096]u8 = undefined;
    var plain_buf: [4096]u8 = undefined;
    const peaks = [_]waveform.Peak{ 0, 8192, 16384, 24576, 32767 };
    var cols: usize = 0;
    const line = composeLiveLine(&buf, 5, &peaks, 12, true, &cols);
    // Escape codes carry no width: the plain and colored lines agree on cols.
    var plain_cols: usize = 0;
    _ = composeLiveLine(&plain_buf, 5, &peaks, 12, false, &plain_cols);
    try std.testing.expectEqual(plain_cols, cols);
    // Width 12: 9 cells of prefix, 3 bar columns — the 5 peaks compress to
    // silence, yellow, red (integer-division column slices).
    try std.testing.expectEqualStrings(
        "\r \x1b[31m⏺\x1b[0m \x1b[1m00:05\x1b[0m \x1b[2m▁\x1b[0m\x1b[33m▅\x1b[0m\x1b[31m█\x1b[0m",
        line,
    );
}
