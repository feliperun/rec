const std = @import("std");

pub const recordings_dir = "recordings";

/// One row of the library: a WAV under ./recordings/ with its stats and the
/// duration parsed from its header (null when the header is unreadable).
pub const Entry = struct {
    name: []u8,
    mtime: std.Io.Timestamp,
    size: u64,
    duration_sec: ?f64,
};

pub fn freeEntries(gpa: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |e| gpa.free(e.name);
    entries.deinit(gpa);
}

/// Appends every ./recordings/*.wav to `entries` (names owned by `gpa`; the
/// caller sorts and frees). A missing directory is the empty library, not an
/// error: `list` renders its empty state and `play` reports no match.
pub fn scan(io: std.Io, gpa: std.mem.Allocator, entries: *std.ArrayList(Entry)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, recordings_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wav")) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch continue;

        // Header prefix only: durations come from the chunk headers, so a few
        // KiB is plenty and meeting-sized files are never read whole.
        var prefix: [4096]u8 = undefined;
        const data: []u8 = dir.readFile(io, entry.name, &prefix) catch prefix[0..0];

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try entries.append(gpa, .{
            .name = name,
            .mtime = stat.mtime,
            .size = stat.size,
            .duration_sec = parseDurationPrefix(data, stat.size),
        });
    }
}

fn entryNewerFirst(_: void, a: Entry, b: Entry) bool {
    if (a.mtime.nanoseconds != b.mtime.nanoseconds) {
        return a.mtime.nanoseconds > b.mtime.nanoseconds;
    }
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// `list`: renders the library table, or the empty state. Returns the exit
/// code (always 0 unless scanning ran out of memory).
pub fn listRecordings(io: std.Io, gpa: std.mem.Allocator) u8 {
    var entries: std.ArrayList(Entry) = .empty;
    defer freeEntries(gpa, &entries);

    scan(io, gpa, &entries) catch {
        printStderr(io, "list: out of memory\n");
        return 1;
    };

    if (entries.items.len == 0) {
        printStdout(io, "No recordings yet.\n");
        return 0;
    }

    std.mem.sort(Entry, entries.items, {}, entryNewerFirst);

    var name_w: usize = "name".len;
    for (entries.items) |e| name_w = @max(name_w, e.name.len);

    var line: [512]u8 = undefined;
    {
        var n: usize = 0;
        appendStr(&line, &n, "  #  ");
        appendStr(&line, &n, "name");
        appendSpaces(&line, &n, name_w - "name".len);
        appendStr(&line, &n, "  time  size\n");
        printStdout(io, line[0..n]);
    }

    for (entries.items, 1..) |e, idx| {
        var n: usize = 0;
        appendUintPadded(&line, &n, idx, 3);
        appendStr(&line, &n, "  ");
        appendStr(&line, &n, e.name);
        appendSpaces(&line, &n, name_w - e.name.len);
        appendStr(&line, &n, "  ");
        appendDuration(&line, &n, e.duration_sec);
        appendStr(&line, &n, "  ");
        appendSize(&line, &n, e.size);
        appendStr(&line, &n, "\n");
        printStdout(io, line[0..n]);
    }
    return 0;
}

/// Duration from the chunk headers found in `data`, a prefix of a WAV file
/// of `file_size` bytes. Unlike wav.parseWavDuration (which needs the whole
/// image), the data chunk body may extend past the prefix: its declared size
/// is clamped to the bytes the file actually holds.
fn parseDurationPrefix(data: []const u8, file_size: u64) ?f64 {
    if (data.len < 44 or file_size < 44) return null;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) {
        return null;
    }

    var byte_rate: u64 = 0;
    var data_bytes: ?u64 = null;

    var off: usize = 12;
    while (off + 8 <= data.len) {
        const id = data[off .. off + 4];
        const size = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const body = off + 8;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16 or data.len < body + 16) return null;
            const format = std.mem.readInt(u16, data[body..][0..2], .little);
            const channels = std.mem.readInt(u16, data[body + 2 ..][0..2], .little);
            const rate = std.mem.readInt(u32, data[body + 4 ..][0..4], .little);
            const br = std.mem.readInt(u32, data[body + 8 ..][0..4], .little);
            const bits = std.mem.readInt(u16, data[body + 14 ..][0..2], .little);
            if (format != 1 or bits != 16 or channels == 0 or br == 0 or rate == 0) {
                return null;
            }
            byte_rate = br;
        } else if (std.mem.eql(u8, id, "data")) {
            const present: u64 = if (file_size > body) file_size - body else 0;
            data_bytes = @min(@as(u64, size), present);
        }

        // Step by the declared size even past the prefix: only the chunk
        // headers need to be inside it.
        const next = @as(u64, off) + 8 + size + (size & 1);
        if (next >= data.len) break;
        off = @intCast(next);
    }

    const bytes = data_bytes orelse return null;
    if (byte_rate == 0) return null;
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(byte_rate));
}

