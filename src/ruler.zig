//! The time ruler under a waveform: a tick row (`┬` on a `─` line wherever
//! a round interval falls) and a label row with the time at each tick. The
//! axis maps columns to time, so the same ruler scrolls with a live
//! recording (a negative origin before the first block) and spans a whole
//! recording under the player. Pure; the views position the rows.

const std = @import("std");

/// How the columns map to time.
pub const Axis = struct {
    /// Time at column 0, in ms; negative when the view starts before the
    /// recording did (the recorder's scrolling window).
    origin_ms: i64,
    /// Milliseconds one column spans.
    ms_per_col: f64,
};

/// Round intervals between labeled ticks, in ms.
const intervals_ms = [_]u32{
    1_000,   2_000,   5_000,   10_000,  15_000,    30_000,    60_000,
    120_000, 300_000, 600_000, 900_000, 1_800_000, 3_600_000,
};

/// Columns between ticks so the labels ("1:02:03" at most) never touch.
const min_tick_cols: f64 = 12;

/// The smallest round interval whose ticks sit at least `min_tick_cols`
/// apart at `ms_per_col`.
pub fn tickInterval(ms_per_col: f64) u32 {
    for (intervals_ms) |i| {
        if (@as(f64, @floatFromInt(i)) / ms_per_col >= min_tick_cols) return i;
    }
    return intervals_ms[intervals_ms.len - 1];
}

/// The column time `t_ms` falls in, or null outside the width.
fn columnOf(axis: Axis, width: usize, t_ms: i64) ?usize {
    const c = @floor(@as(f64, @floatFromInt(t_ms - axis.origin_ms)) / axis.ms_per_col + 1e-6);
    if (c < 0 or c >= @as(f64, @floatFromInt(width))) return null;
    return @intFromFloat(c);
}

/// The first tick at or after the view's start (never before time zero).
fn firstTick(axis: Axis, interval: u32) i64 {
    const start = @max(axis.origin_ms, 0);
    const i: i64 = interval;
    return @divFloor(start + i - 1, i) * i;
}

/// Bytes the tick row needs: three per column.
pub fn ticksBufferLen(width: usize) usize {
    return width * 3;
}

/// The tick row: `─` across the width with `┬` under each round interval.
pub fn renderTicks(buf: []u8, width: usize, axis: Axis) []const u8 {
    const interval = tickInterval(axis.ms_per_col);
    var n: usize = 0;
    var col: usize = 0;
    var t = firstTick(axis, interval);
    var next_tick = columnOf(axis, width, t);
    while (col < width) : (col += 1) {
        const tick = next_tick != null and next_tick.? == col;
        n = appendStr(buf, n, if (tick) "┬" else "─");
        if (tick) {
            t += interval;
            next_tick = columnOf(axis, width, t);
        }
    }
    return buf[0..n];
}

/// The label row: the time of each tick starting under it, left-aligned;
/// labels that would run past the width or into the previous label are
/// skipped. Trailing space is trimmed. `buf` must fit `width` bytes.
pub fn renderLabels(buf: []u8, width: usize, axis: Axis) []const u8 {
    const interval = tickInterval(axis.ms_per_col);
    @memset(buf[0..width], ' ');
    var end: usize = 0;
    var t = firstTick(axis, interval);
    while (columnOf(axis, width, t)) |col| : (t += interval) {
        var label: [16]u8 = undefined;
        const text = fmtTime(&label, t);
        if (col < end or col + text.len > width) continue;
        @memcpy(buf[col .. col + text.len], text);
        end = col + text.len + 1;
    }
    return buf[0..end -| 1];
}

/// "M:SS" under an hour, "H:MM:SS" past it.
fn fmtTime(buf: []u8, t_ms: i64) []const u8 {
    const total: u64 = @intCast(@divFloor(@max(t_ms, 0), 1000));
    const h = total / 3600;
    const m = (total / 60) % 60;
    const s = total % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ total / 60, s }) catch buf[0..0];
}

fn appendStr(buf: []u8, n: usize, s: []const u8) usize {
    const end = n + s.len;
    @memcpy(buf[n..end], s);
    return end;
}

// --- tests ---------------------------------------------------------------------

test "tickInterval picks the first round interval with room for labels" {
    try std.testing.expectEqual(@as(u32, 1_000), tickInterval(43.8)); // 6 s over 137 cols
    try std.testing.expectEqual(@as(u32, 2_000), tickInterval(100)); // the recorder: 10 cols/s
    try std.testing.expectEqual(@as(u32, 15_000), tickInterval(1_000));
    try std.testing.expectEqual(@as(u32, 300_000), tickInterval(20_000)); // 40 min over 120 cols
    try std.testing.expectEqual(@as(u32, 3_600_000), tickInterval(1_000_000)); // never denser than an hour
}

test "renderTicks marks every interval across the width" {
    var buf: [ticksBufferLen(40)]u8 = undefined;
    // Ten seconds over forty columns: a tick every 5 s (2 s would be 8 cols).
    const axis = Axis{ .origin_ms = 0, .ms_per_col = 250 };
    try std.testing.expectEqualStrings(
        "┬" ++ ("─" ** 19) ++ "┬" ++ ("─" ** 19),
        renderTicks(&buf, 40, axis),
    );
}

test "renderLabels writes each tick's time under it" {
    var buf: [40]u8 = undefined;
    const axis = Axis{ .origin_ms = 0, .ms_per_col = 250 };
    try std.testing.expectEqualStrings("0:00" ++ (" " ** 16) ++ "0:05", renderLabels(&buf, 40, axis));
}

test "a scrolling axis starts its ticks at time zero" {
    // The recorder 1.5 s in on a 40-column grid at 100 ms/col: columns 0..14
    // are before the recording started, 0:00 lands on column 15 and the
    // 2 s tick on column 35.
    var ticks: [ticksBufferLen(40)]u8 = undefined;
    var labels: [40]u8 = undefined;
    const axis = Axis{ .origin_ms = -1500, .ms_per_col = 100 };
    try std.testing.expectEqualStrings(
        ("─" ** 15) ++ "┬" ++ ("─" ** 19) ++ "┬" ++ ("─" ** 4),
        renderTicks(&ticks, 40, axis),
    );
    try std.testing.expectEqualStrings((" " ** 15) ++ "0:00" ++ (" " ** 16) ++ "0:02", renderLabels(&labels, 40, axis));
}

test "renderLabels skips a label that would run past the width" {
    var labels: [40]u8 = undefined;
    // The 2 s tick lands on column 37: "0:02" would need column 40.
    const axis = Axis{ .origin_ms = -1700, .ms_per_col = 100 };
    try std.testing.expectEqualStrings((" " ** 17) ++ "0:00", renderLabels(&labels, 40, axis));
}

test "fmtTime spells minutes and hours" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:00", fmtTime(&buf, 0));
    try std.testing.expectEqualStrings("1:05", fmtTime(&buf, 65_000));
    try std.testing.expectEqualStrings("10:00", fmtTime(&buf, 600_000));
    try std.testing.expectEqualStrings("1:02:03", fmtTime(&buf, 3_723_000));
}
