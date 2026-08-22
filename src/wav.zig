const std = @import("std");

/// Parsed WAV metadata used by `list` and the smoke checks.
pub const WavInfo = struct {
    sample_rate: u32,
    channels: u16,
    duration_sec: f64,
};

pub const WavError = error{
    NotWav,
    UnsupportedFormat,
    MissingDataChunk,
};

/// Canonical 44-byte PCM WAV header; size fields are the caller's to fill.
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
    std.mem.writeInt(u16, buf[32..34], channels * 2, .little); // block align
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits per sample
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
}

/// Where a WavWriter sends its bytes: a real file (written through the
/// process Io interface) or an in-memory list (unit tests inspect the
/// bytes without touching disk).
pub const Sink = union(enum) {
    file: struct {
        io: std.Io,
        file: std.Io.File,
    },
    mem: struct {
        gpa: std.mem.Allocator,
        list: *std.ArrayList(u8),
    },
};

pub const WavWriter = struct {
    sink: Sink,
    sample_rate: u32,
    channels: u16,
    data_bytes: u64,

    /// Writes the header immediately (sizes zeroed until finalize).
    pub fn init(sink: Sink, sample_rate: u32, channels: u16) !WavWriter {
        var w: WavWriter = .{
            .sink = sink,
            .sample_rate = sample_rate,
            .channels = channels,
            .data_bytes = 0,
        };
        var header: [44]u8 = undefined;
        writeHeader(&header, sample_rate, channels, 0);
        try w.writeAll(&header);
        return w;
    }

    /// Appends interleaved PCM16 frames (raw bytes, little-endian s16).
    pub fn writeFrames(self: *WavWriter, pcm: []const u8) !void {
        if (pcm.len == 0) return;
        try self.writeAll(pcm);
        self.data_bytes += pcm.len;
    }

    /// Patches the RIFF and data chunk sizes so parsers see the real length.
    pub fn finalize(self: *WavWriter) !u64 {
        if (self.data_bytes > std.math.maxInt(u32)) return error.TooLarge;
        const data: u32 = @intCast(self.data_bytes);
        switch (self.sink) {
            .file => |f| {
                var sizes: [4]u8 = undefined;
                std.mem.writeInt(u32, &sizes, 36 + data, .little);
                try f.file.writePositionalAll(f.io, &sizes, 4);
                std.mem.writeInt(u32, &sizes, data, .little);
                try f.file.writePositionalAll(f.io, &sizes, 40);
            },
            .mem => |m| {
                const bytes = m.list.items;
                if (bytes.len >= 44) {
                    std.mem.writeInt(u32, bytes[4..8], 36 + data, .little);
                    std.mem.writeInt(u32, bytes[40..44], data, .little);
                }
            },
        }
        return self.data_bytes;
    }

    fn writeAll(self: *WavWriter, bytes: []const u8) !void {
        switch (self.sink) {
            .file => |f| try f.file.writeStreamingAll(f.io, bytes),
            .mem => |m| try m.list.appendSlice(m.gpa, bytes),
        }
    }
};

/// Parses fmt/data chunks from an in-memory RIFF/WAVE image and returns
/// sample rate, channel count and duration in seconds.
pub fn parseWavDuration(data: []const u8) WavError!WavInfo {
    if (data.len < 44) return error.NotWav;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) {
        return error.NotWav;
    }

    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var byte_rate: u32 = 0;
    var data_bytes: ?u64 = null;

    var off: usize = 12;
    while (off + 8 <= data.len) {
        const id = data[off .. off + 4];
        const size = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const body = off + 8;
        if (body + size > data.len) return error.NotWav;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.NotWav;
            const format = std.mem.readInt(u16, data[body..][0..2], .little);
            if (format != 1) return error.UnsupportedFormat;
            channels = std.mem.readInt(u16, data[body + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, data[body + 4 ..][0..4], .little);
            byte_rate = std.mem.readInt(u32, data[body + 8 ..][0..4], .little);
            const bits = std.mem.readInt(u16, data[body + 14 ..][0..2], .little);
            if (bits != 16 or channels == 0 or byte_rate == 0) return error.NotWav;
        } else if (std.mem.eql(u8, id, "data")) {
            data_bytes = size;
        }

        off = body + size + (size & 1); // chunks are word-aligned
    }

    if (sample_rate == 0 or data_bytes == null) return error.MissingDataChunk;
    const duration: f64 = @as(f64, @floatFromInt(data_bytes.?)) / @as(f64, @floatFromInt(byte_rate));
    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .duration_sec = duration,
    };
}

test "header round-trip" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    var w = try WavWriter.init(.{ .mem = .{ .gpa = std.testing.allocator, .list = &list } }, 48000, 2);
    // 4800 stereo frames of PCM16 = 19200 bytes = 0.1 s at 48 kHz.
    const frames = [_]u8{0xAB} ** 19200;
    try w.writeFrames(&frames);
    const written = try w.finalize();

    try std.testing.expectEqual(@as(u64, 19200), written);
    try std.testing.expectEqual(@as(usize, 44 + 19200), list.items.len);
    try std.testing.expectEqualStrings("RIFF", list.items[0..4]);
    try std.testing.expectEqualStrings("WAVE", list.items[8..12]);
    try std.testing.expectEqualStrings("data", list.items[36..40]);
    try std.testing.expectEqual(@as(u32, 19200), std.mem.readInt(u32, list.items[40..44], .little));
    try std.testing.expectEqual(@as(u32, 36 + 19200), std.mem.readInt(u32, list.items[4..8], .little));

    const info = try parseWavDuration(list.items);
    try std.testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), info.channels);
    try std.testing.expect(@abs(info.duration_sec - 0.1) < 0.000001);
}

test "duration parsing across formats and failures" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    var w = try WavWriter.init(.{ .mem = .{ .gpa = std.testing.allocator, .list = &list } }, 8000, 1);
    // 8000 mono frames = 16000 bytes = 1.0 s at 8 kHz.
    try w.writeFrames(&([_]u8{0} ** 16000));
    _ = try w.finalize();

    const info = try parseWavDuration(list.items);
    try std.testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), info.channels);
    try std.testing.expect(@abs(info.duration_sec - 1.0) < 0.000001);

    // Truncated and non-WAV inputs must be rejected, not mis-parsed.
    try std.testing.expectError(error.NotWav, parseWavDuration(list.items[0..20]));
    try std.testing.expectError(error.NotWav, parseWavDuration("not a wav file at all...."));
    try std.testing.expectError(error.NotWav, parseWavDuration(&[_]u8{}));
}
