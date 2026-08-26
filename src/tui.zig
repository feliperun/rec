const std = @import("std");
const capture = @import("capture.zig");
const library = @import("library.zig");
const playback = @import("playback.zig");
const main = @import("main.zig");

/// Set by the SIGINT handler while the interactive loop owns the terminal.
var g_sigint = std.atomic.Value(bool).init(false);
/// The cooked termios to restore from the handler and the exit defer;
/// non-null exactly while raw mode is on.
var g_cooked: ?std.posix.termios = null;

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_sigint.store(true, .release);
    capture.requestStop(); // stops an in-flight recording under this handler
    // Give the terminal back immediately; tcsetattr is a plain ioctl, safe
    // to call from a handler. The exit defer repeats this on the normal path.
    if (g_cooked) |t| std.posix.tcsetattr(0, .FLUSH, t) catch {};
}

fn installHandler() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

const NextKey = union(enum) {
    none, // no key within the poll window
    key: u8,
    eof,
};

/// Waits up to 200 ms for a keystroke so the SIGINT flag is noticed even
/// while idle.
fn nextKey() NextKey {
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, 200) catch return .none;
    if (ready == 0) return .none;
    var buf: [1]u8 = undefined;
    const n = std.posix.read(0, &buf) catch return .none;
    if (n == 0) return .eof;
    return .{ .key = buf[0] };
}

/// Interactive menu: raw-mode key loop over the record/list/play commands.
/// The cooked terminal state comes back via the defer and the SIGINT
/// handler, so the shell is never left broken.
pub fn runInteractive(io: std.Io, gpa: std.mem.Allocator, recordings_path: []const u8) u8 {
    // isTty first: tcgetattr on a non-tty can trip "unexpected errno" dumps
    // (macOS reports ENODEV for /dev/null) for what is an ordinary failure.
    const is_tty = std.Io.File.stdin().isTty(io) catch false;
    const maybe_cooked: ?std.posix.termios = if (is_tty) (std.posix.tcgetattr(0) catch null) else null;
    const cooked = maybe_cooked orelse {
        printStderr(io, "interactive mode needs a terminal on stdin\n");
        return 1;
    };

    // Handler first: from here on a Ctrl-C puts the terminal back for us.
    var old_act: std.posix.Sigaction = undefined;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, &old_act);

    var raw = cooked;
    raw.lflag.ICANON = false; // one key at a time
    raw.lflag.ECHO = false; // we echo manually
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false; // Ctrl-S/Q must not freeze the terminal
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    // .NOW (not .FLUSH): keystrokes that arrived before raw mode was on stay
    // in the input queue instead of being discarded as typeahead.
    std.posix.tcsetattr(0, .NOW, raw) catch {
        std.posix.sigaction(std.posix.SIG.INT, &old_act, null);
        printStderr(io, "interactive mode cannot enter raw mode\n");
        return 1;
    };
    g_cooked = cooked;

    defer {
        std.posix.tcsetattr(0, .FLUSH, cooked) catch {};
        g_cooked = null;
        std.posix.sigaction(std.posix.SIG.INT, &old_act, null);
    }

    printStdout(io, "rec: r=record  l=list  <number>+Enter=play  q=quit\n> ");

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
                    _ = main.recordOnce(io, gpa, null, true, recordings_path);
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
