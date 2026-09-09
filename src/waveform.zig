//! Waveform rendering: peak and RMS per 100 ms block of interleaved s16le
//! PCM, laid out into terminal columns, and drawn as a layered scope.
//! Eighth-block glyphs give every character row eight levels of
//! resolution, mirrored around the grid's midline; the RMS core sits bright
//! inside the dimmer peak halo, and the rows are colored by height as a VU
//! ramp. Pure computation, kept free of I/O so every behavior is testable
//! offline; the terminal geometry probe at the bottom is the one exception.

const std = @import("std");

/// Absolute sample amplitude (0..32768).
pub const Amplitude = u16;

/// Full-scale amplitude of an s16 sample, the ceiling of an Amplitude.
pub const full_scale: Amplitude = 32768;

/// One hundred ms of audio per block: plenty of resolution for a terminal
/// grid, tiny enough to compute incrementally while recording, and one
/// column per tick when the recorder scrolls.
pub const peak_block_ms: u64 = 100;

/// PCM bytes that make up one block at `byte_rate` bytes of audio per
/// second; never zero.
pub fn peakBlockBytes(byte_rate: u64) usize {
    return @intCast(@max(byte_rate * peak_block_ms / 1000, 1));
}

/// One block of audio: its peak (the outer envelope) and its RMS (the
/// energy inside it).
pub const Block = struct {
    peak: Amplitude,
    rms: Amplitude,
};

