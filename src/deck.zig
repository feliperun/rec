//! The listening room: responsive chrome around the audio light field.
const std = @import("std");
const library = @import("library.zig");
const ruler = @import("ruler.zig");
const spectrum = @import("spectrum.zig");
const viewport = @import("viewport.zig");
const visualizer = @import("visualizer.zig");
const waveform = @import("waveform.zig");

pub const Settings = struct {
    mode: visualizer.Mode = .aurora,
    focus: bool = false,
    help: bool = false,
    volume: u8 = 100,
    muted: bool = false,

    pub fn key(self: *Settings, c: u8) bool {
        switch (c) {
            'v', 'V' => self.mode = self.mode.next(),
            'z', 'Z' => self.focus = !self.focus,
            '?' => self.help = !self.help,
            '-', '_' => self.volume -|= 5,
            '+', '=' => self.volume = @min(self.volume + 5, 100),
            'm', 'M' => self.muted = !self.muted,
            else => return false,
        }
        return true;
    }

    pub fn gain(self: Settings) f32 {
        return if (self.muted) 0 else @as(f32, @floatFromInt(self.volume)) / 100;
    }
};

pub const Frame = struct {
    name: []const u8,
    status: []const u8,
    paused: bool,
    elapsed: f64,
    duration: f64,
    sample_rate: u32,
    channels: u32,
    blocks: []const waveform.Block,
    selection: ?[2]f64,
    note: ?[]const u8,
    color: bool,
    tabs: []const u8,
    analysis: *const spectrum.Analysis,
    settings: Settings,
};

const cyan = "\x1b[38;5;87m";
const violet = "\x1b[38;5;147m";
const muted = "\x1b[38;5;245m";
const white = "\x1b[1;38;5;255m";
const reset = "\x1b[0m";

const Canvas = struct {
    gpa: std.mem.Allocator,
    frame: *std.ArrayList(u8),
    width: usize,
    color: bool,

    fn line(self: Canvas, text: []const u8, tone: []const u8) !void {
        if (self.color) try self.frame.appendSlice(self.gpa, tone);
        try self.frame.appendSlice(self.gpa, viewport.clipped(text, self.width));
        if (self.color) try self.frame.appendSlice(self.gpa, reset);
        try self.frame.append(self.gpa, '\n');
    }

    fn print(self: Canvas, comptime fmt: []const u8, args: anytype, tone: []const u8) !void {
        var buf: [32768]u8 = undefined;
        try self.line(try std.fmt.bufPrint(&buf, fmt, args), tone);
    }
};

pub fn draw(gpa: std.mem.Allocator, frame: *std.ArrayList(u8), f: Frame, cols: usize, rows: usize) !void {
    frame.clearRetainingCapacity();
    const c = Canvas{ .gpa = gpa, .frame = frame, .width = @min(cols, waveform.max_columns), .color = f.color };
    var title_buf: [1024]u8 = undefined;
    const title = cleanTitle(library.stripExt(f.name), &title_buf);
    if (rows < 16 or cols < 42) return compact(c, f, title, rows);
    try c.print("  rec  /  LISTENING ROOM{s}", .{if (f.settings.focus) "  /  FOCUS" else ""}, cyan);
    try c.print("  {s}", .{title}, white);
    if (!f.settings.focus) {
        try c.print("  {d:.1} kHz  ·  {s}  ·  {s}", .{ @as(f64, @floatFromInt(f.sample_rate)) / 1000, if (f.channels == 1) "MONO" else "STEREO", "AUDIO + NOTES" }, muted);
        try c.line("", "");
    }
    try c.print("  {s}  /  {s}", .{ if (f.settings.help) "CONTROLS" else f.settings.mode.label(), if (f.paused) "PAUSED" else "PLAYING" }, violet);
    const reserve: usize = if (f.settings.focus) 6 else 18;
    const height = @max(@min(rows -| reserve, 40), 4);
    try stage(c, f, height);
    if (!f.settings.focus) try legend(c, f.settings.mode, f.sample_rate);
    try transport(c, f);
    if (!f.settings.focus) {
        try overview(c, f, 2);
        try c.line(f.note orelse "  I/O mark  ·  DEL cut  ·  R reset  ·  T/F notes", muted);
        try c.print("  {s}", .{f.tabs}, violet);
    } else try c.line(f.note orelse "  Z return  ·  V change visual  ·  ? controls", muted);
}

