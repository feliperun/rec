//! Waveform rendering: incremental peaks over interleaved s16le PCM and a
//! multi-row Unicode grid — half-block glyphs pack two half-rows of
//! resolution into every character row, symmetric around the grid's middle —
//! plus the terminal width the grid is drawn to. Pure computation is kept
//! free of I/O so every behavior is testable offline.

const std = @import("std");
const style = @import("style.zig");

/// Absolute sample amplitude (0..32768) of one PCM block.
pub const Peak = u16;

/// Full-scale amplitude of an s16 sample, the ceiling of a Peak.
pub const full_scale: Peak = 32768;

/// One hundred ms of audio per peak: plenty of resolution for a terminal
/// grid, tiny enough to compute incrementally while recording.
pub const peak_block_ms: u64 = 100;

/// PCM bytes that make up one peak block at `byte_rate` bytes of audio per
/// second; never zero.
pub fn peakBlockBytes(byte_rate: u64) usize {
    return @intCast(@max(byte_rate * peak_block_ms / 1000, 1));
}

/// Character rows of the waveform grid: tall enough that the half-block
/// cells read as a real waveform (2·height levels per column), short enough
/// to leave the status and note rows room on a 24-row terminal.
pub const view_height: usize = 10;

/// Columns the grid renderer is built for; wider terminals clamp to this.
pub const max_columns: usize = 512;

/// Stack bytes a `renderRow` call needs: a worst-case SGR transition plus
/// a three-byte glyph per column, plus the trailing reset.
pub fn rowBufferLen(columns: usize) usize {
    return columns * 12 + 16;
}

/// Incremental peak accumulator: `feed` the PCM bytes as they arrive (in any
/// frame-aligned chunks) and read `peaks` — one absolute amplitude per
/// `block_bytes` of audio.
pub const PeakTracker = struct {
    gpa: std.mem.Allocator,
    /// One peak per completed block.
    peaks: std.ArrayList(Peak),
    /// PCM bytes that make up one block.
    block_bytes: usize,
    /// Bytes and running peak of the block being filled.
    partial_bytes: usize,
    partial_peak: Peak,

    pub fn init(gpa: std.mem.Allocator, block_bytes: usize) PeakTracker {
        return .{
            .gpa = gpa,
            .peaks = .empty,
            .block_bytes = block_bytes,
            .partial_bytes = 0,
            .partial_peak = 0,
        };
    }

    pub fn deinit(self: *PeakTracker) void {
        self.peaks.deinit(self.gpa);
    }

    /// Absorbs `pcm` (a frame-aligned slice of interleaved s16le samples,
    /// any channel count) into the peak list.
    pub fn feed(self: *PeakTracker, pcm: []const u8) void {
        var off: usize = 0;
        while (off < pcm.len) {
            const remaining = self.block_bytes - self.partial_bytes;
            const take = @min(remaining, pcm.len - off);
            self.partial_peak = @max(self.partial_peak, slicePeak(pcm[off .. off + take]));
            self.partial_bytes += take;
            off += take;
            if (self.partial_bytes == self.block_bytes) {
                self.peaks.append(self.gpa, self.partial_peak) catch {
                    // Out of memory: drop the block rather than the recording.
                    // Reset the partial state so the next feed stays aligned.
                    self.partial_bytes = 0;
                    self.partial_peak = 0;
                    continue;
                };
                self.partial_bytes = 0;
                self.partial_peak = 0;
            }
        }
    }

    /// The completed peaks plus the block currently being filled, so an
    /// in-progress tail is visible while recording. Returns a view into
    /// `out`; when there is no partial block, `out` simply mirrors `peaks`.
    pub fn view(self: *const PeakTracker, out: *std.ArrayList(Peak)) std.mem.Allocator.Error![]Peak {
        out.clearRetainingCapacity();
        try out.appendSlice(self.gpa, self.peaks.items);
        if (self.partial_bytes > 0) try out.append(self.gpa, self.partial_peak);
        return out.items;
    }
};

/// Absolute amplitude (max |sample|) of an interleaved s16le slice, over
/// every channel. Trailing bytes short of a full sample are ignored.
fn slicePeak(pcm: []const u8) Peak {
    var peak: Peak = 0;
    var off: usize = 0;
    while (off + 2 <= pcm.len) : (off += 2) {
        const sample = std.mem.readInt(i16, pcm[off..][0..2], .little);
        const mag: Peak = @intCast(@abs(@as(i32, sample)));
        peak = @max(peak, mag);
    }
    return peak;
}

