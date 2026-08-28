//! Splitting a recording in two at a playback position: load the audio as
//! PCM (native M4A decode or direct WAV parse), cut at a frame boundary,
//! write `<stem>-part1.m4a`/`<stem>-part2.m4a` beside it, drop the original.

const std = @import("std");
const library = @import("library.zig");
const m4a = @import("m4a.zig");

pub const SplitError = error{
    CannotDecode,
    CannotWrite,
    OutOfMemory,
};

pub const Parts = struct {
    first: []const u8,
    second: []const u8,
};

/// Cuts `pcm` (interleaved s16le) at `pos_sec` into two frame-aligned parts.
/// Positions outside the audio clamp to its edges.
pub fn splitPcm(pcm: []const u8, channels: u32, sample_rate: u32, pos_sec: f64) Parts {
    const bytes_per_frame: usize = @max(@as(usize, channels) * 2, 1);
    const byte_rate: u64 = @as(u64, sample_rate) * channels * 2;

    if (pos_sec <= 0 or byte_rate == 0) return .{ .first = pcm[0..0], .second = pcm };
    const offset_f = pos_sec * @as(f64, @floatFromInt(byte_rate));
    if (offset_f >= @as(f64, @floatFromInt(pcm.len))) {
        const end = pcm.len - pcm.len % bytes_per_frame;
        return .{ .first = pcm[0..end], .second = pcm[end..] };
    }
    const raw: usize = @intFromFloat(offset_f);
    const offset = raw - raw % bytes_per_frame;
    return .{ .first = pcm[0..offset], .second = pcm[offset..] };
}

/// The PCM payload and layout of a 16-bit PCM WAV image.
pub const Wav = struct {
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
};

/// Locates the data chunk of a 16-bit PCM WAV image; null for anything else.
pub fn parseWav(image: []const u8) ?Wav {
    if (image.len < 44) return null;
    if (!std.mem.eql(u8, image[0..4], "RIFF") or !std.mem.eql(u8, image[8..12], "WAVE")) return null;

    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var data: ?[]const u8 = null;

    var off: usize = 12;
    while (off + 8 <= image.len) {
        const id = image[off .. off + 4];
        const size = std.mem.readInt(u32, image[off + 4 ..][0..4], .little);
        const body = off + 8;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16 or image.len < body + 16) return null;
            const format = std.mem.readInt(u16, image[body..][0..2], .little);
            const bits = std.mem.readInt(u16, image[body + 14 ..][0..2], .little);
            if (format != 1 or bits != 16) return null; // PCM16 only
            channels = std.mem.readInt(u16, image[body + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, image[body + 4 ..][0..4], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            const take = @min(@as(usize, size), image.len - body);
            data = image[body .. body + take];
        }

        const next = @as(u64, off) + 8 + size + (size & 1);
        if (next >= image.len) break;
        off = @intCast(next);
    }

    const pcm = data orelse return null;
    if (channels == 0 or sample_rate == 0) return null;
    return .{ .pcm = pcm, .sample_rate = sample_rate, .channels = channels };
}

/// A recording loaded as canonical interleaved s16le PCM, plus whatever
/// backing memory keeps `pcm` alive. `deinit` frees in the right order.
pub const Loaded = struct {
    pcm: []u8,
    sample_rate: u32,
    channels: u32,
    /// WAV only: the whole file image `pcm` is a slice into.
    image: ?[]u8 = null,
    /// M4A only: `pcm` is the decoded buffer itself.
    pcm_owned: bool = false,

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        if (self.pcm_owned) gpa.free(self.pcm);
        if (self.image) |img| gpa.free(img);
        self.pcm_owned = false;
        self.image = null;
    }

    /// Bytes of PCM per second.
    pub fn byteRate(self: *const Loaded) u64 {
        return @as(u64, self.sample_rate) * self.channels * 2;
    }
};

