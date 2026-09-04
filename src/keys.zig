//! Raw-mode keystrokes: read one key from stdin (plain byte, arrow keys,
//! or their SHIFT variants) and classify escape sequences. Shared by the
//! live views' key loops; parsing is pure so it is testable offline.

const std = @import("std");

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

/// Waits up to `ms` for a keystroke and parses it. The poll window is what
/// paces the UI loops.
pub fn readKey(ms: i32) Key {
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
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, ms) catch return false;
    return ready > 0;
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
