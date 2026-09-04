const std = @import("std");
const cut = @import("cut.zig");
const keys = @import("keys.zig");
const library = @import("library.zig");
const llm = @import("llm.zig");
const live = @import("live.zig");
const player_mod = @import("player.zig");
const prompts = @import("prompts.zig");
const style = @import("style.zig");
const transcribecmd = @import("transcribecmd.zig");
const waveform = @import("waveform.zig");

/// Set by the SIGINT handler while the interactive loop owns the terminal.
var g_interrupted = std.atomic.Value(bool).init(false);

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_interrupted.store(true, .release);
}

fn installSigint() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// `play <index|filename>`: resolves the selection against the library and
/// plays it in-process on the default output device — the same decoded PCM
/// the waveform is drawn from. On a terminal, playback is a live view on
/// the alternate screen — the multi-row waveform with the playhead over it
/// — driven by keys: SPACE pauses/resumes, ←/→ seek one second (SHIFT for
/// five), I and O anchor the two cursors of the region to cut (drawn as
/// full-height columns with the span reversed), DELETE asks and ENTER
/// confirms the cut, T transcribes the recording or opens its transcript,
/// R clears the marks, Q or Ctrl-C stops. Without a terminal it plays to
/// completion under Ctrl-C.
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

    // An absolute path so the decode and any later cut never depend on cwd.
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, recording_path, &abs_buf) catch {
        printStderr(io, "play: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    // A transcribed recording shows its transcript in full above the player.
    printTranscript(io, gpa, recordings_path, name);

    // One decode serves both the waveform and the audio: without it there
    // is nothing to draw and nothing to play.
    var audio = cut.loadPcm(gpa, abs_buf[0..abs_len]) catch {
        printStderr(io, "play: cannot decode ");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };
    defer audio.deinit(gpa);

    const duration_sec = @as(f64, @floatFromInt(audio.pcm.len)) / @as(f64, @floatFromInt(audio.byteRate()));

    var peaks: std.ArrayList(waveform.Peak) = .empty;
    defer peaks.deinit(gpa);
    var tracker = waveform.PeakTracker.init(gpa, waveform.peakBlockBytes(audio.byteRate()));
    defer tracker.deinit();
    tracker.feed(audio.pcm);
    peaks.appendSlice(gpa, tracker.peaks.items) catch {};

    const is_tty = blk: {
        const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
        const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
        break :blk stdin_tty and stderr_tty;
    };

    if (is_tty) {
        return playInteractive(io, gpa, abs_buf[0..abs_len], audio.pcm, audio.sample_rate, audio.channels, name, peaks.items, duration_sec, recordings_path);
    }

    printStderr(io, "Playing ");
    printStderr(io, name);
    printStderr(io, " (Ctrl-C to stop)\n");
    return playBlocking(io, audio.pcm, audio.sample_rate, audio.channels);
}

/// Plays to completion — the non-interactive path. The caller prints the
/// messages. Returns 0, or 130 on Ctrl-C.
fn playBlocking(io: std.Io, pcm: []const u8, sample_rate: u32, channels: u32) u8 {
    installSigint();

    var p = player_mod.Player{};
    p.start(pcm, sample_rate, @intCast(channels)) catch {
        printStderr(io, "play: cannot open the audio output device\n");
        return 1;
    };
    defer p.deinit();

    while (!p.isDone() and !g_interrupted.load(.acquire)) {
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    if (g_interrupted.load(.acquire)) {
        printStderr(io, "play: interrupted\n");
        return 130; // 128 + SIGINT
    }
    return 0;
}

// --- interactive playback ----------------------------------------------------

/// How often the view redraws, in ms — fast enough to feel live, slow enough
/// to keep the terminal quiet.
const tick_ms = 100;

/// Seek steps: the arrows move the playhead by one second, SHIFT+arrows by
/// five.
const seek_step_sec: f64 = 1.0;
const seek_step_shift_sec: f64 = 5.0;

const PlayState = enum { playing, paused };

/// Runs the live view while the player plays: the status line, the
/// multi-row waveform (played part bright, rest dim, the marked region
/// reversed between its two anchor cursors, playhead over everything), a
/// notes row, and the key hints — one composed frame per tick. Restores
/// the terminal on every exit path.
fn playInteractive(
    io: std.Io,
    gpa: std.mem.Allocator,
    abs_path: []const u8,
    pcm: []const u8,
    sample_rate: u32,
    channels: u32,
    name: []const u8,
    peaks: []const waveform.Peak,
    duration_sec: f64,
    recordings_path: []const u8,
) u8 {
    const cooked = std.posix.tcgetattr(0) catch {
        // Raw mode is unavailable (odd terminal); degrade to plain playback.
        printStderr(io, "Playing ");
        printStderr(io, name);
        printStderr(io, " (Ctrl-C to stop)\n");
        return playBlocking(io, pcm, sample_rate, channels);
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

    installSigint();

    const color = style.detect(io, .stderr());

    // The live view owns the alternate screen; messages printed while it is
    // up would be wiped by the leave, so every exit path restores the normal
    // screen before printing.
    var esc_buf: [32]u8 = undefined; // enter/leave fit; check live.enter if you grow them
    var alt_on = std.Io.File.stderr().isTty(io) catch false;
    if (alt_on) printStderr(io, live.enter(&esc_buf));
    const leaveAlt = struct {
        fn f(io_: std.Io, on: *bool, buf: []u8) void {
            if (!on.*) return;
            printStderr(io_, live.leave(buf));
            on.* = false;
        }
    }.f;

    var p = player_mod.Player{};
    defer p.deinit();
    p.start(pcm, sample_rate, @intCast(channels)) catch {
        leaveAlt(io, &alt_on, &esc_buf);
        printStderr(io, "play: cannot open the audio output device\n");
        return 1;
    };

    // The whole view is composed here and written in one shot per tick —
    // many small writes are what made the cursor's movement flicker.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);

    var state: PlayState = .playing;
    var exit_code: u8 = 0;
    // The region to cut, anchored at the positions where I and O were
    // pressed; null until marked. Either mark alone resolves against the
    // recording's edges (O cuts the head, I the tail).
    var mark_in: ?f64 = null;
    var mark_out: ?f64 = null;
    // The region DELETE is waiting on: the next key either confirms it
    // (ENTER cuts) or cancels it. While it pends, the notes row shows why.
    var confirming: ?[2]f64 = null;
    // A notice shown on the notes row until the next keypress — the
    // delete prompt or a transient "can't do that" message.
    var note_buf: [128]u8 = undefined;
    var note: ?[]const u8 = null;

    keys: while (true) {
        if (p.isDone()) break :keys;
        if (g_interrupted.load(.acquire)) {
            exit_code = 130;
            break :keys;
        }

        draw(io, gpa, &frame, state, p.positionSec(), duration_sec, peaks, mark_in, mark_out, note, color);

        const key = keys.readKey(tick_ms);
        if (key == .none) continue :keys; // no key: the notice stays up
        note = null;

        // A pending delete resolves on the very next key: ENTER cuts,
        // anything else — a second DELETE, the arrows, SPACE — cancels.
        // Ctrl-C still quits outright.
        if (confirming) |span| {
            confirming = null;
            const pressed: ?u8 = if (key == .byte) key.byte else null;
            if (pressed == '\r' or pressed == '\n') {
                // The cut reports on the normal screen: leave first.
                leaveAlt(io, &alt_on, &esc_buf);
                cut.cutIntervalFile(io, gpa, abs_path, span[0], span[1]) catch |err| {
                    printStderr(io, "play: cannot cut (");
                    printStderr(io, @errorName(err));
                    printStderr(io, ")\n");
                };
                break :keys;
            }
            if (pressed == 0x03) {
                exit_code = 130;
                break :keys;
            }
            continue :keys;
        }

        switch (key) {
            .eof => break :keys,
            .byte => |c| switch (c) {
                ' ' => {
                    state = if (state == .playing) .paused else .playing;
                    p.setPaused(state == .paused);
                },
                'i', 'I' => {
                    // The anchors sit at the current position; pressing the
                    // same key again moves that cursor.
                    mark_in = p.positionSec();
                },
                'o', 'O' => {
                    mark_out = p.positionSec();
                },
                'r', 'R' => {
                    mark_in = null;
                    mark_out = null;
                },
                't', 'T' => {
                    // Transcribing (or editing the transcript) takes the
                    // normal screen and a stopped player.
                    leaveAlt(io, &alt_on, &esc_buf);
                    p.stop();
                    exit_code = openTranscript(io, gpa, name, recordings_path);
                    break :keys;
                },
                'q' => break :keys,
                0x03 => { // Ctrl-C byte: ISIG is off in raw mode
                    exit_code = 130;
                    break :keys;
                },
                else => {},
            },
            .delete => {
                const span = cutSpan(mark_in, mark_out, duration_sec) orelse {
                    note = "mark the region with I and O first";
                    continue :keys;
                };
                // A cut needs at least 0.2 s on both sides: the marked
                // region must be real, and it must not eat the file.
                const removed = span[1] - span[0];
                if (removed < 0.2 or duration_sec - removed < 0.2) {
                    note = "nothing to cut: region too short or covering everything";
                    continue :keys;
                }
                confirming = span;
                note = confirmNote(&note_buf, span);
            },
            .left => p.seekBy(-seek_step_sec),
            .right => p.seekBy(seek_step_sec),
            .shift_left => p.seekBy(-seek_step_shift_sec),
            .shift_right => p.seekBy(seek_step_shift_sec),
            .none => unreachable,
        }
    }

    p.stop();
    leaveAlt(io, &alt_on, &esc_buf);
    printStderr(io, "\n");
    return exit_code;
}

// --- the live view -----------------------------------------------------------

/// Composes the whole view — the status line, the waveform grid (the
/// playhead over it, the marked region reversed between its two anchor
/// cursors), a notes row, and the key hints — into `frame` behind a
/// synchronized-update bracket and writes it once. One write per tick with
/// the hardware cursor hidden is what keeps the view from flickering while
/// the playhead moves; the absolute positioning also overwrites whatever a
/// resize did to the grid.
fn draw(
    io: std.Io,
    gpa: std.mem.Allocator,
    frame: *std.ArrayList(u8),
    state: PlayState,
    elapsed_sec: f64,
    duration_sec: f64,
    peaks: []const waveform.Peak,
    mark_in: ?f64,
    mark_out: ?f64,
    note: ?[]const u8,
    color: bool,
) void {
    const width = @min(waveform.termWidth(), waveform.max_columns);
    var esc: [16]u8 = undefined;
    var line: [waveform.rowBufferLen(waveform.max_columns)]u8 = undefined;

    var fractions: [waveform.max_columns]u8 = undefined;
    const fr = waveform.columnFractions(peaks, fractions[0..width]);

    const cursor = @min(playedCols(width, elapsed_sec, duration_sec), width -| 1);
    const has_marks = cutSpan(mark_in, mark_out, duration_sec) != null;
    const sel: ?waveform.SelRange = if (cutSpan(mark_in, mark_out, duration_sec)) |s|
        .{ .start_col = playedCols(width, s[0], duration_sec), .end_col = playedCols(width, s[1], duration_sec) }
    else
        null;
    // The two anchors, drawn as full-height columns at the marked positions
    // — the region's start and end cursors. A lone mark resolves against
    // the recording's edges, like the cut itself does.
    const edges: ?waveform.SelRange = if (mark_in == null and mark_out == null)
        null
    else
        .{
            .start_col = playedCols(width, mark_in orelse 0, duration_sec),
            .end_col = playedCols(width, mark_out orelse duration_sec, duration_sec),
        };

    frame.clearRetainingCapacity();
    frame.appendSlice(gpa, live.sync_begin) catch return;
    frame.appendSlice(gpa, live.moveTo(&esc, 1, 1)) catch return;
    frame.appendSlice(gpa, live.clearLine(&esc)) catch return;
    frame.appendSlice(gpa, statusLine(&line, state, elapsed_sec, duration_sec, mark_in, mark_out, color)) catch return;

    var row: usize = 0;
    while (row < waveform.view_height) : (row += 1) {
        frame.appendSlice(gpa, live.moveTo(&esc, 2 + row, 1)) catch return;
        frame.appendSlice(gpa, live.clearLine(&esc)) catch return;
        frame.appendSlice(gpa, waveform.renderRow(fr, waveform.view_height, row, .{
            .played_cols = cursor,
            .cursor_col = cursor,
            .sel = sel,
            .sel_edges = edges,
            .color = color,
        }, &line)) catch return;
    }

    // The notes row: the pending-delete prompt or a transient notice.
    frame.appendSlice(gpa, live.moveTo(&esc, 2 + waveform.view_height, 1)) catch return;
    frame.appendSlice(gpa, live.clearLine(&esc)) catch return;
    if (note) |msg| {
        var styled: [192]u8 = undefined;
        var n: usize = 0;
        style.appendStyled(&styled, &n, color, style.yellow, msg);
        frame.appendSlice(gpa, styled[0..n]) catch return;
    }

    // The key legend, one dim row under the grid.
    frame.appendSlice(gpa, live.moveTo(&esc, 3 + waveform.view_height, 1)) catch return;
    frame.appendSlice(gpa, live.clearLine(&esc)) catch return;
    frame.appendSlice(gpa, hintsLine(&line, has_marks, state == .paused, color)) catch return;

    frame.appendSlice(gpa, live.sync_end) catch return;
    printStderr(io, frame.items);
}

/// "delete 00:05–00:12? ENTER deletes, anything else cancels" — the note
/// shown while a DELETE is pending confirmation.
fn confirmNote(buf: []u8, span: [2]f64) []const u8 {
    var n: usize = 0;
    appendStr(buf, &n, "delete ");
    _ = appendTime(buf, &n, span[0]);
    appendStr(buf, &n, "–");
    _ = appendTime(buf, &n, span[1]);
    appendStr(buf, &n, "? ENTER deletes, anything else cancels");
    return buf[0..n];
}

/// How many columns of the grid the playback has covered.
fn playedCols(width: usize, elapsed_sec: f64, duration_sec: f64) usize {
    if (duration_sec <= 0) return 0;
    const frac = @min(@max(elapsed_sec / duration_sec, 0.0), 1.0);
    const cols = frac * @as(f64, @floatFromInt(width));
    if (cols >= @as(f64, @floatFromInt(width))) return width;
    return @intFromFloat(cols);
}

/// The interval the marks describe, normalized: the earlier mark is the
/// start. Only O cuts the head [0..O], only I the tail [I..end], both the
/// middle [min..max]. Null when no marks are set.
fn cutSpan(mark_in: ?f64, mark_out: ?f64, duration_sec: f64) ?[2]f64 {
    if (mark_in == null and mark_out == null) return null;
    const start = mark_in orelse 0;
    const end = mark_out orelse duration_sec;
    return .{ @min(start, end), @max(start, end) };
}

/// "▶ 00:12 / 01:30" — a green ▶ (yellow ⏸ when paused), bold elapsed, dim
/// total; with marks set, the resolved span in cyan. The key legend lives
/// in hintsLine, one row under the grid.
fn statusLine(buf: []u8, state: PlayState, elapsed_sec: f64, duration_sec: f64, mark_in: ?f64, mark_out: ?f64, color: bool) []const u8 {
    var n: usize = 0;
    style.appendStyled(buf, &n, color, if (state == .playing) style.green else style.yellow, if (state == .playing) "▶" else "⏸");
    appendStr(buf, &n, " ");
    style.begin(buf, &n, color, style.bold);
    _ = appendTime(buf, &n, elapsed_sec);
    style.end(buf, &n, color);
    style.begin(buf, &n, color, style.dim);
    appendStr(buf, &n, " / ");
    _ = appendTime(buf, &n, duration_sec);
    style.end(buf, &n, color);
    if (cutSpan(mark_in, mark_out, duration_sec)) |s| {
        style.begin(buf, &n, color, style.cyan);
        appendStr(buf, &n, "  [");
        _ = appendTime(buf, &n, s[0]);
        appendStr(buf, &n, "–"); // en dash: three bytes, one cell
        _ = appendTime(buf, &n, s[1]);
        appendStr(buf, &n, "]");
        style.end(buf, &n, color);
    }
    return buf[0..n];
}

/// The dim key legend under the grid. With marks set, the I/O hints give
/// way to R=reset; SPACE names what the next press does.
fn hintsLine(buf: []u8, has_marks: bool, paused: bool, color: bool) []const u8 {
    var n: usize = 0;
    style.begin(buf, &n, color, style.dim);
    appendStr(buf, &n, if (paused) "SPACE=play " else "SPACE=pause ");
    if (has_marks) {
        appendStr(buf, &n, "←→=1s SHIFT+←→=5s DEL=delete R=reset T=transcribe Q=stop");
    } else {
        appendStr(buf, &n, "←→=1s SHIFT+←→=5s I=in O=out DEL=delete T=transcribe Q=stop");
    }
    style.end(buf, &n, color);
    return buf[0..n];
}

/// "MM:SS", or "H:MM:SS" past an hour; negative values clamp to zero.
/// Returns the number of display columns written.
fn appendTime(buf: []u8, n: *usize, sec: f64) usize {
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
    return if (h > 0) 8 else 5;
}

/// Prints the sibling transcript (`<stem>.md`) in full — frontmatter off,
/// prose verbatim — above the player. No file or empty body: silent.
fn printTranscript(io: std.Io, gpa: std.mem.Allocator, recordings_path: []const u8, name: []const u8) void {
    var md_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const md_path = transcriptPath(recordings_path, name, &md_path_buf) orelse return;

    const doc = std.Io.Dir.cwd().readFileAlloc(io, md_path, gpa, .limited(16 * 1024 * 1024)) catch return;
    defer gpa.free(doc);

    const parts = prompts.splitFrontmatter(doc);
    if (parts.body.len == 0) return;
    printStderr(io, parts.body);
    if (parts.body[parts.body.len - 1] != '\n') printStderr(io, "\n");
    printStderr(io, "\n");
}

/// The sibling transcript path (`<stem>.md`), or null when the name does
/// not fit the buffers.
fn transcriptPath(recordings_path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var md_name_buf: [80]u8 = undefined;
    var md_len: usize = 0;
    record.appendStr(&md_name_buf, &md_len, library.stripExt(name));
    record.appendStr(&md_name_buf, &md_len, ".md");
    return library.recordingPath(recordings_path, md_name_buf[0..md_len], buf);
}

/// The `T` handler: a transcript on disk opens in $EDITOR (vi as the
/// fallback); none, and the recording is transcribed first — the same
/// `rec transcribe` the user would type. Returns the exit code.
fn openTranscript(io: std.Io, gpa: std.mem.Allocator, name: []const u8, recordings_path: []const u8) u8 {
    var md_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (transcriptPath(recordings_path, name, &md_path_buf)) |md_path| {
        if (std.Io.Dir.cwd().statFile(io, md_path, .{})) |_| {
            return openInEditor(io, md_path);
        } else |_| {}
    }
    return transcribeNow(io, gpa, name, recordings_path);
}

/// Opens `path` in the user's $EDITOR, handing the terminal over; returns
/// the editor's exit code.
fn openInEditor(io: std.Io, path: []const u8) u8 {
    const editor = llm.envValue("EDITOR") orelse "vi";
    var argv = [_][]const u8{ editor, path };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        printStderr(io, "play: cannot run the editor\n");
        return 1;
    };
    const term = child.wait(io) catch {
        printStderr(io, "play: editor failed\n");
        return 1;
    };
    return switch (term) {
        .exited => |code| @truncate(code),
        else => 1,
    };
}

/// Runs the transcribe command for this recording. The selection must be a
/// null-terminated token, so the name is copied into one.
fn transcribeNow(io: std.Io, gpa: std.mem.Allocator, name: []const u8, recordings_path: []const u8) u8 {
    var name_buf: [80]u8 = undefined;
    if (name.len >= name_buf.len) {
        printStderr(io, "play: recording name too long to transcribe\n");
        return 1;
    }
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const sel: [:0]const u8 = name_buf[0..name.len :0];
    return transcribecmd.run(
        io,
        gpa,
        &.{sel},
        llm.envValue("DEEPGRAM_API_KEY"),
        llm.envValue("HOME") orelse "",
        recordings_path,
    );
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

test "playedCols maps elapsed time onto the grid width" {
    try std.testing.expectEqual(@as(usize, 0), playedCols(80, 0, 100));
    try std.testing.expectEqual(@as(usize, 40), playedCols(80, 50, 100));
    try std.testing.expectEqual(@as(usize, 80), playedCols(80, 100, 100));
    // Past the end clamps to full; no duration is a flat dark grid.
    try std.testing.expectEqual(@as(usize, 80), playedCols(80, 300, 100));
    try std.testing.expectEqual(@as(usize, 0), playedCols(80, 50, 0));
}

test "statusLine shows state, times, and the marked span" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "▶ 00:12 / 01:30",
        statusLine(&buf, .playing, 12.3, 90, null, null, false),
    );
    try std.testing.expectEqualStrings(
        "⏸ 00:12 / 01:30",
        statusLine(&buf, .paused, 12.3, 90, null, null, false),
    );
    // With marks, the resolved span is shown; only one mark resolves
    // against the recording's edges.
    try std.testing.expectEqualStrings(
        "▶ 00:12 / 01:30  [00:05–00:12]",
        statusLine(&buf, .playing, 12.3, 90, 12.3, 5.1, false),
    );
    try std.testing.expectEqualStrings(
        "▶ 00:12 / 01:30  [00:05–01:30]",
        statusLine(&buf, .playing, 12.3, 90, 5.1, null, false),
    );
}

test "hintsLine lists the keys; R=reset only once marks exist" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "SPACE=pause ←→=1s SHIFT+←→=5s I=in O=out DEL=delete T=transcribe Q=stop",
        hintsLine(&buf, false, false, false),
    );
    try std.testing.expectEqualStrings(
        "SPACE=pause ←→=1s SHIFT+←→=5s DEL=delete R=reset T=transcribe Q=stop",
        hintsLine(&buf, true, false, false),
    );
    // While paused, SPACE names what it resumes.
    try std.testing.expectEqualStrings(
        "SPACE=play ←→=1s SHIFT+←→=5s DEL=delete R=reset T=transcribe Q=stop",
        hintsLine(&buf, true, true, false),
    );
    // Dimmed on a color terminal.
    try std.testing.expectEqualStrings(
        "\x1b[2mSPACE=pause ←→=1s SHIFT+←→=5s I=in O=out DEL=delete T=transcribe Q=stop\x1b[0m",
        hintsLine(&buf, false, false, true),
    );
}

