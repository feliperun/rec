const std = @import("std");
const capture = @import("capture.zig");
const keys = @import("keys.zig");
const library = @import("library.zig");
const live = @import("live.zig");
const m4a = @import("m4a.zig");
const style = @import("style.zig");
const waveform = @import("waveform.zig");

/// How often the live view redraws, in ms — also the keystroke poll window.
const tick_ms = 100;

/// The record command body, shared by the CLI and the interactive 'r' key:
/// captures the microphone and encodes $HOME/recordings/YYYYMMDD-HHMMSS.m4a
/// (AAC) until the duration elapses, Ctrl-C, or ESC. SPACE pauses and
/// resumes — paused audio is dropped, so the recording keeps only what was
/// played. On a terminal the live view (status + waveform grid) runs on the
/// alternate screen. Returns the exit code.
pub fn recordOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    duration_sec: ?f64,
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
    const view_tty = std.Io.File.stderr().isTty(io) catch false;
    const keys_tty = std.Io.File.stdin().isTty(io) catch false;

    // "Recording to <path>" — the key hints live in the status line on a
    // terminal; piped stderr spells out the only control it has.
    const hint: []const u8 = if (view_tty) "" else " (Ctrl-C to stop)";
    var header_buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    var hn: usize = 0;
    appendStr(&header_buf, &hn, "Recording to ");
    style.appendStyled(&header_buf, &hn, color, style.cyan, path);
    style.appendStyled(&header_buf, &hn, color, style.dim, hint);
    var screen = LiveView{
        .header = header_buf[0..hn],
        .header_cells = "Recording to ".len + path.len + hint.len,
    };

    // The summary prints after the alt-screen leave below (defers run in
    // reverse registration order): success and failures land on the normal
    // screen, never inside the live view.
    var result: Outcome = .none;
    defer switch (result) {
        .none => {},
        .saved => |s| printSaved(io, path, s.dur_csec, s.bytes, color),
        .failed => |msg| printStderr(io, msg),
    };

    var esc_buf: [32]u8 = undefined; // enter/leave fit; check live.enter if you grow them
    if (view_tty) printStderr(io, live.enter(&esc_buf));
    defer if (view_tty) printStderr(io, live.leave(&esc_buf));

    if (!view_tty) {
        printStderr(io, screen.header);
        printStderr(io, "\n");
    }

    var encoder = m4a.Encoder.init(temp_path, rec.sample_rate, rec.channels) catch {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        result = .{ .failed = "record: failed to initialize M4A encoder\n" };
        return 1;
    };
    var encoder_open = true;
    defer {
        if (encoder_open) {
            encoder.abort();
            std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        }
    }

    // One raw read per keystroke; the cooked terminal comes back whatever
    // way the loop ends.
    var cooked: ?std.posix.termios = null;
    if (keys_tty) {
        cooked = std.posix.tcgetattr(0) catch null;
        if (cooked) |ck| {
            var raw = ck;
            raw.lflag.ICANON = false; // one key at a time
            raw.lflag.ECHO = false; // we echo manually
            raw.lflag.ISIG = false; // Ctrl-C arrives as a byte we handle
            raw.lflag.IEXTEN = false;
            raw.iflag.IXON = false; // Ctrl-S/Q must not freeze the terminal
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(0, .NOW, raw) catch {
                cooked = null;
            };
        }
    }
    defer if (cooked) |ck| {
        std.posix.tcsetattr(0, .FLUSH, ck) catch {};
    };

    const started_at = std.Io.Timestamp.now(io, .awake);
    const duration_ns: ?i128 = if (duration_sec) |sec| durationNanoseconds(sec) else null;

    // The live view: peaks accumulate from whatever the audio thread has
    // appended since the last tick.
    const byte_rate: u64 = @as(u64, rec.sample_rate) * rec.channels * 2;
    var tracker = waveform.PeakTracker.init(gpa, waveform.peakBlockBytes(byte_rate));
    defer tracker.deinit();
    var new_pcm: std.ArrayList(u8) = .empty;
    defer new_pcm.deinit(gpa);
    var peak_view: std.ArrayList(waveform.Peak) = .empty;
    defer peak_view.deinit(gpa);
    var consumed: usize = 0;

    // The whole view is composed here and written in one shot per tick —
    // many small writes are what made the view flicker.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);

    // Pausing (SPACE) drops incoming audio instead of encoding it, so the
    // timer counts recorded time only and the published duration comes from
    // the encoded bytes.
    var paused = false;
    var active_ns: i128 = 0;
    var seg_start = started_at;
    var encoded_len: usize = 0;

    loop: while (true) {
        switch (keys.readKey(tick_ms)) {
            .byte => |c| switch (c) {
                ' ' => {
                    const now = std.Io.Timestamp.now(io, .awake);
                    if (!paused) {
                        active_ns += now.nanoseconds - seg_start.nanoseconds;
                        paused = true;
                    } else {
                        seg_start = now;
                        paused = false;
                    }
                },
                0x1b, 0x03 => break :loop, // ESC stops, like Ctrl-C
                else => {}, // arrows and friends do nothing while recording
            },
            .none => {},
            .eof => {}, // stdin gone; Ctrl-C still stops
            else => {},
        }
        if (capture.stopRequested()) break :loop;

        const now = std.Io.Timestamp.now(io, .awake);
        const active: i128 = if (paused)
            active_ns
        else
            active_ns + (now.nanoseconds - seg_start.nanoseconds);
        if (duration_ns) |d| {
            if (active >= d) break :loop;
        }

        rec.takeNewPcm(&new_pcm, &consumed);
        if (!paused and new_pcm.items.len > 0) {
            encoder.write(new_pcm.items) catch {
                result = .{ .failed = "record: failed to encode M4A audio\n" };
                return 1;
            };
            tracker.feed(new_pcm.items);
            encoded_len += new_pcm.items.len;
        }

        // readKey's poll window is the tick pacing; no extra sleep.
        const secs: u32 = @intCast(@divTrunc(active, std.time.ns_per_s));
        printLiveView(io, gpa, &frame, secs, paused, tracker.view(&peak_view) catch &.{}, &screen, view_tty, color);
    }

    rec.stop();
    // The final callback block may have arrived after the last tick; it is
    // encoded only when it was not paused away.
    rec.takeNewPcm(&new_pcm, &consumed);
    if (!paused) encoded_len += new_pcm.items.len;
    // Duration comes from the PCM actually encoded; the size from the
    // encoded file on disk.
    const dur_csec: u64 = @as(u64, encoded_len) * 100 / byte_rate;
    const tail: []const u8 = if (paused) "" else new_pcm.items;
    const published = publish(io, &encoder, tail, dur_csec, temp_path, path, &result);
    encoder_open = !published;
    return if (published) 0 else 1;
}

