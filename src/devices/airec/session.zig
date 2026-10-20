//! A conversation with one AIREC recorder over any link that can write a
//! characteristic and hand back notifications (src/ble.zig on hardware,
//! fake.zig in tests). It opens the session the way the vendor app does,
//! lists and downloads recordings, and surfaces the recorder's
//! started/saved events, keeping the ones that arrive mid-download.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const Event = union(enum) {
    started: protocol.Name,
    saved: protocol.Entry,
};

/// How long a reply may take before the recorder counts as unresponsive.
pub const reply_timeout_ms = 3000;

/// How long a download may stall between two packets.
pub const data_timeout_ms = 15000;

/// The vendor app's opening sequence after `01`, with the reply each step
/// waits for (null: none comes). Without it a button press while connected
/// records nothing and raises no event; which steps matter is untested, so
/// it is replayed whole.
const Step = struct { cmd: u8, args: []const u8 = &.{}, reply: ?u8 };
const opening = [_]Step{
    .{ .cmd = 0x20, .reply = 0x20 },
    .{ .cmd = 0x0f, .reply = 0x0f },
    .{ .cmd = 0x12, .reply = 0x12 },
    .{ .cmd = 0x26, .reply = 0x26 },
    .{ .cmd = 0x29, .reply = 0x29 },
    .{ .cmd = 0x0b, .reply = 0x0d },
    .{ .cmd = 0x0e, .reply = 0x0e },
    .{ .cmd = 0x36, .reply = null },
    .{ .cmd = protocol.Code.list, .reply = protocol.Code.list_end },
};
/// After every list and download the app sends `02 <clock>` and then these.
/// Whether the recorder needs them there is untested; rec does the same.
const rearm_tail = [_]Step{
    .{ .cmd = 0x69, .args = &.{0}, .reply = null },
    .{ .cmd = protocol.Code.get_clock, .reply = protocol.Code.get_clock },
    .{ .cmd = 0x66, .args = &.{0}, .reply = null },
};

/// `Link` provides `write(index, bytes) Link.Error!void` and
/// `next(timeout_ms) Link.Error!?Notification`, where a notification has an
/// `index` into protocol.characteristics and `bytes` valid until the next
/// call.
pub fn Session(comptime Link: type) type {
    return struct {
        const Self = @This();
        pub const Error = Link.Error || error{ Timeout, Truncated, OutOfMemory };

        gpa: std.mem.Allocator,
        link: *Link,
        /// The local time the recorder names recordings by.
        clock: *const fn (*protocol.Name) void,
        /// Events that arrived while the session waited for something else.
        pending: std.ArrayList(Event) = .empty,

        pub fn init(gpa: std.mem.Allocator, link: *Link, clock: *const fn (*protocol.Name) void) Self {
            return .{ .gpa = gpa, .link = link, .clock = clock };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit(self.gpa);
        }

        /// Opens the session; the recorder ignores every other command until
        /// `01`.
        pub fn open(self: *Self) Error!void {
            try self.step(.{ .cmd = protocol.Code.open, .reply = protocol.Code.open });
            for (opening) |s| try self.step(s);
            try self.rearm();
        }

        /// Sets the clock and puts the recorder back into raising events,
        /// as the app does after every list and download.
        fn rearm(self: *Self) Error!void {
            var now: protocol.Name = undefined;
            self.clock(&now);
            try self.step(.{ .cmd = protocol.Code.set_clock, .args = &now, .reply = protocol.Code.set_clock });
            for (rearm_tail) |s| try self.step(s);
        }

        /// Every recording on the device, in the recorder's order. Caller
        /// frees the slice.
        pub fn list(self: *Self) Error![]protocol.Entry {
            try self.send(protocol.Code.list, &.{});
            var entries: std.ArrayList(protocol.Entry) = .empty;
            errdefer entries.deinit(self.gpa);
            while (try self.reply(reply_timeout_ms)) |r| {
                if (r.code == protocol.Code.list_end) {
                    try self.rearm();
                    return entries.toOwnedSlice(self.gpa);
                }
                if (r.code != protocol.Code.list) continue;
                if (protocol.parseEntry(r.data)) |e| try entries.append(self.gpa, e);
            }
            return error.Timeout;
        }

        /// The recording's bytes, exactly as stored on the device. Caller
        /// frees them.
        pub fn download(self: *Self, name: protocol.Name) Error![]u8 {
            const args = protocol.downloadArgs(name, 0);
            try self.send(protocol.Code.download, &args);
            var bytes: std.ArrayList(u8) = .empty;
            errdefer bytes.deinit(self.gpa);
            var size: ?u32 = null;
            while (true) {
                const n = try self.link.next(data_timeout_ms) orelse return error.Timeout;
                switch (channel(n.index)) {
                    .data => try bytes.appendSlice(self.gpa, n.bytes),
                    .reply => {
                        const r = protocol.parse(n.bytes) orelse continue;
                        if (try self.keepEvent(r)) continue;
                        if (r.code == protocol.Code.download) {
                            if (protocol.parseEntry(r.data)) |e| size = e.size;
                        } else if (r.code == protocol.Code.download_end) break;
                    },
                    else => {},
                }
            }
            if (size == null or bytes.items.len != size.?) return error.Truncated;
            try self.rearm();
            return bytes.toOwnedSlice(self.gpa);
        }

        /// The next started/saved event, oldest first; null when none comes
        /// within `timeout_ms`.
        pub fn nextEvent(self: *Self, timeout_ms: u32) Error!?Event {
            while (self.pending.items.len == 0) {
                _ = try self.reply(timeout_ms) orelse return null;
            }
            return self.pending.orderedRemove(0);
        }

        fn step(self: *Self, s: Step) Error!void {
            try self.send(s.cmd, s.args);
            const want = s.reply orelse return;
            while (try self.reply(reply_timeout_ms)) |r| {
                if (r.code == want) return;
            }
            return error.Timeout;
        }

        fn send(self: *Self, cmd: u8, args: []const u8) Error!void {
            var buf: [protocol.max_frame]u8 = undefined;
            try self.link.write(@intFromEnum(protocol.Channel.command), protocol.encode(&buf, cmd, args));
        }

        /// The next reply that is not an event, within `timeout_ms` of
        /// silence; events are queued, live audio and data are dropped.
        fn reply(self: *Self, timeout_ms: u32) Error!?protocol.Reply {
            while (try self.link.next(timeout_ms)) |n| {
                if (channel(n.index) != .reply) continue;
                const r = protocol.parse(n.bytes) orelse continue;
                if (try self.keepEvent(r)) continue;
                return r;
            }
            return null;
        }

        /// Queues a started/saved event; true when `r` was one.
        fn keepEvent(self: *Self, r: protocol.Reply) error{OutOfMemory}!bool {
            if (r.code == protocol.Code.started) {
                if (protocol.parseName(r.data)) |name| try self.pending.append(self.gpa, .{ .started = name });
                return true;
            }
            if (r.code == protocol.Code.saved) {
                if (protocol.parseEntry(r.data)) |e| try self.pending.append(self.gpa, .{ .saved = e });
                return true;
            }
            return false;
        }
    };
}

