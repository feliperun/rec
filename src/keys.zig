//! Raw-mode keystrokes: read one key from stdin (plain byte, arrow keys,
//! or their SHIFT variants) and classify escape sequences. Shared by the
//! live views' key loops; parsing is pure so it is testable offline.
//! Also owns the stdin terminal state: `enableRaw`/`restoreRaw` are the
//! one switch point for cooked↔raw on POSIX (termios) and Windows
//! (SetConsoleMode VT input, where Ctrl-C arrives as the 0x03 byte just
//! like raw POSIX).

const std = @import("std");
const builtin = @import("builtin");

pub const Key = union(enum) {
    none,
    byte: u8,
    eof,
    left,
    right,
    shift_left,
    shift_right,
    delete,
};

// --- stdin terminal state ---------------------------------------------------

/// Saved cooked-mode state for stdin; pass it back to `restoreRaw`.
pub const Cooked = if (builtin.os.tag == .windows) u32 else std.posix.termios;

/// Windows console plumbing for stdin (kernel32; libc is linked for
/// miniaudio on every platform, but these are declared directly, like the
/// CoreAudio externs).
const std_input_handle: i32 = -10;
const enable_virtual_terminal_input: u32 = 0x0200;
const wait_object_0: u32 = 0;
extern "kernel32" fn GetStdHandle(nStdHandle: i32) ?std.os.windows.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *u32) i32;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: u32) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: u32) u32;
extern "kernel32" fn ReadFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) i32;

fn stdInput() ?std.os.windows.HANDLE {
    return GetStdHandle(std_input_handle);
}

/// Puts stdin into one-key-at-a-time raw mode and returns the state to
/// hand to `restoreRaw`. Null when stdin is not a console (pipe, file, or
/// an odd terminal) — callers degrade to non-interactive behavior.
pub fn enableRaw() ?Cooked {
    if (builtin.os.tag == .windows) {
        const h = stdInput() orelse return null;
        var old: u32 = 0;
        if (GetConsoleMode(h, &old) == 0) return null;
        // VT input alone: no line buffering, no echo, and Ctrl-C surfaces as
        // the 0x03 byte — exactly the shape the POSIX raw config produces.
        if (SetConsoleMode(h, enable_virtual_terminal_input) == 0) return null;
        return old;
    }
    const cooked = std.posix.tcgetattr(0) catch return null;
    var raw = cooked;
    raw.lflag.ICANON = false; // one key at a time
    raw.lflag.ECHO = false; // we echo manually
    raw.lflag.ISIG = false; // Ctrl-C arrives as a byte we handle ourselves
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false; // Ctrl-S/Q must not freeze the terminal
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    // .NOW (not .FLUSH): keystrokes that arrived before raw mode was on stay
    // in the input queue instead of being discarded as typeahead.
    std.posix.tcsetattr(0, .NOW, raw) catch return null;
    return cooked;
}

/// Restores the cooked state `enableRaw` returned.
pub fn restoreRaw(cooked: Cooked) void {
    if (builtin.os.tag == .windows) {
        if (stdInput()) |h| _ = SetConsoleMode(h, cooked);
        return;
    }
    std.posix.tcsetattr(0, .FLUSH, cooked) catch {};
}

// --- raw keystrokes ---------------------------------------------------------

/// Waits up to `ms` for a keystroke and parses it. The poll window is what
/// paces the UI loops.
pub fn readKey(ms: i32) Key {
    if (builtin.os.tag == .windows) {
        const win = stdInput() orelse return .none;
        if (WaitForSingleObject(win, @intCast(@max(ms, 0))) != wait_object_0) return .none;
        var buf: [32]u8 = undefined;
        var got: u32 = 0;
        if (ReadFile(win, &buf, buf.len, &got, null) == 0) return .none;
        if (got == 0) return .eof;
        var len: usize = got;

        // An escape sequence may arrive split across reads; collect the rest.
        if (buf[0] == 0x1b) {
            while (!sequenceComplete(buf[0..len]) and len < buf.len and waitReadable(20)) {
                var more: u32 = 0;
                if (ReadFile(win, buf[len..].ptr, @intCast(buf.len - len), &more, null) == 0) break;
                if (more == 0) break;
                len += more;
            }
        }
        return parseKey(buf[0..len]);
    }
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, ms) catch return .none;
    if (ready == 0) return .none;

    var buf: [32]u8 = undefined;
    const n = std.posix.read(0, &buf) catch return .none;
    if (n == 0) return .eof;
    var len: usize = n;

    // An escape sequence may arrive split across writes; collect the rest.
    if (buf[0] == 0x1b) {
        while (!sequenceComplete(buf[0..len]) and len < buf.len and waitReadable(20)) {
            const more = std.posix.read(0, buf[len..]) catch break;
            if (more == 0) break;
            len += more;
        }
    }
    return parseKey(buf[0..len]);
}

