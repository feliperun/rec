const std = @import("std");
const capture = @import("capture.zig");
const keys = @import("keys.zig");
const library = @import("library.zig");
const live = @import("live.zig");
const ruler = @import("ruler.zig");
const style = @import("style.zig");
const waveform = @import("waveform.zig");

/// How often the live view redraws, in ms — also the keystroke poll window.
const tick_ms = 100;

/// The record command body: captures the microphone and encodes
/// $HOME/recordings/YYYYMMDD-HHMMSS<library.recording.ext> (the platform recording
/// format) until the duration elapses, Ctrl-C, or ESC. SPACE pauses and
/// resumes — paused audio is dropped, so the recording keeps only what was
/// played. On a terminal the live view (status, the scrolling waveform,
/// its time ruler) runs on the alternate screen. Returns the exit code.
pub fn recordOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    duration_sec: ?f64,
    recordings_path: []const u8,
) u8 {
    // Reset the per-recording flag before installing the handler, so a stale
    // stop request cannot end this run.
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
    @memcpy(filename_buf[15..19], library.recording.ext);
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
    // expose it to the recording library as a recording.
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
    // screen, never inside the live view. A capture that never got audible
    // adds its warning right after the summary.
    var result: Outcome = .none;
    var dead_capture = false;
    defer switch (result) {
        .none => {},
        .saved => |s| {
            printSaved(io, path, s.dur_csec, s.bytes, color);
            if (dead_capture) printStderr(io, dead_capture_warning);
        },
        .failed => |msg| printStderr(io, msg),
    };

    var esc_buf: [32]u8 = undefined; // enter/leave fit; check live.enter if you grow them
    if (view_tty) printStderr(io, live.enter(&esc_buf));
    defer if (view_tty) printStderr(io, live.leave(&esc_buf));

    if (!view_tty) {
        printStderr(io, screen.header);
        printStderr(io, "\n");
    }

    var encoder = library.recording.Encoder.init(temp_path, rec.sample_rate, rec.channels) catch {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        result = .{ .failed = "record: failed to initialize the " ++ library.recording.format_name ++ " encoder\n" };
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
    var cooked: ?keys.Cooked = null;
    if (keys_tty) cooked = keys.enableRaw();
    defer if (cooked) |ck| keys.restoreRaw(ck);

    const started_at = std.Io.Timestamp.now(io, .awake);
    const duration_ns: ?i128 = if (duration_sec) |sec| durationNanoseconds(sec) else null;

    // The live view: blocks accumulate from whatever the audio thread has
    // appended since the last tick.
    const byte_rate: u64 = @as(u64, rec.sample_rate) * rec.channels * 2;
    var tracker = waveform.Tracker.init(gpa, waveform.peakBlockBytes(byte_rate));
    defer tracker.deinit();
    var new_pcm: std.ArrayList(u8) = .empty;
    defer new_pcm.deinit(gpa);
    var block_view: std.ArrayList(waveform.Block) = .empty;
    defer block_view.deinit(gpa);
    var consumed: usize = 0;

    // Watches what the encoder actually gets, so the audibility verdict
    // covers exactly the content of the published file.
    var levels = LevelTracker.init(rec.sample_rate, rec.channels);

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
        switch (keys.readKey(io, tick_ms)) {
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
            levels.add(new_pcm.items);
            encoded_len += new_pcm.items.len;
        }

        // readKey's poll window is the tick pacing; no extra sleep.
        const secs: u32 = @intCast(@divTrunc(active, std.time.ns_per_s));
        printLiveView(io, gpa, &frame, secs, paused, tracker.view(&block_view) catch &.{}, &screen, view_tty, color);
    }

    rec.stop();
    // The final callback block may have arrived after the last tick; it is
    // encoded only when it was not paused away.
    rec.takeNewPcm(&new_pcm, &consumed);
    if (!paused) {
        levels.add(new_pcm.items);
        encoded_len += new_pcm.items.len;
    }
    // Fold the trailing partial second in before judging audibility.
    levels.finish();
    dead_capture = levels.isDead();
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

const dead_capture_warning =
    "warning: recorded audio stayed very quiet (check the input device and its volume before recording again; transcription may miss speech)\n";

/// A second of audio whose RMS stays under this level (s16 linear, -40 dBFS)
/// triggers a low-level warning. Signal level alone cannot establish whether
/// speech is present or intelligible; this is not a voice activity detector.
const audibility_floor: f64 = 32768.0 * std.math.pow(f64, 10.0, -40.0 / 20.0);

/// How long a recording must run before the dead-capture verdict is offered,
/// so short quiet clips do not nag.
const audibility_min_sec: usize = 10;

/// Watches the recorded signal's level, one whole second of audio at a time.
/// Fed the same PCM the encoder gets — paused audio never reaches it — so
/// the verdict covers exactly what lands in the published file.
const LevelTracker = struct {
    rate: u32,
    channels: u16,
    /// Samples in one full second across all channels.
    window_samples: usize,
    open_samples: usize = 0,
    open_sum_sq: u64 = 0,
    /// RMS (s16 linear) of the loudest window so far, the trailing partial
    /// folded in by finish() when it is at least half a second long.
    loudest_rms: f64 = 0,
    total_samples: usize = 0,

    fn init(rate: u32, channels: u16) LevelTracker {
        return .{ .rate = rate, .channels = channels, .window_samples = @as(usize, rate) * channels };
    }

    fn add(self: *LevelTracker, bytes: []const u8) void {
        const samples = std.mem.bytesAsSlice(i16, bytes);
        self.total_samples += samples.len;
        for (samples) |s| {
            const v: i32 = s;
            self.open_sum_sq += @as(u64, @intCast(v * v));
            self.open_samples += 1;
            if (self.open_samples == self.window_samples) self.closeWindow();
        }
    }

    /// Closes the trailing partial window when it holds at least half a
    /// second: speech confined to the tail of the recording must keep the
    /// capture audible, or it would false-positive as dead.
    fn finish(self: *LevelTracker) void {
        if (self.open_samples * 2 >= self.window_samples) self.closeWindow();
    }

    fn closeWindow(self: *LevelTracker) void {
        const rms: f64 = @sqrt(@as(f64, @floatFromInt(self.open_sum_sq)) / @as(f64, @floatFromInt(self.open_samples)));
        if (rms > self.loudest_rms) self.loudest_rms = rms;
        self.open_samples = 0;
        self.open_sum_sq = 0;
    }

    /// The capture never became audible: it ran at least audibility_min_sec
    /// seconds and no second of it ever reached the audibility floor.
    fn isDead(self: *const LevelTracker) bool {
        const min_samples = audibility_min_sec * self.window_samples;
        return self.total_samples >= min_samples and self.loudest_rms < audibility_floor;
    }
};

/// Final flush and atomic publication of a finished recording: the last PCM
/// block, the moov-flushing finish, the rename over the public name, and the
/// size stat. Fills `outcome` and reports whether the file was published, so
/// the caller can release its encoder-abort guard.
fn publish(
    io: std.Io,
    encoder: *library.recording.Encoder,
    new_pcm: []const u8,
    dur_csec: u64,
    temp_path: []const u8,
    path: []const u8,
    outcome: *Outcome,
) bool {
    encoder.write(new_pcm) catch {
        outcome.* = .{ .failed = "record: failed to encode " ++ library.recording.format_name ++ " audio\n" };
        return false;
    };

    // The encoder's finish flushes any trailer the format needs. The public
    // name is exposed only after that succeeds, so an interrupted run leaves
    // no corrupt recording behind.
    encoder.finish() catch {
        outcome.* = .{ .failed = "record: failed to finalize " ++ library.recording.format_name ++ " audio\n" };
        return false;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp_path, std.Io.Dir.cwd(), path, io) catch {
        outcome.* = .{ .failed = "record: failed to save " ++ library.recording.format_name ++ " audio\n" };
        return false;
    };
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        outcome.* = .{ .failed = "record: failed to write " ++ library.recording.format_name ++ " audio\n" };
        return false;
    };
    outcome.* = .{ .saved = .{ .dur_csec = dur_csec, .bytes = stat.size } };
    return true;
}