/// A contiguous run of grid columns marked for cutting, inclusive of both ends.
pub const SelRange = struct {
    start_col: usize,
    end_col: usize,
};

/// The perceived amplitude of one displayed column: the square root of the
/// peak, scaled to 0..255. Speech sits far below full scale, so the sqrt
/// keeps quiet passages shaped instead of flatlining the grid.
fn fractionOf(peak: Peak) u8 {
    const frac = std.math.sqrt(@as(f64, @floatFromInt(peak)) / @as(f64, full_scale));
    return @intFromFloat(@min(frac * 255.0 + 0.5, 255.0));
}

/// Compresses `peaks` into one fraction per displayed column (at most
/// `out.len`): more peaks than columns takes the max of each column's
/// slice, fewer grows the waveform from the left over silence. Returns the
/// used slice of `out`.
pub fn columnFractions(peaks: []const Peak, out: []u8) []u8 {
    const width = out.len;
    var col: usize = 0;
    while (col < width) : (col += 1) {
        var peak: Peak = 0;
        if (peaks.len <= width) {
            if (col < peaks.len) peak = peaks[col];
        } else {
            const start = col * peaks.len / width;
            const end = (col + 1) * peaks.len / width;
            for (peaks[start..end]) |p| peak = @max(peak, p);
        }
        out[col] = fractionOf(peak);
    }
    return out[0..width];
}

/// How one grid row treats the audio: where playback has reached, the
/// marked span, the playhead column, and whether VU colors are on.
pub const RowStyle = struct {
    /// Columns at and past this one draw dim (not yet played); maxInt
    /// keeps a whole grid bright, which is how the live recording draws.
    played_cols: usize = std.math.maxInt(usize),
    /// Columns shown in reverse video (the marked span).
    sel: ?SelRange = null,
    /// The playhead column: a full-height bright bar over the audio.
    cursor_col: ?usize = null,
    /// VU-meter colors (dim silence, green quiet, yellow mid, red loud).
    color: bool = false,
};

/// Renders character row `row` (0..height-1) of the waveform grid into
/// `out` and returns the written slice. Every cell packs two half-rows of
/// resolution around the grid's middle: '█' fills both, '▀' the top,
/// '▄' the bottom, ' ' neither. The cursor column draws as a full-height
/// bar in bright white; a marked span reverses its columns; dim covers
/// everything at or past `played_cols`. SGR escapes are emitted only on
/// transitions, and always reset at the end when one was emitted. `out`
/// must fit rowBufferLen(fractions.len).
pub fn renderRow(fractions: []const u8, height: usize, row: usize, opts: RowStyle, out: []u8) []const u8 {
    var n: usize = 0;
    var cur: []const u8 = ""; // the SGR sequence in effect, "" = default
    var col: usize = 0;
    while (col < fractions.len) : (col += 1) {
        const is_cursor = opts.cursor_col != null and opts.cursor_col.? == col;
        const in_sel = if (opts.sel) |s| s.start_col <= col and col <= s.end_col else false;
        const want: []const u8 = if (is_cursor)
            style.white
        else if (in_sel)
            "\x1b[7m"
        else if (col >= opts.played_cols)
            style.dim
        else if (opts.color) levelSgr(fractions[col])
        else "";
        if (!std.mem.eql(u8, want, cur)) {
            if (cur.len > 0) n = appendStr(out, n, style.reset);
            if (want.len > 0) n = appendStr(out, n, want);
            cur = want;
        }
        n = appendStr(out, n, cellGlyph(fractions[col], height, row, is_cursor));
    }
    if (cur.len > 0) n = appendStr(out, n, style.reset);
    return out[0..n];
}

/// The VU ramp for a fraction: silence barely visible, loudness red.
fn levelSgr(fraction: u8) []const u8 {
    return switch (@as(u16, fraction) * 8 / 256) {
        0 => style.dim,
        1...3 => style.green,
        4...5 => style.yellow,
        else => style.red,
    };
}

