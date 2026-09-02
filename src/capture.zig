const std = @import("std");

pub const ma = @cImport({
    @cInclude("miniaudio.h");
});

/// Set from the SIGINT handler (async-signal-safe: atomic store only).
var g_stop = std.atomic.Value(bool).init(false);

pub fn requestStop() void {
    g_stop.store(true, .release);
}

pub fn resetStop() void {
    g_stop.store(false, .release);
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
    /// Guards `pcm` between the audio callback's appends and readers on the
    /// main thread (an append may reallocate the buffer under them). A
    /// spinlock, because the critical section is a short append or copy and
    /// the callback must never block.
    pcm_lock: std.atomic.Mutex = .unlocked,
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

    pub fn capturedBytes(self: *Recorder) usize {
        return self.pcm.items.len;
    }

    /// Copies the PCM appended since `*consumed` into `out` (replacing its
    /// contents) under the append lock, then advances `*consumed`. This is
    /// how the main thread watches the recording grow while the audio
    /// callback owns the buffer.
    pub fn takeNewPcm(self: *Recorder, out: *std.ArrayList(u8), consumed: *usize) void {
        // Never let a skipped tick replay the previous chunk to consumers.
        out.clearRetainingCapacity();
        // Skip the tick if the callback holds the lock; `consumed` does not
        // advance, so the next tick copies everything appended since then.
        if (!self.pcm_lock.tryLock()) return;
        defer self.pcm_lock.unlock();
        if (self.pcm.items.len <= consumed.*) {
            out.clearRetainingCapacity();
            return;
        }
        const slice = self.pcm.items[consumed.*..];
        out.replaceRange(self.gpa, 0, out.items.len, slice) catch {
            out.clearRetainingCapacity();
            return;
        };
        consumed.* = self.pcm.items.len;
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
    // On contention the callback drops the block rather than blocking the
    // audio thread; recordings here are short enough for that to be moot.
    if (!self.pcm_lock.tryLock()) return;
    defer self.pcm_lock.unlock();
    self.pcm.appendSlice(self.gpa, src[0..bytes]) catch return;
    _ = self.frames_written.fetchAdd(frame_count, .monotonic);
}

test "takeNewPcm drains each append exactly once" {
    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.pcm.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var consumed: usize = 0;

    rec.takeNewPcm(&out, &consumed);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, out.items);
    try std.testing.expectEqual(@as(usize, 4), consumed);

    // Nothing new: out is cleared, consumed stays put.
    rec.takeNewPcm(&out, &consumed);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(usize, 4), consumed);

    // More audio arrives: only the new bytes come out.
    try rec.pcm.appendSlice(std.testing.allocator, &.{ 5, 6, 7, 8 });
    rec.takeNewPcm(&out, &consumed);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, out.items);
}

test "takeNewPcm does not replay a chunk when the callback owns the lock" {
    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.pcm.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.append(std.testing.allocator, 99);
    var consumed: usize = 0;

    rec.pcm_lock = .locked;
    defer rec.pcm_lock = .unlocked;
    rec.takeNewPcm(&out, &consumed);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(usize, 0), consumed);
}
