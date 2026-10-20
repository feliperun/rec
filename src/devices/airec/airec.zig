//! The AIREC smart voice recorder integration: `.ops` files copied off the
//! recorder (ops.zig, docs/adr/0021) and Bluetooth sync over the vendor
//! protocol (protocol.zig, session.zig on src/ble.zig, docs/adr/0022).
//! Recordings land in the library through src/devices/ingest.zig.

const std = @import("std");
const ble = @import("../../ble.zig");
const ingest = @import("../ingest.zig");
const library = @import("../../library.zig");
const localtime = @import("../../localtime.zig");
const ops = @import("ops.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const wav = @import("../../wav.zig");

pub const name = "airec";
pub const description = "AIREC smart voice recorder: import .ops files, sync over Bluetooth";

const usage =
    \\Usage: rec device airec import <file.ops>...  Convert files copied off the recorder
    \\       rec device airec sync [--no-notes]     Fetch new recordings over Bluetooth
    \\       rec device airec watch [--no-notes]    Stay connected and bring in each
    \\                                              recording as soon as it is saved
    \\
    \\sync and watch transcribe and format what they bring in unless --no-notes.
    \\
;

/// The real radio, or a directory-backed recorder in E2E builds.
const Link = if (@import("build_info").fake_airec) @import("fake.zig").DirLink else ble.Link;
const Session = session_mod.Session(Link);

const spec = ble.Spec{
    .advertised = protocol.advertised_service,
    .service = protocol.service,
    .characteristics = &protocol.characteristics,
};

/// How long `sync` looks for the recorder before giving up.
const scan_timeout_s = 20;
/// Pause before `watch` retries a connection that failed.
const retry_s = 5;

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8, ctx: ingest.Context) u8 {
    if (args.len == 0) return usageError(io);
    const action = args[0];
    if (std.mem.eql(u8, action, "import")) return importFiles(io, gpa, args[1..], ctx);
    const notes = parseNotes(args[1..]) orelse return usageError(io);
    if (std.mem.eql(u8, action, "sync")) return sync(io, gpa, ctx, notes);
    if (std.mem.eql(u8, action, "watch")) return watch(io, gpa, ctx, notes);
    return usageError(io);
}

fn usageError(io: std.Io) u8 {
    ingest.print(io, usage, .{});
    return 1;
}

/// True (transcribe and format) unless `--no-notes`; null for anything else.
fn parseNotes(args: []const [:0]const u8) ?bool {
    if (args.len == 0) return true;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--no-notes")) return false;
    return null;
}

// --- publishing --------------------------------------------------------------

/// A recording that reached the library.
const Imported = struct {
    buf: [std.Io.Dir.max_name_bytes]u8 = undefined,
    len: usize = 0,
    secs: u64 = 0,

    fn fileName(self: *const Imported) []const u8 {
        return self.buf[0..self.len];
    }
};

const PublishError = error{ NotOps, NoAudio } || ingest.Error;

/// Decodes `.ops` bytes into `<stem>` in the library; null when that
/// recording is already there.
fn publish(io: std.Io, image: []const u8, stem: []const u8, recordings_path: []const u8) PublishError!?Imported {
    if (ingest.exists(io, recordings_path, stem)) return null;
    if (ops.packetCount(image.len) == 0) return error.NoAudio;
    var w = try ingest.begin(io, recordings_path, stem, ops.sample_rate, ops.channels);
    decodeInto(image, &w) catch |err| {
        w.abort(io);
        return err;
    };
    try w.finish(io);
    var out = Imported{ .len = w.name().len, .secs = w.seconds() };
    @memcpy(out.buf[0..out.len], w.name());
    return out;
}

/// Streams every packet through libopus into `w`; memory stays at one
/// packet of PCM however long the recording is.
fn decodeInto(image: []const u8, w: *ingest.Writer) PublishError!void {
    var decoder = ops.Decoder.init() catch return error.NotOps;
    defer decoder.deinit();
    var pcm: [ops.max_packet_frames * ops.channels]i16 = undefined;
    for (0..ops.packetCount(image.len)) |p| {
        const packet = image[p * ops.packet_bytes ..][0..ops.packet_bytes];
        const n = decoder.decodePacket(packet, &pcm) catch return error.NotOps;
        try w.write(std.mem.sliceAsBytes(pcm[0 .. n * ops.channels]));
    }
}

fn publishFailure(err: PublishError) []const u8 {
    return switch (err) {
        error.NotOps => "is not a readable .ops recording",
        error.NoAudio => "holds no audio",
        error.NameTooLong => "has a name too long for ~/recordings/",
        error.CannotWrite => "could not be written to ~/recordings/",
    };
}

