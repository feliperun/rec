//! Clipboard and deep-link sharing for transcript/Markdown content.

const std = @import("std");

pub const Destination = enum { clipboard, chatgpt, claude, gemini };

pub fn destinationName(d: Destination) []const u8 {
    return switch (d) {
        .clipboard => "clipboard",
        .chatgpt => "chatgpt",
        .claude => "claude",
        .gemini => "gemini",
    };
}

pub fn parseDestination(value: []const u8) ?Destination {
    if (std.mem.eql(u8, value, "clipboard") or std.mem.eql(u8, value, "copy")) return .clipboard;
    if (std.mem.eql(u8, value, "chat") or std.mem.eql(u8, value, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, value, "claude") or std.mem.eql(u8, value, "claude-code")) return .claude;
    if (std.mem.eql(u8, value, "gemini") or std.mem.eql(u8, value, "google")) return .gemini;
    return null;
}

pub fn shareText(io: std.Io, text: []const u8, destination: Destination) bool {
    if (!copyText(io, text)) return false;
    const url = switch (destination) {
        .clipboard => return true,
        .chatgpt => "https://chatgpt.com/",
        .claude => "https://claude.ai/new",
        .gemini => "https://gemini.google.com/app",
    };
    return openUrl(io, url);
}

pub fn copyText(io: std.Io, text: []const u8) bool {
    const argv_macos = [_][]const u8{"pbcopy"};
    const argv_linux = [_][]const u8{ "xclip", "-selection", "clipboard" };
    const argv_xsel = [_][]const u8{ "xsel", "--clipboard", "--input" };
    const argv_wl = [_][]const u8{"wl-copy"};
    const argv_windows = [_][]const u8{"clip.exe"};
    const os = @import("builtin").os.tag;
    if (os == .macos) return runWithInput(io, &argv_macos, text);
    if (os == .windows) return runWithInput(io, &argv_windows, text);
    return runWithInput(io, &argv_linux, text) or runWithInput(io, &argv_xsel, text) or runWithInput(io, &argv_wl, text);
}

/// Open a fixed destination; the full document is already on the clipboard.
fn openUrl(io: std.Io, link: []const u8) bool {
    const os = @import("builtin").os.tag;
    if (os == .macos) {
        const argv = [_][]const u8{ "open", link };
        return run(io, &argv);
    }
    if (os == .windows) {
        const argv = [_][]const u8{ "cmd.exe", "/c", "start", "", link };
        return run(io, &argv);
    }
    const argv = [_][]const u8{ "xdg-open", link };
    return run(io, &argv);
}

fn runWithInput(io: std.Io, argv: anytype, input: []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore }) catch return false;
    defer child.kill(io);
    if (child.stdin) |*f| {
        f.writeStreamingAll(io, input) catch {
            f.close(io);
            child.stdin = null;
            return false;
        };
        f.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn run(io: std.Io, argv: anytype) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .inherit, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "destination aliases are stable" {
    try std.testing.expectEqual(Destination.clipboard, parseDestination("copy").?);
    try std.testing.expectEqual(Destination.chatgpt, parseDestination("chat").?);
    try std.testing.expect(parseDestination("other") == null);
}
