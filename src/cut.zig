//! Cutting a marked interval out of a recording: load the audio as PCM
//! (direct WAV parse, or the system M4A decode on macOS), remove the span at
//! frame boundaries, re-encode what remains in the platform recording
//! format and replace the original. A legacy .wav on macOS is replaced by
//! the M4A cut beside it; elsewhere the .wav is cut in place.

const std = @import("std");
const library = @import("library.zig");
const wav = @import("wav.zig");

pub const CutError = error{
    CannotDecode,
    CannotWrite,
    NothingToCut,
    OutOfMemory,
};

/// The frame-aligned PCM that survives cutting `[start_sec, end_sec)` out of
/// `pcm` (interleaved s16le): `head` is the audio before the span, `tail`
/// the audio after it. Positions outside the audio clamp to its edges; an
/// empty or inverted span cuts nothing — the whole body comes back as the
/// head and the caller reports `NothingToCut`.
pub const Remainder = struct {
    head: []const u8,
    tail: []const u8,
};

/// Removes `[start_sec, end_sec)` from `pcm` (interleaved s16le) at frame
/// boundaries. Positions outside the audio clamp to its edges.
pub fn cutPcm(pcm: []const u8, channels: u32, sample_rate: u32, start_sec: f64, end_sec: f64) Remainder {
    const bytes_per_frame: usize = @max(@as(usize, channels) * 2, 1);
    const byte_rate = @as(f64, @floatFromInt(sample_rate)) * @as(f64, @floatFromInt(channels)) * 2.0;
    const pcm_len = @as(f64, @floatFromInt(pcm.len));

    // An empty or inverted span cuts nothing.
    if (start_sec >= end_sec or byte_rate == 0) return .{ .head = pcm, .tail = pcm[0..0] };

    // Clamp in float space: @intFromFloat of an out-of-range float panics.
    var start: usize = 0;
    const start_f = @max(start_sec, 0.0) * byte_rate;
    if (start_f < pcm_len) {
        const raw: usize = @intFromFloat(start_f);
        start = raw - raw % bytes_per_frame;
    } else {
        start = pcm.len - pcm.len % bytes_per_frame;
    }

    var end: usize = pcm.len;
    const end_f = @max(end_sec, 0.0) * byte_rate;
    if (end_f < pcm_len) {
        const raw: usize = @intFromFloat(end_f);
        end = raw - raw % bytes_per_frame;
    }
    if (end < start) end = start;
    return .{ .head = pcm[0..start], .tail = pcm[end..] };
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

/// Loads a recording as PCM for waveform display or cutting: M4A through
/// the system decoder (resampled to 48 kHz stereo), WAV straight from its
/// chunks. Anything else is not ours to read.
pub fn loadPcm(gpa: std.mem.Allocator, path: []const u8) CutError!Loaded {
    if (std.mem.endsWith(u8, path, ".wav")) {
        const image = readWholeFile(gpa, path) catch return error.CannotDecode;
        errdefer gpa.free(image);
        const parsed = wav.parseWav(image) orelse return error.CannotDecode;
        return .{
            .pcm = @constCast(parsed.pcm),
            .sample_rate = parsed.sample_rate,
            .channels = parsed.channels,
            .image = image,
        };
    }
    if (std.mem.endsWith(u8, path, ".m4a")) {
        if (library.recording.m4a_supported) {
            const decoded = library.recording.decode(gpa, path) catch |err| return switch (err) {
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
    }
    return error.CannotDecode;
}

/// Removes the marked span from the recording at `path`: decodes it, cuts
/// `[start_sec, end_sec)` out at frame boundaries, re-encodes the remainder
/// into one M4A and replaces the original — the temp file is renamed over it
/// atomically, so a failed encode never destroys the source. A legacy .wav
/// is replaced by the M4A cut beside it. Reports what it did on stderr.
pub fn cutIntervalFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, start_sec: f64, end_sec: f64) CutError!void {
    var audio = try loadPcm(gpa, path);
    defer audio.deinit(gpa);

    const rem = cutPcm(audio.pcm, audio.channels, audio.sample_rate, start_sec, end_sec);
    const kept_len = rem.head.len + rem.tail.len;
    // Nothing removed, or the whole body gone: refuse both.
    if (kept_len == audio.pcm.len or kept_len == 0) return error.NothingToCut;

    const kept = gpa.alloc(u8, kept_len) catch return error.OutOfMemory;
    defer gpa.free(kept);
    @memcpy(kept[0..rem.head.len], rem.head);
    @memcpy(kept[rem.head.len..], rem.tail);

    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const stem = stripExt(base);

    // The cut replaces the original: on macOS a legacy .wav becomes the M4A
    // cut beside it; elsewhere the recording format already matches. The
    // temp name is never scanned by the library.
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = if (std.mem.endsWith(u8, base, ".wav"))
        joinPath(&target_buf, dir, stem, library.recording.ext) orelse return error.CannotWrite
    else
        path;
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = joinPath(&tmp_buf, dir, std.fs.path.basename(target), ".cut.tmp") orelse return error.CannotWrite;

    library.recording.encode(tmp, kept, audio.sample_rate, audio.channels) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return error.CannotWrite;
    };
    // Atomic replace: the original is swapped only once the cut is encoded.
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), target, io) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return error.CannotWrite;
    };
    if (!std.mem.eql(u8, target, path)) std.Io.Dir.cwd().deleteFile(io, path) catch {};

    printStderr(io, "Cut ");
    printStderr(io, base);
    printStderr(io, " ");
    var line: [32]u8 = undefined;
    printStderr(io, mmss(&line, start_sec));
    printStderr(io, "–");
    printStderr(io, mmss(&line, end_sec));
    printStderr(io, " → ");
    if (!std.mem.eql(u8, target, path)) {
        printStderr(io, std.fs.path.basename(target));
        printStderr(io, " (");
    }
    printStderr(io, secs(&line, @as(f64, @floatFromInt(kept_len)) / @as(f64, @floatFromInt(audio.byteRate()))));
    printStderr(io, " s");
    if (!std.mem.eql(u8, target, path)) printStderr(io, ")");
    printStderr(io, "\n");
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