/// Loads a recording as PCM for waveform display or splitting: M4A through
/// the system decoder (resampled to 48 kHz stereo), WAV straight from its
/// chunks. Anything else is not ours to read.
pub fn loadPcm(gpa: std.mem.Allocator, path: []const u8) SplitError!Loaded {
    if (std.mem.endsWith(u8, path, ".wav")) {
        const image = readWholeFile(gpa, path) catch return error.CannotDecode;
        errdefer gpa.free(image);
        const wav = parseWav(image) orelse return error.CannotDecode;
        return .{
            .pcm = @constCast(wav.pcm),
            .sample_rate = wav.sample_rate,
            .channels = wav.channels,
            .image = image,
        };
    }
    if (std.mem.endsWith(u8, path, ".m4a")) {
        const decoded = m4a.decode(gpa, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CannotDecode,
        };
        return .{
            .pcm = decoded.pcm,
            .sample_rate = decoded.sample_rate,
            .channels = decoded.channels,
            .pcm_owned = true,
        };
    }
    return error.CannotDecode;
}

/// Splits the recording at `path` at `pos_sec`: decodes it, writes
/// `<stem>-part1.m4a` and `<stem>-part2.m4a` beside it, and removes the
/// original. Reports what it did on stderr.
pub fn splitFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, pos_sec: f64) SplitError!void {
    var audio = try loadPcm(gpa, path);
    defer audio.deinit(gpa);

    const parts = splitPcm(audio.pcm, audio.channels, audio.sample_rate, pos_sec);
    const byte_rate = audio.byteRate();

    // Parts land beside the original; a same-named file is replaced, like
    // every other write in this project.
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const stem = stripExt(base);

    var p1_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var p2_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const p1 = joinPart(&p1_buf, dir, stem, "-part1.m4a") orelse return error.CannotWrite;
    const p2 = joinPart(&p2_buf, dir, stem, "-part2.m4a") orelse return error.CannotWrite;

    m4a.encode(p1, parts.first, audio.sample_rate, audio.channels) catch return error.CannotWrite;
    m4a.encode(p2, parts.second, audio.sample_rate, audio.channels) catch {
        std.Io.Dir.cwd().deleteFile(io, p1) catch {};
        return error.CannotWrite;
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    printStderr(io, "Split ");
    printStderr(io, base);
    printStderr(io, " at ");
    var line: [32]u8 = undefined;
    printStderr(io, mmss(&line, pos_sec));
    printStderr(io, " → ");
    printStderr(io, std.fs.path.basename(p1));
    printStderr(io, " (");
    printStderr(io, secs(&line, @as(f64, @floatFromInt(parts.first.len)) / @as(f64, @floatFromInt(byte_rate))));
    printStderr(io, " s), ");
    printStderr(io, std.fs.path.basename(p2));
    printStderr(io, " (");
    printStderr(io, secs(&line, @as(f64, @floatFromInt(parts.second.len)) / @as(f64, @floatFromInt(byte_rate))));
    printStderr(io, " s)\n");
}

/// A recording's stem: the name without its .m4a/.wav extension.
const stripExt = library.stripExt;

// libc file I/O (libc is already linked for miniaudio): a plain read() into
// owned memory, so the image's lifetime is exactly ours to manage.
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

const ReadError = error{ CannotRead, OutOfMemory };

fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    var path_z_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return error.CannotRead;

    const fd = open(path_z.ptr, 0); // O_RDONLY
    if (fd < 0) return error.CannotRead;
    defer _ = close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break; // EOF or error: keep what we have
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

fn joinPart(buf: []u8, dir: []const u8, stem: []const u8, suffix: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, stem, suffix }) catch null;
}

/// "MM:SS"
fn mmss(buf: []u8, sec: f64) []const u8 {
    const total: u64 = @intFromFloat(@max(sec + 0.5, 0.0));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
}

/// "1.2"-style seconds with one decimal.
fn secs(buf: []u8, sec: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{@max(sec, 0.0)}) catch "";
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

// --- test-only helpers -------------------------------------------------------

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) unreachable;
        off += @intCast(n);
    }
}

fn testPath(buf: []u8, suffix: []const u8) [*:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/rec-split-test-{d}{s}", .{ getpid(), suffix }) catch unreachable;
}