/// Incremental block accumulator: `feed` the PCM bytes as they arrive (in
/// any frame-aligned chunks) and read `blocks` — one peak/RMS pair per
/// `block_bytes` of audio.
pub const Tracker = struct {
    gpa: std.mem.Allocator,
    /// One entry per completed block.
    blocks: std.ArrayList(Block),
    /// PCM bytes that make up one block.
    block_bytes: usize,
    /// The block being filled: bytes so far, its running peak, and the sum
    /// of squares over its samples (u64 holds 2^31 full-scale squares).
    partial_bytes: usize,
    partial_peak: Amplitude,
    partial_sum_sq: u64,
    partial_samples: usize,

    pub fn init(gpa: std.mem.Allocator, block_bytes: usize) Tracker {
        return .{
            .gpa = gpa,
            .blocks = .empty,
            .block_bytes = block_bytes,
            .partial_bytes = 0,
            .partial_peak = 0,
            .partial_sum_sq = 0,
            .partial_samples = 0,
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.blocks.deinit(self.gpa);
    }

    /// Absorbs `pcm` (a frame-aligned slice of interleaved s16le samples,
    /// any channel count) into the block list.
    pub fn feed(self: *Tracker, pcm: []const u8) void {
        var off: usize = 0;
        while (off < pcm.len) {
            const remaining = self.block_bytes - self.partial_bytes;
            const take = @min(remaining, pcm.len - off);
            const stats = sliceStats(pcm[off .. off + take]);
            self.partial_peak = @max(self.partial_peak, stats.peak);
            self.partial_sum_sq += stats.sum_sq;
            self.partial_samples += stats.samples;
            self.partial_bytes += take;
            off += take;
            if (self.partial_bytes == self.block_bytes) {
                // Out of memory drops the block rather than the recording;
                // the partial state resets either way so feeds stay aligned.
                self.blocks.append(self.gpa, self.partialBlock()) catch {};
                self.resetPartial();
            }
        }
    }

    /// The completed blocks plus the block currently being filled, so an
    /// in-progress tail is visible while recording. Returns a view into
    /// `out`; when there is no partial block, `out` simply mirrors `blocks`.
    pub fn view(self: *const Tracker, out: *std.ArrayList(Block)) std.mem.Allocator.Error![]Block {
        out.clearRetainingCapacity();
        try out.appendSlice(self.gpa, self.blocks.items);
        if (self.partial_bytes > 0) try out.append(self.gpa, self.partialBlock());
        return out.items;
    }

    fn partialBlock(self: *const Tracker) Block {
        return .{ .peak = self.partial_peak, .rms = rmsOf(self.partial_sum_sq, self.partial_samples) };
    }

    fn resetPartial(self: *Tracker) void {
        self.partial_bytes = 0;
        self.partial_peak = 0;
        self.partial_sum_sq = 0;
        self.partial_samples = 0;
    }
};

const SliceStats = struct { peak: Amplitude, sum_sq: u64, samples: usize };

/// Peak, sum of squares, and sample count of an interleaved s16le slice,
/// over every channel. Trailing bytes short of a full sample are ignored.
fn sliceStats(pcm: []const u8) SliceStats {
    var stats: SliceStats = .{ .peak = 0, .sum_sq = 0, .samples = 0 };
    var off: usize = 0;
    while (off + 2 <= pcm.len) : (off += 2) {
        const sample: i32 = std.mem.readInt(i16, pcm[off..][0..2], .little);
        const mag: Amplitude = @intCast(@abs(sample));
        stats.peak = @max(stats.peak, mag);
        stats.sum_sq += @as(u64, @intCast(sample * sample));
        stats.samples += 1;
    }
    return stats;
}

/// The RMS amplitude of `samples` samples whose squares sum to `sum_sq`.
fn rmsOf(sum_sq: u64, samples: usize) Amplitude {
    if (samples == 0) return 0;
    const mean = @as(f64, @floatFromInt(sum_sq)) / @as(f64, @floatFromInt(samples));
    return @intFromFloat(@min(@sqrt(mean), @as(f64, full_scale)));
}

// --- columns -------------------------------------------------------------------

/// Columns the grid renderer is built for; wider terminals clamp to this.
pub const max_columns: usize = 512;

/// Stack bytes a `renderRow` call needs: the longest SGR transition plus a
/// three-byte glyph per column, plus the trailing reset.
pub fn rowBufferLen(columns: usize) usize {
    return columns * 32 + 16;
}

/// One displayed column: the perceived peak and RMS, 0..255.
pub const Column = struct {
    peak: u8 = 0,
    rms: u8 = 0,
};

/// The perceived size of an amplitude: the square root of its fraction of
/// full scale, scaled to 0..255. Speech sits far below full scale, so the
/// sqrt keeps quiet passages shaped instead of flatlining the grid.
fn fractionOf(amp: Amplitude) u8 {
    const frac = std.math.sqrt(@as(f64, @floatFromInt(amp)) / @as(f64, full_scale));
    return @intFromFloat(@min(frac * 255.0 + 0.5, 255.0));
}

/// How blocks map onto the columns: `fit` stretches or compresses the
/// whole recording across the width (the player's overview); `tail` shows
/// the most recent block per column, right-aligned, so a live recording
/// scrolls in from the right edge.
pub const Layout = enum { fit, tail };

/// Lays `blocks` out into `out` (one Column per displayed column) and
/// returns it. Compressing takes the peak's max and the RMS's true
/// aggregate over each column's blocks; stretching repeats blocks.
pub fn layoutColumns(blocks: []const Block, out: []Column, layout: Layout) []Column {
    const width = out.len;
    switch (layout) {
        .fit => {
            if (blocks.len == 0) {
                @memset(out, .{});
                return out;
            }
            for (out, 0..) |*c, i| {
                const start = i * blocks.len / width;
                const end = @max((i + 1) * blocks.len / width, start + 1);
                c.* = aggregate(blocks[start..end]);
            }
        },
        .tail => {
            const shown = @min(blocks.len, width);
            const pad = width - shown;
            @memset(out[0..pad], .{});
            for (blocks[blocks.len - shown ..], out[pad..]) |b, *c| {
                c.* = .{ .peak = fractionOf(b.peak), .rms = fractionOf(b.rms) };
            }
        },
    }
    return out;
}

fn aggregate(blocks: []const Block) Column {
    var peak: Amplitude = 0;
    var sum_sq: f64 = 0;
    for (blocks) |b| {
        peak = @max(peak, b.peak);
        const r: f64 = @floatFromInt(b.rms);
        sum_sq += r * r;
    }
    const rms: Amplitude = @intFromFloat(@sqrt(sum_sq / @as(f64, @floatFromInt(blocks.len))));
    return .{ .peak = fractionOf(peak), .rms = fractionOf(rms) };
}

// --- the grid --------------------------------------------------------------------

/// A contiguous run of grid columns marked for cutting, inclusive of both ends.
pub const SelRange = struct {
    start_col: usize,
    end_col: usize,
};

/// How the grid treats the audio: where playback has reached, the marked
/// span and its anchor columns, the playhead column, and whether colors
/// are on.
pub const Overlay = struct {
    /// Columns at and past this one draw as not yet played; maxInt keeps
    /// a whole grid live, which is how the recorder draws.
    played_cols: usize = std.math.maxInt(usize),
    /// Columns whose wave is recolored as marked for deletion.
    sel: ?SelRange = null,
    /// The selection's anchor columns: full-height lines — the two cursors
    /// marking where the region starts and ends.
    sel_edges: ?SelRange = null,
    /// The playhead column: a full-height heavy line over the audio.
    cursor_col: ?usize = null,
    /// Colors on (the VU ramp, the RMS core, the gray unplayed part) or
    /// off (shape only; the unplayed part dims).
    color: bool = false,
};

/// Eighths of a cell filled from its bottom edge, 1..8.
const lower_blocks = [8][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

const State = enum { live, unplayed, marked };

/// A pair of 256-color indexes: the RMS core and the peak halo around it.
const Tone = struct { core: u8, halo: u8 };

/// The VU ramp from the midline outward — blue through cyan and green to
/// yellow and red — so only loud audio reaches the warm rows.
const live_tones = [_]Tone{
    .{ .core = 33, .halo = 25 },
    .{ .core = 39, .halo = 31 },
    .{ .core = 44, .halo = 30 },
    .{ .core = 48, .halo = 35 },
    .{ .core = 154, .halo = 106 },
    .{ .core = 220, .halo = 136 },
    .{ .core = 202, .halo = 124 },
};
const unplayed_tone = Tone{ .core = 245, .halo = 239 };
const marked_tone = Tone{ .core = 201, .halo = 127 };

/// The ramp stop for a row `d` half-rows away from the midline on a grid of
/// `half` rows per side: the outermost row is always the last stop.
fn stopIndex(d: usize, half: usize) usize {
    if (half <= 1) return 0;
    const last = live_tones.len - 1;
    return (d * last * 2 + (half - 1)) / (2 * (half - 1));
}

fn toneFor(state: State, d: usize, half: usize) Tone {
    return switch (state) {
        .live => live_tones[stopIndex(d, half)],
        .unplayed => unplayed_tone,
        .marked => marked_tone,
    };
}

/// The SGR attributes of one cell; plain means the terminal's defaults.
const Style = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    reverse: bool = false,
    dim: bool = false,

    fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bg == b.bg and a.reverse == b.reverse and a.dim == b.dim;
    }

    fn isPlain(s: Style) bool {
        return s.eql(.{});
    }
};