/// How a recording run ended; printed on the normal screen after the live
/// view is gone.
const Outcome = union(enum) { none, saved: struct { dur_csec: u64, bytes: u64 }, failed: []const u8 };

/// Final flush and atomic publication of a finished recording: the last PCM
/// block, the moov-flushing finish, the rename over the public name, and the
/// size stat. Fills `outcome` and reports whether the file was published, so
/// the caller can release its encoder-abort guard.
fn publish(
    io: std.Io,
    encoder: *m4a.Encoder,
    new_pcm: []const u8,
    dur_csec: u64,
    temp_path: []const u8,
    path: []const u8,
    outcome: *Outcome,
) bool {
    encoder.write(new_pcm) catch {
        outcome.* = .{ .failed = "record: failed to encode M4A audio\n" };
        return false;
    };

    // Dispose flushes the moov atom. The public name is exposed only after
    // that succeeds, so an interrupted run leaves no corrupt .m4a behind.
    encoder.finish() catch {
        outcome.* = .{ .failed = "record: failed to finalize M4A audio\n" };
        return false;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp_path, std.Io.Dir.cwd(), path, io) catch {
        outcome.* = .{ .failed = "record: failed to save M4A audio\n" };
        return false;
    };
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        outcome.* = .{ .failed = "record: failed to write M4A audio\n" };
        return false;
    };
    outcome.* = .{ .saved = .{ .dur_csec = dur_csec, .bytes = stat.size } };
    return true;
}