fn stage(c: Canvas, f: Frame, height: usize) !void {
    var buf: [waveform.max_columns * 40]u8 = undefined;
    const view = visualizer.View{ .analysis = f.analysis, .mode = f.settings.mode, .width = c.width -| 4, .height = height, .color = f.color };
    for (0..height) |row| {
        if (f.settings.help) {
            try c.line(helpLine(row), muted);
        } else try c.print("  {s}", .{view.row(row, &buf)}, "");
    }
}

fn helpLine(row: usize) []const u8 {
    const lines = [_][]const u8{
        "  SPACE       pause / resume       ← →         seek 1 second",
        "  V           change visual        SHIFT ← →   seek 5 seconds",
        "  Z           focus mode           0–9         jump to 0–90%",
        "  + / −       volume               M           mute / unmute",
        "  I / O       mark region          DEL         cut (asks first)",
        "  T / F       transcript / notes   Tab         switch document",
        "  ↑ ↓ / wheel scroll text          Home / End  start / end",
        "  Y / S       copy / share         C / L / G   share to AI",
        "  ?           close controls       Q / Ctrl-C  quit",
    };
    return if (row < lines.len) lines[row] else "";
}

fn legend(c: Canvas, mode: visualizer.Mode, rate: u32) !void {
    const width = c.width -| 4;
    var buf: [waveform.max_columns]u8 = @splat(' ');
    const left = if (mode == .scope) "L / CYAN" else "45 Hz";
    const center = if (mode == .scope) "STEREO WAVEFORM" else "FREQUENCY";
    var hz: [24]u8 = undefined;
    const right = if (mode == .scope) "R / ROSE" else try std.fmt.bufPrint(&hz, "{d:.1} kHz", .{spectrum.frequency(spectrum.bands - 1, rate) / 1000});
    @memcpy(buf[0..left.len], left);
    const mid = (width -| center.len) / 2;
    @memcpy(buf[mid..][0..center.len], center);
    @memcpy(buf[width -| right.len..][0..right.len], right);
    try c.print("  {s}", .{buf[0..width]}, muted);
}

fn transport(c: Canvas, f: Frame) !void {
    var volume: [32]u8 = undefined;
    const gain = if (f.settings.muted) "MUTED" else try std.fmt.bufPrint(&volume, "VOL {d}%", .{f.settings.volume});
    var right_buf: [128]u8 = undefined;
    var left_meter: [32]u8 = undefined;
    var right_meter: [32]u8 = undefined;
    const right = if (c.width >= 90) try std.fmt.bufPrint(&right_buf, "L {s}  R {s}    {s}  ", .{ meter(f.analysis.level[0], &left_meter), meter(f.analysis.level[1], &right_meter), gain }) else gain;
    var buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try out.print("  {s}", .{f.status});
    const gap = @max(c.width -| (cells(f.status) + cells(right) + 2), 2);
    for (0..gap) |_| try out.writeByte(' ');
    try out.writeAll(right);
    try c.line(out.buffered(), "");
}

fn meter(level: f32, buf: []u8) []const u8 {
    var out = std.Io.Writer.fixed(buf);
    const filled: usize = @intFromFloat(spectrum.magnitude(level) * 6);
    for (0..6) |i| out.writeAll(if (i < filled) "▰" else "▱") catch break;
    return out.buffered();
}

fn cells(text: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) count += 1;
        i += viewport.tokenLen(text[i..]);
    }
    return count;
}