const Cell = struct {
    glyph: []const u8,
    style: Style,
};

/// The column's extent in eighths of a row, out of the `half · 8` on each
/// side of the midline.
fn extentEighths(fraction: u8, half: usize) usize {
    return (@as(usize, fraction) * half * 8 + 127) / 255;
}

/// How many eighths of the band starting `band_start` eighths from the
/// midline an `extent` covers.
fn fillOf(extent: usize, band_start: usize) u8 {
    return @intCast(@min(extent -| band_start, 8));
}

/// A cell `k` eighths full (1..7) from the midline's side: the top half
/// fills from the bottom edge with a lower block; the bottom half fills
/// from the top edge, which no glyph draws — so it draws the complement in
/// reverse video, swapping ink and ground.
fn partialCell(k: u8, top: bool, style: Style) Cell {
    if (top) return .{ .glyph = lower_blocks[k - 1], .style = style };
    var s = style;
    s.reverse = true;
    return .{ .glyph = lower_blocks[8 - k - 1], .style = s };
}

/// The cell of `col` on `row` of a `2·half`-row grid: the peak envelope in
/// the halo tone, the RMS core inside it in the core tone (a cell holding
/// the core's edge splits: glyph in the core tone over a halo ground), a
/// full cell of core where the RMS reaches. Without color the core layer is
/// dropped and only the shape remains.
fn composeCell(col: Column, half: usize, row: usize, state: State, color: bool) Cell {
    const top = row < half;
    const d: usize = if (top) half - 1 - row else row - half;
    const band = d * 8;
    const k_peak = fillOf(extentEighths(col.peak, half), band);
    const k_rms: u8 = if (color) fillOf(extentEighths(col.rms, half), band) else 0;
    if (k_peak == 0) return .{ .glyph = " ", .style = .{} };

    const tone = toneFor(state, d, half);
    var style = Style{ .dim = !color and state == .unplayed };
    if (k_rms == 8) {
        style.fg = tone.core;
        return .{ .glyph = "█", .style = style };
    }
    if (k_peak == 8) {
        if (k_rms == 0) {
            if (color) style.fg = tone.halo;
            return .{ .glyph = "█", .style = style };
        }
        style.fg = tone.core;
        style.bg = tone.halo;
        return partialCell(k_rms, top, style);
    }
    // The halo's own edge; an RMS edge inside the same cell is dropped.
    if (color) style.fg = tone.halo;
    return partialCell(k_peak, top, style);
}

