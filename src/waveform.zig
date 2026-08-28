//! Waveform rendering: incremental peaks over interleaved s16le PCM and a
//! one-line Unicode block bar, optionally dimming the columns past the
//! playback position, plus the terminal width the bar is drawn to. Pure
//! computation is kept free of I/O so every behavior is testable offline.

const std = @import("std");

/// Absolute sample amplitude (0..32768) of one PCM block.
pub const Peak = u16;

/// Full-scale amplitude of an s16 sample, the ceiling of a Peak.
pub const full_scale: Peak = 32768;

/// One hundred ms of audio per peak: plenty of resolution for a terminal
/// bar, tiny enough to compute incrementally while recording.
pub const peak_block_ms: u64 = 100;

/// PCM bytes that make up one peak block at `byte_rate` bytes of audio per
/// second; never zero.
pub fn peakBlockBytes(byte_rate: u64) usize {
    return @intCast(@max(byte_rate * peak_block_ms / 1000, 1));
}

/// Unicode block levels, index 0..7.
const blocks = [8][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

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

/// Renders `peaks` as one line of at most `width` block glyphs: when there
/// are more peaks than columns, each column shows the max peak of its slice;
/// when fewer, the line is padded with silence. Columns at `played_cols` and
/// beyond are dimmed (ANSI), the rest at normal intensity — pass `width`
/// (or more) to keep the whole bar bright, e.g. while recording. Returns the
/// written slice of `out`.
pub fn renderBar(peaks: []const Peak, width: usize, played_cols: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var dim = false; // current intensity, flipped only on transitions
    var col: usize = 0;
    while (col < width) : (col += 1) {
        const want_dim = col >= played_cols;
        if (want_dim != dim) {
            n = appendStr(out, n, if (want_dim) "\x1b[2m" else "\x1b[0m");
            dim = want_dim;
        }
        n = appendStr(out, n, blocks[columnLevel(peaks, col, width)]);
    }
    if (dim) n = appendStr(out, n, "\x1b[0m");
    return out[0..n];
}

/// The block level (0..7) shown at `col`: peak-for-column while the audio is
/// still shorter than the line (so a live recording grows from the left),
/// otherwise the max peak of the column's slice of `peaks`. Silence past the
/// end or when the slice is empty.
fn columnLevel(peaks: []const Peak, col: usize, width: usize) usize {
    var peak: Peak = 0;
    if (peaks.len <= width) {
        if (col < peaks.len) peak = peaks[col];
    } else {
        const start = col * peaks.len / width;
        const end = (col + 1) * peaks.len / width;
        for (peaks[start..end]) |p| peak = @max(peak, p);
    }
    // Scale to the 8 glyph levels; saturate at full scale.
    return @min(@as(u32, peak) * 8 / full_scale, 7);
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

/// Columns available for a bar drawn on stderr; one column is kept in
/// reserve so the line does not wrap on terminals that auto-scroll, and 79
/// is the fallback when the ioctl says nothing.
pub fn termWidth() usize {
    var ws: Winsize = .{ .rows = 0, .cols = 0, .xpixel = 0, .ypixel = 0 };
    if (ioctl(2, tiocgwinsz, &ws) == 0 and ws.cols >= 2) return ws.cols - 1;
    return 79;
}

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

test "renderBar maps peaks to block levels and pads with silence" {
    var buf: [128]u8 = undefined;
    // 0, 8192, 16384, 24576, 32767 → levels 0, 2, 4, 6, 7; rest is silence.
    const peaks = [_]Peak{ 0, 8192, 16384, 24576, 32767 };
    const line = renderBar(&peaks, 10, 10, &buf);
    try std.testing.expectEqualStrings("▁▃▅▇█▁▁▁▁▁", line);
}

test "renderBar compresses more peaks than columns by max per column" {
    var buf: [128]u8 = undefined;
    // 20 peaks in (0, 16384) pairs, width 10 → every column is the pair max.
    var peaks: [20]Peak = undefined;
    for (&peaks, 0..) |*p, i| p.* = if (i % 2 == 1) 16384 else 0;
    const line = renderBar(&peaks, 10, 10, &buf);
    try std.testing.expectEqualStrings("▅▅▅▅▅▅▅▅▅▅", line);
}

test "renderBar dims columns at and past the playback position" {
    var buf: [128]u8 = undefined;
    const peaks = [_]Peak{ 8192, 8192, 8192, 8192 };
    try std.testing.expectEqualStrings("▃▃\x1b[2m▃▃\x1b[0m", renderBar(&peaks, 4, 2, &buf));

    // Nothing played: the whole bar is dim; everything played: no escapes.
    try std.testing.expectEqualStrings("\x1b[2m▃▃▃▃\x1b[0m", renderBar(&peaks, 4, 0, &buf));
    try std.testing.expectEqualStrings("▃▃▃▃", renderBar(&peaks, 4, 4, &buf));
}

test "renderBar with no peaks is a line of silence" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("▁▁▁", renderBar(&.{}, 3, 3, &buf));
    try std.testing.expectEqualStrings("", renderBar(&.{}, 0, 0, &buf));
}