fn joinPath(buf: []u8, dir: []const u8, name: []const u8, suffix: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, name, suffix }) catch null;
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
    return std.fmt.bufPrintZ(buf, "/tmp/rec-cut-test-{d}{s}", .{ getpid(), suffix }) catch unreachable;
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

test "cutPcm removes the span at frame boundaries and clamps" {
    // 100 stereo frames at 50 Hz = 2 s; 200 bytes per second.
    var pcm: [400]u8 = undefined;
    @memset(&pcm, 0);

    // Middle cut: [0.5, 1.5] removes 1 s, keeping 0.5 s before and after.
    const mid = cutPcm(&pcm, 2, 50, 0.5, 1.5);
    try std.testing.expectEqual(@as(usize, 100), mid.head.len);
    try std.testing.expectEqual(@as(usize, 100), mid.tail.len);

    // Head cut: [0, 1.5] removes the beginning, keeping the tail.
    const head = cutPcm(&pcm, 2, 50, 0.0, 1.5);
    try std.testing.expectEqual(@as(usize, 0), head.head.len);
    try std.testing.expectEqual(@as(usize, 100), head.tail.len);

    // Tail cut: [0.5, 99] removes everything past 0.5 s (clamped to the end).
    const tail = cutPcm(&pcm, 2, 50, 0.5, 99.0);
    try std.testing.expectEqual(@as(usize, 100), tail.head.len);
    try std.testing.expectEqual(@as(usize, 0), tail.tail.len);

    // Inverted span cuts nothing: the whole body is the head.
    const none = cutPcm(&pcm, 2, 50, 1.5, 0.5);
    try std.testing.expectEqual(@as(usize, 400), none.head.len);
    try std.testing.expectEqual(@as(usize, 0), none.tail.len);

    // Positions inside a frame truncate down to whole frames.
    const odd = cutPcm(&pcm, 2, 50, 1.001, 1.499);
    try std.testing.expectEqual(@as(usize, 200), odd.head.len);
    try std.testing.expectEqual(@as(usize, 104), odd.tail.len);
}

