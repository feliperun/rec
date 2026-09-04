//! In-place redraw of a small block of live lines (the recorder's one-line
//! meter, the player's status + waveform): the cursor is moved back onto the
//! first row of the previously drawn block, erasing every row that block
//! wraps across under the *current* terminal width, so a resize cannot
//! garble the view. The row math is pure; I/O stays with the callers.

const std = @import("std");

/// Rows a line of `cols` display columns occupies on a terminal `term_cols`
/// columns wide: the row holding its last column, counting each full-width
/// chunk as a wrap. An exact multiple does not add a row — the cursor stays
/// on the last row in pending-wrap state until a further column forces it.
/// Always at least one row: even an empty line is a row the cursor sits on.
pub fn rowsSpanned(cols: usize, term_cols: usize) usize {
    if (term_cols == 0 or cols == 0) return 1;
    return (cols - 1) / term_cols + 1;
}

/// Escapes moving the cursor from the end of a drawn block back onto its
/// first row, clearing every row the block occupies on a terminal
/// `term_cols` columns wide. `lines` holds each drawn line's display
/// columns, top to bottom (a one-line block is a one-element slice). The
/// next draw then starts on a clean slate at the new width.
pub fn eraseSequence(buf: []u8, lines: []const usize, term_cols: usize) []const u8 {
    if (lines.len == 0) return "";
    var n: usize = 0;
    appendStr(buf, &n, "\r"); // col 1 of the row the cursor is on
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        // Clear upward through the rows this line wraps across.
        for (1..rowsSpanned(lines[i], term_cols)) |_| {
            appendStr(buf, &n, "\x1b[2K\x1b[1A");
        }
        appendStr(buf, &n, "\x1b[2K");
        // Climb onto the previous line's last row (written before a \n).
        if (i > 0) appendStr(buf, &n, "\x1b[1A");
    }
    return buf[0..n];
}

/// The lines a caller currently has on screen, so the next draw can erase
/// the whole block (see `erase`). Callers push one display width per line
/// as they draw it.
pub const Block = struct {
    lines: [4]usize = .{0} ** 4,
    len: usize = 0,

    /// Records a drawn line of `cols` display columns.
    pub fn push(self: *Block, cols: usize) void {
        if (self.len < self.lines.len) {
            self.lines[self.len] = cols;
            self.len += 1;
        }
    }

    /// Emits the escapes erasing everything on screen; the block empties.
    pub fn erase(self: *Block, term_cols: usize, buf: []u8) []const u8 {
        const out = eraseSequence(buf, self.lines[0..self.len], term_cols);
        self.len = 0;
        return out;
    }
};

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

test "rowsSpanned wraps once per full terminal width" {
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(0, 80));
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(79, 80));
    // An exact multiple stays on its own row: pending wrap, not a new one.
    try std.testing.expectEqual(@as(usize, 1), rowsSpanned(80, 80));
    try std.testing.expectEqual(@as(usize, 3), rowsSpanned(123, 41));
    try std.testing.expectEqual(@as(usize, 4), rowsSpanned(124, 41));
}

test "eraseSequence clears the current line in place" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\r\x1b[2K", eraseSequence(&buf, &.{12}, 80));
}

test "eraseSequence climbs the rows a line wraps across after a shrink" {
    var buf: [64]u8 = undefined;
    // A 120-column draw on a now-50-column terminal spans three rows.
    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K", eraseSequence(&buf, &.{120}, 50));
}

test "eraseSequence walks a multi-line block bottom-up" {
    var buf: [64]u8 = undefined;
    // Status + bar, neither wrapping: clear, up once, clear.
    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[1A\x1b[2K", eraseSequence(&buf, &.{ 30, 79 }, 80));
    // The bottom line wrapping into three rows adds its clears before the
    // climb to the top line.
    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K", eraseSequence(&buf, &.{ 30, 120 }, 50));
}

test "Block tracks drawn lines and erases nothing before the first" {
    var buf: [64]u8 = undefined;
    var block: Block = .{};
    try std.testing.expectEqualStrings("", block.erase(80, &buf)); // nothing drawn

    block.push(30);
    block.push(120);
    try std.testing.expectEqualStrings(
        "\r\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K",
        block.erase(50, &buf),
    );
    // After the erase the slate is clean again.
    try std.testing.expectEqualStrings("", block.erase(50, &buf));
}
