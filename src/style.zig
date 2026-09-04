//! ANSI styling for the terminal views: plain 16-color SGR codes that follow
//! the terminal theme, decided per output stream — colors only for a tty
//! that did not opt out through NO_COLOR, so piped output stays plain for
//! scripts. Callers compose into buffers; every styled piece is the code +
//! text + reset, or the bare text when styling is off.

const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const cyan = "\x1b[36m";

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// The value of `name` in the environment, null when unset or empty
/// (libc getenv — libc is already linked; see llm.envValue).
fn envValue(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return s;
}

/// Colors belong on `file` when it is a terminal that did not opt out
/// through NO_COLOR.
pub fn detect(io: std.Io, file: std.Io.File) bool {
    const tty = file.isTty(io) catch false;
    return enabled(tty, envValue("NO_COLOR"));
}

/// The pure decision behind `detect`: NO_COLOR opts out at any value.
pub fn enabled(is_tty: bool, no_color: ?[]const u8) bool {
    return is_tty and no_color == null;
}

/// Opens `code` when styling is on; pair with `end`.
pub fn begin(buf: []u8, n: *usize, on: bool, code: []const u8) void {
    if (on) appendStr(buf, n, code);
}

/// Closes a `begin`, back to the default attributes.
pub fn end(buf: []u8, n: *usize, on: bool) void {
    if (on) appendStr(buf, n, reset);
}

/// Wraps `text` in `code` when styling is on; the bare text otherwise.
pub fn appendStyled(buf: []u8, n: *usize, on: bool, code: []const u8, text: []const u8) void {
    begin(buf, n, on, code);
    appendStr(buf, n, text);
    end(buf, n, on);
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

test "enabled is a tty that did not set NO_COLOR" {
    try std.testing.expect(enabled(true, null));
    try std.testing.expect(!enabled(false, null));
    // Any present value opts out; detect() normalizes an empty NO_COLOR to
    // null first, so it never reaches here.
    try std.testing.expect(!enabled(true, "1"));
    try std.testing.expect(!enabled(true, ""));
}

test "appendStyled wraps only when on" {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    appendStyled(&buf, &n, false, red, "hi");
    try std.testing.expectEqualStrings("hi", buf[0..n]);

    n = 0;
    appendStyled(&buf, &n, true, red, "hi");
    try std.testing.expectEqualStrings("\x1b[31mhi\x1b[0m", buf[0..n]);
}
