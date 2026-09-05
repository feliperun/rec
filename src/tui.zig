const std = @import("std");
const builtin = @import("builtin");
const capture = @import("capture.zig");
const keys = @import("keys.zig");
const library = @import("library.zig");
const playback = @import("playback.zig");
const record = @import("record.zig");
const style = @import("style.zig");

/// Set by the SIGINT handler while the interactive loop owns the terminal.
var g_sigint = std.atomic.Value(bool).init(false);
/// The cooked terminal state to restore from the handler and the exit
/// defer; non-null exactly while raw mode is on.
var g_cooked: ?keys.Cooked = null;

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_sigint.store(true, .release);
    capture.requestStop(); // stops an in-flight recording under this handler
    // Give the terminal back immediately; tcsetattr is a plain ioctl, safe
    // to call from a handler. The exit defer repeats this on the normal path.
    if (g_cooked) |t| keys.restoreRaw(t);
}

var g_old_act: std.posix.Sigaction = undefined;

fn installHandler() void {
    // Windows has no SIGINT for console apps; Ctrl-C arrives as the 0x03
    // key byte, which the menu handles.
    if (builtin.os.tag == .windows) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, &g_old_act);
}

fn restoreHandler() void {
    if (builtin.os.tag == .windows) return;
    std.posix.sigaction(std.posix.SIG.INT, &g_old_act, null);
}

const NextKey = union(enum) {
    none, // no key within the poll window
    key: u8,
    eof,
};

/// Waits up to 200 ms for a keystroke so the SIGINT flag is noticed even
/// while idle.
fn nextKey() NextKey {
    var b: u8 = 0;
    if (!keys.waitReadable(200)) return .none;
    if (!keys.readByte(&b)) return .eof;
    return .{ .key = b };
}

/// Interactive menu: raw-mode key loop over the record/list/play commands.
/// The cooked terminal state comes back via the defer and the SIGINT
/// handler, so the shell is never left broken.
pub fn runInteractive(io: std.Io, gpa: std.mem.Allocator, recordings_path: []const u8) u8 {
    // isTty first: probing raw mode on a non-tty can trip "unexpected errno"
    // dumps (macOS reports ENODEV for /dev/null) for what is an ordinary
    // failure.
    const is_tty = std.Io.File.stdin().isTty(io) catch false;
    const maybe_cooked: ?keys.Cooked = if (is_tty) keys.enableRaw() else null;
    const cooked = maybe_cooked orelse {
        printStderr(io, "interactive mode needs a terminal on stdin\n");
        return 1;
    };

    // Handler first: from here on a Ctrl-C puts the terminal back for us.
    installHandler();
    g_cooked = cooked;

    defer {
        keys.restoreRaw(cooked);
        g_cooked = null;
        restoreHandler();
    }

    var banner_buf: [128]u8 = undefined;
    printStdout(io, menuBanner(&banner_buf, style.detect(io, .stdout())));

    var digits: [9]u8 = undefined;
    var digits_len: usize = 0;
    var exit_code: u8 = 0;

    menu: while (true) {
        if (g_sigint.load(.acquire)) {
            exit_code = 130;
            break :menu;
        }

        switch (nextKey()) {
            .none => continue,
            .eof => {
                exit_code = 0;
                break :menu;
            },
            .key => |c| switch (c) {
                'r' => {
                    digits_len = 0;
                    printStdout(io, "\n");
                    _ = record.recordOnce(io, gpa, null, recordings_path);
                    // recordOnce installed the plain recording handler.
                    installHandler();
                    printStdout(io, "\n> ");
                },
                'l' => {
                    digits_len = 0;
                    printStdout(io, "\n");
                    _ = library.listRecordings(io, gpa, recordings_path);
                    printStdout(io, "> ");
                },
                'q' => {
                    exit_code = 0;
                    break :menu;
                },
                '\n', '\r' => {
                    if (digits_len == 0) continue;
                    printStdout(io, "\n");
                    _ = playback.playSelection(io, gpa, digits[0..digits_len], recordings_path);
                    digits_len = 0;
                    printStdout(io, "> ");
                },
                '0'...'9' => {
                    if (digits_len < digits.len) {
                        digits[digits_len] = c;
                        digits_len += 1;
                        printStdout(io, &.{c});
                    }
                },
                0x7f, 0x08 => { // backspace: edit the number buffer
                    if (digits_len > 0) {
                        digits_len -= 1;
                        printStdout(io, "\x08 \x08");
                    }
                },
                0x03 => { // Ctrl-C byte, in case ISIG was off
                    exit_code = 130;
                    break :menu;
                },
                else => {}, // unmapped keys (incl. escape sequences)
            },
        }
    }

    printStdout(io, "\n");
    return exit_code;
}

fn printStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

/// The menu banner: bold keys, dim prompt. `buf` must fit the banner.
fn menuBanner(buf: []u8, color: bool) []const u8 {
    var n: usize = 0;
    appendStr(buf, &n, "rec: ");
    style.appendStyled(buf, &n, color, style.bold, "r");
    appendStr(buf, &n, "=record  ");
    style.appendStyled(buf, &n, color, style.bold, "l");
    appendStr(buf, &n, "=list  ");
    style.appendStyled(buf, &n, color, style.bold, "<number>+Enter");
    appendStr(buf, &n, "=play  ");
    style.appendStyled(buf, &n, color, style.bold, "q");
    appendStr(buf, &n, "=quit\n");
    style.appendStyled(buf, &n, color, style.dim, "> ");
    return buf[0..n];
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

test "menuBanner is plain without color and bolds the keys with it" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "rec: r=record  l=list  <number>+Enter=play  q=quit\n> ",
        menuBanner(&buf, false),
    );
    try std.testing.expectEqualStrings(
        "rec: \x1b[1mr\x1b[0m=record  \x1b[1ml\x1b[0m=list  \x1b[1m<number>+Enter\x1b[0m=play  \x1b[1mq\x1b[0m=quit\n\x1b[2m> \x1b[0m",
        menuBanner(&buf, true),
    );
}