/// Canonical 44-byte PCM WAV header + `data_bytes` of a square wave.
fn testWav(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, data_bytes: usize) !void {
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], @intCast(36 + data_bytes), .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], 2, .little);
    std.mem.writeInt(u32, header[24..28], 48000, .little);
    std.mem.writeInt(u32, header[28..32], 48000 * 2 * 2, .little);
    std.mem.writeInt(u16, header[32..34], 4, .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], @intCast(data_bytes), .little);
    try buf.appendSlice(gpa, &header);

    var frame: usize = 0;
    while (frame < data_bytes / 4) : (frame += 1) {
        const level: u16 = if (frame % 110 < 55) 8000 else @as(u16, @bitCast(@as(i16, -8000)));
        var frame_bytes: [4]u8 = undefined;
        for (0..2) |ch| {
            std.mem.writeInt(u16, frame_bytes[ch * 2 ..][0..2], level, .little);
        }
        try buf.appendSlice(gpa, &frame_bytes);
    }
}

test "splitPcm cuts at a frame boundary and clamps to the body" {
    // 100 stereo frames at 50 Hz = 2 s; 200 bytes per second.
    var pcm: [400]u8 = undefined;
    @memset(&pcm, 0);

    const half = splitPcm(&pcm, 2, 50, 1.0);
    try std.testing.expectEqual(@as(usize, 200), half.first.len);
    try std.testing.expectEqual(@as(usize, 200), half.second.len);

    // A position inside a frame truncates down to the whole frame.
    const odd = splitPcm(&pcm, 2, 50, 1.001);
    try std.testing.expectEqual(@as(usize, 200), odd.first.len);

    // Out-of-range positions clamp so no part goes negative.
    const start = splitPcm(&pcm, 2, 50, -1.0);
    try std.testing.expectEqual(@as(usize, 0), start.first.len);
    const end = splitPcm(&pcm, 2, 50, 99.0);
    try std.testing.expectEqual(@as(usize, 0), end.second.len);
}

test "parseWav finds the data chunk and layout" {
    var wav: std.ArrayList(u8) = .empty;
    defer wav.deinit(std.testing.allocator);
    try testWav(&wav, std.testing.allocator, 400);
    const parsed = parseWav(wav.items).?;
    try std.testing.expectEqual(@as(u32, 48000), parsed.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), parsed.channels);
    try std.testing.expectEqual(@as(usize, 400), parsed.pcm.len);

    try std.testing.expect(parseWav("definitely not a wav file at all....") == null);
}

test "splitFile writes two playable parts and drops the original" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    // A 0.4 s WAV, split in half.
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".wav");
    defer _ = unlink(path);
    var part1_buf: [104]u8 = undefined;
    var part2_buf: [104]u8 = undefined;
    const part1_path = testPath(&part1_buf, "-part1.m4a");
    const part2_path = testPath(&part2_buf, "-part2.m4a");
    defer _ = unlink(part1_path);
    defer _ = unlink(part2_path);

    var wav: std.ArrayList(u8) = .empty;
    defer wav.deinit(gpa);
    try testWav(&wav, gpa, 48000 * 2 * 2 * 4 / 10); // 0.4 s
    {
        const fd = open(path, 0x601, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
        defer _ = close(fd);
        writeAll(fd, wav.items);
    }

    try splitFile(io, gpa, std.mem.sliceTo(path, 0), 0.2);

    const d1 = m4a.durationSec(std.mem.sliceTo(part1_path, 0)).?;
    const d2 = m4a.durationSec(std.mem.sliceTo(part2_path, 0)).?;
    try std.testing.expect(@abs(d1 - 0.2) < 0.05);
    try std.testing.expect(@abs(d2 - 0.2) < 0.05);

    // The original is gone: the split is a cut, not a copy.
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, std.mem.sliceTo(path, 0), .{}),
    );
}

test "splitFile rejects audio it cannot decode" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();

    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".txt");
    defer _ = unlink(path);
    {
        const fd = open(path, 0x601, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
        defer _ = close(fd);
        writeAll(fd, "not audio");
    }

    try std.testing.expectError(
        error.CannotDecode,
        splitFile(io, std.testing.allocator, std.mem.sliceTo(path, 0), 0.5),
    );
}
