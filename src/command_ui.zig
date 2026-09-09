//! Commands may present their result or leave presentation to the audio session.
const std = @import("std");
const markdown = @import("markdown.zig");

pub const Mode = enum {
    terminal,
    background,

    pub fn print(self: Mode, io: std.Io, text: []const u8) void {
        if (self == .terminal) std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    }

    pub fn open(self: Mode, io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
        if (self == .terminal) _ = markdown.showFile(io, gpa, path);
    }
};
