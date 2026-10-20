//! `rec device`: integrations that bring recordings in from other devices.
//! Each device module exposes `name`, `description`, and
//! `run(io, gpa, args, ingest.Context) u8`; this verb lists and dispatches
//! them. What they share (publishing into the library, transcribing and
//! formatting) lives in src/devices/ingest.zig.

const std = @import("std");
const ingest = @import("devices/ingest.zig");

pub const Context = ingest.Context;

const all = .{
    @import("devices/airec/airec.zig"),
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8, ctx: Context) u8 {
    if (args.len == 0) {
        printDevices(io);
        return 0;
    }
    inline for (all) |device| {
        if (std.mem.eql(u8, args[0], device.name)) return device.run(io, gpa, args[1..], ctx);
    }
    ingest.print(io, "device: unknown device '{s}'\n", .{args[0]});
    printDevices(io);
    return 1;
}

fn printDevices(io: std.Io) void {
    ingest.print(io, "Supported devices (rec device <name> for its actions):\n", .{});
    inline for (all) |device| ingest.print(io, "  {s: <8} {s}\n", .{ device.name, device.description });
}
