//! What every device integration does with a recording it brings in:
//! publish it under ~/recordings/ in the platform's recording format, the
//! way `record` does (a `.part` file renamed into place), then transcribe
//! and format it like `rec transcribe` and `rec format` would. Device
//! modules only decode their own format into canonical PCM.

const std = @import("std");
const formatcmd = @import("../formatcmd.zig");
const library = @import("../library.zig");
const transcribecmd = @import("../transcribecmd.zig");

pub const Context = struct {
    home_dir: []const u8,
    recordings_path: []const u8,
    /// DEEPGRAM_API_KEY when set; transcription reports its absence.
    api_key: ?[]const u8,
};

pub const Error = error{ NameTooLong, CannotWrite };

/// A recording being encoded to `<stem><ext>.part`; `finish` publishes it.
pub const Writer = struct {
    encoder: library.recording.Encoder,
    sample_rate: u32,
    channels: u32,
    frames: u64 = 0,
    name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    temp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    temp_len: usize = 0,

    /// The published file name, e.g. "20261020165922.m4a".
    pub fn name(self: *const Writer) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Interleaved s16le PCM in the layout `begin` was given.
    pub fn write(self: *Writer, pcm: []const u8) Error!void {
        self.encoder.write(pcm) catch return error.CannotWrite;
        self.frames += pcm.len / (2 * self.channels);
    }

    pub fn finish(self: *Writer, io: std.Io) Error!void {
        const temp = self.temp_buf[0..self.temp_len];
        self.encoder.finish() catch {
            std.Io.Dir.cwd().deleteFile(io, temp) catch {};
            return error.CannotWrite;
        };
        std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), self.path_buf[0..self.path_len], io) catch {
            std.Io.Dir.cwd().deleteFile(io, temp) catch {};
            return error.CannotWrite;
        };
    }

    /// Drops an unfinished recording; nothing reaches the library.
    pub fn abort(self: *Writer, io: std.Io) void {
        self.encoder.abort();
        std.Io.Dir.cwd().deleteFile(io, self.temp_buf[0..self.temp_len]) catch {};
    }

    /// Duration of the audio written so far, rounded like `list` shows it.
    pub fn seconds(self: *const Writer) u64 {
        return (self.frames + self.sample_rate / 2) / self.sample_rate;
    }
};

/// Whether `<stem><ext>` is already in the library: imports skip it, so
/// bringing a device in again only adds what is new.
pub fn exists(io: std.Io, recordings_path: []const u8, stem: []const u8) bool {
    var name_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ stem, library.recording.ext }) catch return false;
    const path = library.recordingPath(recordings_path, name, &path_buf) orelse return false;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Starts `<stem><ext>` in the library. The caller writes PCM and then
/// either `finish`es or `abort`s.
pub fn begin(io: std.Io, recordings_path: []const u8, stem: []const u8, sample_rate: u32, channels: u32) Error!Writer {
    std.Io.Dir.cwd().createDirPath(io, recordings_path) catch return error.CannotWrite;
    var w = Writer{ .encoder = undefined, .sample_rate = sample_rate, .channels = channels };
    const name = std.fmt.bufPrint(&w.name_buf, "{s}{s}", .{ stem, library.recording.ext }) catch return error.NameTooLong;
    w.name_len = name.len;
    const path = library.recordingPath(recordings_path, name, &w.path_buf) orelse return error.NameTooLong;
    w.path_len = path.len;
    const temp = std.fmt.bufPrint(&w.temp_buf, "{s}.part", .{path}) catch return error.NameTooLong;
    w.temp_len = temp.len;
    // A `.part` left by an interrupted import is replaced.
    std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    w.encoder = library.recording.Encoder.init(temp, sample_rate, channels) catch return error.CannotWrite;
    return w;
}

/// Transcribes the recording `name` and formats the transcript with the
/// default template, printing one line per step. Failures are reported,
/// not fatal: the recording is already in the library.
pub fn transcribeAndFormat(io: std.Io, ctx: Context, name: []const u8) void {
    // The commands allocate freely; one arena per recording bounds them.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const arg = gpa.dupeZ(u8, name) catch return;
    const stem = library.stripExt(name);

    if (transcribecmd.run(io, gpa, &.{arg}, ctx.api_key, ctx.home_dir, ctx.recordings_path, .background) != 0) {
        print(io, "  transcription failed; `rec transcribe {s}` shows why\n", .{name});
        return;
    }
    print(io, "  transcript → {s}/{s}.md\n", .{ library.recordings_dir, stem });
    if (formatcmd.run(io, gpa, &.{arg}, ctx.home_dir, ctx.recordings_path, .background) != 0) {
        print(io, "  formatting failed; `rec format {s}` shows why\n", .{name});
        return;
    }
    print(io, "  notes → {s}/{s}.{s}.md\n", .{ library.recordings_dir, stem, formatcmd.default_template });
}

pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}
