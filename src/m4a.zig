//! M4A/AAC recording format, backed by AudioToolbox's system encoder. All
//! bindings are hand-declared externs with fourccs verified against the macOS
//! SDK headers (see docs/adr/0004): the binary already links AudioToolbox and
//! CoreFoundation for miniaudio, so no new dependency is introduced.

const std = @import("std");

pub const M4aError = error{
    CreateFailed,
    SetPropertyFailed,
    WriteFailed,
    InvalidPcm,
};

/// Four-cc constants from the AudioToolbox headers, spelled as the tags they
/// come from so they can be checked against the SDK at a glance.
fn fcc(comptime tag: *const [4]u8) u32 {
    return (@as(u32, tag[0]) << 24) | (@as(u32, tag[1]) << 16) | (@as(u32, tag[2]) << 8) | @as(u32, tag[3]);
}

// --- CoreFoundation ---------------------------------------------------------

const CFURLRef = ?*const anyopaque;

/// `Boolean` in CoreFoundation is UInt8, not C bool.
extern "c" fn CFURLCreateFromFileSystemRepresentation(
    allocator: ?*const anyopaque,
    buffer: [*]const u8,
    len: c_long,
    is_directory: u8,
) CFURLRef;
extern "c" fn CFRelease(cf: *const anyopaque) void;

fn fileUrl(path: []const u8) CFURLRef {
    return CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0);
}

// --- AudioToolbox -----------------------------------------------------------

const OSStatus = i32;
const ExtAudioFileRef = ?*anyopaque;
const AudioFileID = ?*anyopaque;

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
};

const AudioBuffer = extern struct {
    number_channels: u32,
    data_byte_size: u32,
    data: ?*anyopaque,
};

const AudioBufferList = extern struct {
    number_buffers: u32,
    buffers: [1]AudioBuffer,
};

extern "c" fn ExtAudioFileCreateWithURL(
    in_url: CFURLRef,
    in_file_type: u32,
    in_stream_desc: *const AudioStreamBasicDescription,
    in_channel_layout: ?*const anyopaque,
    in_flags: u32,
    out_file: *ExtAudioFileRef,
) OSStatus;
extern "c" fn ExtAudioFileSetProperty(
    in_file: ExtAudioFileRef,
    in_property_id: u32,
    in_size: u32,
    in_data: *const anyopaque,
) OSStatus;
extern "c" fn ExtAudioFileWrite(
    in_file: ExtAudioFileRef,
    in_num_frames: u32,
    io_data: *const AudioBufferList,
) OSStatus;
extern "c" fn ExtAudioFileDispose(in_file: ExtAudioFileRef) OSStatus;
extern "c" fn AudioFileOpenURL(
    in_file: CFURLRef,
    in_permissions: i8,
    in_file_type_hint: u32,
    out_file: *AudioFileID,
) OSStatus;
extern "c" fn AudioFileGetProperty(
    in_file: AudioFileID,
    in_property_id: u32,
    io_data_size: *u32,
    out_data: *anyopaque,
) OSStatus;
extern "c" fn AudioFileClose(in_file: AudioFileID) OSStatus;

