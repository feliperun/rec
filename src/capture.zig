const std = @import("std");
const wav = @import("wav.zig");

pub const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// Set from the SIGINT handler (async-signal-safe: atomic store only).
var g_stop = std.atomic.Value(bool).init(false);

pub fn requestStop() void {
    g_stop.store(true, .release);
}

pub fn stopRequested() bool {
    return g_stop.load(.acquire);
}

pub const CaptureConfig = struct {
    sample_rate: u32 = 48000,
    channels: u16 = 2,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    ctx: ma.ma_context,
    device: ma.ma_device,
    pcm: std.ArrayList(u8),
    frames_written: std.atomic.Value(u64),
    sample_rate: u32,
    channels: u16,
    started: bool,

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{
            .gpa = gpa,
            .ctx = undefined,
            .device = undefined,
            .pcm = .empty,
            .frames_written = std.atomic.Value(u64).init(0),
            .sample_rate = 48000,
            .channels = 2,
            .started = false,
        };
    }

    /// Initializes the default capture device (s16 / stereo / 48 kHz) and
    /// starts it; the data callback appends PCM frames to `pcm`.
    pub fn start(self: *Recorder, cfg: CaptureConfig) !void {
        self.sample_rate = cfg.sample_rate;
        self.channels = cfg.channels;

        if (ma.ma_context_init(null, 0, null, &self.ctx) != ma.MA_SUCCESS) {
            return error.AudioBackendInit;
        }

        var dc = ma.ma_device_config_init(ma.ma_device_type_capture);
        dc.sampleRate = cfg.sample_rate;
        dc.capture.format = ma.ma_format_s16;
        dc.capture.channels = cfg.channels;
        dc.dataCallback = dataCallback;
        dc.pUserData = self;

        if (ma.ma_device_init(&self.ctx, &dc, &self.device) != ma.MA_SUCCESS) {
            _ = ma.ma_context_uninit(&self.ctx);
            return error.DeviceInit;
        }
        if (ma.ma_device_start(&self.device) != ma.MA_SUCCESS) {
            _ = ma.ma_device_uninit(&self.device);
            _ = ma.ma_context_uninit(&self.ctx);
            return error.DeviceStart;
        }
        self.started = true;
    }

    /// Stops the device; once this returns, no more data callbacks run, so
    /// the main thread owns `pcm` again.
    pub fn stop(self: *Recorder) void {
        if (self.started) {
            _ = ma.ma_device_stop(&self.device);
        }
    }

    /// Streams the captured PCM into `file` (freshly created, position 0)
    /// as a finalized WAV: header first, then data, then patched sizes.
    pub fn writeWav(self: *Recorder, io: std.Io, file: std.Io.File) !u64 {
        var w = try wav.WavWriter.init(.{ .file = .{ .io = io, .file = file } }, self.sample_rate, self.channels);
        try w.writeFrames(self.pcm.items);
        return w.finalize();
    }

    pub fn capturedBytes(self: *Recorder) usize {
        return self.pcm.items.len;
    }

    pub fn deinit(self: *Recorder) void {
        if (self.started) {
            _ = ma.ma_device_stop(&self.device);
            _ = ma.ma_device_uninit(&self.device);
            _ = ma.ma_context_uninit(&self.ctx);
            self.started = false;
        }
        self.pcm.deinit(self.gpa);
    }
};

fn dataCallback(
    p_device: ?*ma.ma_device,
    p_output: ?*anyopaque,
    p_input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = p_output;
    const device = p_device orelse return;
    const input = p_input orelse return;
    const self: *Recorder = @ptrCast(@alignCast(device.pUserData));

    // Interleaved s16 frames: 2 bytes per sample, `channels` samples per frame.
    const bytes = frame_count * @as(ma.ma_uint32, self.channels) * 2;
    const src: [*]const u8 = @ptrCast(input);
    // On allocation failure the callback drops the block rather than blocking
    // the audio thread; recordings here are short enough for that to be moot.
    self.pcm.appendSlice(self.gpa, src[0..bytes]) catch return;
    _ = self.frames_written.fetchAdd(frame_count, .monotonic);
}