/// Renders character row `row` (0..height-1, height even) of the waveform
/// grid into `out` and returns the written slice. The cursor column is a
/// full-height heavy line in the default color, the selection anchors are
/// full-height light lines, a marked span recolors its wave, and columns
/// at or past `played_cols` draw as unplayed. SGR escapes are emitted only
/// on transitions and always reset at the end when one was emitted. `out`
/// must fit rowBufferLen(cols.len).
pub fn renderRow(cols: []const Column, height: usize, row: usize, o: Overlay, out: []u8) []const u8 {
    std.debug.assert(height % 2 == 0 and row < height);
    const half = height / 2;
    var n: usize = 0;
    var cur = Style{};
    for (cols, 0..) |col, i| {
        const cell = cellAt(col, half, row, i, o);
        if (!cell.style.eql(cur)) {
            n = if (cell.style.isPlain()) appendStr(out, n, reset) else appendSgr(out, n, cell.style);
            cur = cell.style;
        }
        n = appendStr(out, n, cell.glyph);
    }
    if (!cur.isPlain()) n = appendStr(out, n, reset);
    return out[0..n];
}

fn cellAt(col: Column, half: usize, row: usize, i: usize, o: Overlay) Cell {
    if (o.cursor_col != null and o.cursor_col.? == i) return .{ .glyph = "┃", .style = .{} };
    const is_edge = if (o.sel_edges) |e| e.start_col == i or e.end_col == i else false;
    if (is_edge) return .{ .glyph = "│", .style = .{ .fg = if (o.color) marked_tone.core else null } };
    const in_sel = if (o.sel) |s| s.start_col <= i and i <= s.end_col else false;
    const state: State = if (in_sel) .marked else if (i >= o.played_cols) .unplayed else .live;
    return composeCell(col, half, row, state, o.color);
}

const reset = "\x1b[0m";

/// "\x1b[0;2;7;38;5;N;48;5;Mm" with only the attributes `s` sets: a full
/// respecification from the defaults, so no attribute leaks between cells.
fn appendSgr(out: []u8, start: usize, s: Style) usize {
    var n = appendStr(out, start, "\x1b[0");
    if (s.dim) n = appendStr(out, n, ";2");
    if (s.reverse) n = appendStr(out, n, ";7");
    if (s.fg) |c| {
        n = appendStr(out, n, ";38;5;");
        n = appendUint(out, n, c);
    }
    if (s.bg) |c| {
        n = appendStr(out, n, ";48;5;");
        n = appendUint(out, n, c);
    }
    return appendStr(out, n, "m");
}

/// A single-row meter for output that is not a terminal: one lower block
/// per column by peak, no escapes at all. `out` must fit `cols.len * 3`.
pub fn renderStrip(cols: []const Column, out: []u8) []const u8 {
    var n: usize = 0;
    for (cols) |col| {
        const k = fillOf(extentEighths(col.peak, 1), 0);
        n = appendStr(out, n, if (k == 0) " " else lower_blocks[k - 1]);
    }
    return out[0..n];
}

fn appendStr(buf: []u8, n: usize, s: []const u8) usize {
    const end = n + s.len;
    @memcpy(buf[n..end], s);
    return end;
}

fn appendUint(buf: []u8, n: usize, v: u8) usize {
    var tmp: [3]u8 = undefined;
    var len: usize = 0;
    var x: usize = v;
    while (true) {
        tmp[len] = '0' + @as(u8, @intCast(x % 10));
        len += 1;
        x /= 10;
        if (x == 0) break;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) buf[n + i] = tmp[len - 1 - i];
    return n + len;
}

