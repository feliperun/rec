//! The local wall clock as `YYYYMMDDHHMMSS` digits: how recordings are
//! named, and the clock rec hands a device that names its own recordings.
//! libc time functions (libc is already linked for miniaudio) give local
//! time without dragging in tz parsing.

const std = @import("std");

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
// callers are single-threaded around this call).
extern "c" fn localtime(now: *const i64) ?*Tm;

fn localTime(now: *const i64, out: *Tm) bool {
    if (@import("builtin").os.tag == .windows) {
        const t = localtime(now) orelse return false;
        out.* = t.*;
        return true;
    }
    return localtime_r(now, out) != null;
}

/// The current local time as 14 digits; the epoch if libc cannot tell.
pub fn digits(out: *[14]u8) void {
    const now: i64 = time(null);
    var tm: Tm = undefined;
    if (!localTime(&now, &tm)) {
        @memcpy(out, "19700101000000");
        return;
    }
    const year: u32 = @intCast(@max(tm.year + 1900, 0));
    put2(out[0..2], year / 100);
    put2(out[2..4], year % 100);
    put2(out[4..6], @intCast(tm.mon + 1));
    put2(out[6..8], @intCast(tm.mday));
    put2(out[8..10], @intCast(tm.hour));
    put2(out[10..12], @intCast(tm.min));
    put2(out[12..14], @intCast(tm.sec));
}

fn put2(buf: []u8, v: u32) void {
    buf[0] = '0' + @as(u8, @intCast((v % 100) / 10));
    buf[1] = '0' + @as(u8, @intCast(v % 10));
}

test "the clock reads as 14 digits" {
    var out: [14]u8 = undefined;
    digits(&out);
    for (out) |c| try std.testing.expect(std.ascii.isDigit(c));
    try std.testing.expect(std.mem.startsWith(u8, &out, "20"));
}