/// Where the live view stands on the alternate screen: the header sits on
/// row 1 (redrawn when the width changes, since it may wrap differently),
/// the status line and the waveform grid below it.
const LiveView = struct {
    /// The header, composed with color, no trailing newline.
    header: []const u8,
    /// Display cells of the plain header text.
    header_cells: usize,
    /// Width the header was last drawn at.
    width: usize = 0,
};

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

/// Draws the live view, composing everything into `frame` and writing it
/// once. On a tty: absolutely positioned on the alternate screen behind a
/// synchronized-update bracket — the header on row 1 (redrawn whenever the
/// width changes, since it may wrap differently), the status line and the
/// waveform grid below it; whatever a resize did to the grid is overwritten
/// by this tick, and the single write keeps the view flicker-free. Off a
/// tty: a plain single line, carriage-returned over the previous one, with
/// a one-row slice of the waveform as the meter.
fn printLiveView(
    io: std.Io,
    gpa: std.mem.Allocator,
    frame: *std.ArrayList(u8),
    secs: u32,
    paused: bool,
    peaks: []const waveform.Peak,
    screen: *LiveView,
    tty: bool,
    color: bool,
) void {
    const width = @min(waveform.termWidth(), waveform.max_columns);
    var esc: [16]u8 = undefined;
    var line: [waveform.rowBufferLen(waveform.max_columns)]u8 = undefined;
    var fractions: [waveform.max_columns]u8 = undefined;

    frame.clearRetainingCapacity();
    const put = struct {
        fn f(fr: *std.ArrayList(u8), al: std.mem.Allocator, s: []const u8) void {
            fr.appendSlice(al, s) catch {};
        }
    }.f;

    if (!tty) {
        put(frame, gpa, "\r\x1b[2K");
        var cells: usize = 0;
        put(frame, gpa, composeStatus(&line, secs, paused, color, &cells));
        const bar_width = width -| cells;
        const fr = waveform.columnFractions(peaks, fractions[0..bar_width]);
        put(frame, gpa, waveform.renderRow(
            fr,
            waveform.view_height,
            waveform.view_height / 2,
            .{ .color = color },
            &line,
        ));
        printStderr(io, frame.items);
        return;
    }

    put(frame, gpa, live.sync_begin);

    const header_rows = live.rowsSpanned(screen.header_cells, width);
    if (width != screen.width) {
        // Erase the whole previous view — header, status, and grid rows —
        // then redraw the header; the rest follows below it.
        if (screen.width != 0) {
            const last = 1 + live.rowsSpanned(screen.header_cells, screen.width) + waveform.view_height;
            var row: usize = 1;
            while (row <= last) : (row += 1) {
                put(frame, gpa, live.moveTo(&esc, row, 1));
                put(frame, gpa, live.clearLine(&esc));
            }
        }
        put(frame, gpa, live.moveTo(&esc, 1, 1));
        put(frame, gpa, screen.header);
        screen.width = width;
    }

    const status_row = 1 + header_rows;
    put(frame, gpa, live.moveTo(&esc, status_row, 1));
    put(frame, gpa, live.clearLine(&esc));
    var cells: usize = 0;
    put(frame, gpa, composeStatus(&line, secs, paused, color, &cells));

    const fr = waveform.columnFractions(peaks, fractions[0..width]);
    var r: usize = 0;
    while (r < waveform.view_height) : (r += 1) {
        put(frame, gpa, live.moveTo(&esc, status_row + 1 + r, 1));
        put(frame, gpa, live.clearLine(&esc));
        put(frame, gpa, waveform.renderRow(fr, waveform.view_height, r, .{ .color = color }, &line));
    }

    put(frame, gpa, live.sync_end);
    printStderr(io, frame.items);
}