// --- terminal geometry -------------------------------------------------------

pub const TermSize = struct {
    cols: usize,
    rows: usize,
};

/// Fallback geometry when the terminal says nothing.
const default_size = TermSize{ .cols = 79, .rows = 24 };

/// Rows of the waveform grid for `rows_available` terminal rows left by
/// the fixed chrome around it: always even, at least 4, and capped at 12 —
/// taller than that the wave looks stretched rather than detailed.
pub fn viewHeight(rows_available: usize) usize {
    return @min(@max(rows_available, 4), 12) & ~@as(usize, 1);
}

const Winsize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16,
    ypixel: u16,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// TIOCGWINSZ on macOS and Linux (the same value on both).
const tiocgwinsz: c_ulong = if (@import("builtin").os.tag == .linux) 0x5413 else 0x40087468;

/// Windows console geometry (kernel32; stderr's visible window is what a
/// grid is drawn against).
const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ConsoleScreenBufferInfo = extern struct {
    dw_size: Coord,
    dw_cursor_position: Coord,
    w_attributes: u16,
    sr_window: SmallRect,
    dw_maximum_window_size: Coord,
};
extern "kernel32" fn GetStdHandle(nStdHandle: i32) ?std.os.windows.HANDLE;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: std.os.windows.HANDLE, info: *ConsoleScreenBufferInfo) i32;
const std_output_handle: i32 = -11;

/// The terminal a grid drawn on stderr has: one column is kept in reserve
/// so the rows do not wrap on terminals that auto-scroll, and 79×24 is
/// the fallback when the terminal says nothing.
pub fn termSize() TermSize {
    if (@import("builtin").os.tag == .windows) {
        var info: ConsoleScreenBufferInfo = undefined;
        const h = GetStdHandle(std_output_handle) orelse return default_size;
        if (GetConsoleScreenBufferInfo(h, &info) != 0) {
            const cols: i32 = @as(i32, info.sr_window.right) - info.sr_window.left + 1;
            const rows: i32 = @as(i32, info.sr_window.bottom) - info.sr_window.top + 1;
            if (cols >= 1 and rows >= 1) return .{ .cols = @max(@as(usize, @intCast(cols)) - 1, 1), .rows = @intCast(rows) };
        }
        return default_size;
    }
    var ws: Winsize = .{ .rows = 0, .cols = 0, .xpixel = 0, .ypixel = 0 };
    if (ioctl(2, tiocgwinsz, &ws) == 0 and ws.cols >= 1 and ws.rows >= 1) {
        return .{ .cols = @max(ws.cols - 1, 1), .rows = ws.rows };
    }
    return default_size;
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

test "tracker blocks peak and rms per block_bytes of pcm" {
    // 8 bytes per block = 2 stereo frames; the partial tail stays visible.
    var t = Tracker.init(std.testing.allocator, 8);
    defer t.deinit();

    var block: [8]u8 = undefined;
    stereoFrames(&block, 100);
    t.feed(&block);
    stereoFrames(&block, 200);
    t.feed(&block);
    stereoFrames(&block, 300);
    t.feed(&block);

    // A half block at ±400: not a completed block yet, but view() shows it.
    stereoFrames(block[0..4], 400);
    t.feed(block[0..4]);

    var out: std.ArrayList(Block) = .empty;
    defer out.deinit(std.testing.allocator);
    // Constant magnitude: the RMS equals the peak.
    try std.testing.expectEqualSlices(Block, &.{
        .{ .peak = 100, .rms = 100 },
        .{ .peak = 200, .rms = 200 },
        .{ .peak = 300, .rms = 300 },
        .{ .peak = 400, .rms = 400 },
    }, try t.view(&out));
}

test "tracker rms sits below a lone peak" {
    var t = Tracker.init(std.testing.allocator, 8);
    defer t.deinit();
    // Samples 1000, 0, 0, 0: peak 1000, RMS sqrt(1e6 / 4) = 500.
    var block = [_]u8{0} ** 8;
    std.mem.writeInt(i16, block[0..2], 1000, .little);
    t.feed(&block);
    try std.testing.expectEqual(Block{ .peak = 1000, .rms = 500 }, t.blocks.items[0]);
}

test "tracker feeds may split a block across chunks" {
    var t = Tracker.init(std.testing.allocator, 8);
    defer t.deinit();

    var block: [8]u8 = undefined;
    stereoFrames(&block, 250);
    t.feed(block[0..4]); // chunks may split blocks, not samples
    t.feed(block[4..8]);

    var out: std.ArrayList(Block) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Block, &.{.{ .peak = 250, .rms = 250 }}, try t.view(&out));
}