/// The glyph at one cell: the column's extent in half-rows — the square
/// root-scaled fraction of the `2·height` half-rows, centered on the
/// grid's middle — intersected with this row's top and bottom half. The
/// cursor overrides the shape and fills the whole column.
fn cellGlyph(fraction: u8, height: usize, row: usize, cursor: bool) []const u8 {
    if (cursor) return "█";
    const extent: usize = @intFromFloat(
        @as(f64, @floatFromInt(fraction)) / 255.0 * @as(f64, @floatFromInt(height)) + 0.5,
    );
    const start = height - extent;
    const end = height + extent;
    const top = 2 * row;
    const bottom = top + 1;
    const in_top = top >= start and top < end;
    const in_bottom = bottom >= start and bottom < end;
    if (in_top and in_bottom) return "█";
    if (in_top) return "▀";
    if (in_bottom) return "▄";
    return " ";
}

fn appendStr(buf: []u8, n: usize, s: []const u8) usize {
    const end = n + s.len;
    @memcpy(buf[n..end], s);
    return end;
}

// --- terminal geometry -------------------------------------------------------

const Winsize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16,
    ypixel: u16,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// TIOCGWINSZ on macOS.
const tiocgwinsz: c_ulong = 0x40087468;

/// Columns available for a grid drawn on stderr; one column is kept in
/// reserve so the lines do not wrap on terminals that auto-scroll, and 79
/// is the fallback when the ioctl says nothing.
pub fn termWidth() usize {
    var ws: Winsize = .{ .rows = 0, .cols = 0, .xpixel = 0, .ypixel = 0 };
    if (ioctl(2, tiocgwinsz, &ws) == 0 and ws.cols >= 2) return ws.cols - 1;
    return 79;
}

// --- tests --------------------------------------------------------------------

/// Writes `buf.len / 4` stereo frames alternating ±amp, the capture layout.
fn stereoFrames(buf: []u8, amp: i16) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        const s: i16 = if ((i / 4) % 2 == 0) amp else -amp;
        std.mem.writeInt(i16, buf[i..][0..2], s, .little);
        std.mem.writeInt(i16, buf[i + 2 ..][0..2], s, .little);
    }
}

test "peak tracker blocks amplitudes per block_bytes of pcm" {
    // 8 bytes per block = 2 stereo frames; the partial tail stays visible.
    var t = PeakTracker.init(std.testing.allocator, 8);
    defer t.deinit();

    var block: [8]u8 = undefined;
    stereoFrames(&block, 100);
    t.feed(&block);
    stereoFrames(&block, 200);
    t.feed(&block);
    stereoFrames(&block, 300);
    t.feed(&block);

    // A half block at ±400: not a completed peak yet, but view() shows it.
    stereoFrames(block[0..4], 400);
    t.feed(block[0..4]);

    var out: std.ArrayList(Peak) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Peak, &.{ 100, 200, 300, 400 }, try t.view(&out));
}

test "peak tracker feeds may split a block across chunks" {
    var t = PeakTracker.init(std.testing.allocator, 8);
    defer t.deinit();

    var block: [8]u8 = undefined;
    stereoFrames(&block, 250);
    t.feed(block[0..4]); // chunks may split blocks, not samples
    t.feed(block[4..8]);

    var out: std.ArrayList(Peak) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Peak, &.{250}, try t.view(&out));
}

test "peakBlockBytes is a hundred ms of audio" {
    try std.testing.expectEqual(@as(usize, 19200), peakBlockBytes(192000)); // 48 kHz stereo
    try std.testing.expectEqual(@as(usize, 1), peakBlockBytes(0)); // never zero
}

test "columnFractions compresses by max and pads with silence" {
    var out: [20]u8 = undefined;
    // Full-scale first, then silence: the wave grows from the left.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0 }, columnFractions(&.{full_scale}, out[0..4]));

    // Twenty peaks alternating silence and half-scale: sqrt(0.5) ≈ 180.
    var peaks: [20]Peak = undefined;
    for (&peaks, 0..) |*p, i| p.* = if (i % 2 == 1) 16384 else 0;
    const f = columnFractions(&peaks, out[0..10]);
    try std.testing.expectEqual(@as(usize, 10), f.len);
    for (f) |v| try std.testing.expectEqual(@as(u8, 180), v);

    // Nothing recorded yet: an all-silence grid.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, columnFractions(&.{}, out[0..3]));
}

test "columnFractions scales peaks perceptually" {
    var out: [3]u8 = undefined;
    // A quarter-amplitude peak reads as half of the grid: sqrt(0.25) = 0.5.
    const f = columnFractions(&.{ 0, 8192, 32768 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255 }, f);
}