fn overview(c: Canvas, f: Frame, height: usize) !void {
    var columns: [waveform.max_columns]waveform.Column = undefined;
    const width = c.width -| 4;
    const cols = waveform.layoutColumns(f.blocks, columns[0..width], .fit);
    const selection: ?waveform.SelRange = if (f.selection) |s| .{ .start_col = playedCols(width, s[0], f.duration), .end_col = playedCols(width, s[1], f.duration) } else null;
    var buf: [waveform.max_columns * 40]u8 = undefined;
    for (0..height) |row| {
        const line = waveform.renderRow(cols, height, row, .{ .played_cols = width, .cursor_col = @min(playedCols(width, f.elapsed, f.duration), width -| 1), .sel = selection, .sel_edges = selection, .color = f.color }, &buf);
        try c.print("  {s}", .{line}, "");
    }
    const axis = ruler.Axis{ .origin_ms = 0, .ms_per_col = @max(f.duration, 0.001) * 1000 / @as(f64, @floatFromInt(@max(width, 1))) };
    try c.print("  {s}", .{ruler.renderLabels(&buf, width, axis)}, muted);
}

fn compact(c: Canvas, f: Frame, title: []const u8, rows: usize) !void {
    try c.print("{s} · {s}", .{ f.settings.mode.label(), title }, cyan);
    try transport(c, f);
    if (f.settings.help) {
        try c.line("CONTROLS", violet);
        const lines = [_][]const u8{
            "SPACE  pause / resume",
            "← →  seek 1 second",
            "SHIFT ← →  seek 5 seconds",
            "0–9  jump to 0–90%",
            "V  change visual",
            "Z  toggle focus",
            "+ / -  volume",
            "M  mute / unmute",
            "I / O  mark region",
            "DEL  cut; ENTER confirms",
            "R  clear marks",
            "T / F  transcript / notes",
            "Tab  switch document",
            "↑ ↓ / wheel  scroll",
            "Home / End  start / end",
            "Y / S  copy / share",
            "C / L / G  share to AI",
            "?  close controls",
            "Q / Ctrl-C  quit",
        };
        for (lines) |line| try c.line(line, muted);
        return;
    }
    try c.line(if (f.paused) "PAUSED" else "PLAYING", violet);
    if (rows >= 9) try overview(c, f, 2);
    try c.line(f.note orelse "V visual · Z focus · ? help", muted);
}

pub fn footer(cols: usize, color: bool) []const u8 {
    const small = "Q quit · SPACE · ? help";
    const medium = "  SPACE play  ←→ seek  V visual  Z focus  ? help  Q quit";
    const full = "  SPACE play / pause   ← → seek   V visual   Z focus   + − volume   ? controls   Q quit";
    if (cols < 42) return if (color) muted ++ small ++ reset else small;
    if (cols < 85) return if (color) muted ++ medium ++ reset else medium;
    return if (color) muted ++ full ++ reset else full;
}

pub fn playedCols(width: usize, elapsed: f64, duration: f64) usize {
    if (duration <= 0) return 0;
    return @intFromFloat(std.math.clamp(elapsed / duration, 0, 1) * @as(f64, @floatFromInt(width)));
}

fn cleanTitle(name: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < name.len) {
        const len = viewport.tokenLen(name[i..]);
        const token = name[i..][0..len];
        i += len;
        if (token[0] < 32 or token[0] == 127) continue;
        if (n + len > buf.len) break;
        @memcpy(buf[n..][0..len], token);
        n += len;
    }
    return buf[0..n];
}

test "volume stays bounded and mute preserves the selected level" {
    var settings = Settings{};
    for (0..30) |_| _ = settings.key('-');
    try std.testing.expectEqual(@as(f32, 0), settings.gain());
    for (0..30) |_| _ = settings.key('+');
    try std.testing.expectEqual(@as(f32, 1), settings.gain());
    _ = settings.key('-');
    _ = settings.key('m');
    try std.testing.expectEqual(@as(f32, 0), settings.gain());
    _ = settings.key('m');
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), settings.gain(), 0.0001);
}

test "a recording title cannot inject terminal commands or extra rows" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Northern Lights", cleanTitle("Northern\n\x1b[31m Lights\x1b[0m", &buf));
}

test "focus leaves transcript and formatted note shortcuts available" {
    var settings = Settings{};
    try std.testing.expect(!settings.key('f'));
    try std.testing.expect(!settings.key('F'));
    try std.testing.expect(!settings.key('t'));
    try std.testing.expect(settings.key('z'));
    try std.testing.expect(settings.focus);
    try std.testing.expect(settings.key('Z'));
    try std.testing.expect(!settings.focus);
}
