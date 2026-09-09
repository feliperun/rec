//! Braille contours and half-block bars. Every moving contour comes from PCM measurements.
const std = @import("std");
const spectrum = @import("spectrum.zig");

pub const Mode = enum {
    aurora,
    spectrum,
    scope,

    pub fn next(self: Mode) Mode {
        return @enumFromInt((@intFromEnum(self) + 1) % 3);
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .aurora => "AURORA",
            .spectrum => "SPECTRUM",
            .scope => "SCOPE",
        };
    }
};

pub const View = struct {
    analysis: *const spectrum.Analysis,
    mode: Mode,
    width: usize,
    height: usize,
    color: bool,

    pub fn row(self: View, y: usize, buf: []u8) []const u8 {
        if (self.mode != .spectrum) return self.dots(y, buf);
        var out = std.Io.Writer.fixed(buf);
        var previous: [2]u8 = .{ 0, 0 };
        for (0..self.width) |x| {
            const top = self.pixel(x, y * 2);
            const bottom = self.pixel(x, y * 2 + 1);
            if (self.color) {
                const pair = [2]u8{ ink(top), ink(bottom) };
                if (!std.mem.eql(u8, &pair, &previous)) {
                    out.print("\x1b[38;5;{d};48;5;{d}m", .{ pair[0], pair[1] }) catch break;
                    previous = pair;
                }
                out.writeAll("▀") catch break;
            } else {
                const shades = [_][]const u8{ " ", "·", "░", "▒", "▓", "█" };
                const i: usize = @intFromFloat(@min(@max(top.light, bottom.light), 1) * 5);
                out.writeAll(shades[i]) catch break;
            }
        }
        if (self.color) out.writeAll("\x1b[0m") catch {};
        return out.buffered();
    }

    fn dots(self: View, row_index: usize, buf: []u8) []const u8 {
        var out = std.Io.Writer.fixed(buf);
        var previous: u8 = 0;
        const masks = [4][2]u8{ .{ 1, 8 }, .{ 2, 16 }, .{ 4, 32 }, .{ 64, 128 } };
        for (0..self.width) |col| {
            var bits: u8 = 0;
            var brightest = Pixel{ .light = 0, .hue = 0 };
            for (masks, 0..) |pair, dy| {
                for (pair, 0..) |bit, dx| {
                    const x = @as(f32, @floatFromInt(col * 2 + dx)) / @as(f32, @floatFromInt(@max(self.width * 2 -| 1, 1)));
                    const y: f32 = @floatFromInt(row_index * 4 + dy);
                    const h: f32 = @floatFromInt(self.height * 4);
                    const point = if (self.mode == .aurora) Pixel{ .light = self.aurora(x, y, h), .hue = x } else self.scope(x, y, h);
                    if (point.light > 0.24) bits |= bit;
                    if (point.light > brightest.light) brightest = point;
                }
            }
            const color = ink(brightest);
            if (self.color and color != previous) {
                out.print("\x1b[38;5;{d};48;5;232m", .{color}) catch break;
                previous = color;
            }
            if (bits == 0) {
                out.writeByte(' ') catch break;
            } else {
                var glyph: [3]u8 = undefined;
                const len = std.unicode.utf8Encode(@as(u21, 0x2800) + bits, &glyph) catch unreachable;
                out.writeAll(glyph[0..len]) catch break;
            }
        }
        if (self.color) out.writeAll("\x1b[0m") catch {};
        return out.buffered();
    }

    fn pixel(self: View, x: usize, y: usize) Pixel {
        const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(self.width -| 1, 1)));
        const fy: f32 = @floatFromInt(y);
        const h: f32 = @floatFromInt(self.height * 2);
        return switch (self.mode) {
            .aurora => .{ .light = self.aurora(fx, fy, h), .hue = fx },
            .spectrum => .{ .light = self.bars(x, fy, h), .hue = 1 - fy / h },
            .scope => self.scope(fx, fy, h),
        };
    }

    fn aurora(self: View, x: f32, y: f32, height: f32) f32 {
        const horizon = height * 0.72;
        const reflected = y > horizon;
        const py = if (reflected) horizon - (y - horizon) * 1.7 else y;
        var light: f32 = 0;
        for (self.analysis.history, 0..) |band, depth| {
            const energy = interpolate(&band, x);
            if (energy < 0.015) continue;
            const d: f32 = @floatFromInt(depth);
            const crest = horizon - energy * height * 0.65 + d * 0.55;
            const distance = @abs(py - crest);
            const trail = (1 - d / spectrum.history_len);
            const ridge = if (distance < 2) trail / (1 + distance * distance * 4) else 0;
            light = @max(light, ridge);
        }
        return @min(light * (if (reflected) @as(f32, 0.38) else 1), 1);
    }

    fn bars(self: View, x: usize, y: f32, height: f32) f32 {
        const count: usize = @min(spectrum.bands, @max(self.width / 3, 1));
        const b: usize = @min(x * count / @max(self.width, 1), count - 1);
        const first = (b * self.width + count - 1) / count;
        if (x == first and self.width >= 3) return 0;
        const low = b * spectrum.bands / count;
        const high = @max(low + 1, (b + 1) * spectrum.bands / count);
        var energy: f32 = 0;
        var peak: f32 = 0;
        for (low..high) |i| {
            energy = @max(energy, self.analysis.energy[i]);
            peak = @max(peak, self.analysis.peaks[i]);
        }
        const from_bottom = height - 1 - y;
        if (peak > 0.02 and @abs(from_bottom - peak * (height - 1)) < 0.6) return 1;
        if (from_bottom < energy * height) return 0.45 + 0.45 * from_bottom / height;
        return 0;
    }

    fn scope(self: View, x: f32, y: f32, height: f32) Pixel {
        const index: usize = @intFromFloat(x * (spectrum.scope_len - 1));
        var result = Pixel{ .light = 0, .hue = 0 };
        for (0..2) |ch| {
            const center = height * (if (ch == 0) @as(f32, 0.27) else 0.73);
            const gain = @min(0.35 / @max(self.analysis.level[ch], 0.001), 6);
            const current = center - self.analysis.scope[index][ch] * gain * height * 0.23;
            const previous = center - self.analysis.scope[index -| 1][ch] * gain * height * 0.23;
            const distance = @max(@min(current, previous) - y, y - @max(current, previous));
            const light = @exp(-@max(distance, 0) * 1.8);
            if (light > result.light) result = .{ .light = light, .hue = if (ch == 0) 0.05 else 0.9 };
        }
        return result;
    }
};

