//! The WAV (RIFF/PCM16) recording format: the streaming encoder behind
//! non-macOS recordings (see docs/adr/0012) plus the parser that reads them
//! back for waveform, cutting, and playback. Bindings are plain libc —
//! already linked for miniaudio — matching m4a.zig's no-new-dependency
//! stance.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    CreateFailed,
    WriteFailed,
    FinalizeFailed,
    InvalidPcm,
};

const is_windows = builtin.os.tag == .windows;

/// O_WRONLY | O_CREAT | O_TRUNC, spelled through std.posix because the octal
/// differs between macOS (0x601) and Linux (0o1101). Windows routes through
/// the CRT's _open flags — _O_BINARY is what stops the CRT from rewriting
/// \n bytes and corrupting the PCM body.
pub const create_write_flags: c_int = if (is_windows)
    0x0001 | 0x0100 | 0x0200 | 0x8000 // _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY
else
    @bitCast(std.posix.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    });

/// Writes the canonical 44-byte PCM16 header for `data_bytes` of audio.
fn writeHeader(buf: *[44]u8, sample_rate: u32, channels: u16, data_bytes: u32) void {
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_bytes, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * @as(u32, channels) * 2, .little);
    std.mem.writeInt(u16, buf[32..34], channels * 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
}

/// A streaming WAV encoder with the same shape as m4a's: PCM in while
/// recording runs, sizes patched and file closed by `finish`, `abort` for
/// every other exit path (the partial file is the caller's to delete).
pub const Encoder = struct {
    fd: c_int,
    bytes_per_frame: u32,
    data_bytes: u64 = 0,
    closed: bool = false,

    pub fn init(path: []const u8, sample_rate: u32, channels: u32) Error!Encoder {
        if (channels == 0 or channels > std.math.maxInt(u16)) return error.InvalidPcm;
        const bytes_per_frame: u32 = channels * 2;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.CreateFailed;
        const fd = openNew(path_z.ptr);
        if (fd < 0) return error.CreateFailed;
        errdefer _ = cclose(fd);

        var header: [44]u8 = undefined;
        writeHeader(&header, sample_rate, @intCast(channels), 0); // patched by finish
        writeAll(fd, &header) catch return error.WriteFailed;
        return .{ .fd = fd, .bytes_per_frame = bytes_per_frame };
    }

    pub fn write(self: *Encoder, pcm: []const u8) Error!void {
        if (self.closed) return error.WriteFailed;
        if (pcm.len % self.bytes_per_frame != 0) return error.InvalidPcm;
        writeAll(self.fd, pcm) catch return error.WriteFailed;
        self.data_bytes += pcm.len;
    }

    /// Patches the RIFF/data chunk sizes in and closes the file — a WAV is
    /// only valid once its sizes describe the body actually written.
    pub fn finish(self: *Encoder) Error!void {
        if (self.closed) return;
        self.closed = true;
        // RIFF is a u32-sized container; a longer body cannot be published.
        if (self.data_bytes > std.math.maxInt(u32) - 36) return error.FinalizeFailed;
        const data_bytes: u32 = @intCast(self.data_bytes);

        var patch: [4]u8 = undefined;
        std.mem.writeInt(u32, &patch, 36 + data_bytes, .little);
        if (cpwrite(self.fd, &patch, 4) != 4) return error.FinalizeFailed;
        std.mem.writeInt(u32, &patch, data_bytes, .little);
        if (cpwrite(self.fd, &patch, 40) != 4) return error.FinalizeFailed;

        if (cclose(self.fd) != 0) return error.FinalizeFailed;
    }

    /// Closes an unfinished encoder without making its file valid.
    pub fn abort(self: *Encoder) void {
        if (self.closed) return;
        self.closed = true;
        _ = cclose(self.fd);
    }
};

