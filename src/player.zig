//! In-process playback: interleaved s16le PCM on the default output device
//! through the vendored miniaudio — the same PCM `cut.loadPcm` decodes for
//! the waveform, so playing costs no extra memory and no child process.
//! The data callback copies frames from the borrowed PCM at the playhead
//! and advances it; pausing gates the copy, seeking stores a new playhead.
//! Everything the UI reads (position, paused, done) is atomic, so the
//! callback stays lock-free and the UI stays lock-free.

const std = @import("std");

pub const ma = @cImport({
    @cInclude("miniaudio.h");
});

pub const Player = struct {
    ctx: ma.ma_context = undefined,
    device: ma.ma_device = undefined,
    /// The audio being played; borrowed and immutable while the device runs.
    pcm: []const u8 = &.{},
    channels: u16 = 2,
    sample_rate: u32 = 48000,
    /// The playhead in frames. The callback advances it; seek stores into
    /// it; both sides use atomics, so a seek lands on a callback boundary.
    pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set once the playhead reached the end.
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: bool = false,

    /// Initializes the default playback device for `pcm`'s layout and
    /// starts it (miniaudio resamples to the hardware rate when needed).
    pub fn start(self: *Player, pcm: []const u8, sample_rate: u32, channels: u16) !void {
        self.pcm = pcm;
        self.sample_rate = sample_rate;
        self.channels = @max(channels, 1);
        self.pos.store(0, .release);
        self.paused.store(false, .release);
        self.done.store(pcm.len == 0, .release);

        if (ma.ma_context_init(null, 0, null, &self.ctx) != ma.MA_SUCCESS) {
            return error.AudioBackendInit;
        }
        errdefer _ = ma.ma_context_uninit(&self.ctx);

        var dc = ma.ma_device_config_init(ma.ma_device_type_playback);
        dc.sampleRate = sample_rate;
        dc.playback.format = ma.ma_format_s16;
        dc.playback.channels = self.channels;
        dc.dataCallback = dataCallback;
        dc.pUserData = self;

        if (ma.ma_device_init(&self.ctx, &dc, &self.device) != ma.MA_SUCCESS) {
            return error.DeviceInit;
        }
        errdefer _ = ma.ma_device_uninit(&self.device);

        if (ma.ma_device_start(&self.device) != ma.MA_SUCCESS) {
            return error.DeviceStart;
        }
        self.started = true;
    }

    /// Stops the device; once this returns, no more data callbacks run.
    pub fn stop(self: *Player) void {
        if (self.started) {
            _ = ma.ma_device_stop(&self.device);
        }
    }

    pub fn deinit(self: *Player) void {
        if (self.started) {
            _ = ma.ma_device_stop(&self.device);
            _ = ma.ma_device_uninit(&self.device);
            _ = ma.ma_context_uninit(&self.ctx);
            self.started = false;
        }
    }

    /// Bytes of PCM per second.
    fn bytesPerSec(self: *const Player) u64 {
        return @as(u64, self.sample_rate) * self.channels * 2;
    }

    pub fn durationSec(self: *const Player) f64 {
        return @as(f64, @floatFromInt(self.pcm.len)) / @as(f64, @floatFromInt(self.bytesPerSec()));
    }

    /// The playhead in seconds; frozen while paused.
    pub fn positionSec(self: *const Player) f64 {
        const pos = self.pos.load(.acquire);
        return @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Moves the playhead to `sec`, clamped to the audio's edges.
    pub fn seekSec(self: *Player, sec: f64) void {
        const clamped = @min(@max(sec, 0), self.durationSec());
        const frame: u64 = @intFromFloat(clamped * @as(f64, @floatFromInt(self.sample_rate)));
        self.done.store(frame >= self.totalFrames(), .release);
        self.pos.store(frame, .release);
    }

    /// Moves the playhead by `delta` seconds, clamped to the edges.
    pub fn seekBy(self: *Player, delta: f64) void {
        self.seekSec(self.positionSec() + delta);
    }

    pub fn setPaused(self: *Player, p: bool) void {
        self.paused.store(p, .release);
    }

    pub fn isDone(self: *const Player) bool {
        return self.done.load(.acquire);
    }

    fn totalFrames(self: *const Player) u64 {
        return self.pcm.len / (@as(usize, self.channels) * 2);
    }
};

fn dataCallback(
    p_device: ?*ma.ma_device,
    p_output: ?*anyopaque,
    p_input: ?*const anyopaque,
    frame_count: ma.ma_uint32,
) callconv(.c) void {
    _ = p_input;
    const device = p_device orelse return;
    const out: [*]u8 = @ptrCast(p_output orelse return);
    const self: *Player = @ptrCast(@alignCast(device.pUserData));

    const frame_bytes = @as(usize, self.channels) * 2;
    const bytes = @as(usize, frame_count) * frame_bytes;

    // Paused: silence, and the playhead freezes where it is.
    if (self.paused.load(.acquire)) {
        @memset(out[0..bytes], 0);
        return;
    }

    var pos = self.pos.load(.acquire);
    const total = self.totalFrames();
    if (pos >= total) {
        @memset(out[0..bytes], 0);
        self.done.store(true, .release);
        return;
    }

    const take = @min(@as(usize, frame_count), total - pos);
    const take_bytes = take * frame_bytes;
    const src = self.pcm[pos * frame_bytes ..][0..take_bytes];
    @memcpy(out[0..take_bytes], src);
    pos += take;
    self.pos.store(pos, .release);
    if (pos >= total) self.done.store(true, .release);
    // A short read (past the end) pads with silence.
    if (take_bytes < bytes) @memset(out[take_bytes..bytes], 0);
}

// --- pure-view tests ----------------------------------------------------------

const testing = std.testing;

/// A player with the callback never started: the pure seek/position math
/// still runs against a pretend PCM body.
fn idlePlayer(pcm_len: usize, sample_rate: u32, channels: u16) Player {
    return .{ .pcm = @as([*]const u8, @ptrFromInt(0x1000))[0..pcm_len], .sample_rate = sample_rate, .channels = channels };
}

test "position and duration map frames to seconds" {
    var p = idlePlayer(48000 * 2 * 2, 48000, 2); // exactly one second
    try testing.expectEqual(@as(f64, 1.0), p.durationSec());
    try testing.expectEqual(@as(f64, 0.0), p.positionSec());

    p.pos.store(24000, .release);
    try testing.expectApproxEqAbs(@as(f64, 0.5), p.positionSec(), 1e-9);
}

test "seekSec clamps to the audio's edges" {
    var p = idlePlayer(48000 * 2 * 2, 48000, 2);
    p.seekSec(-5);
    try testing.expectEqual(@as(u64, 0), p.pos.load(.acquire));

    p.seekSec(100);
    try testing.expectEqual(@as(f64, 1.0), p.positionSec());
    try testing.expect(p.isDone()); // parked at the end

    p.seekSec(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.25), p.positionSec(), 1e-9);
    try testing.expect(!p.isDone());
}

test "seekBy moves relative to the playhead" {
    var p = idlePlayer(48000 * 2 * 2 * 2, 48000, 2); // two seconds
    p.seekBy(1.5);
    try testing.expectApproxEqAbs(@as(f64, 1.5), p.positionSec(), 1e-9);
    p.seekBy(5);
    try testing.expectEqual(@as(f64, 2.0), p.positionSec());
    p.seekBy(-10);
    try testing.expectEqual(@as(f64, 0.0), p.positionSec());
}

test "an empty body has no duration and no position" {
    var p = Player{};
    try testing.expectEqual(@as(f64, 0.0), p.durationSec());
    try testing.expectEqual(@as(f64, 0.0), p.positionSec());
}