const Pixel = struct { light: f32, hue: f32 };

fn ink(pixel: Pixel) u8 {
    if (pixel.light < 0.035) return 232;
    const hues = [_][4]u8{
        .{ 23, 30, 44, 87 },    .{ 24, 31, 45, 123 },
        .{ 24, 32, 75, 117 },   .{ 25, 62, 69, 111 },
        .{ 60, 61, 105, 147 },  .{ 60, 97, 141, 183 },
        .{ 53, 133, 177, 219 }, .{ 89, 132, 175, 218 },
    };
    const hue: usize = @intFromFloat(std.math.clamp(pixel.hue, 0, 1) * (hues.len - 1));
    const value: usize = @intFromFloat(@min(pixel.light, 1) * 3.99);
    return hues[hue][value];
}

fn interpolate(values: []const f32, x: f32) f32 {
    const index = x * @as(f32, @floatFromInt(values.len - 1));
    const lo: usize = @intFromFloat(index);
    const fraction = index - @as(f32, @floatFromInt(lo));
    const smooth = fraction * fraction * (3 - 2 * fraction);
    return values[lo] * (1 - smooth) + values[@min(lo + 1, values.len - 1)] * smooth;
}

test "silent aurora and spectrum do not invent signal, monochrome has no escapes" {
    const analysis = spectrum.Analysis{};
    var buf: [4096]u8 = undefined;
    for ([_]Mode{ .aurora, .spectrum }) |mode| {
        const view = View{ .analysis = &analysis, .mode = mode, .width = 40, .height = 8, .color = false };
        for (0..8) |y| try std.testing.expectEqualStrings(" " ** 40, view.row(y, &buf));
    }
}

test "every visual stays within its cell budget at narrow and wide sizes" {
    const viewport = @import("viewport.zig");
    var analysis = spectrum.Analysis{};
    analysis.energy = @splat(0.7);
    analysis.peaks = @splat(0.8);
    analysis.history = @splat(@splat(0.7));
    var buf: [512 * 40]u8 = undefined;
    for ([_]Mode{ .aurora, .spectrum, .scope }) |mode| {
        for ([_]usize{ 0, 1, 12, 40, 135, 508 }) |width| {
            const view = View{ .analysis = &analysis, .mode = mode, .width = width, .height = 12, .color = true };
            for (0..12) |y| {
                const line = view.row(y, &buf);
                try std.testing.expect(std.unicode.utf8ValidateSlice(line));
                try std.testing.expectEqualStrings(line, viewport.clipped(line, width));
            }
        }
    }
}

test "spectrum bars keep a gap at fractional cell widths" {
    var analysis = spectrum.Analysis{};
    analysis.energy = @splat(0.7);
    const view = View{ .analysis = &analysis, .mode = .spectrum, .width = 135, .height = 8, .color = false };
    var buf: [4096]u8 = undefined;
    const line = view.row(7, &buf);
    try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, line, " "));
}