test "cutIntervalFile replaces the recording with the cut" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    // A 0.4 s WAV; the cut removes [0.1, 0.3] → 0.2 s remains.
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".wav");
    defer _ = unlink(path);
    var m4a_buf: [96]u8 = undefined;
    const m4a_path = testPath(&m4a_buf, ".m4a");
    defer _ = unlink(m4a_path);
    var tmp_buf: [112]u8 = undefined;
    const tmp_path = testPath(&tmp_buf, ".m4a.cut.tmp");
    defer _ = unlink(tmp_path);

    var wav_image: std.ArrayList(u8) = .empty;
    defer wav_image.deinit(gpa);
    try testWav(&wav_image, gpa, 48000 * 2 * 2 * 4 / 10); // 0.4 s
    {
        const fd = open(path, wav.create_write_flags, @as(c_uint, 0o644));
        defer _ = close(fd);
        writeAll(fd, wav_image.items);
    }

    try cutIntervalFile(io, gpa, std.mem.sliceTo(path, 0), 0.1, 0.3);

    if (library.recording.m4a_supported) {
        // The .wav is gone; the cut lives beside it as .m4a, 0.2 s long.
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().statFile(io, std.mem.sliceTo(path, 0), .{}),
        );
        const d = library.recording.durationSec(std.mem.sliceTo(m4a_path, 0)).?;
        try std.testing.expect(@abs(d - 0.2) < 0.05);
    } else {
        // The .wav is cut in place: same path, 0.2 s of PCM left.
        const image = try readWholeFile(gpa, std.mem.sliceTo(path, 0));
        defer gpa.free(image);
        try std.testing.expectEqual(
            @as(usize, 48000 * 2 * 2 * 2 / 10),
            wav.parseWav(image).?.pcm.len,
        );
    }
    // No encode temp file is left behind.
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, std.mem.sliceTo(tmp_path, 0), .{}),
    );
}

test "cutIntervalFile cuts an m4a in place" {
    if (!library.recording.m4a_supported) return; // no M4A recordings exist elsewhere
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    // Encode 0.4 s of silence, then cut [0.1, 0.3] out of it.
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".m4a");
    defer _ = unlink(path);
    var tmp_buf: [112]u8 = undefined;
    const tmp_path = testPath(&tmp_buf, ".m4a.cut.tmp");
    defer _ = unlink(tmp_path);

    const pcm = try gpa.alloc(u8, 48000 * 2 * 2 * 4 / 10); // 0.4 s of silence
    defer gpa.free(pcm);
    @memset(pcm, 0);
    try library.recording.encode(std.mem.sliceTo(path, 0), pcm, 48000, 2);

    try cutIntervalFile(io, gpa, std.mem.sliceTo(path, 0), 0.1, 0.3);

    // The original path now holds the 0.2 s cut.
    const d = library.recording.durationSec(std.mem.sliceTo(path, 0)).?;
    try std.testing.expect(@abs(d - 0.2) < 0.05);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, std.mem.sliceTo(tmp_path, 0), .{}),
    );
}

test "cutIntervalFile refuses spans that cut nothing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    // An inverted span on a valid recording: nothing to cut, file untouched.
    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".wav");
    defer _ = unlink(path);

    var wav_image: std.ArrayList(u8) = .empty;
    defer wav_image.deinit(gpa);
    try testWav(&wav_image, gpa, 48000 * 2 * 2 * 4 / 10); // 0.4 s
    {
        const fd = open(path, wav.create_write_flags, @as(c_uint, 0o644));
        defer _ = close(fd);
        writeAll(fd, wav_image.items);
    }

    try std.testing.expectError(
        error.NothingToCut,
        cutIntervalFile(io, gpa, std.mem.sliceTo(path, 0), 0.3, 0.1),
    );
    // The file is intact: the same 0.4 s of PCM.
    const image = try readWholeFile(gpa, std.mem.sliceTo(path, 0));
    defer gpa.free(image);
    try std.testing.expectEqual(@as(usize, 48000 * 2 * 2 * 4 / 10), wav.parseWav(image).?.pcm.len);
}

test "cutIntervalFile rejects audio it cannot decode" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();

    var path_buf: [96]u8 = undefined;
    const path = testPath(&path_buf, ".txt");
    defer _ = unlink(path);
    {
        const fd = open(path, wav.create_write_flags, @as(c_uint, 0o644));
        defer _ = close(fd);
        writeAll(fd, "not audio");
    }

    try std.testing.expectError(
        error.CannotDecode,
        cutIntervalFile(io, std.testing.allocator, std.mem.sliceTo(path, 0), 0.1, 0.2),
    );
}
