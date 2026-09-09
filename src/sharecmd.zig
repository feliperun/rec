const std = @import("std");
const library = @import("library.zig");
const share = @import("share.zig");

const usage = "rec share [index|path] [--to clipboard|chatgpt|claude|gemini]\n";
const max_bytes = 16 * 1024 * 1024;

const Args = struct {
    selection: []const u8 = library.latest_selection,
    destination: share.Destination = .clipboard,
};

const Parse = union(enum) { ok: Args, invalid };

fn parseArgs(args: []const [:0]const u8) Parse {
    var out = Args{};
    var seen = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--to") or std.mem.eql(u8, args[i], "--target")) {
            i += 1;
            if (i >= args.len) return .invalid;
            out.destination = share.parseDestination(args[i]) orelse return .invalid;
        } else if (!seen and !std.mem.startsWith(u8, args[i], "-")) {
            out.selection = args[i];
            seen = true;
        } else {
            return .invalid;
        }
    }
    return .{ .ok = out };
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8, recordings_path: []const u8) u8 {
    const parsed = switch (parseArgs(args)) {
        .ok => |v| v,
        .invalid => {
            printErr(io, usage);
            return 1;
        },
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = resolvePath(io, gpa, &path_buf, parsed.selection, recordings_path) orelse {
        printErr(io, "share: transcript not found\n");
        return 1;
    };
    const doc = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch {
        printErr(io, "share: cannot read transcript\n");
        return 1;
    };
    defer gpa.free(doc);

    if (!share.shareText(io, doc, parsed.destination)) {
        printErr(io, "share: destination failed\n");
        return 1;
    }
    printErr(io, "Shared via ");
    printErr(io, share.destinationName(parsed.destination));
    printErr(io, "\n");
    return 0;
}

fn resolvePath(io: std.Io, gpa: std.mem.Allocator, buf: []u8, selection: []const u8, recordings_path: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, selection, '/') != null or std.mem.endsWith(u8, selection, ".md")) {
        std.Io.Dir.cwd().access(io, selection, .{}) catch return null;
        if (selection.len > buf.len) return null;
        @memcpy(buf[0..selection.len], selection);
        return buf[0..selection.len];
    }

    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);
    library.scan(io, gpa, &entries, recordings_path) catch return null;
    library.sortNewestFirst(entries.items);
    const name = library.resolveName(selection, entries.items) orelse return null;
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const stem_path = library.recordingPath(recordings_path, library.stripExt(name), &name_buf) orelse return null;
    const n = std.fmt.bufPrint(buf, "{s}.md", .{stem_path}) catch return null;
    std.Io.Dir.cwd().access(io, n, .{}) catch return null;
    return n;
}

fn printErr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

test "share args default to latest clipboard" {
    const parsed = switch (parseArgs(&.{})) {
        .ok => |v| v,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(library.latest_selection, parsed.selection);
    try std.testing.expectEqual(share.Destination.clipboard, parsed.destination);
}

test "share args parse explicit destination" {
    const parsed = switch (parseArgs(&.{ "notes.md", "--to", "gemini" })) {
        .ok => |v| v,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("notes.md", parsed.selection);
    try std.testing.expectEqual(share.Destination.gemini, parsed.destination);
}