test "peakBlockBytes is a hundred ms of audio" {
    try std.testing.expectEqual(@as(usize, 19200), peakBlockBytes(192000)); // 48 kHz stereo
    try std.testing.expectEqual(@as(usize, 1), peakBlockBytes(0)); // never zero
}

test "fractionOf scales amplitudes perceptually" {
    // A quarter-amplitude peak reads as half of the grid: sqrt(0.25) = 0.5.
    try std.testing.expectEqual(@as(u8, 0), fractionOf(0));
    try std.testing.expectEqual(@as(u8, 128), fractionOf(8192));
    try std.testing.expectEqual(@as(u8, 255), fractionOf(full_scale));
}

test "layoutColumns fit stretches few blocks and compresses many" {
    var out: [4]Column = undefined;
    const two = [_]Block{ .{ .peak = full_scale, .rms = 8192 }, .{ .peak = 0, .rms = 0 } };
    // Two blocks over four columns: each block repeats over two columns.
    try std.testing.expectEqualSlices(Column, &.{
        .{ .peak = 255, .rms = 128 }, .{ .peak = 255, .rms = 128 }, .{}, .{},
    }, layoutColumns(&two, &out, .fit));

    // Four blocks over two columns: the peak's max, the RMS's aggregate
    // (sqrt of the mean square: 300 and 400 aggregate to 353).
    const four = [_]Block{
        .{ .peak = 100, .rms = 100 }, .{ .peak = 8192, .rms = 100 },
        .{ .peak = 500, .rms = 300 }, .{ .peak = 700, .rms = 400 },
    };
    const f = layoutColumns(&four, out[0..2], .fit);
    try std.testing.expectEqual(Column{ .peak = 128, .rms = fractionOf(100) }, f[0]);
    try std.testing.expectEqual(Column{ .peak = fractionOf(700), .rms = fractionOf(353) }, f[1]);

    // Nothing decoded yet: an all-silence grid.
    try std.testing.expectEqualSlices(Column, &.{ .{}, .{}, .{}, .{} }, layoutColumns(&.{}, &out, .fit));
}

test "layoutColumns tail right-aligns the most recent blocks" {
    var out: [4]Column = undefined;
    const two = [_]Block{ .{ .peak = full_scale, .rms = full_scale }, .{ .peak = 8192, .rms = 8192 } };
    // Fewer blocks than columns: they sit at the right edge over silence.
    try std.testing.expectEqualSlices(Column, &.{
        .{}, .{}, .{ .peak = 255, .rms = 255 }, .{ .peak = 128, .rms = 128 },
    }, layoutColumns(&two, &out, .tail));

    // More blocks than columns: only the last ones show, one per column.
    var six: [6]Block = undefined;
    for (&six, 0..) |*b, i| b.* = .{ .peak = @intCast(i * 1000), .rms = 0 };
    const t = layoutColumns(&six, &out, .tail);
    try std.testing.expectEqual(fractionOf(2000), t[0].peak);
    try std.testing.expectEqual(fractionOf(5000), t[3].peak);
}

test "renderRow shapes the wave in eighths around the midline" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    // Peaks 255, 128, 32, 0 on a two-row grid: extents 8, 4, 1, 0 eighths.
    const cols = [_]Column{ .{ .peak = 255 }, .{ .peak = 128 }, .{ .peak = 32 }, .{} };
    // The top row fills from its bottom edge with lower blocks.
    try std.testing.expectEqualStrings("█▄▁ ", renderRow(&cols, 2, 0, .{}, &buf));
    // The bottom row fills from its top edge: the complement in reverse video.
    try std.testing.expectEqualStrings("█\x1b[0;7m▄▇\x1b[0m ", renderRow(&cols, 2, 1, .{}, &buf));
}

