//! Indexed, wrapped terminal rows shared by the reader and audio view.
const std = @import("std");
const keys = @import("keys.zig");
const live = @import("live.zig");
const style = @import("style.zig");

pub const mouse_on = "\x1b[?1000h\x1b[?1006h";
pub const mouse_off = "\x1b[?1006l\x1b[?1000l";

pub const Document = struct {
    bytes: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(usize) = .empty,
    width: usize = 0,

    pub fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.starts.deinit(gpa);
    }

    pub fn set(self: *Document, gpa: std.mem.Allocator, text: []const u8, width: usize) !void {
        self.bytes.clearRetainingCapacity();
        self.starts.clearRetainingCapacity();
        self.width = @max(width, 1);
        if (text.len == 0) return;
        try self.starts.append(gpa, 0);
        var col: usize = 0;
        var i: usize = 0;
        var active: []const u8 = "";
        while (i < text.len) {
            const len = tokenLen(text[i..]);
            const token = text[i..][0..len];
            i += len;
            if (token[0] == 0x1b) {
                if (std.mem.endsWith(u8, token, "m")) {
                    active = if (std.mem.eql(u8, token, style.reset)) "" else token;
                    try self.bytes.appendSlice(gpa, token);
                }
                continue;
            }
            if (token[0] == '\n') {
                try self.newline(gpa, active, i < text.len);
                col = 0;
                continue;
            }
            if (token[0] < 32 and token[0] != '\t') continue;
            const cells = if (token[0] == '\t') 4 - col % 4 else cellWidth(token);
            if (col + cells > self.width and col > 0) {
                try self.newline(gpa, active, true);
                col = 0;
            }
            if (token[0] == '\t') {
                try self.bytes.appendNTimes(gpa, ' ', @min(cells, self.width));
            } else if (cells <= self.width) try self.bytes.appendSlice(gpa, token);
            col += cells;
        }
    }

    fn newline(self: *Document, gpa: std.mem.Allocator, active: []const u8, more: bool) !void {
        try self.bytes.appendSlice(gpa, style.reset ++ "\n");
        if (more) {
            try self.starts.append(gpa, self.bytes.items.len);
            try self.bytes.appendSlice(gpa, active);
        }
    }

    pub fn line(self: *const Document, index: usize) []const u8 {
        if (index >= self.starts.items.len) return "";
        const start = self.starts.items[index];
        const end = if (index + 1 < self.starts.items.len) self.starts.items[index + 1] else self.bytes.items.len;
        return std.mem.trimEnd(u8, self.bytes.items[start..end], "\n");
    }
};

pub fn tokenLen(text: []const u8) usize {
    if (text[0] == 0x1b and text.len > 1 and text[1] == '[') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
        return text.len;
    }
    return @min(std.unicode.utf8ByteSequenceLength(text[0]) catch 1, text.len);
}

fn cellWidth(token: []const u8) usize {
    const cp = std.unicode.utf8Decode(token) catch return 1;
    if ((cp >= 0x300 and cp <= 0x36f) or cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0x1f300 and cp <= 0x1faff) or cp >= 0x20000) return 2;
    return 1;
}

pub fn clipped(text: []const u8, width: usize) []const u8 {
    var i: usize = 0;
    var col: usize = 0;
    while (i < text.len) {
        const len = tokenLen(text[i..]);
        const cells = if (text[i] == 0x1b) 0 else cellWidth(text[i..][0..len]);
        if (text[i] == '\n' or col + cells > width) break;
        col += cells;
        i += len;
    }
    return text[0..i];
}

pub fn navigate(offset: *usize, key: keys.Key, total: usize, rows: usize) bool {
    const limit = total -| rows;
    switch (key) {
        .up => offset.* -|= 1,
        .down => offset.* = @min(offset.* + 1, limit),
        .wheel_up => offset.* -|= 3,
        .wheel_down => offset.* = @min(offset.* + 3, limit),
        .page_up => offset.* -|= @max(rows -| 1, 1),
        .page_down => offset.* = @min(offset.* + @max(rows -| 1, 1), limit),
        .home => offset.* = 0,
        .end => offset.* = limit,
        else => return false,
    }
    return true;
}

pub const Screen = struct {
    previous: std.ArrayList(u8) = .empty,
    next: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        self.previous.deinit(gpa);
        self.next.deinit(gpa);
    }

    pub fn paint(self: *Screen, io: std.Io, gpa: std.mem.Allocator, head: *const Document, body: *const Document, offset: *usize, rows: usize, width: usize, footer: []const u8) !void {
        const count = head.starts.items.len + body.starts.items.len;
        const visible = rows -| 1;
        offset.* = @min(offset.*, count -| visible);
        self.next.clearRetainingCapacity();
        var esc: [32]u8 = undefined;
        try self.next.appendSlice(gpa, live.sync_begin);
        for (0..rows) |r| {
            try self.next.appendSlice(gpa, live.moveTo(&esc, r + 1, 1));
            const index = offset.* + r;
            const text = if (r == visible) footer else if (index < head.starts.items.len) head.line(index) else body.line(index - head.starts.items.len);
            try self.next.appendSlice(gpa, clipped(text, width));
            try self.next.appendSlice(gpa, style.reset ++ "\x1b[K");
        }
        try self.next.appendSlice(gpa, live.sync_end);
        if (!std.mem.eql(u8, self.previous.items, self.next.items)) {
            try std.Io.File.writeStreamingAll(.stderr(), io, self.next.items);
            std.mem.swap(std.ArrayList(u8), &self.previous, &self.next);
        }
    }
};

test "indexed wrapping preserves wide glyphs and style on each row" {
    var doc = Document{};
    defer doc.deinit(std.testing.allocator);
    try doc.set(std.testing.allocator, "\x1b[1mab界cd\x1b[0m\nlast", 4);
    try std.testing.expectEqual(@as(usize, 3), doc.starts.items.len);
    try std.testing.expectEqualStrings("\x1b[1mab界\x1b[0m", doc.line(0));
    try std.testing.expect(std.mem.startsWith(u8, doc.line(1), "\x1b[1mcd"));
    try std.testing.expectEqualStrings("last", doc.line(2));
    try std.testing.expectEqualStrings("ab", clipped("ab界", 3));
}