/// The live status line: a red ⏺ (yellow ⏸ when paused), the bold timer,
/// dim key hints. `cells_out` receives the display cells (escapes carry no
/// width; the ⏺/⏸ glyph is one cell).
fn composeStatus(buf: []u8, secs: u32, paused: bool, color: bool, cells_out: *usize) []const u8 {
    var n: usize = 0;
    var cells: usize = 0;
    appendStr(buf, &n, " ");
    cells += 1;
    style.appendStyled(buf, &n, color, if (paused) style.yellow else style.red, if (paused) "⏸" else "⏺");
    cells += 1;
    appendStr(buf, &n, " ");
    cells += 1;
    style.begin(buf, &n, color, style.bold);
    cells += appendTimer(buf, &n, secs);
    style.end(buf, &n, color);
    style.begin(buf, &n, color, style.dim);
    const word: []const u8 = if (paused) "resume" else "pause";
    appendStr(buf, &n, "  SPACE=");
    appendStr(buf, &n, word);
    appendStr(buf, &n, " ESC=stop");
    style.end(buf, &n, color);
    cells += "  SPACE=".len + word.len + " ESC=stop".len;
    cells_out.* = cells;
    return buf[0..n];
}

/// "MM:SS", or "H:MM:SS" past an hour. Returns the display cells.
fn appendTimer(buf: []u8, n: *usize, secs: u32) usize {
    const hours = secs / 3600;
    var cells: usize = 0;
    if (hours > 0) {
        appendUint(buf, n, hours);
        buf[n.*] = ':';
        n.* += 1;
        cells += digitCount(hours) + 1;
    }
    put2(buf[n.*..][0..2], (secs / 60) % 60);
    n.* += 2;
    buf[n.*] = ':';
    n.* += 1;
    put2(buf[n.*..][0..2], secs % 60);
    n.* += 2;
    return cells + 5;
}

/// Decimal digits of `v` (v > 0).
fn digitCount(v: u32) usize {
    var d: usize = 1;
    var x = v / 10;
    while (x > 0) : (x /= 10) d += 1;
    return d;
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

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

test "composeStatus draws the state, timer, and hints" {
    var buf: [256]u8 = undefined;
    var cells: usize = 0;
    try std.testing.expectEqualStrings(
        " ⏺ 00:05  SPACE=pause ESC=stop",
        composeStatus(&buf, 5, false, false, &cells),
    );
    try std.testing.expectEqual(@as(usize, 30), cells);
    try std.testing.expectEqualStrings(
        " ⏸ 00:05  SPACE=resume ESC=stop",
        composeStatus(&buf, 5, true, false, &cells),
    );
    try std.testing.expectEqual(@as(usize, 31), cells);
}

test "composeStatus switches to H:MM:SS past an hour" {
    var buf: [256]u8 = undefined;
    var cells: usize = 0;
    const line = composeStatus(&buf, 3661, false, false, &cells);
    try std.testing.expectEqualStrings(" ⏺ 1:01:01  SPACE=pause ESC=stop", line);
    try std.testing.expectEqual(@as(usize, 32), cells);
}

test "composeStatus colors the dot, timer, and hints without changing cells" {
    var buf: [256]u8 = undefined;
    var cells: usize = 0;
    const line = composeStatus(&buf, 5, false, true, &cells);
    try std.testing.expectEqualStrings(
        " \x1b[31m⏺\x1b[0m \x1b[1m00:05\x1b[0m\x1b[2m  SPACE=pause ESC=stop\x1b[0m",
        line,
    );
    try std.testing.expectEqual(@as(usize, 30), cells);

    // Paused: the dot goes yellow.
    const paused_line = composeStatus(&buf, 5, true, true, &cells);
    try std.testing.expectEqualStrings(
        " \x1b[33m⏸\x1b[0m \x1b[1m00:05\x1b[0m\x1b[2m  SPACE=resume ESC=stop\x1b[0m",
        paused_line,
    );
    try std.testing.expectEqual(@as(usize, 31), cells);
}
