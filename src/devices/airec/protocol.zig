//! The AIREC recorder's Bluetooth LE protocol, learned from the vendor app's
//! traffic (docs/adr/0022). One GATT service carries everything: the host
//! writes `55 aa <len> <cmd> <args>` to the command characteristic, the
//! recorder answers and raises events as `aa 55 <len> <code> <data>` on the
//! reply characteristic, and file bytes stream on the data characteristic.
//! This module only encodes and parses frames; no I/O.

const std = @import("std");

/// The 16-bit service UUID in the recorder's advertisement; scanning for it
/// finds AIREC recorders and nothing else.
pub const advertised_service = "AF43";
pub const service = "0011200A-2233-4455-6677-8899DFDEDDDC";

/// The service's characteristics, indexed by `Channel`.
pub const characteristics = [_][:0]const u8{
    "0011201A-2233-4455-6677-8899DFDEDDDC",
    "0011202A-2233-4455-6677-8899DFDEDDDC",
    "0011203A-2233-4455-6677-8899DFDEDDDC",
    "0011204A-2233-4455-6677-8899DFDEDDDC",
};

pub const Channel = enum(u8) {
    /// Opus packets streamed live while a recording runs.
    live = 0,
    /// Host-to-recorder commands.
    command = 1,
    /// Replies and unsolicited events.
    reply = 2,
    /// Recording bytes during a download.
    data = 3,
};

pub const Code = struct {
    pub const open: u8 = 0x01;
    pub const set_clock: u8 = 0x02;
    pub const started: u8 = 0x03;
    pub const saved: u8 = 0x04;
    pub const list: u8 = 0x05;
    pub const list_end: u8 = 0x06;
    pub const download: u8 = 0x07;
    pub const download_end: u8 = 0x09;
    pub const get_clock: u8 = 0x30;
};

/// Recording names are the recorder's local start time, `YYYYMMDDHHMMSS`.
pub const name_len = 14;
pub const Name = [name_len]u8;

/// The longest frame: three header bytes plus a 255-byte body.
pub const max_frame = 3 + 255;

/// Writes `55 aa <len> <cmd> <args>` into `buf` and returns it.
pub fn encode(buf: *[max_frame]u8, cmd: u8, args: []const u8) []const u8 {
    std.debug.assert(args.len < 255);
    buf[0] = 0x55;
    buf[1] = 0xaa;
    buf[2] = @intCast(args.len + 1);
    buf[3] = cmd;
    @memcpy(buf[4..][0..args.len], args);
    return buf[0 .. 4 + args.len];
}

pub const Reply = struct {
    code: u8,
    data: []const u8,
};

/// A recorder frame `aa 55 <len> <code> <data>`; null for anything else,
/// including a length byte that disagrees with the frame.
pub fn parse(frame: []const u8) ?Reply {
    if (frame.len < 4 or frame[0] != 0xaa or frame[1] != 0x55) return null;
    if (frame[2] == 0 or frame.len != 3 + @as(usize, frame[2])) return null;
    return .{ .code = frame[3], .data = frame[4..] };
}

/// One recording as list entries, download acknowledgements, and `saved`
/// events describe it.
pub const Entry = struct {
    name: Name,
    size: u32,
};

/// `<name> <size u32 BE>`. The name becomes a file name in the library, so
/// anything but 14 digits is refused here.
pub fn parseEntry(data: []const u8) ?Entry {
    if (data.len != name_len + 4) return null;
    const name = parseName(data[0..name_len]) orelse return null;
    return .{ .name = name, .size = std.mem.readInt(u32, data[name_len..][0..4], .big) };
}

pub fn parseName(data: []const u8) ?Name {
    if (data.len != name_len) return null;
    for (data) |c| if (!std.ascii.isDigit(c)) return null;
    return data[0..name_len].*;
}

/// The arguments of a download request: `<name> <offset u32 BE>`.
pub fn downloadArgs(name: Name, offset: u32) [name_len + 4]u8 {
    var args: [name_len + 4]u8 = undefined;
    @memcpy(args[0..name_len], &name);
    std.mem.writeInt(u32, args[name_len..][0..4], offset, .big);
    return args;
}

test "commands are framed with their length" {
    var buf: [max_frame]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0xaa, 0x01, 0x05 }, encode(&buf, Code.list, &.{}));
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0xaa, 0x02, 0x69, 0x00 }, encode(&buf, 0x69, &.{0}));
}

test "replies parse and malformed frames do not" {
    const battery = parse(&.{ 0xaa, 0x55, 0x02, 0x0e, 0x60 }).?;
    try std.testing.expectEqual(@as(u8, 0x0e), battery.code);
    try std.testing.expectEqualSlices(u8, &.{0x60}, battery.data);
    try std.testing.expectEqual(@as(u8, Code.list_end), parse(&.{ 0xaa, 0x55, 0x01, 0x06 }).?.code);

    try std.testing.expect(parse(&.{ 0x55, 0xaa, 0x01, 0x06 }) == null); // a command, not a reply
    try std.testing.expect(parse(&.{ 0xaa, 0x55, 0x02, 0x0e }) == null); // shorter than its length
    try std.testing.expect(parse(&.{ 0xaa, 0x55, 0x00 }) == null);
    // Recording bytes start with Opus TOC bytes, never the reply magic.
    try std.testing.expect(parse(&.{ 0x4b, 0x41, 0x0d, 0x21, 0xd2 }) == null);
}

test "a list entry carries a 14-digit name and a big-endian size" {
    const frame = [_]u8{ 0xaa, 0x55, 0x13, 0x05 } ++ "20250101120000".* ++ [_]u8{ 0x00, 0x1a, 0x9b, 0xc0 };
    const reply = parse(&frame).?;
    const entry = parseEntry(reply.data).?;
    try std.testing.expectEqualStrings("20250101120000", &entry.name);
    try std.testing.expectEqual(@as(u32, 1_743_808), entry.size);
}

test "names that could escape the library are refused" {
    try std.testing.expect(parseEntry("../../etc/pass" ++ "\x00\x00\x00\x01") == null);
    try std.testing.expect(parseEntry("2025010112000" ++ "\x00\x00\x00\x00\x01") == null);
    try std.testing.expect(parseName("2025010112000/") == null);
}

test "download requests name the recording and the byte offset" {
    var buf: [max_frame]u8 = undefined;
    const args = downloadArgs("20250101120000".*, 0);
    const frame = encode(&buf, Code.download, &args);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0x55, 0xaa, 0x13, 0x07 } ++ "20250101120000".* ++ [_]u8{ 0, 0, 0, 0 }), frame);
}
