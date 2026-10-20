//! AIREC voice recorder `.ops` files: Opus packets stored back to back with
//! no container (see docs/adr/0021). The recorder encodes 16 kHz mono SILK
//! at a constant 32 kbps, so every 20 ms packet is exactly `packet_bytes`
//! long — CBR fills short frames with Opus's own code-3 padding. libopus
//! decodes them into the project's canonical s16 / 48 kHz / stereo layout.

const std = @import("std");

pub const Error = error{ CreateFailed, InvalidPacket };

/// Size of every packet in a `.ops` file.
pub const packet_bytes = 80;

/// The canonical layout decoded packets come out in (capture's layout).
pub const sample_rate: u32 = 48000;
pub const channels: u32 = 2;

/// The longest Opus packet is 120 ms: the most frames one decode can yield.
pub const max_packet_frames = 5760;

/// Number of whole packets in a file of `size` bytes; a trailing partial
/// packet (a recording cut off mid-write) is dropped.
pub fn packetCount(size: usize) usize {
    return size / packet_bytes;
}

// libopus, linked from the opus package in build.zig.
const OpusDecoder = opaque {};
extern fn opus_decoder_create(fs: i32, channels: c_int, err: *c_int) ?*OpusDecoder;
extern fn opus_decoder_destroy(st: *OpusDecoder) void;
extern fn opus_decode(st: *OpusDecoder, data: [*]const u8, len: i32, pcm: [*]i16, frame_size: c_int, decode_fec: c_int) c_int;

/// A libopus decoder pinned to the canonical layout; a mono stream comes
/// out on both channels.
pub const Decoder = struct {
    st: *OpusDecoder,

    pub fn init() Error!Decoder {
        var err: c_int = 0;
        const st = opus_decoder_create(sample_rate, channels, &err) orelse return error.CreateFailed;
        return .{ .st = st };
    }

    pub fn deinit(self: *Decoder) void {
        opus_decoder_destroy(self.st);
    }

    /// Decodes one packet into `out` as interleaved s16 and returns the
    /// frames written.
    pub fn decodePacket(self: *Decoder, packet: []const u8, out: *[max_packet_frames * channels]i16) Error!usize {
        const n = opus_decode(self.st, packet.ptr, @intCast(packet.len), out, max_packet_frames, 0);
        if (n < 0) return error.InvalidPacket;
        return @intCast(n);
    }
};

// --- tests -------------------------------------------------------------------

const OpusEncoder = opaque {};
extern fn opus_encoder_create(fs: i32, channels: c_int, application: c_int, err: *c_int) ?*OpusEncoder;
extern fn opus_encoder_destroy(st: *OpusEncoder) void;
extern fn opus_encoder_ctl(st: *OpusEncoder, request: c_int, ...) c_int;
extern fn opus_encode(st: *OpusEncoder, pcm: [*]const i16, frame_size: c_int, data: [*]u8, max_data_bytes: i32) i32;

const OPUS_APPLICATION_VOIP: c_int = 2048;
const OPUS_SET_BITRATE_REQUEST: c_int = 4002;
const OPUS_SET_VBR_REQUEST: c_int = 4006;

/// A synthetic `.ops` image the way the recorder writes one: a 440 Hz tone
/// at 16 kHz mono, 20 ms SILK packets at a constant 32 kbps.
fn testImage(gpa: std.mem.Allocator, packets: usize) ![]u8 {
    var err: c_int = 0;
    const enc = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &err) orelse return error.TestUnexpectedResult;
    defer opus_encoder_destroy(enc);
    try std.testing.expectEqual(@as(c_int, 0), opus_encoder_ctl(enc, OPUS_SET_BITRATE_REQUEST, @as(i32, 32000)));
    try std.testing.expectEqual(@as(c_int, 0), opus_encoder_ctl(enc, OPUS_SET_VBR_REQUEST, @as(i32, 0)));

    const image = try gpa.alloc(u8, packets * packet_bytes);
    errdefer gpa.free(image);
    var pcm: [320]i16 = undefined;
    for (0..packets) |p| {
        for (&pcm, 0..) |*s, i| {
            const t: f64 = @as(f64, @floatFromInt(p * pcm.len + i)) / 16000.0;
            s.* = @intFromFloat(12000.0 * @sin(2.0 * std.math.pi * 440.0 * t));
        }
        const n = opus_encode(enc, &pcm, pcm.len, image[p * packet_bytes ..].ptr, packet_bytes);
        try std.testing.expectEqual(@as(i32, packet_bytes), n);
    }
    return image;
}

test "decodes back-to-back CBR packets into canonical 48 kHz stereo" {
    const gpa = std.testing.allocator;
    const image = try testImage(gpa, 25);
    defer gpa.free(image);
    try std.testing.expectEqual(@as(usize, 25), packetCount(image.len));

    var decoder = try Decoder.init();
    defer decoder.deinit();
    var out: [max_packet_frames * channels]i16 = undefined;
    var frames: usize = 0;
    var peak: i32 = 0;
    for (0..packetCount(image.len)) |p| {
        const n = try decoder.decodePacket(image[p * packet_bytes ..][0..packet_bytes], &out);
        try std.testing.expectEqual(@as(usize, 960), n); // 20 ms at 48 kHz
        frames += n;
        for (out[0 .. n * channels]) |s| peak = @max(peak, @as(i32, @abs(s)));
    }
    try std.testing.expectEqual(@as(usize, 24000), frames); // 0.5 s
    try std.testing.expect(peak > 4000); // the tone survives the codec
}

test "a trailing partial packet is not audio" {
    try std.testing.expectEqual(@as(usize, 0), packetCount(packet_bytes - 1));
    try std.testing.expectEqual(@as(usize, 2), packetCount(2 * packet_bytes + 48));
}

test "a malformed packet is refused" {
    var decoder = try Decoder.init();
    defer decoder.deinit();
    var out: [max_packet_frames * channels]i16 = undefined;
    // Code-3 TOC (SILK WB 20 ms) announcing zero frames.
    try std.testing.expectError(error.InvalidPacket, decoder.decodePacket(&.{ 0x4b, 0x00 }, &out));
}
