//! Display-side analysis of the decoded PCM, never the audio callback.
//! The vendored miniaudio biquads provide a logarithmic band-pass bank.
const std = @import("std");
const ma = @import("player.zig").ma;

pub const bands = 40;
pub const history_len = 18;
pub const scope_len = 256;
const window_frames: usize = 4096;

pub const Analysis = struct {
    energy: [bands]f32 = @splat(0),
    peaks: [bands]f32 = @splat(0),
    history: [history_len][bands]f32 = @splat(@splat(0)),
    scope: [scope_len][2]f32 = @splat(@splat(0)),
    level: [2]f32 = @splat(0),
    last_frame: ?usize = null,

    pub fn update(self: *Analysis, pcm: []const u8, rate: u32, channels: u32, position: usize) void {
        const stride = @as(usize, @max(channels, 1)) * 2;
        const end = @min(position, pcm.len / stride);
        if (self.last_frame == end) return;
        const discontinuity = if (self.last_frame) |last| end < last or end -| last > window_frames else true;
        if (discontinuity) self.* = .{};
        self.last_frame = end;
        var input: [window_frames * 2]f32 = @splat(0);
        const count: usize = @min(end, window_frames);
        readWindow(pcm, stride, end - count, input[(window_frames - count) * 2 ..]);
        removeOffset(&input);
        self.measure(&input, rate);
        self.trace(&input);
        var depth: usize = history_len - 1;
        while (depth > 0) : (depth -= 1) self.history[depth] = self.history[depth - 1];
        self.history[0] = self.energy;
    }

    fn measure(self: *Analysis, input: []const f32, rate: u32) void {
        var output: [window_frames * 2]f32 = undefined;
        for (0..bands) |b| {
            var filter: ma.ma_bpf2 = undefined;
            var heap: [128]u8 align(16) = undefined;
            const config = ma.ma_bpf2_config_init(ma.ma_format_f32, 2, rate, frequency(b, rate), 4.0);
            var size: usize = 0;
            if (ma.ma_bpf2_get_heap_size(&config, &size) != ma.MA_SUCCESS or size > heap.len) continue;
            if (ma.ma_bpf2_init_preallocated(&config, &heap, &filter) != ma.MA_SUCCESS) continue;
            _ = ma.ma_bpf2_process_pcm_frames(&filter, &output, input.ptr, window_frames);
            // Discard the filter's warm-up; stereo energy cannot phase-cancel.
            const value = magnitude(rms(output[window_frames..]));
            self.energy[b] += (value - self.energy[b]) * (if (value > self.energy[b]) @as(f32, 0.8) else 0.24);
            self.peaks[b] = @max(self.energy[b], self.peaks[b] - 0.018);
        }
        var sum: [2]f32 = @splat(0);
        for (input[input.len - 1024 ..], 0..) |s, i| sum[i % 2] += s * s;
        for (0..2) |ch| self.level[ch] = @sqrt(sum[ch] / 512);
    }

    fn trace(self: *Analysis, input: []const f32) void {
        // A rising zero crossing stabilizes periodic signals without inventing motion.
        var start: usize = window_frames - scope_len;
        var i: usize = window_frames - scope_len * 2;
        while (i < window_frames - scope_len) : (i += 1) {
            if (input[i * 2] <= 0 and input[(i + 1) * 2] > 0) {
                start = i;
                break;
            }
        }
        for (&self.scope, 0..) |*point, x| point.* = .{ input[(start + x) * 2], input[(start + x) * 2 + 1] };
    }
};

// Restarting a filter on an offset window otherwise manufactures a transient.
fn removeOffset(input: []f32) void {
    var mean: [2]f32 = @splat(0);
    for (input, 0..) |value, i| mean[i % 2] += value;
    for (&mean) |*value| value.* /= @as(f32, @floatFromInt(input.len / 2));
    for (input, 0..) |*value, i| value.* -= mean[i % 2];
}

fn readWindow(pcm: []const u8, stride: usize, start: usize, output: []f32) void {
    for (0..output.len / 2) |i| {
        const offset = (start + i) * stride;
        output[i * 2] = sample(pcm[offset..][0..2]);
        output[i * 2 + 1] = sample(pcm[offset + @min(stride - 2, 2) ..][0..2]);
    }
}

fn sample(bytes: *const [2]u8) f32 {
    return @as(f32, @floatFromInt(std.mem.readInt(i16, bytes, .little))) / 32768.0;
}

pub fn frequency(band: usize, rate: u32) f64 {
    const high = @min(16000.0, @as(f64, @floatFromInt(rate)) * 0.45);
    return 45.0 * std.math.pow(f64, high / 45.0, @as(f64, @floatFromInt(band)) / (bands - 1));
}

fn rms(values: []const f32) f32 {
    var sum: f32 = 0;
    for (values) |v| sum += v * v;
    return @sqrt(sum / @as(f32, @floatFromInt(values.len)));
}

pub fn magnitude(value: f32) f32 {
    return std.math.clamp((20 * @log10(@max(value, 0.000001)) + 60) / 60, 0, 1);
}