test "renderRow shapes the wave around the middle with half-blocks" {
    var buf: [rowBufferLen(6)]u8 = undefined;
    // Fractions 0, 64, 128, 191, 255 on a 10-row grid: extents 0, 3, 5, 7,
    // 10 half-rows around the middle.
    const f = [_]u8{ 0, 64, 128, 191, 255 };
    // Middle row: every nonzero column is inside its extent.
    try std.testing.expectEqualStrings(" ████", renderRow(&f, 10, 5, .{}, &buf));
    // Near the top only the loud columns reach (bottom half of the row).
    try std.testing.expectEqualStrings("   ▄█", renderRow(&f, 10, 1, .{}, &buf));
    // Near the bottom, mirrored: the loud tail's top half.
    try std.testing.expectEqualStrings("   ▀█", renderRow(&f, 10, 8, .{}, &buf));
}

test "renderRow draws silence as blank space" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const silence = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectEqualStrings("    ", renderRow(&silence, 10, 3, .{}, &buf));
}

test "renderRow draws the cursor as a full-height column" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const f = [_]u8{ 255, 0 };
    // The playhead fills its column even where the audio is silent — in
    // bright white, so it stays visible under NO_COLOR too.
    try std.testing.expectEqualStrings(
        "█\x1b[97m█\x1b[0m",
        renderRow(&f, 3, 1, .{ .cursor_col = 1 }, &buf),
    );
    try std.testing.expectEqualStrings(
        "█\x1b[97m█\x1b[0m",
        renderRow(&f, 3, 0, .{ .cursor_col = 1 }, &buf),
    );
    // Without the cursor, row 1 shows the full column and the silence.
    try std.testing.expectEqualStrings("█ ", renderRow(&f, 3, 1, .{}, &buf));
}

test "renderRow dims columns at and past the played position" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    const f = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expectEqualStrings("██\x1b[2m██\x1b[0m", renderRow(&f, 1, 0, .{ .played_cols = 2 }, &buf));

    // Nothing played: the whole row is dim; everything played: no escapes.
    try std.testing.expectEqualStrings("\x1b[2m████\x1b[0m", renderRow(&f, 1, 0, .{ .played_cols = 0 }, &buf));
    try std.testing.expectEqualStrings("████", renderRow(&f, 1, 0, .{ .played_cols = 4 }, &buf));
}

test "renderRow shows the marked span in reverse video" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    const f = [_]u8{ 255, 255, 255, 255 };

    // A middle mark reverses its columns; the rest stays plain.
    try std.testing.expectEqualStrings(
        "█\x1b[7m██\x1b[0m█",
        renderRow(&f, 1, 0, .{ .sel = .{ .start_col = 1, .end_col = 2 } }, &buf),
    );
    // The cursor wins over the mark.
    try std.testing.expectEqualStrings(
        "\x1b[97m█\x1b[0m\x1b[7m█\x1b[0m██",
        renderRow(&f, 1, 0, .{ .cursor_col = 0, .sel = .{ .start_col = 0, .end_col = 1 } }, &buf),
    );
}

test "renderRow colors the levels as a VU meter when color is on" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    // 10, 100, 140, 200, 255 → dim, green, yellow, then two reds.
    const f = [_]u8{ 10, 100, 140, 200, 255 };
    try std.testing.expectEqualStrings(
        "\x1b[2m \x1b[0m\x1b[32m▄\x1b[0m\x1b[33m▄\x1b[0m\x1b[31m██\x1b[0m",
        renderRow(&f, 2, 0, .{ .color = true }, &buf),
    );
}

test "renderRow keeps the same width with and without color" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    var plain: [rowBufferLen(8)]u8 = undefined;
    const f = [_]u8{ 10, 100, 140, 200, 255 };
    const plain_row = renderRow(&f, 2, 0, .{}, &plain);
    const colored = renderRow(&f, 2, 0, .{ .color = true }, &buf);
    // Escapes carry no display width: strip them and the rows agree.
    try std.testing.expectEqual(plain_row.len + escapeBytes(colored), colored.len);
}

/// Total bytes of SGR escapes in `s`.
fn escapeBytes(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            while (i < s.len) {
                const c = s[i];
                i += 1;
                count += 1;
                if (c == 'm') break;
            }
            continue;
        }
        i += 1;
    }
    return count;
}
