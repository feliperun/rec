//! The two documents belonging to an open recording and their background job.
const std = @import("std");
const library = @import("library.zig");
const llm = @import("llm.zig");
const markdown = @import("markdown.zig");
const prompts = @import("prompts.zig");
const transcribecmd = @import("transcribecmd.zig");
const formatcmd = @import("formatcmd.zig");

pub const Tab = enum { transcript, formatted };
const State = enum { missing, ready, failed };

const Document = struct {
    path: []u8,
    raw: ?[]u8 = null,
    rendered: ?[]u8 = null,
    state: State = .missing,

    fn load(self: *Document, io: std.Io, gpa: std.mem.Allocator, color: bool) void {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(markdown.max_document_bytes)) catch return;
        if (std.mem.trim(u8, raw, " \r\n\t").len == 0) {
            gpa.free(raw);
            return;
        }
        const rendered = markdown.render(gpa, prompts.splitFrontmatter(raw).body, color) catch {
            gpa.free(raw);
            return;
        };
        if (self.raw) |old| gpa.free(old);
        if (self.rendered) |old| gpa.free(old);
        self.raw = raw;
        self.rendered = rendered;
        self.state = .ready;
    }

    fn deinit(self: *Document, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        if (self.raw) |raw| gpa.free(raw);
        if (self.rendered) |rendered| gpa.free(rendered);
    }
};

pub const Session = struct {
    name: [:0]u8,
    recordings_path: []const u8,
    documents: [2]Document,
    active: Tab = .transcript,
    job: ?Tab = null,
    future: ?std.Io.Future(u8) = null,
    done: std.atomic.Value(bool) = .init(false),
    want_format: bool = false,
    color: bool,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, path: []const u8, name: []const u8, color: bool) !Session {
        const selected = try gpa.dupeZ(u8, name);
        errdefer gpa.free(selected);
        const transcript = try std.fmt.allocPrint(gpa, "{s}/{s}.md", .{ path, library.stripExt(name) });
        errdefer gpa.free(transcript);
        const formatted = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}.md", .{ path, library.stripExt(name), formatcmd.default_template });
        var self = Session{
            .name = selected,
            .recordings_path = path,
            .color = color,
            .documents = .{ .{ .path = transcript }, .{ .path = formatted } },
        };
        for (&self.documents) |*doc| doc.load(io, gpa, color);
        return self;
    }

    pub fn deinit(self: *Session, io: std.Io, gpa: std.mem.Allocator) void {
        if (self.future) |*future| _ = future.cancel(io);
        for (&self.documents) |*doc| doc.deinit(gpa);
        gpa.free(self.name);
    }

    fn document(self: *Session, tab: Tab) *Document {
        return &self.documents[@intFromEnum(tab)];
    }

    pub fn raw(self: *Session) []const u8 {
        return self.document(self.active).raw orelse "";
    }

    pub fn text(self: *Session) []const u8 {
        if (self.document(self.active).rendered) |rendered| return rendered;
        if (self.job == self.active or (self.active == .formatted and self.want_format))
            return "Generating text... You can keep listening or switch tabs.\n";
        if (self.document(self.active).state == .failed) return switch (self.active) {
            .transcript => "Transcription failed. Check your connection and rec setup, then press T to retry.\n",
            .formatted => "Formatting failed. Check your connection and rec setup, then press F to retry.\n",
        };
        return switch (self.active) {
            .transcript => "No transcript yet. Press T to transcribe this recording.\n",
            .formatted => "No formatted notes yet. Press F to generate them.\n",
        };
    }

    pub fn tabs(self: *const Session) []const u8 {
        return switch (self.active) {
            .transcript => "[T Transcript]   F Formatted",
            .formatted => " T Transcript   [F Formatted]",
        };
    }

    pub fn status(self: *const Session) ?[]const u8 {
        return switch (self.job orelse return null) {
            .transcript => if (self.want_format) "Transcribing, then formatting..." else "Transcribing...",
            .formatted => "Formatting...",
        };
    }

    /// Existing documents only switch tabs. Repeated keys never duplicate work.
    pub fn select(self: *Session, io: std.Io, tab: Tab) void {
        self.active = tab;
        if (self.document(tab).state == .ready) return;
        if (tab == .formatted) self.want_format = true;
        if (self.job != null) return;
        self.start(io, if (self.document(.transcript).state != .ready) .transcript else tab);
    }

    fn start(self: *Session, io: std.Io, tab: Tab) void {
        self.done.store(false, .release);
        self.job = tab;
        self.future = io.concurrent(generate, .{ self, io, tab }) catch {
            self.failed(tab);
            self.job = null;
            return;
        };
    }

    fn failed(self: *Session, tab: Tab) void {
        self.document(tab).state = .failed;
        if (self.want_format) self.document(.formatted).state = .failed;
        self.want_format = false;
    }

    /// Only the UI thread publishes documents; workers never touch view state.
    pub fn poll(self: *Session, io: std.Io, gpa: std.mem.Allocator) bool {
        const tab = self.job orelse return false;
        if (!self.done.load(.acquire)) return false;
        const code = self.future.?.await(io);
        self.future = null;
        self.job = null;
        if (code != 0) {
            self.failed(tab);
            return true;
        }
        self.document(tab).load(io, gpa, self.color);
        if (self.document(tab).state != .ready) {
            self.failed(tab);
        } else if (tab == .transcript and self.want_format) {
            self.start(io, .formatted);
        } else self.want_format = false;
        return true;
    }

    fn generate(self: *Session, io: std.Io, tab: Tab) u8 {
        defer self.done.store(true, .release);
        // The worker's allocations are independent of the UI allocator.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home = llm.envValue(home_var) orelse "";
        return switch (tab) {
            .transcript => transcribecmd.run(io, arena.allocator(), &.{self.name}, llm.envValue("DEEPGRAM_API_KEY"), home, self.recordings_path, .background),
            .formatted => formatcmd.run(io, arena.allocator(), &.{self.name}, home, self.recordings_path, .background),
        };
    }
};