fn printImported(io: std.Io, source: []const u8, imported: *const Imported) void {
    ingest.print(io, "Imported {s} → {s}/{s} ({d:0>2}:{d:0>2})\n", .{
        source, library.recordings_dir, imported.fileName(), imported.secs / 60, imported.secs % 60,
    });
}

// --- import ------------------------------------------------------------------

fn importFiles(io: std.Io, gpa: std.mem.Allocator, files: []const [:0]const u8, ctx: ingest.Context) u8 {
    if (files.len == 0) return usageError(io);
    var code: u8 = 0;
    for (files) |src| {
        if (!importFile(io, gpa, src, ctx.recordings_path)) code = 1;
    }
    return code;
}

/// The recording stem of an `.ops` source: its basename without the
/// extension, matched case-insensitively (FAT volumes may upper-case it).
/// Null for any other file.
fn sourceStem(src: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(src);
    if (base.len <= ".ops".len) return null;
    const stem_len = base.len - ".ops".len;
    if (!std.ascii.eqlIgnoreCase(base[stem_len..], ".ops")) return null;
    return base[0..stem_len];
}

fn importFile(io: std.Io, gpa: std.mem.Allocator, src: []const u8, recordings_path: []const u8) bool {
    const stem = sourceStem(src) orelse {
        ingest.print(io, "device airec: {s} is not an .ops recording\n", .{src});
        return false;
    };
    if (ingest.exists(io, recordings_path, stem)) {
        ingest.print(io, "Skipped {s}: {s}/{s}{s} already exists\n", .{ src, library.recordings_dir, stem, library.recording.ext });
        return true;
    }
    const image = wav.readWholeFile(gpa, src) catch {
        ingest.print(io, "device airec: {s} cannot be read\n", .{src});
        return false;
    };
    defer gpa.free(image);
    const imported = publish(io, image, stem, recordings_path) catch |err| {
        ingest.print(io, "device airec: {s} {s}\n", .{ src, publishFailure(err) });
        return false;
    } orelse return true;
    printImported(io, src, &imported);
    return true;
}

// --- Bluetooth ---------------------------------------------------------------

fn linkFailure(err: ble.Error) []const u8 {
    return switch (err) {
        error.Unsupported => "Bluetooth sync is only available on macOS for now; copy the .ops files off the recorder and run `rec device airec import`",
        error.Unauthorized => "Bluetooth access is denied; allow your terminal under System Settings > Privacy & Security > Bluetooth",
        error.BluetoothOff => "Bluetooth is off",
        error.NotFound => "no AIREC recorder found; turn it on, keep it near, and close the AIREC app on your phone (the recorder takes one connection at a time)",
        error.ConnectFailed, error.ServiceMissing, error.Disconnected => "could not connect to the recorder; try again",
        error.OutOfMemory => "out of memory",
    };
}

fn sessionFailure(err: Session.Error) []const u8 {
    return switch (err) {
        error.Timeout => "the recorder stopped answering",
        error.Truncated => "a download ended early",
        error.Disconnected => "the recorder disconnected",
        error.OutOfMemory => "out of memory",
        else => linkFailure(@errorCast(err)),
    };
}

/// `sync`: connect, bring in every recording the library lacks, disconnect,
/// then transcribe and format what arrived.
fn sync(io: std.Io, gpa: std.mem.Allocator, ctx: ingest.Context, notes: bool) u8 {
    ingest.print(io, "Looking for the AIREC recorder over Bluetooth...\n", .{});
    var link = Link.connect(io, gpa, spec, scan_timeout_s) catch |err| {
        ingest.print(io, "device airec: {s}\n", .{linkFailure(err)});
        return 1;
    };
    var imported: std.ArrayList(Imported) = .empty;
    defer imported.deinit(gpa);
    const ok = blk: {
        defer link.close();
        var session = Session.init(gpa, &link);
        defer session.deinit();
        break :blk catchUp(io, gpa, &session, ctx, &imported);
    };
    if (notes) for (imported.items) |*i| ingest.transcribeAndFormat(io, ctx, i.fileName());
    return if (ok) 0 else 1;
}

/// `watch`: stay connected, reconnecting whenever the recorder comes back,
/// and bring in each recording as soon as the recorder reports it saved.
fn watch(io: std.Io, gpa: std.mem.Allocator, ctx: ingest.Context, notes: bool) u8 {
    while (true) {
        ingest.print(io, "Waiting for the AIREC recorder (Ctrl-C stops)...\n", .{});
        var link = Link.connect(io, gpa, spec, null) catch |err| switch (err) {
            error.Unsupported, error.Unauthorized, error.BluetoothOff, error.OutOfMemory => {
                ingest.print(io, "device airec: {s}\n", .{linkFailure(err)});
                return 1;
            },
            else => {
                io.sleep(.fromSeconds(retry_s), .awake) catch {};
                continue;
            },
        };
        defer link.close();
        var session = Session.init(gpa, &link);
        defer session.deinit();
        follow(io, gpa, &session, ctx, notes);
        ingest.print(io, "The recorder disconnected.\n", .{});
    }
}