/// True when stdin has bytes within `ms`.
pub fn waitReadable(ms: i32) bool {
    if (builtin.os.tag == .windows) {
        const win = stdInput() orelse return false;
        return WaitForSingleObject(win, @intCast(@max(ms, 0))) == wait_object_0;
    }
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, ms) catch return false;
    return ready > 0;
}

/// One byte from stdin (cooked or raw); false at EOF or error. Line input
/// readers use this so a console's \r\n endings are handled by the caller.
pub fn readByte(b: *u8) bool {
    if (builtin.os.tag == .windows) {
        const win = stdInput() orelse return false;
        var got: u32 = 0;
        if (ReadFile(win, b[0..1].ptr, 1, &got, null) == 0) return false;
        return got != 0;
    }
    const got = std.posix.read(0, std.mem.asBytes(b)) catch return false;
    return got != 0;
}

/// True when `seq` holds a whole keystroke: a bare ESC (nothing followed
/// within the wait window) or a complete CSI/SS3 sequence with its final byte.
pub fn sequenceComplete(seq: []const u8) bool {
    if (seq.len == 0) return false;
    if (seq[0] != 0x1b) return true;
    if (seq.len == 1) return false; // bare ESC, still waiting
    if (seq.len < 3) return false;
    const last = seq[seq.len - 1];
    return last >= 0x40 and last <= 0x7e;
}

/// Classifies a raw keystroke: a plain byte (the Delete key in its
/// backspace spelling included), the arrow keys (xterm CSI `ESC [ 1;2C` and
/// legacy SS3 `ESC O C`, SHIFT as the `2` modifier), the xterm Delete key
/// (`ESC [ 3~`), or nothing for sequences rec has no binding for.
pub fn parseKey(seq: []const u8) Key {
    if (seq.len == 0) return .none;
    if (seq[0] != 0x1b) {
        return if (seq[0] == 0x7f or seq[0] == 0x08) .delete else .{ .byte = seq[0] };
    }
    if (seq.len == 1) return .{ .byte = 0x1b }; // bare ESC
    if (seq.len < 3) return .none;
    const final = seq[seq.len - 1];
    const params = seq[2 .. seq.len - 1];

    var shift = false;
    var it = std.mem.splitScalar(u8, if (seq[1] == '[') params else "", ';');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "2")) shift = true;
    }

    return switch (final) {
        'D' => if (shift) .shift_left else .left,
        'C' => if (shift) .shift_right else .right,
        '~' => blk: {
            // xterm Delete is parameter 3; every other ~ key is unbound.
            var first = std.mem.splitScalar(u8, params, ';');
            break :blk if (std.mem.eql(u8, first.next() orelse "", "3")) .delete else .none;
        },
        else => .none,
    };
}

test "parseKey classifies plain bytes and bare escape" {
    try std.testing.expectEqual(Key{ .byte = ' ' }, parseKey(" "));
    try std.testing.expectEqual(Key{ .byte = 'q' }, parseKey("q"));
    try std.testing.expectEqual(Key{ .byte = 0x03 }, parseKey("\x03"));
    try std.testing.expectEqual(Key{ .byte = 0x1b }, parseKey("\x1b")); // bare ESC
    try std.testing.expectEqual(Key.none, parseKey(""));
}

test "parseKey classifies arrow keys and their shift variants" {
    try std.testing.expectEqual(Key.left, parseKey("\x1b[D"));
    try std.testing.expectEqual(Key.right, parseKey("\x1b[C"));
    // xterm modifier encoding: parameter 2 is SHIFT.
    try std.testing.expectEqual(Key.shift_left, parseKey("\x1b[1;2D"));
    try std.testing.expectEqual(Key.shift_right, parseKey("\x1b[1;2C"));
    // Application cursor mode sends SS3.
    try std.testing.expectEqual(Key.right, parseKey("\x1bOC"));
    // Unbound sequences (Home, F-keys) classify to nothing.
    try std.testing.expectEqual(Key.none, parseKey("\x1b[A"));
    try std.testing.expectEqual(Key.none, parseKey("\x1b[15~"));
}

test "parseKey classifies the delete key in all its spellings" {
    try std.testing.expectEqual(Key.delete, parseKey("\x7f")); // the Delete key
    try std.testing.expectEqual(Key.delete, parseKey("\x08")); // legacy backspace
    try std.testing.expectEqual(Key.delete, parseKey("\x1b[3~")); // xterm Delete
    // Modifier variants and other ~ keys stay out of the binding.
    try std.testing.expectEqual(Key.none, parseKey("\x1b[15~"));
}

test "sequenceComplete tells whole keystrokes from split ones" {
    try std.testing.expect(!sequenceComplete("\x1b[1;"));
    try std.testing.expect(sequenceComplete("\x1b[1;2D"));
    try std.testing.expect(!sequenceComplete("\x1b"));
    try std.testing.expect(sequenceComplete("x"));
    try std.testing.expect(!sequenceComplete(""));
}
