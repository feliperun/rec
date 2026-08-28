const std = @import("std");
const library = @import("library.zig");
const prompts = @import("prompts.zig");
const split = @import("split.zig");
const waveform = @import("waveform.zig");

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
/// plays it through the system player. On a terminal, the playback is a
/// two-line live view — status plus waveform with the played part bright —
/// driven by keys: SPACE pauses/resumes (SIGSTOP/SIGCONT on afplay), S cuts
/// the recording in two at the current position, Q or Ctrl-C stops. Without
/// a terminal it plays to completion under Ctrl-C, as before.
pub fn playSelection(io: std.Io, gpa: std.mem.Allocator, selection: []const u8, recordings_path: []const u8) u8 {
    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);

    library.scan(io, gpa, &entries, recordings_path) catch {
        printStderr(io, "play: out of memory\n");
        return 1;
    };
    if (entries.items.len == 0) {
        printStderr(io, "No recordings yet.\n");
        return 1;
    }

    // Numeric selections index the newest-first order `list` shows; scan
    // returns directory order, so normalize before resolving.
    library.sortNewestFirst(entries.items);

    const name = library.resolveName(selection, entries.items) orelse {
        printStderr(io, "play: no recording matches '");
        printStderr(io, selection);
        printStderr(io, "' (see `rec list`)\n");
        return 1;
    };

    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recording_path = library.recordingPath(recordings_path, name, &rel_buf) orelse {
        printStderr(io, "play: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    // afplay gets an absolute path so it never depends on our cwd.
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, recording_path, &abs_buf) catch {
        printStderr(io, "play: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };
    const abs_path = abs_buf[0..abs_len];

    // A transcribed recording shows its transcript in full above the player.
    printTranscript(io, gpa, recordings_path, name);

    // The waveform is drawn from decoded PCM; failing to decode must not
    // cost the user the playback, so it degrades to a flat bar.
    var peaks: std.ArrayList(waveform.Peak) = .empty;
    defer peaks.deinit(gpa);
    var duration_sec: f64 = 0;
    if (split.loadPcm(gpa, abs_path)) |*audio| {
        var a = audio.*;
        defer a.deinit(gpa);
        duration_sec = @as(f64, @floatFromInt(a.pcm.len)) / @as(f64, @floatFromInt(a.byteRate()));
        var tracker = waveform.PeakTracker.init(gpa, peakBlockBytes(a.byteRate()));
        defer tracker.deinit();
        tracker.feed(a.pcm);
        peaks.appendSlice(gpa, tracker.peaks.items) catch {};
    } else |_| {
        for (entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) duration_sec = e.duration_sec orelse 0;
        }
    }

    const is_tty = blk: {
        const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
        const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
        break :blk stdin_tty and stderr_tty;
    };

    if (is_tty) {
        return playInteractive(io, gpa, abs_path, name, peaks.items, duration_sec);
    }

    printStderr(io, "Playing ");
    printStderr(io, name);
    printStderr(io, " (Ctrl-C to stop)\n");
    return playBlocking(io, abs_path);
}

/// Decodes, plays, and waits — the non-interactive path. The caller prints
/// the messages. Returns afplay's exit code (130 on Ctrl-C).
fn playBlocking(io: std.Io, abs_path: []const u8) u8 {
    installSigint(io);

    var child = std.process.spawn(io, .{
        .argv = &.{ afplay_path, abs_path },
    }) catch {
        printStderr(io, "play: cannot spawn ");
        printStderr(io, afplay_path);
        printStderr(io, "\n");
        return 1;
    };
    if (child.id) |pid| g_child_pid.store(pid, .release);
    defer g_child_pid.store(-1, .release);

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

// --- interactive playback ----------------------------------------------------

/// How often the view redraws, in ms — fast enough to feel live, slow enough
/// to keep the terminal quiet.
const tick_ms = 100;

const peakBlockBytes = waveform.peakBlockBytes;

const PlayState = enum { playing, paused };

/// Runs the two-line live view over afplay: the waveform (played part
/// bright, rest dim) and a status line, redrawn each tick. Keys: SPACE
/// pause/resume, S split here, Q/Ctrl-C stop. Restores the terminal on
/// every exit path.
fn playInteractive(
    io: std.Io,
    gpa: std.mem.Allocator,
    abs_path: []const u8,
    name: []const u8,
    peaks: []const waveform.Peak,
    duration_sec: f64,
) u8 {
    const cooked = std.posix.tcgetattr(0) catch {
        // Raw mode is unavailable (odd terminal); degrade to plain playback.
        printStderr(io, "Playing ");
        printStderr(io, name);
        printStderr(io, " (Ctrl-C to stop)\n");
        return playBlocking(io, abs_path);
    };

    var raw = cooked;
    raw.lflag.ICANON = false; // one key at a time
    raw.lflag.ECHO = false; // we echo manually
    raw.lflag.ISIG = false; // Ctrl-C arrives as a byte we handle ourselves
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false; // Ctrl-S/Q must not freeze the terminal
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(0, .NOW, raw) catch {
        printStderr(io, "play: cannot enter raw mode\n");
        return 1;
    };
    defer std.posix.tcsetattr(0, .FLUSH, cooked) catch {};

    installSigint(io);

    const child = std.process.spawn(io, .{
        .argv = &.{ afplay_path, abs_path },
    }) catch {
        printStderr(io, "play: cannot spawn ");
        printStderr(io, afplay_path);
        printStderr(io, "\n");
        return 1;
    };
    const pid: std.posix.pid_t = child.id orelse {
        printStderr(io, "play: cannot spawn ");
        printStderr(io, afplay_path);
        printStderr(io, "\n");
        return 1;
    };
    g_child_pid.store(pid, .release);
    defer g_child_pid.store(-1, .release);

    const started = std.Io.Timestamp.now(io, .awake);
    var state: PlayState = .playing;
    var paused_ns: i128 = 0;
    var pause_started = started;
    var first_draw = true;
    var exit_code: u8 = 0;
    var reaped = false;

    keys: while (true) {
        // Natural end: reap without blocking and leave the view.
        if (!reaped) {
            var status: c_int = 0;
            if (std.c.waitpid(pid, &status, std.posix.W.NOHANG) == pid) {
                reaped = true;
                break :keys;
            }
        }
        if (g_interrupted.load(.acquire)) {
            exit_code = 130;
            break :keys;
        }

        // Elapsed playing time: the wall clock minus whatever was spent
        // paused (the reference freezes at pause_started while paused).
        const now = std.Io.Timestamp.now(io, .awake);
        const ref = if (state == .paused) pause_started else now;
        const elapsed_ns = ref.nanoseconds - started.nanoseconds - paused_ns;
        const elapsed_sec = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1e9;

        draw(io, state, elapsed_sec, duration_sec, peaks, &first_draw);

        switch (readKey(io, tick_ms)) {
            .none => {},
            .eof => break :keys,
            .key => |c| switch (c) {
                ' ' => {
                    if (state == .playing) {
                        pause_started = std.Io.Timestamp.now(io, .awake);
                        if (std.posix.kill(pid, .STOP)) |_| {} else |_| {}
                        state = .paused;
                    } else {
                        const resumed = std.Io.Timestamp.now(io, .awake);
                        paused_ns += resumed.nanoseconds - pause_started.nanoseconds;
                        if (std.posix.kill(pid, .CONT)) |_| {} else |_| {}
                        state = .playing;
                    }
                },
                's', 'S' => {
                    // A cut needs audio on both sides; near the edges there
                    // is nothing to split, so say so and keep playing.
                    if (elapsed_sec < 0.2 or duration_sec - elapsed_sec < 0.2) {
                        drawNote(io, "nothing to split this close to the edge", &first_draw);
                        continue :keys;
                    }
                    stopChild(pid, &reaped);
                    split.splitFile(io, gpa, abs_path, elapsed_sec) catch |err| {
                        printStderr(io, "play: cannot split (");
                        printStderr(io, @errorName(err));
                        printStderr(io, ")\n");
                    };
                    break :keys;
                },
                'q' => break :keys,
                0x03 => { // Ctrl-C byte: ISIG is off in raw mode
                    exit_code = 130;
                    break :keys;
                },
                else => {},
            },
        }
    }

    if (!reaped) stopChild(pid, &reaped);
    printStderr(io, "\n");
    return exit_code;
}

/// Kills and reaps the child, ignoring an already-dead pid (ESRCH).
fn stopChild(pid: std.posix.pid_t, reaped: *bool) void {
    std.posix.kill(pid, .TERM) catch {};
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    reaped.* = true;
}

const Key = union(enum) {
    none,
    key: u8,
    eof,
};

/// Waits up to `ms` for a keystroke; the poll window is what paces the UI.
fn readKey(io: std.Io, ms: i32) Key {
    _ = io;
    var fds = [_]std.posix.pollfd{.{
        .fd = 0,
        .events = std.posix.POLL.IN,
        .revents = undefined,
    }};
    const ready = std.posix.poll(&fds, ms) catch return .none;
    if (ready == 0) return .none;
    var buf: [1]u8 = undefined;
    const n = std.posix.read(0, &buf) catch return .none;
    if (n == 0) return .eof;
    return .{ .key = buf[0] };
}

// --- the live view -----------------------------------------------------------

fn termWidth() usize {
    return waveform.termWidth();
}

/// Draws the two-line view: on the first draw the lines are printed, after
/// that the cursor climbs back one line and both are rewritten in place.
fn draw(
    io: std.Io,
    state: PlayState,
    elapsed_sec: f64,
    duration_sec: f64,
    peaks: []const waveform.Peak,
    first_draw: *bool,
) void {
    const width = termWidth();
    var line: [512]u8 = undefined;

    if (!first_draw.*) printStderr(io, "\x1b[1A\r");
    printStderr(io, statusLine(&line, state, elapsed_sec, duration_sec));
    printStderr(io, "\x1b[K\n");
    printStderr(io, waveform.renderBar(peaks, width, playedCols(width, elapsed_sec, duration_sec), &line));
    printStderr(io, "\x1b[K");
    first_draw.* = false;
}

/// A transient one-line notice under the view; the next redraw covers it.
fn drawNote(io: std.Io, msg: []const u8, first_draw: *bool) void {
    if (!first_draw.*) printStderr(io, "\x1b[1B\r"); // back onto the status line
    printStderr(io, msg);
    printStderr(io, "\x1b[K\r");
    first_draw.* = true; // the next draw reprints both lines in place
}

/// How many columns of the bar the playback has covered.
fn playedCols(width: usize, elapsed_sec: f64, duration_sec: f64) usize {
    if (duration_sec <= 0) return 0;
    const frac = @min(@max(elapsed_sec / duration_sec, 0.0), 1.0);
    const cols = frac * @as(f64, @floatFromInt(width));
    if (cols >= @as(f64, @floatFromInt(width))) return width;
    return @intFromFloat(cols);
}

/// "▶ 00:12 / 01:30  SPACE=pause S=split Q=stop" — the whole status line.
fn statusLine(buf: []u8, state: PlayState, elapsed_sec: f64, duration_sec: f64) []const u8 {
    var n: usize = 0;
    appendStr(buf, &n, if (state == .playing) "▶ " else "⏸ ");
    appendTime(buf, &n, elapsed_sec);
    appendStr(buf, &n, " / ");
    appendTime(buf, &n, duration_sec);
    appendStr(buf, &n, if (state == .playing) "  SPACE=pause S=split Q=stop" else "  SPACE=play S=split Q=stop");
    return buf[0..n];
}

/// "MM:SS", or "H:MM:SS" past an hour; negative values clamp to zero.
fn appendTime(buf: []u8, n: *usize, sec: f64) void {
    const total: u64 = @intFromFloat(@max(sec + 0.5, 0.0));
    const h = total / 3600;
    const m = (total / 60) % 60;
    const s = total % 60;
    if (h > 0) {
        record.appendUint(buf, n, h);
        buf[n.*] = ':';
        n.* += 1;
        record.append2(buf, n, m);
    } else {
        record.append2(buf, n, m);
    }
    buf[n.*] = ':';
    n.* += 1;
    record.append2(buf, n, s);
}

/// Prints the sibling transcript (`<stem>.md`) in full — frontmatter off,
/// prose verbatim — above the player. No file or empty body: silent.
fn printTranscript(io: std.Io, gpa: std.mem.Allocator, recordings_path: []const u8, name: []const u8) void {
    var stem_buf: [64]u8 = undefined;
    const stem = library.stripExt(name);
    if (stem.len > stem_buf.len) return;
    @memcpy(stem_buf[0..stem.len], stem);

    var md_name_buf: [80]u8 = undefined;
    var md_len: usize = 0;
    record.appendStr(&md_name_buf, &md_len, stem);
    record.appendStr(&md_name_buf, &md_len, ".md");

    var md_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const md_path = library.recordingPath(recordings_path, md_name_buf[0..md_len], &md_path_buf) orelse return;

    const doc = std.Io.Dir.cwd().readFileAlloc(io, md_path, gpa, .limited(16 * 1024 * 1024)) catch return;
    defer gpa.free(doc);

    const parts = prompts.splitFrontmatter(doc);
    if (parts.body.len == 0) return;
    printStderr(io, parts.body);
    if (parts.body[parts.body.len - 1] != '\n') printStderr(io, "\n");
    printStderr(io, "\n");
}

fn installSigint(io: std.Io) void {
    _ = io;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
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

const record = @import("record.zig");

// --- pure-view tests ---------------------------------------------------------

test "playedCols maps elapsed time onto the bar width" {
    try std.testing.expectEqual(@as(usize, 0), playedCols(80, 0, 100));
    try std.testing.expectEqual(@as(usize, 40), playedCols(80, 50, 100));
    try std.testing.expectEqual(@as(usize, 80), playedCols(80, 100, 100));
    // Past the end clamps to full; no duration is a flat dark bar.
    try std.testing.expectEqual(@as(usize, 80), playedCols(80, 300, 100));
    try std.testing.expectEqual(@as(usize, 0), playedCols(80, 50, 0));
}

test "statusLine shows state, times, and keys" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "▶ 00:12 / 01:30  SPACE=pause S=split Q=stop",
        statusLine(&buf, .playing, 12.3, 90),
    );
    try std.testing.expectEqualStrings(
        "⏸ 00:12 / 01:30  SPACE=play S=split Q=stop",
        statusLine(&buf, .paused, 12.3, 90),
    );
}

test "appendTime formats MM:SS and H:MM:SS" {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    appendTime(&buf, &n, 12.3);
    try std.testing.expectEqualStrings("00:12", buf[0..n]);

    n = 0;
    appendTime(&buf, &n, 3661.0);
    try std.testing.expectEqualStrings("1:01:01", buf[0..n]);

    n = 0;
    appendTime(&buf, &n, -5);
    try std.testing.expectEqualStrings("00:00", buf[0..n]);
}

test "peakBlockBytes is a hundred ms of audio" {
    try std.testing.expectEqual(@as(usize, 19200), peakBlockBytes(192000)); // 48 kHz stereo
    try std.testing.expectEqual(@as(usize, 1), peakBlockBytes(0)); // never zero
}