fn channel(index: usize) protocol.Channel {
    return if (index < protocol.characteristics.len) @enumFromInt(index) else .live;
}

// --- tests -------------------------------------------------------------------

const Fake = @import("fake.zig").Fake;
const TestSession = Session(Fake);

fn testClock(out: *protocol.Name) void {
    out.* = "20261020170000".*;
}

fn testFile(gpa: std.mem.Allocator, len: usize) ![]u8 {
    const bytes = try gpa.alloc(u8, len);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 7);
    return bytes;
}

test "opening replays the app's sequence and sets the clock" {
    const gpa = std.testing.allocator;
    var fake = Fake.init(gpa, &.{});
    defer fake.deinit();
    var session = TestSession.init(gpa, &fake, testClock);
    defer session.deinit();

    try session.open();
    try std.testing.expectEqualStrings("20261020170000", &fake.clock.?);
    try std.testing.expect(fake.connected_mode);
}

test "the recorder ignores commands until the session is open" {
    const gpa = std.testing.allocator;
    var fake = Fake.init(gpa, &.{});
    defer fake.deinit();
    var session = TestSession.init(gpa, &fake, testClock);
    defer session.deinit();
    try std.testing.expectError(error.Timeout, session.list());
}

test "lists recordings and downloads one byte for byte" {
    const gpa = std.testing.allocator;
    const a = try testFile(gpa, 53_184);
    defer gpa.free(a);
    const b = try testFile(gpa, 600);
    defer gpa.free(b);
    var fake = Fake.init(gpa, &.{
        .{ .name = "20250101120000".*, .bytes = a },
        .{ .name = "20250102130000".*, .bytes = b },
    });
    defer fake.deinit();
    var session = TestSession.init(gpa, &fake, testClock);
    defer session.deinit();
    try session.open();

    const entries = try session.list();
    defer gpa.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("20250102130000", &entries[1].name);
    try std.testing.expectEqual(@as(u32, 600), entries[1].size);

    try std.testing.expect(fake.connected_mode); // re-armed after the list

    const got = try session.download(entries[0].name);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, a, got);
    try std.testing.expect(fake.connected_mode); // and after the download
}

test "a short download is an error, not a recording" {
    const gpa = std.testing.allocator;
    const a = try testFile(gpa, 1000);
    defer gpa.free(a);
    var fake = Fake.init(gpa, &.{.{ .name = "20250101120000".*, .bytes = a }});
    defer fake.deinit();
    fake.drop_data_after = 500;
    var session = TestSession.init(gpa, &fake, testClock);
    defer session.deinit();
    try session.open();
    try std.testing.expectError(error.Truncated, session.download("20250101120000".*));
}

test "events raised mid-download are kept, live audio is ignored" {
    const gpa = std.testing.allocator;
    const a = try testFile(gpa, 2000);
    defer gpa.free(a);
    var fake = Fake.init(gpa, &.{.{ .name = "20250101120000".*, .bytes = a }});
    defer fake.deinit();
    var session = TestSession.init(gpa, &fake, testClock);
    defer session.deinit();
    try session.open();

    try fake.raise(protocol.Code.started, "20261020170100");
    try fake.live(&.{ 0x4b, 0x41, 0x02, 0x87 });
    try fake.raise(protocol.Code.saved, "20261020170100" ++ "\x00\x00\x67\xc0");
    const got = try session.download("20250101120000".*);
    gpa.free(got);

    const first = (try session.nextEvent(0)).?;
    try std.testing.expectEqualStrings("20261020170100", &first.started);
    const second = (try session.nextEvent(0)).?;
    try std.testing.expectEqualStrings("20261020170100", &second.saved.name);
    try std.testing.expectEqual(@as(u32, 0x67c0), second.saved.size);
    try std.testing.expect(try session.nextEvent(0) == null);
}
