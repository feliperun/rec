const std = @import("std");
const capture = @import("capture.zig");
const library = @import("library.zig");

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