/// Where the live view stands on the alternate screen: the header sits on
/// row 1 (redrawn when the geometry changes, since it may wrap
/// differently), the status line, the waveform grid and its ruler below it.
const LiveView = struct {
    /// The header, composed with color, no trailing newline.
    header: []const u8,
    /// Display cells of the plain header text.
    header_cells: usize,
    /// Geometry the view was last drawn at; zero before the first draw.
    width: usize = 0,
    height: usize = 0,
};

/// Rows the recorder's chrome takes besides the header: the status line
/// and the ruler's two rows.
const chrome_rows = 3;

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    capture.requestStop();
}

fn installSigintHandler() void {
    // Windows has no SIGINT for console apps; Ctrl-C arrives as the 0x03
    // key byte (VT input) and the loop breaks on it like on ESC.
    if (@import("builtin").os.tag == .windows) return;
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
// Windows CRT: no _r functions — localtime fills a static buffer (fine;
// the record loop is single-threaded around this call).
extern "c" fn localtime(now: *const i64) ?*Tm;

fn localTime(now: *const i64, out: *Tm) bool {
    if (@import("builtin").os.tag == .windows) {
        const t = localtime(now) orelse return false;
        out.* = t.*;
        return true;
    }
    return localtime_r(now, out) != null;
}

/// "YYYYMMDD-HHMMSS" (15 bytes) from the local wall clock.
fn localTimestamp(out: *[15]u8) void {
    const now: i64 = time(null);
    var tm: Tm = undefined;
    if (!localTime(&now, &tm)) {
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
/// synchronized-update bracket — the header on row 1, the status line, the
/// waveform grid scrolling in from the right edge (the newest block is the
/// last column), and the time ruler under it. A geometry change erases the
/// screen and redraws the header, so whatever a resize did to the grid is
/// gone by this tick, and the single write keeps the view flicker-free. Off
/// a tty: a plain single line, carriage-returned over the previous one,
/// with a one-row strip of the wave as the meter.
fn printLiveView(
    io: std.Io,
    gpa: std.mem.Allocator,
    frame: *std.ArrayList(u8),
    secs: u32,
    paused: bool,
    blocks: []const waveform.Block,
    screen: *LiveView,
    tty: bool,
    color: bool,
) void {
    const size = waveform.termSize();
    const width = @min(size.cols, waveform.max_columns);
    var esc: [16]u8 = undefined;
    var line: [waveform.rowBufferLen(waveform.max_columns)]u8 = undefined;
    var columns: [waveform.max_columns]waveform.Column = undefined;

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
        const strip_width = width -| cells;
        const cols = waveform.layoutColumns(blocks, columns[0..strip_width], .tail);
        put(frame, gpa, waveform.renderStrip(cols, &line));
        printStderr(io, frame.items);
        return;
    }

    put(frame, gpa, live.sync_begin);

    const header_rows = live.rowsSpanned(screen.header_cells, width);
    const height = waveform.viewHeight(size.rows -| (header_rows + chrome_rows));
    if (width != screen.width or height != screen.height) {
        // Erase the whole previous view, then redraw the header; the rest
        // follows below it every tick.
        put(frame, gpa, live.clearScreen(&esc));
        put(frame, gpa, live.moveTo(&esc, 1, 1));
        put(frame, gpa, screen.header);
        screen.width = width;
        screen.height = height;
    }

    const status_row = 1 + header_rows;
    put(frame, gpa, live.moveTo(&esc, status_row, 1));
    put(frame, gpa, live.clearLine(&esc));
    var cells: usize = 0;
    put(frame, gpa, composeStatus(&line, secs, paused, color, &cells));

    const cols = waveform.layoutColumns(blocks, columns[0..width], .tail);
    var r: usize = 0;
    while (r < height) : (r += 1) {
        put(frame, gpa, live.moveTo(&esc, status_row + 1 + r, 1));
        put(frame, gpa, live.clearLine(&esc));
        put(frame, gpa, waveform.renderRow(cols, height, r, .{ .color = color }, &line));
    }

    // The ruler scrolls with the wave: the last column is the newest block,
    // so column 0 sits `width` blocks before it — before time zero while
    // the recording is younger than the grid is wide.
    const axis = ruler.Axis{
        .origin_ms = (@as(i64, @intCast(blocks.len)) - @as(i64, @intCast(width))) * @as(i64, waveform.peak_block_ms),
        .ms_per_col = @floatFromInt(waveform.peak_block_ms),
    };
    put(frame, gpa, live.moveTo(&esc, status_row + 1 + height, 1));
    put(frame, gpa, live.clearLine(&esc));
    if (color) put(frame, gpa, style.dim);
    put(frame, gpa, ruler.renderTicks(&line, width, axis));
    put(frame, gpa, live.moveTo(&esc, status_row + 2 + height, 1));
    put(frame, gpa, live.clearLine(&esc));
    put(frame, gpa, ruler.renderLabels(&line, width, axis));
    if (color) put(frame, gpa, style.reset);

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

// --- level tracker tests -----------------------------------------------------

// One full second of stereo s16 samples: 48000 frames x 2 channels.
const test_window_samples = 48000 * 2;
/// A constant amplitude whose RMS (-44.3 dBFS) matches the real dead
/// captures the warning exists for.
const test_quiet_amp: i16 = 200;
/// A clearly audible constant amplitude (-18.3 dBFS).
const test_loud_amp: i16 = 4000;

fn quietSeconds(sec: usize) ![]i16 {
    const buf = try std.testing.allocator.alloc(i16, sec * test_window_samples);
    @memset(buf, test_quiet_amp);
    return buf;
}

fn quietSecondsWithLoudWindow(sec: usize, loud_at: usize, loud_amp: i16) ![]i16 {
    const buf = try quietSeconds(sec);
    @memset(buf[loud_at * test_window_samples .. (loud_at + 1) * test_window_samples], loud_amp);
    return buf;
}

test "level tracker: a long all-quiet capture reads as dead" {
    const buf = try quietSeconds(11);
    defer std.testing.allocator.free(buf);

    var levels = LevelTracker.init(48000, 2);
    levels.add(std.mem.sliceAsBytes(buf));
    levels.finish();
    try std.testing.expect(levels.isDead());
    // -44.3 dBFS: the floor must sit far below real speech and above the wash.
    try std.testing.expect(levels.loudest_rms < audibility_floor);
}

test "level tracker: one audible second clears the dead verdict" {
    const buf = try quietSecondsWithLoudWindow(11, 6, test_loud_amp);
    defer std.testing.allocator.free(buf);

    var levels = LevelTracker.init(48000, 2);
    levels.add(std.mem.sliceAsBytes(buf));
    levels.finish();
    try std.testing.expect(!levels.isDead());
}

test "level tracker: short quiet recordings are not judged" {
    const buf = try quietSeconds(9);
    defer std.testing.allocator.free(buf);

    var levels = LevelTracker.init(48000, 2);
    levels.add(std.mem.sliceAsBytes(buf));
    levels.finish();
    try std.testing.expect(!levels.isDead());
}

test "level tracker: speech confined to the trailing partial second counts" {
    var levels = LevelTracker.init(48000, 2);
    const quiet = try quietSeconds(10);
    defer std.testing.allocator.free(quiet);
    levels.add(std.mem.sliceAsBytes(quiet));
    // A 0.6 s tail at full speech level: the recording must not read dead.
    const tail = try std.testing.allocator.alloc(i16, test_window_samples * 6 / 10);
    defer std.testing.allocator.free(tail);
    @memset(tail, test_loud_amp);
    levels.add(std.mem.sliceAsBytes(tail));
    levels.finish();
    try std.testing.expect(!levels.isDead());
}

test "level tracker: a quiet trailing partial stays dead" {
    var levels = LevelTracker.init(48000, 2);
    const quiet = try quietSeconds(10);
    defer std.testing.allocator.free(quiet);
    levels.add(std.mem.sliceAsBytes(quiet));
    levels.add(std.mem.sliceAsBytes(quiet[0 .. test_window_samples * 6 / 10]));
    levels.finish();
    try std.testing.expect(levels.isDead());
}