/// Encodes interleaved s16le PCM (the capture format) into a WAV at `path`,
/// overwriting any file already there.
pub fn encode(path: []const u8, pcm: []const u8, sample_rate: u32, channels: u32) Error!void {
    var encoder = try Encoder.init(path, sample_rate, channels);
    defer encoder.abort();
    try encoder.write(pcm);
    try encoder.finish();
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

// libc file I/O (libc is already linked for miniaudio; the CRT spellings on
// Windows): a plain fd with the lifetime exactly ours to manage, like the
// rest of the format modules.

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn _open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn _write(fd: c_int, buf: [*]const u8, count: u32) c_int;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, count: usize, offset: c_long) isize;
extern "c" fn _lseeki64(fd: c_int, offset: i64, origin: c_int) i64;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn _read(fd: c_int, buf: [*]u8, count: u32) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn _unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;
extern "c" fn _getpid() c_int;

const seek_set: c_int = 0;
const seek_cur: c_int = 1;

fn openNew(path: [*:0]const u8) c_int {
    if (is_windows) return _open(path, create_write_flags, @as(c_uint, 0o600)); // _S_IREAD|_S_IWRITE
    return open(path, create_write_flags, @as(c_uint, 0o644));
}

fn openReadOnly(path: [*:0]const u8) c_int {
    if (is_windows) return _open(path, 0); // _O_RDONLY
    return open(path, 0);
}

fn cclose(fd: c_int) c_int {
    if (is_windows) return _close(fd);
    return close(fd);
}

fn cwrite(fd: c_int, bytes: []const u8) isize {
    if (is_windows) return _write(fd, bytes.ptr, @intCast(bytes.len));
    return write(fd, bytes.ptr, bytes.len);
}

fn cread(fd: c_int, buf: []u8) isize {
    if (is_windows) return _read(fd, buf.ptr, @intCast(buf.len));
    return read(fd, buf.ptr, buf.len);
}