/// MM:SS from the parsed duration; "--:--" when the header was unreadable.
fn appendDuration(buf: []u8, n: *usize, duration: ?f64) void {
    const d = duration orelse {
        appendStr(buf, n, "--:--");
        return;
    };
    const total: u64 = @intFromFloat(@max(d + 0.5, 0.0));
    const mm = total / 60;
    const ss = total % 60;
    if (mm >= 100) {
        appendUint(buf, n, mm);
    } else {
        buf[n.*] = '0' + @as(u8, @intCast(mm / 10));
        n.* += 1;
        buf[n.*] = '0' + @as(u8, @intCast(mm % 10));
        n.* += 1;
    }
    buf[n.*] = ':';
    n.* += 1;
    buf[n.*] = '0' + @as(u8, @intCast(ss / 10));
    n.* += 1;
    buf[n.*] = '0' + @as(u8, @intCast(ss % 10));
    n.* += 1;
}

/// Human-readable size: "862 B", "187.5 KiB", "1.4 MiB", ...
fn appendSize(buf: []u8, n: *usize, bytes: u64) void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    if (bytes < 1024) {
        appendUint(buf, n, bytes);
        appendStr(buf, n, " B");
        return;
    }
    var whole = bytes;
    var frac10: u64 = 0; // tenths of the current unit
    var ui: usize = 0;
    while (ui < 4) : (ui += 1) {
        if (whole < 1024) break;
        frac10 = (whole % 1024) * 10 / 1024;
        whole /= 1024;
    }
    appendUint(buf, n, whole);
    if (frac10 != 0) {
        buf[n.*] = '.';
        n.* += 1;
        buf[n.*] = '0' + @as(u8, @intCast(frac10));
        n.* += 1;
    }
    appendStr(buf, n, " ");
    appendStr(buf, n, units[ui]);
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

fn appendSpaces(buf: []u8, n: *usize, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        buf[n.*] = ' ';
        n.* += 1;
    }
}

fn appendUint(buf: []u8, n: *usize, v: u64) void {
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (x > 0) {
            tmp[len] = '0' + @as(u8, @intCast(x % 10));
            len += 1;
            x /= 10;
        }
    }
    while (len > 0) {
        len -= 1;
        buf[n.*] = tmp[len];
        n.* += 1;
    }
}

fn appendUintPadded(buf: []u8, n: *usize, v: u64, width: usize) void {
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (x > 0) {
            tmp[len] = '0' + @as(u8, @intCast(x % 10));
            len += 1;
            x /= 10;
        }
    }
    appendSpaces(buf, n, width -| len);
    while (len > 0) {
        len -= 1;
        buf[n.*] = tmp[len];
        n.* += 1;
    }
}

fn printStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

/// Canonical 44-byte PCM WAV header, for the parser tests below.
fn buildTestHeader(buf: *[44]u8, sample_rate: u32, channels: u16, data_bytes: u32) void {
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_bytes, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * @as(u32, channels) * 2, .little);
    std.mem.writeInt(u16, buf[32..34], channels * 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
}

test "duration from a fully buffered header" {
    // 1 s of 48 kHz stereo PCM16 = 192000 data bytes.
    var img: [44 + 64]u8 = undefined;
    buildTestHeader(img[0..44], 48000, 2, 192000);
    const d = parseDurationPrefix(&img, 44 + 192000).?;
    try std.testing.expect(@abs(d - 1.0) < 0.000001);
}

test "duration tolerates a data body beyond the prefix" {
    // Only the 44-byte header is in the prefix; the declared data size is
    // clamped to what the file actually holds.
    var img: [44]u8 = undefined;
    buildTestHeader(&img, 48000, 2, 192000);
    const d = parseDurationPrefix(&img, 44 + 192000).?;
    try std.testing.expect(@abs(d - 1.0) < 0.000001);

    // File shorter than declared: clamp to the real bytes (0.5 s here).
    const half = parseDurationPrefix(&img, 44 + 96000).?;
    try std.testing.expect(@abs(half - 0.5) < 0.000001);
}

test "rejects non-WAV and truncated prefixes" {
    var img: [44]u8 = undefined;
    buildTestHeader(&img, 48000, 2, 192000);
    try std.testing.expectEqual(@as(?f64, null), parseDurationPrefix(&img, 0));
    try std.testing.expectEqual(@as(?f64, null), parseDurationPrefix(img[0..20], 44));
    try std.testing.expectEqual(@as(?f64, null), parseDurationPrefix("not a wav file at all....", 25));

    // Non-PCM format.
    img[20] = 3;
    try std.testing.expectEqual(@as(?f64, null), parseDurationPrefix(&img, 44 + 4));
}