test "confirmNote spells out the region and the keys" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "delete 00:05–00:12? ENTER deletes, anything else cancels",
        confirmNote(&buf, .{ 5.1, 12.3 }),
    );
}

test "statusLine colors state, times, and marks" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[32m▶\x1b[0m \x1b[1m00:12\x1b[0m\x1b[2m / 01:30\x1b[0m",
        statusLine(&buf, .playing, 12.3, 90, null, null, true),
    );

    // The marked span is cyan; the ⏸ paused state is yellow.
    try std.testing.expectEqualStrings(
        "\x1b[33m⏸\x1b[0m \x1b[1m00:12\x1b[0m\x1b[2m / 01:30\x1b[0m\x1b[36m  [00:05–00:12]\x1b[0m",
        statusLine(&buf, .paused, 12.3, 90, 12.3, 5.1, true),
    );
}

test "cutSpan normalizes the marks into the interval to cut" {
    // Inverted marks swap to a positive span.
    const s1 = cutSpan(12.3, 5.1, 90).?;
    try std.testing.expectEqual(@as(f64, 5.1), s1[0]);
    try std.testing.expectEqual(@as(f64, 12.3), s1[1]);
    // Only O cuts from the start; only I cuts to the end.
    const s2 = cutSpan(null, 3.0, 90).?;
    try std.testing.expectEqual(@as(f64, 0), s2[0]);
    try std.testing.expectEqual(@as(f64, 3.0), s2[1]);
    const s3 = cutSpan(4.0, null, 90).?;
    try std.testing.expectEqual(@as(f64, 4.0), s3[0]);
    try std.testing.expectEqual(@as(f64, 90), s3[1]);
    // No marks: no span.
    try std.testing.expect(cutSpan(null, null, 90) == null);
}

test "appendTime formats MM:SS and H:MM:SS" {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    try std.testing.expectEqual(@as(usize, 5), appendTime(&buf, &n, 12.3));
    try std.testing.expectEqualStrings("00:12", buf[0..n]);

    n = 0;
    try std.testing.expectEqual(@as(usize, 8), appendTime(&buf, &n, 3661.0));
    try std.testing.expectEqualStrings("1:01:01", buf[0..n]);

    n = 0;
    _ = appendTime(&buf, &n, -5);
    try std.testing.expectEqualStrings("00:00", buf[0..n]);
}
