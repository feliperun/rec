//! A simulated AIREC recorder for tests: it answers the protocol.zig
//! commands the session sends, serves in-memory recordings in 244-byte
//! notifications like the real one, and lets a test raise events or live
//! audio. Commands before `01` are ignored, as on the device.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const File = struct {
    name: protocol.Name,
    bytes: []const u8,
};

pub const Notification = struct {
    index: usize,
    bytes: []const u8,
};

const Item = struct {
    index: usize,
    bytes: []u8,
};

/// Notification payload size the recorder uses at its 247-byte MTU.
const chunk = 244;

pub const Fake = struct {
    pub const Error = error{ Disconnected, OutOfMemory };

    gpa: std.mem.Allocator,
    files: []const File,
    queue: std.ArrayList(Item) = .empty,
    last: ?[]u8 = null,
    open: bool = false,
    clock: ?protocol.Name = null,
    /// Set by `66 00`, cleared by a list or download, so tests can check the
    /// session re-arms the recorder after both, as the vendor app does.
    connected_mode: bool = false,
    /// Data bytes served before a download stops short (tests only).
    drop_data_after: ?usize = null,

    pub fn init(gpa: std.mem.Allocator, files: []const File) Fake {
        return .{ .gpa = gpa, .files = files };
    }

    pub fn deinit(self: *Fake) void {
        for (self.queue.items) |item| self.gpa.free(item.bytes);
        self.queue.deinit(self.gpa);
        if (self.last) |b| self.gpa.free(b);
    }

    pub fn write(self: *Fake, index: usize, frame: []const u8) Error!void {
        std.debug.assert(index == @intFromEnum(protocol.Channel.command));
        if (frame.len < 4 or frame[0] != 0x55 or frame[1] != 0xaa) return;
        const cmd = frame[3];
        const args = frame[4..];
        if (cmd == protocol.Code.open) {
            self.open = true;
            try self.reply(cmd, "000000000000000");
            try self.reply(0x36, &.{0});
            return;
        }
        if (!self.open) return;
        switch (cmd) {
            protocol.Code.list => {
                self.connected_mode = false;
                for (self.files) |f| try self.reply(cmd, &entryBytes(f));
                try self.reply(protocol.Code.list_end, &.{});
            },
            protocol.Code.download => {
                self.connected_mode = false;
                try self.serve(args);
            },
            protocol.Code.set_clock => {
                self.clock = protocol.parseName(args);
                try self.reply(cmd, &.{});
            },
            protocol.Code.get_clock => try self.reply(cmd, &(self.clock orelse "00000000000000".*)),
            0x0b => {
                try self.reply(0x0c, &.{ 0, 0, 0x1d, 0xde });
                try self.reply(0x0d, &.{ 0, 0, 0x1d, 0xec });
            },
            0x36, 0x69 => {},
            0x66 => self.connected_mode = true,
            else => try self.reply(cmd, &.{0}),
        }
    }

    pub fn next(self: *Fake, timeout_ms: u32) Error!?Notification {
        _ = timeout_ms;
        if (self.last) |b| self.gpa.free(b);
        self.last = null;
        if (self.queue.items.len == 0) return null;
        const item = self.queue.orderedRemove(0);
        self.last = item.bytes;
        return .{ .index = item.index, .bytes = item.bytes };
    }

    /// Queues an unsolicited event, as a button press on the device would.
    pub fn raise(self: *Fake, code: u8, data: []const u8) Error!void {
        try self.reply(code, data);
    }

    /// Queues a live-audio notification.
    pub fn live(self: *Fake, bytes: []const u8) Error!void {
        try self.push(@intFromEnum(protocol.Channel.live), bytes);
    }

    fn serve(self: *Fake, args: []const u8) Error!void {
        if (args.len != protocol.name_len + 4) return;
        const f = for (self.files) |f| {
            if (std.mem.eql(u8, &f.name, args[0..protocol.name_len])) break f;
        } else return;
        try self.reply(protocol.Code.download, &entryBytes(f));
        const served = @min(f.bytes.len, self.drop_data_after orelse f.bytes.len);
        var off: usize = 0;
        while (off < served) : (off += chunk) {
            try self.push(@intFromEnum(protocol.Channel.data), f.bytes[off..@min(off + chunk, served)]);
        }
        try self.reply(protocol.Code.download_end, &.{});
    }

    fn reply(self: *Fake, code: u8, data: []const u8) Error!void {
        var frame: [protocol.max_frame]u8 = undefined;
        frame[0] = 0xaa;
        frame[1] = 0x55;
        frame[2] = @intCast(data.len + 1);
        frame[3] = code;
        @memcpy(frame[4..][0..data.len], data);
        try self.push(@intFromEnum(protocol.Channel.reply), frame[0 .. 4 + data.len]);
    }

    fn push(self: *Fake, index: usize, bytes: []const u8) Error!void {
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(owned);
        try self.queue.append(self.gpa, .{ .index = index, .bytes = owned });
    }
};

fn entryBytes(f: File) [protocol.name_len + 4]u8 {
    var out: [protocol.name_len + 4]u8 = undefined;
    @memcpy(out[0..protocol.name_len], &f.name);
    std.mem.writeInt(u32, out[protocol.name_len..][0..4], @intCast(f.bytes.len), .big);
    return out;
}

// --- E2E link ----------------------------------------------------------------

const ble = @import("../../ble.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// A `ble.Link` stand-in for `zig build -Dfake-airec=true`: a simulated
/// recorder holding the `<14 digits>.ops` files of the directory named by
/// REC_FAKE_AIREC_DIR, so E2E tests exercise sync without a radio.
pub const DirLink = struct {
    pub const Error = ble.Error;

    gpa: std.mem.Allocator,
    fake: Fake,
    files: []File,

    pub fn connect(io: std.Io, gpa: std.mem.Allocator, spec: ble.Spec, timeout_s: ?f64) ble.Error!DirLink {
        _ = spec;
        _ = timeout_s;
        const dir_path = std.mem.span(getenv("REC_FAKE_AIREC_DIR") orelse return error.NotFound);
        var files: std.ArrayList(File) = .empty;
        errdefer files.deinit(gpa);
        errdefer freeFiles(gpa, files.items);
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.NotFound;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".ops")) continue;
            const name = protocol.parseName(entry.name[0 .. entry.name.len - ".ops".len]) orelse continue;
            const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 30)) catch return error.OutOfMemory;
            errdefer gpa.free(bytes);
            try files.append(gpa, .{ .name = name, .bytes = bytes });
        }
        const owned = try files.toOwnedSlice(gpa);
        return .{ .gpa = gpa, .fake = Fake.init(gpa, owned), .files = owned };
    }

    pub fn write(self: *DirLink, index: usize, bytes: []const u8) ble.Error!void {
        try self.fake.write(index, bytes);
    }

    pub fn next(self: *DirLink, timeout_ms: u32) ble.Error!?Notification {
        return self.fake.next(timeout_ms);
    }

    pub fn close(self: *DirLink) void {
        self.fake.deinit();
        freeFiles(self.gpa, self.files);
        self.gpa.free(self.files);
    }

    fn freeFiles(gpa: std.mem.Allocator, files: []const File) void {
        for (files) |f| gpa.free(f.bytes);
    }
};
