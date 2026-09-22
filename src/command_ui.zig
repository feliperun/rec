//! Commands may present their result or leave presentation to the audio session.
const std = @import("std");
const markdown = @import("markdown.zig");
const viewport = @import("viewport.zig");

/// Largest stderr message `Mode.print` filters in one call. Every real message
/// is shorter; the cap only truncates a pathological path.
const max_print_bytes = 4096;

pub const Mode = enum {
    terminal,
    background,

    pub fn print(self: Mode, io: std.Io, text: []const u8) void {
        if (self != .terminal) return;
        var buf: [max_print_bytes]u8 = undefined;
        std.Io.File.stderr().writeStreamingAll(io, filtered(text, &buf)) catch {};
    }

    pub fn open(self: Mode, io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
        if (self == .terminal) _ = markdown.showFile(io, gpa, path);
    }
};

/// The bytes `Mode.print` emits: the shared control/escape filter, with line
/// structure kept so messages stay readable while a filename echoed inside
/// them cannot inject terminal commands.
fn filtered(text: []const u8, buf: []u8) []const u8 {
    return viewport.stripControls(text, "\n\t", buf);
}

test "command output filters control bytes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "transcribe: no recording matches ']0;pwned'\n",
        filtered("transcribe: no recording matches '\x1b]0;pwned\x07'\n", &buf),
    );
}