test "renderRow spreads the extent over the rows of a taller grid" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    // On a four-row grid each side holds 16 eighths: 255 → 16, 191 → 12,
    // 128 → 8, 64 → 4.
    const cols = [_]Column{ .{ .peak = 255 }, .{ .peak = 191 }, .{ .peak = 128 }, .{ .peak = 64 } };
    try std.testing.expectEqualStrings("█▄  ", renderRow(&cols, 4, 0, .{}, &buf)); // outer top
    try std.testing.expectEqualStrings("███▄", renderRow(&cols, 4, 1, .{}, &buf)); // inner top
    try std.testing.expectEqualStrings("███\x1b[0;7m▄\x1b[0m", renderRow(&cols, 4, 2, .{}, &buf)); // inner bottom
    try std.testing.expectEqualStrings("█\x1b[0;7m▄\x1b[0m  ", renderRow(&cols, 4, 3, .{}, &buf)); // outer bottom
}

test "renderRow draws silence as blank space" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const silence = [_]Column{ .{}, .{}, .{}, .{} };
    try std.testing.expectEqualStrings("    ", renderRow(&silence, 10, 3, .{}, &buf));
}

test "renderRow layers the rms core inside the peak halo with color" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    // Two rows: one tone stop, blue core 33 over halo 25.
    const cols = [_]Column{
        .{ .peak = 255, .rms = 255 }, // full core
        .{ .peak = 255, .rms = 128 }, // the core's edge splits the cell: core ink over halo ground
        .{ .peak = 128, .rms = 0 }, // halo edge only
        .{ .peak = 128, .rms = 64 }, // both edges in one cell: the halo edge wins
    };
    try std.testing.expectEqualStrings(
        "\x1b[0;38;5;33m█\x1b[0;38;5;33;48;5;25m▄\x1b[0;38;5;25m▄▄\x1b[0m",
        renderRow(&cols, 2, 0, .{ .color = true }, &buf),
    );
    // The bottom half mirrors it in reverse video: ink and ground swap.
    try std.testing.expectEqualStrings(
        "\x1b[0;38;5;33m█\x1b[0;7;38;5;33;48;5;25m▄\x1b[0;7;38;5;25m▄▄\x1b[0m",
        renderRow(&cols, 2, 1, .{ .color = true }, &buf),
    );
}

test "renderRow climbs the vu ramp with the rows" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const loud = [_]Column{.{ .peak = 255, .rms = 255 }};
    // Ten rows, five per side: the midline row is blue, the outermost red.
    try std.testing.expectEqualStrings("\x1b[0;38;5;33m█\x1b[0m", renderRow(&loud, 10, 4, .{ .color = true }, &buf));
    try std.testing.expectEqualStrings("\x1b[0;38;5;33m█\x1b[0m", renderRow(&loud, 10, 5, .{ .color = true }, &buf));
    try std.testing.expectEqualStrings("\x1b[0;38;5;202m█\x1b[0m", renderRow(&loud, 10, 0, .{ .color = true }, &buf));
    try std.testing.expectEqualStrings("\x1b[0;38;5;202m█\x1b[0m", renderRow(&loud, 10, 9, .{ .color = true }, &buf));
}

test "renderRow ignores the rms layer without color" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const cols = [_]Column{ .{ .peak = 255, .rms = 128 }, .{ .peak = 128, .rms = 64 } };
    try std.testing.expectEqualStrings("█▄", renderRow(&cols, 2, 0, .{}, &buf));
}

test "renderRow grays the unplayed columns, or dims them without color" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    const f = [_]Column{ .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 } };
    try std.testing.expectEqualStrings(
        "\x1b[0;38;5;33m██\x1b[0;38;5;245m██\x1b[0m",
        renderRow(&f, 2, 0, .{ .played_cols = 2, .color = true }, &buf),
    );
    try std.testing.expectEqualStrings("██\x1b[0;2m██\x1b[0m", renderRow(&f, 2, 0, .{ .played_cols = 2 }, &buf));

    // Nothing played: the whole row is unplayed; everything played: no escapes.
    try std.testing.expectEqualStrings("\x1b[0;2m████\x1b[0m", renderRow(&f, 2, 0, .{ .played_cols = 0 }, &buf));
    try std.testing.expectEqualStrings("████", renderRow(&f, 2, 0, .{ .played_cols = 4 }, &buf));
}