/// Encodes interleaved s16 little-endian PCM (the capture format) into an
/// AAC-LC stream inside an M4A container at `path`, overwriting any file
/// already there. The CoreAudio converter owns the encoding: the client
/// format below is the PCM we hand it, the file format is AAC.
pub fn encode(path: []const u8, pcm: []const u8, sample_rate: u32, channels: u32) M4aError!void {
    const bytes_per_frame: u32 = channels * 2;
    if (pcm.len % bytes_per_frame != 0) return error.InvalidPcm;

    const url = fileUrl(path) orelse return error.CreateFailed;
    defer CFRelease(url);

    // The file's data format: plain AAC; packet sizes are the encoder's to
    // fill in.
    const file_desc = AudioStreamBasicDescription{
        .sample_rate = @floatFromInt(sample_rate),
        .format_id = fcc("aac "),
        .format_flags = 0,
        .bytes_per_packet = 0,
        .frames_per_packet = 0,
        .bytes_per_frame = 0,
        .channels_per_frame = channels,
        .bits_per_channel = 0,
        .reserved = 0,
    };
    var out: ExtAudioFileRef = null;
    // Erase flag: a same-named file is replaced, like createFile truncates.
    if (ExtAudioFileCreateWithURL(url, fcc("m4af"), &file_desc, null, 1, &out) != 0) {
        return error.CreateFailed;
    }
    // Dispose also flushes the moov atom; failing to call it would leave a
    // headerless body behind.
    defer _ = ExtAudioFileDispose(out);

    // Pin Apple's software encoder so output does not depend on which
    // codec implementations the host happens to expose.
    var manufacturer: u32 = fcc("appl");
    if (ExtAudioFileSetProperty(out, fcc("cman"), @sizeOf(u32), &manufacturer) != 0) {
        return error.SetPropertyFailed;
    }

    // Client format: exactly what capture.zig accumulates — interleaved
    // packed signed 16-bit little-endian (native) samples.
    const client_desc = AudioStreamBasicDescription{
        .sample_rate = @floatFromInt(sample_rate),
        .format_id = fcc("lpcm"),
        .format_flags = (1 << 2) | (1 << 3), // IsSignedInteger | IsPacked
        .bytes_per_packet = bytes_per_frame,
        .frames_per_packet = 1,
        .bytes_per_frame = bytes_per_frame,
        .channels_per_frame = channels,
        .bits_per_channel = 16,
        .reserved = 0,
    };
    if (ExtAudioFileSetProperty(out, fcc("cfmt"), @sizeOf(AudioStreamBasicDescription), &client_desc) != 0) {
        return error.SetPropertyFailed;
    }

    const buffers = AudioBufferList{
        .number_buffers = 1,
        .buffers = .{.{
            .number_channels = channels,
            .data_byte_size = @intCast(pcm.len),
            .data = @constCast(pcm.ptr),
        }},
    };
    const frames: u32 = @intCast(pcm.len / bytes_per_frame);
    if (ExtAudioFileWrite(out, frames, &buffers) != 0) return error.WriteFailed;
}

/// Duration of the M4A at `path` in seconds, via the system's MP4 parser;
/// null when the file cannot be opened or probed.
pub fn durationSec(path: []const u8) ?f64 {
    const url = fileUrl(path) orelse return null;
    defer CFRelease(url);

    var file: AudioFileID = null;
    if (AudioFileOpenURL(url, 0x01, 0, &file) != 0) return null; // read permission
    defer _ = AudioFileClose(file);

    var duration: f64 = 0;
    var size: u32 = @sizeOf(f64);
    if (AudioFileGetProperty(file, fcc("edur"), &size, &duration) != 0) return null;
    return duration;
}

// --- test-only POSIX I/O (libc is linked; keeps the module free of an
// std.Io dependency its real callers do not need) ----------------------------

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

fn writeTestFile(path: [*:0]const u8, bytes: []const u8) void {
    const fd = open(path, 0x601, @as(c_uint, 0o644)); // O_WRONLY | O_CREAT | O_TRUNC
    if (fd < 0) unreachable;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) unreachable;
        off += @intCast(n);
    }
}

fn testPath(buf: []u8, suffix: []const u8) [*:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/rec-m4a-test-{d}{s}", .{ getpid(), suffix }) catch unreachable;
}

test "encode writes an M4A whose duration parses back" {
    var path_buf: [64]u8 = undefined;
    const path = testPath(&path_buf, ".m4a");
    defer _ = unlink(path);

    // 0.5 s of a square wave at 48 kHz stereo — energy in every frame, so
    // the encoder has real work to do (silence would be a weaker probe).
    const sample_rate: usize = 48000;
    const frames: usize = sample_rate / 2;
    var pcm: std.ArrayList(u8) = .empty;
    defer pcm.deinit(std.testing.allocator);
    try pcm.ensureTotalCapacity(std.testing.allocator, frames * 4);

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        const level: u16 = if (frame % 110 < 55) 8000 else @as(u16, @bitCast(@as(i16, -8000)));
        var frame_bytes: [4]u8 = undefined;
        for (0..2) |ch| {
            std.mem.writeInt(u16, frame_bytes[ch * 2 ..][0..2], level, .little);
        }
        pcm.appendSliceAssumeCapacity(&frame_bytes);
    }

    try encode(std.mem.sliceTo(path, 0), pcm.items, 48000, 2);

    const duration = durationSec(std.mem.sliceTo(path, 0)) orelse return error.TestUnexpectedResult;
    // AAC priming/padding makes container durations accurate to ~±20 ms.
    try std.testing.expect(@abs(duration - 0.5) < 0.05);
}

test "durationSec rejects missing files and non-M4A content" {
    try std.testing.expect(durationSec("/tmp/rec-m4a-test-nonexistent.m4a") == null);

    var path_buf: [64]u8 = undefined;
    const path = testPath(&path_buf, ".bin");
    defer _ = unlink(path);
    writeTestFile(path, "definitely not an audio file");
    try std.testing.expect(durationSec(std.mem.sliceTo(path, 0)) == null);
}
