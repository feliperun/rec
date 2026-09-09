const std = @import("std");
const spectrum = @import("spectrum.zig");
const expect = std.testing.expect;

fn tone(pcm: []u8, hz: f64, opposite: bool) void {
    for (0..pcm.len / 4) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48000;
        const value: i16 = @intFromFloat(@sin(t * hz * 2 * std.math.pi) * 24000);
        std.mem.writeInt(i16, pcm[i * 4 ..][0..2], value, .little);
        std.mem.writeInt(i16, pcm[i * 4 + 2 ..][0..2], if (opposite) -value else value, .little);
    }
}

test "band energy follows actual frequency, including opposite-phase stereo" {
    var pcm: [4096 * 4]u8 = undefined;
    for ([_]f64{ 110, 1000, 8000 }) |hz| {
        var analysis = spectrum.Analysis{};
        tone(&pcm, hz, true);
        analysis.update(&pcm, 48000, 2, 4096);
        const peak = std.sort.argMax(f32, &analysis.energy, {}, std.sort.asc(f32)).?;
        const measured = spectrum.frequency(peak, 48000);
        try expect(measured > hz * 0.8 and measured < hz * 1.2);
        try expect(analysis.energy[peak] > 0.6);
        try std.testing.expectApproxEqAbs(analysis.level[0], analysis.level[1], 0.00001);
    }
}

test "silence and empty or incomplete PCM stay silent and bounded" {
    var analysis = spectrum.Analysis{};
    const silence: [4096 * 4]u8 = @splat(0);
    analysis.update(&silence, 48000, 2, 4096);
    for (analysis.energy) |v| try std.testing.expectEqual(@as(f32, 0), v);
    analysis.update(&.{}, 48000, 1, 9000);
    analysis.update(&.{ 0, 0, 255 }, 48000, 1, 9000);
    for (analysis.energy) |v| try expect(std.math.isFinite(v) and v == 0);
}

test "pause freezes history and seeking clears old energy" {
    var pcm: [8192 * 4]u8 = @splat(0);
    tone(pcm[0 .. 4096 * 4], 1000, false);
    var analysis = spectrum.Analysis{};
    analysis.update(&pcm, 48000, 2, 4096);
    const before = analysis;
    analysis.update(&pcm, 48000, 2, 4096);
    try std.testing.expectEqualDeep(before, analysis);
    analysis.update(&pcm, 48000, 2, 0);
    for (analysis.history) |row| for (row) |v| try std.testing.expectEqual(@as(f32, 0), v);
}