test "renderRow recolors the marked span and draws its anchors as lines" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    const f = [_]Column{ .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 }, .{ .peak = 255, .rms = 255 } };

    // Two anchors stand as magenta lines with the wave between them in
    // the marked tone, whatever its played state.
    try std.testing.expectEqualStrings(
        "\x1b[0;38;5;33m█\x1b[0;38;5;201m│█│\x1b[0;38;5;245m█\x1b[0m",
        renderRow(&f, 2, 0, .{
            .played_cols = 4,
            .sel = .{ .start_col = 1, .end_col = 3 },
            .sel_edges = .{ .start_col = 1, .end_col = 3 },
            .color = true,
        }, &buf),
    );
    // Without color the anchors are plain lines and the span keeps its shape.
    try std.testing.expectEqualStrings(
        "█│█│█",
        renderRow(&f, 2, 0, .{ .sel = .{ .start_col = 1, .end_col = 3 }, .sel_edges = .{ .start_col = 1, .end_col = 3 } }, &buf),
    );
    // A single anchor drawn alone over silence (one mark set, the playhead elsewhere).
    try std.testing.expectEqualStrings(
        " │ ",
        renderRow(&[_]Column{ .{}, .{}, .{} }, 10, 4, .{ .sel_edges = .{ .start_col = 1, .end_col = 1 } }, &buf),
    );
}

test "renderRow draws the cursor as a heavy line in the default color" {
    var buf: [rowBufferLen(4)]u8 = undefined;
    const f = [_]Column{ .{ .peak = 255, .rms = 255 }, .{} };
    // The playhead spans its column even where the audio is silent, and it
    // is never colored — the default foreground is visible on any theme.
    try std.testing.expectEqualStrings("█┃", renderRow(&f, 2, 1, .{ .cursor_col = 1 }, &buf));
    try std.testing.expectEqualStrings(
        "\x1b[0;38;5;33m█\x1b[0m┃",
        renderRow(&f, 2, 0, .{ .cursor_col = 1, .color = true }, &buf),
    );
    // The cursor wins over an anchor and over the marked span.
    try std.testing.expectEqualStrings(
        "┃\x1b[0;38;5;201m│\x1b[0m",
        renderRow(&f, 2, 0, .{ .cursor_col = 0, .sel_edges = .{ .start_col = 0, .end_col = 1 }, .color = true }, &buf),
    );
}

test "renderRow keeps the same width with and without color" {
    var buf: [rowBufferLen(8)]u8 = undefined;
    var plain: [rowBufferLen(8)]u8 = undefined;
    const f = [_]Column{ .{ .peak = 10, .rms = 5 }, .{ .peak = 100, .rms = 60 }, .{ .peak = 140, .rms = 100 }, .{ .peak = 200, .rms = 120 }, .{ .peak = 255, .rms = 255 } };
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        const plain_row = renderRow(&f, 4, row, .{ .played_cols = 3 }, &plain);
        const colored = renderRow(&f, 4, row, .{ .played_cols = 3, .color = true }, &buf);
        // Escapes carry no display width: strip them and the rows agree.
        try std.testing.expectEqual(plain_row.len - escapeBytes(plain_row), colored.len - escapeBytes(colored));
    }
}

test "renderStrip is one lower block per column and no escapes" {
    var buf: [4 * 3]u8 = undefined;
    const cols = [_]Column{ .{ .peak = 255, .rms = 255 }, .{ .peak = 128 }, .{ .peak = 32 }, .{} };
    try std.testing.expectEqualStrings("█▄▁ ", renderStrip(&cols, &buf));
}

test "viewHeight is even, at least 4 and at most 12" {
    try std.testing.expectEqual(@as(usize, 12), viewHeight(30));
    try std.testing.expectEqual(@as(usize, 12), viewHeight(13));
    try std.testing.expectEqual(@as(usize, 8), viewHeight(9));
    try std.testing.expectEqual(@as(usize, 4), viewHeight(5));
    try std.testing.expectEqual(@as(usize, 4), viewHeight(0));
}

test "stopIndex always ends on the last tone" {
    try std.testing.expectEqual(@as(usize, 0), stopIndex(0, 6));
    try std.testing.expectEqual(live_tones.len - 1, stopIndex(5, 6));
    try std.testing.expectEqual(live_tones.len - 1, stopIndex(1, 2));
    try std.testing.expectEqual(@as(usize, 0), stopIndex(0, 1));
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