/// One connected stretch of `watch`: catch up, then handle events until the
/// link drops.
fn follow(io: std.Io, gpa: std.mem.Allocator, session: *Session, ctx: ingest.Context, notes: bool) void {
    var imported: std.ArrayList(Imported) = .empty;
    defer imported.deinit(gpa);
    if (!catchUp(io, gpa, session, ctx, &imported)) return;
    if (notes) for (imported.items) |*i| ingest.transcribeAndFormat(io, ctx, i.fileName());
    ingest.print(io, "Connected. Recordings come in as soon as you save them on the recorder.\n", .{});
    while (true) {
        const event = session.nextEvent(60_000) catch return orelse continue;
        switch (event) {
            .started => |n| ingest.print(io, "Recording {s}...\n", .{&n}),
            .saved => |entry| {
                imported.clearRetainingCapacity();
                fetch(io, gpa, session, ctx, entry.name, &imported) catch |err| {
                    ingest.print(io, "device airec: {s}: {s}\n", .{ &entry.name, sessionFailure(err) });
                    return;
                };
                if (notes) for (imported.items) |*i| ingest.transcribeAndFormat(io, ctx, i.fileName());
            },
        }
    }
}

/// Opens the session and fetches every recording the library lacks, oldest
/// first. False when the recorder could not be read to the end.
fn catchUp(io: std.Io, gpa: std.mem.Allocator, session: *Session, ctx: ingest.Context, out: *std.ArrayList(Imported)) bool {
    var clock: protocol.Name = undefined;
    localtime.digits(&clock);
    const entries = open: {
        session.open(clock) catch |err| break :open err;
        break :open session.list();
    } catch |err| {
        ingest.print(io, "device airec: {s}\n", .{sessionFailure(err)});
        return false;
    };
    defer gpa.free(entries);
    std.mem.sort(protocol.Entry, entries, {}, olderFirst);

    const before = out.items.len;
    for (entries) |e| {
        if (ingest.exists(io, ctx.recordings_path, &e.name)) continue;
        fetch(io, gpa, session, ctx, e.name, out) catch |err| {
            ingest.print(io, "device airec: {s}: {s}\n", .{ &e.name, sessionFailure(err) });
            return false;
        };
    }
    if (out.items.len == before) ingest.print(io, "Up to date: every recording on the recorder is in {s}/.\n", .{library.recordings_dir});
    return true;
}

fn olderFirst(_: void, a: protocol.Entry, b: protocol.Entry) bool {
    return std.mem.order(u8, &a.name, &b.name) == .lt;
}

/// Downloads one recording and publishes it. Session errors propagate (the
/// link may be gone); a recording that fails to decode is reported and
/// skipped.
fn fetch(io: std.Io, gpa: std.mem.Allocator, session: *Session, ctx: ingest.Context, recording: protocol.Name, out: *std.ArrayList(Imported)) Session.Error!void {
    ingest.print(io, "Downloading {s}...\n", .{&recording});
    const bytes = try session.download(recording);
    defer gpa.free(bytes);
    const imported = publish(io, bytes, &recording, ctx.recordings_path) catch |err| {
        ingest.print(io, "device airec: {s} {s}\n", .{ &recording, publishFailure(err) });
        return;
    } orelse return;
    printImported(io, &recording, &imported);
    try out.append(gpa, imported);
}

test "the recording stem comes from an .ops basename, any case" {
    try std.testing.expectEqualStrings("20241231221356", sourceStem("/Volumes/AIREC/20241231221356.ops").?);
    try std.testing.expectEqualStrings("20241231221356", sourceStem("20241231221356.OPS").?);
    try std.testing.expectEqualStrings("a", sourceStem("dir/a.Ops").?);
}

test "anything but a named .ops file is refused" {
    try std.testing.expect(sourceStem("note.wav") == null);
    try std.testing.expect(sourceStem(".ops") == null);
    try std.testing.expect(sourceStem("dir/") == null);
    try std.testing.expect(sourceStem("ops") == null);
}

test "notes are on unless --no-notes; anything else is a usage error" {
    try std.testing.expectEqual(@as(?bool, true), parseNotes(&.{}));
    try std.testing.expectEqual(@as(?bool, false), parseNotes(&.{"--no-notes"}));
    try std.testing.expectEqual(@as(?bool, null), parseNotes(&.{"--verbose"}));
}