/// The one CRT gap: no _pwrite on Windows, so patching is seek, write, seek
/// back — the header patches run before close, racing nothing.
fn cpwrite(fd: c_int, bytes: []const u8, offset: u64) isize {
    if (is_windows) {
        const pos = _lseeki64(fd, 0, seek_cur);
        _ = _lseeki64(fd, @bitCast(offset), seek_set);
        const n = cwrite(fd, bytes);
        _ = _lseeki64(fd, pos, seek_set);
        return n;
    }
    return pwrite(fd, bytes.ptr, bytes.len, @intCast(offset));
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const end = @min(off + (1 << 30), bytes.len); // bounded for _write's u32
        const n = cwrite(fd, bytes[off..end]);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

pub const ReadError = error{ CannotRead, OutOfMemory };

/// The whole file at `path` as owned memory — the reader side of the format
/// plumbing, shared with cut.zig's WAV loading.
pub fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ReadError![]u8 {
    var path_z_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return error.CannotRead;

    const fd = openReadOnly(path_z.ptr);
    if (fd < 0) return error.CannotRead;
    defer _ = cclose(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = cread(fd, &chunk);
        if (n <= 0) break; // EOF or error: keep what we have
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

// --- test-only file plumbing (cut.zig's tests share it) ----------------------

/// Creates (or truncates) the file at `path_z` and writes `bytes` into it.
pub fn writeFileZ(path_z: [*:0]const u8, bytes: []const u8) bool {
    const fd = openNew(path_z);
    if (fd < 0) return false;
    writeAll(fd, bytes) catch {
        _ = cclose(fd);
        return false;
    };
    return cclose(fd) == 0;
}

/// Best-effort unlink for test cleanup.
pub fn unlinkZ(path_z: [*:0]const u8) void {
    if (is_windows) {
        _ = _unlink(path_z);
    } else {
        _ = unlink(path_z);
    }
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn envStr(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    if (v[0] == 0) return null;
    return std.mem.span(v);
}

fn testDir() ?[]const u8 {
    if (envStr("TMPDIR")) |d| return d;
    if (is_windows) {
        if (envStr("TEMP")) |d| return d;
        if (envStr("TMP")) |d| return d;
    }
    return null;
}

/// Scratch path for test artifacts (created and unlinked by the same test):
/// the platform temp dir when the environment exports one, else the working
/// directory. `buf` must be max_path_bytes and holds the returned bytes.
pub fn testPath(buf: []u8, suffix: []const u8) [*:0]u8 {
    const pid = if (is_windows) _getpid() else getpid();
    return std.fmt.bufPrintZ(buf, "{s}/rec-wav-test-{d}{s}", .{ testDir() orelse ".", pid, suffix }) catch unreachable;
}

// --- tests -------------------------------------------------------------------

/// The 0.5 s 48 kHz stereo square wave shared by the encoder tests.
fn testSquareWave(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    const sample_rate: usize = 48000;
    const frames: usize = sample_rate / 2;
    var pcm: std.ArrayList(u8) = .empty;
    errdefer pcm.deinit(gpa);
    try pcm.ensureTotalCapacity(gpa, frames * 4);

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        const level: u16 = if (frame % 110 < 55) 8000 else @as(u16, @bitCast(@as(i16, -8000)));
        var frame_bytes: [4]u8 = undefined;
        for (0..2) |ch| {
            std.mem.writeInt(u16, frame_bytes[ch * 2 ..][0..2], level, .little);
        }
        pcm.appendSliceAssumeCapacity(&frame_bytes);
    }
    return pcm;
}

test "encode writes a WAV whose parse reads the exact audio back" {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = testPath(&path_buf, ".wav");
    defer _ = unlink(path);

    var pcm = try testSquareWave(std.testing.allocator);
    defer pcm.deinit(std.testing.allocator);

    try encode(std.mem.sliceTo(path, 0), pcm.items, 48000, 2);

    // WAV is lossless: the parsed payload is the source PCM, byte for byte.
    const image = try readWholeFile(std.testing.allocator, std.mem.sliceTo(path, 0));
    defer std.testing.allocator.free(image);
    const parsed = parseWav(image).?;
    try std.testing.expectEqual(@as(u32, 48000), parsed.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), parsed.channels);
    try std.testing.expectEqualSlices(u8, pcm.items, parsed.pcm);
}

test "stream encoder finalizes a recording written in chunks" {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = testPath(&path_buf, ".stream.wav");
    defer _ = unlink(path);

    var pcm = try testSquareWave(std.testing.allocator);
    defer pcm.deinit(std.testing.allocator);

    var encoder = try Encoder.init(std.mem.sliceTo(path, 0), 48000, 2);
    defer encoder.abort();
    const midpoint = pcm.items.len / 2;
    try encoder.write(pcm.items[0..midpoint]);
    try encoder.write(pcm.items[midpoint..]);
    try encoder.finish();

    const image = try readWholeFile(std.testing.allocator, std.mem.sliceTo(path, 0));
    defer std.testing.allocator.free(image);
    try std.testing.expectEqualSlices(u8, pcm.items, parseWav(image).?.pcm);
}

test "finish rejects bodies past the 4 GiB RIFF limit" {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = testPath(&path_buf, ".huge.wav");
    defer _ = unlink(path);

    var encoder = try Encoder.init(std.mem.sliceTo(path, 0), 48000, 2);
    defer encoder.abort();
    encoder.data_bytes = std.math.maxInt(u32); // larger than u32 - 36
    try std.testing.expectError(error.FinalizeFailed, encoder.finish());
}

test "parseWav finds the data chunk and layout" {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = testPath(&path_buf, ".parse.wav");
    defer _ = unlink(path);

    var pcm = try testSquareWave(std.testing.allocator);
    defer pcm.deinit(std.testing.allocator);
    try encode(std.mem.sliceTo(path, 0), pcm.items, 48000, 2);
    const image = try readWholeFile(std.testing.allocator, std.mem.sliceTo(path, 0));
    defer std.testing.allocator.free(image);

    const parsed = parseWav(image).?;
    try std.testing.expectEqual(@as(u32, 48000), parsed.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), parsed.channels);
    try std.testing.expectEqual(pcm.items.len, parsed.pcm.len);

    try std.testing.expect(parseWav("definitely not a wav file at all....") == null);
    try std.testing.expect(parseWav(image[0..20]) == null); // truncated
}
