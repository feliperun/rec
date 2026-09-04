//! Full-viewport redraw of the live views (the recorder's meter, the
//! player's status + waveform) on the terminal's alternate screen. Every
//! tick positions the cursor absolutely (CUP) and rewrites its rows in
//! place, so a resize — whatever the terminal does to the grid on reflow —
//! is corrected by the next tick, and the user's scrollback stays clean.
//! The row math is pure; I/O stays with the callers.

const std = @import("std");

/// Enters the alternate screen and homes the cursor on a cleared viewport.
pub fn enter(buf: []u8) []const u8 {
    return buf[0..append(buf, "\x1b[?1049h\x1b[H\x1b[2J", 0)];
}

/// Leaves the alternate screen, restoring the view the process started with.
pub fn leave(buf: []u8) []const u8 {
    return buf[0..append(buf, "\x1b[?1049l", 0)];
}

/// Absolute cursor position (1-based row and column).
pub fn moveTo(buf: []u8, row: usize, col: usize) []const u8 {
    var n: usize = append(buf, "\x1b[", 0);
    n = appendUint(buf, row, n);
    n = append(buf, ";", n);
    n = appendUint(buf, col, n);
    return buf[0..append(buf, "H", n)];
}

/// Erases the whole cursor row.
pub fn clearLine(buf: []u8) []const u8 {
    return buf[0..append(buf, "\x1b[2K", 0)];
}

/// Rows a line of `cols` display columns occupies on a terminal `term_cols`
/// columns wide: the row holding its last column, counting each full-width
/// chunk as a wrap. An exact multiple does not add a row — the cursor stays
/// on the last row in pending-wrap state until a further column forces it.
/// Always at least one row: even an empty line is a row the cursor sits on.
/// Tells where a line drawn at column 1 ends, so the next one can be
/// positioned below it.
pub fn rowsSpanned(cols: usize, term_cols: usize) usize {
    if (term_cols == 0 or cols == 0) return 1;
    return (cols - 1) / term_cols + 1;
}

fn append(buf: []u8, s: []const u8, n: usize) usize {
    @memcpy(buf[n .. n + s.len], s);
    return n + s.len;
}

fn appendUint(buf: []u8, v: usize, n: usize) usize {
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var x = v;
    while (x > 0) {
        tmp[len] = '0' + @as(u8, @intCast(x % 10));
        len += 1;
        x /= 10;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[n + i] = tmp[len - 1 - i];
    }
    return n + len;
}

test "rowsSpanned wraps once per full terminal width" {
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(0, 80));
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(79, 80));
    // An exact multiple stays on its own row: pending wrap, not a new one.
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(80, 80));
    try std.testing.expectEqual(@as(usize, 3), rowsSpanned(123, 41));
    try std.testing.expectEqual(@as(usize, 4), rowsSpanned(124, 41));
}

test "alt screen and cursor positioning sequences" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[H\x1b[2J", enter(&buf));
    try std.testing.expectEqualStrings("\x1b[?1049l", leave(&buf));
    try std.testing.expectEqualStrings("\x1b[2K", clearLine(&buf));
    try std.testing.expectEqualStrings("\x1b[1;1H", moveTo(&buf, 1, 1));
    try std.testing.expectEqualStrings("\x1b[12;34H", moveTo(&buf, 12, 34));
}
