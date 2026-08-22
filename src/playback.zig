const std = @import("std");
const library = @import("library.zig");

const afplay_path = "/usr/bin/afplay";

/// Pid of the running afplay, published for the SIGINT handler (atomic
/// load/store and kill() are async-signal-safe).
var g_child_pid = std.atomic.Value(std.posix.pid_t).init(-1);
var g_interrupted = std.atomic.Value(bool).init(false);

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_interrupted.store(true, .release);
    const pid = g_child_pid.load(.acquire);
    if (pid > 0) std.posix.kill(pid, .INT) catch {};
}

/// `play <index|filename>`: resolves the selection against the library and
/// plays it through the system player. Returns the exit code: afplay's code
/// is propagated, and a Ctrl-C that took the child down exits 130.
pub fn playSelection(io: std.Io, gpa: std.mem.Allocator, selection: []const u8) u8 {
    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);

    library.scan(io, gpa, &entries) catch {
        printStderr(io, "play: out of memory\n");
        return 1;
    };
    if (entries.items.len == 0) {
        printStderr(io, "No recordings yet.\n");
        return 1;
    }

    const name = resolve(selection, entries.items) orelse {
        printStderr(io, "play: no recording matches '");
        printStderr(io, selection);
        printStderr(io, "' (see `rec list`)\n");
        return 1;
    };

    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var rel_len: usize = 0;
    appendStr(&rel_buf, &rel_len, library.recordings_dir);
    appendStr(&rel_buf, &rel_len, "/");
    appendStr(&rel_buf, &rel_len, name);

    // afplay gets an absolute path so it never depends on our cwd.
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, rel_buf[0..rel_len], &abs_buf) catch {
        printStderr(io, "play: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    // Replace SIGINT just for the child's lifetime so Ctrl-C takes down
    // afplay while we survive to reap it; the previous action is restored
    // on return (the interactive loop keeps its own handler).
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_act: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &act, &old_act);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_act, null);

    printStderr(io, "Playing ");
    printStderr(io, name);
    printStderr(io, " (Ctrl-C to stop)\n");

    var child = std.process.spawn(io, .{
        .argv = &.{ afplay_path, abs_buf[0..abs_len] },
    }) catch {
        printStderr(io, "play: cannot spawn ");
        printStderr(io, afplay_path);
        printStderr(io, "\n");
        return 1;
    };
    if (child.id) |pid| g_child_pid.store(pid, .release);
    defer g_child_pid.store(-1, .release);

    // wait() reaps the child on every path: normal exit, or its death after
    // the handler's kill() — no zombies.
    const term = child.wait(io) catch {
        child.kill(io);
        printStderr(io, "play: failed waiting for afplay\n");
        return 1;
    };

    if (g_interrupted.load(.acquire)) {
        printStderr(io, "play: interrupted\n");
        return 130; // 128 + SIGINT
    }

    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@min(@as(u32, 128) + @as(u32, @intCast(@intFromEnum(sig))), 255)),
        .stopped, .unknown => 1,
    };
}

/// Selection → library entry name: a 1-based index, or a filename (with or
/// without the recordings/ prefix).
fn resolve(selection: []const u8, entries: []const library.Entry) ?[]const u8 {
    if (selection.len > 0 and allDigits(selection)) {
        const idx = std.fmt.parseInt(usize, selection, 10) catch return null;
        if (idx < 1 or idx > entries.len) return null;
        return entries[idx - 1].name;
    }
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, selection)) return e.name;
    }
    const with_dir = library.recordings_dir ++ "/";
    if (std.mem.startsWith(u8, selection, with_dir)) {
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, selection[with_dir.len..])) return e.name;
        }
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}
