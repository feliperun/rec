const std = @import("std");
const cut = @import("cut.zig");
const keys = @import("keys.zig");
const library = @import("library.zig");
const audio_notes = @import("audio_notes.zig");
const live = @import("live.zig");
const markdown = @import("markdown.zig");
const player_mod = @import("player.zig");
const deck = @import("deck.zig");
const spectrum = @import("spectrum.zig");
const style = @import("style.zig");
const viewport = @import("viewport.zig");
const waveform = @import("waveform.zig");

/// Set by the SIGINT handler while the interactive loop owns the terminal.
var g_interrupted = std.atomic.Value(bool).init(false);

fn onSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_interrupted.store(true, .release);
}

fn installSigint() void {
    // Windows has no SIGINT for console apps; Ctrl-C arrives as the 0x03
    // key byte (VT input), which the loop breaks on.
    if (@import("builtin").os.tag == .windows) return;
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
/// the alternate screen — the layered waveform over a time ruler, the
/// playhead line over it — driven by keys: SPACE pauses/resumes, ←/→ seek
/// one second (SHIFT for five), I and O anchor the two cursors of the
/// region to cut (drawn as full-height lines with the wave between them
/// recolored), DELETE asks and ENTER confirms the cut, T/F select or generate the
/// transcript/formatted notes without leaving playback, Y copies the active
/// document, S shares it, R clears the marks, Q or Ctrl-C
/// stops. Without a terminal it plays to completion under Ctrl-C.
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

    // One decode serves both the waveform and the audio: without it there
    // is nothing to draw and nothing to play. The interactive view owns the
    // load from here on — a confirmed cut rewrites the file and reloads it.
    var audio = cut.loadPcm(gpa, abs_buf[0..abs_len]) catch {
        printStderr(io, "play: cannot decode ");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };
    defer audio.deinit(gpa);

    const duration_sec = @as(f64, @floatFromInt(audio.pcm.len)) / @as(f64, @floatFromInt(audio.byteRate()));

    const is_tty = blk: {
        const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
        const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
        break :blk stdin_tty and stderr_tty;
    };

    if (is_tty) {
        return playInteractive(io, gpa, abs_buf[0..abs_len], &audio, name, duration_sec, recordings_path);
    }

    // Non-interactive playback prints the sibling document before playing.
    const transcript_raw: ?[]u8 = loadTranscript(io, gpa, recordings_path, name);
    defer if (transcript_raw) |doc| gpa.free(doc);
    var transcript_view: ?[]u8 = null;
    defer if (transcript_view) |view| gpa.free(view);
    if (transcript_raw) |doc| transcript_view = markdown.render(gpa, doc, style.detect(io, .stderr())) catch null;

    if (transcript_view) |view| {
        printStderr(io, view);
        if (view.len == 0 or view[view.len - 1] != '\n') printStderr(io, "\n");
        printStderr(io, "\n");
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
const tick_ms = 33;

/// Seek steps: the arrows move the playhead by one second, SHIFT+arrows by
/// five.
const seek_step_sec: f64 = 1.0;
const seek_step_shift_sec: f64 = 5.0;

const PlayState = enum { playing, paused };

/// Runs the live view while the player plays: the status line, the
/// rendered Markdown transcript panel, and the layered waveform (fully colored, the marked region
/// recolored between its two anchor lines, the playhead line over
/// everything), its time ruler, a notes row, and the key hints — one
/// composed frame per tick. Owns
/// `audio`: a confirmed cut rewrites the file, reloads it, and playback
/// continues on the new PCM with the view still up. Restores the terminal
/// on every exit path.
fn playInteractive(
    io: std.Io,
    gpa: std.mem.Allocator,
    abs_path: []const u8,
    audio: *cut.Loaded,
    name: []const u8,
    duration_sec_in: f64,
    recordings_path: []const u8,
) u8 {
    var duration_sec = duration_sec_in;
    const cooked = keys.enableRaw() orelse {
        // Raw mode is unavailable (odd terminal); degrade to plain playback.
        printStderr(io, "Playing ");
        printStderr(io, name);
        printStderr(io, " (Ctrl-C to stop)\n");
        return playBlocking(io, audio.pcm, audio.sample_rate, audio.channels);
    };
    defer keys.restoreRaw(cooked);

    installSigint();

    const color = style.detect(io, .stderr());
    var notes = audio_notes.Session.init(io, gpa, recordings_path, name, color) catch return 1;
    defer notes.deinit(io, gpa);

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
    defer leaveAlt(io, &alt_on, &esc_buf);

    var p = player_mod.Player{};
    defer p.deinit();
    p.start(audio.pcm, audio.sample_rate, @intCast(audio.channels)) catch {
        leaveAlt(io, &alt_on, &esc_buf);
        printStderr(io, "play: cannot open the audio output device\n");
        return 1;
    };

    // Blocks come from the same PCM the speaker plays, so a reload after a
    // cut redraws the view from the new body.
    var tracker = waveform.Tracker.init(gpa, waveform.peakBlockBytes(audio.byteRate()));
    defer tracker.deinit();
    tracker.feed(audio.pcm);
    var block_view: std.ArrayList(waveform.Block) = .empty;
    defer block_view.deinit(gpa);
    _ = tracker.view(&block_view) catch {};

    // The whole view is composed here and written in one shot per tick —
    // many small writes are what made the cursor's movement flicker.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    var document = viewport.Document{};
    defer document.deinit(gpa);
    var header = viewport.Document{};
    defer header.deinit(gpa);
    var screen = viewport.Screen{};
    defer screen.deinit(gpa);
    var scroll: usize = 0;
    var settings = deck.Settings{};
    var analysis = spectrum.Analysis{};
    var redraw = true;
    var last_size = waveform.TermSize{ .rows = 0, .cols = 0 };
    printStderr(io, viewport.mouse_on);
    defer printStderr(io, viewport.mouse_off);

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
        const tick_started = std.Io.Timestamp.now(io, .awake);
        if (p.isDone()) {
            redraw = redraw or state != .paused;
            state = .paused;
            p.setPaused(true);
        }
        if (g_interrupted.load(.acquire)) {
            exit_code = 130;
            break :keys;
        }

        if (notes.poll(io, gpa)) {
            document.width = 0;
            redraw = true;
        }
        const size = waveform.termSize();
        const resized = size.cols != last_size.cols or size.rows != last_size.rows;
        const visible_audio = scroll < @max(header.starts.items.len, 1);
        if (redraw or resized or (state == .playing and visible_audio)) {
            redraw = false;
            last_size = size;
            if (document.width != size.cols) document.set(gpa, notes.text(), size.cols) catch return 1;
            const position = p.pos.load(.acquire);
            const elapsed = @as(f64, @floatFromInt(position)) / @as(f64, @floatFromInt(audio.sample_rate));
            if (scroll < @max(header.starts.items.len, 1) and !settings.help) analysis.update(audio.pcm, audio.sample_rate, audio.channels, @intCast(position));
            var status_buf: [512]u8 = undefined;
            deck.draw(gpa, &frame, .{
                .name = name,
                .status = statusLine(&status_buf, state, elapsed, duration_sec, mark_in, mark_out, color),
                .paused = state == .paused,
                .elapsed = elapsed,
                .duration = duration_sec,
                .sample_rate = audio.sample_rate,
                .channels = audio.channels,
                .blocks = block_view.items,
                .selection = cutSpan(mark_in, mark_out, duration_sec),
                .note = note orelse notes.status(),
                .color = color,
                .tabs = notes.tabs(),
                .analysis = &analysis,
                .settings = settings,
            }, size.cols, size.rows) catch return 1;
            header.set(gpa, frame.items, size.cols) catch return 1;
            screen.paint(io, gpa, &header, &document, &scroll, size.rows, size.cols, deck.footer(size.cols, color)) catch return 1;
        }

        const spent_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - tick_started.nanoseconds, std.time.ns_per_ms);
        const key = keys.readKey(io, @intCast(@max(tick_ms - spent_ms, 1)));
        if (key == .none) continue :keys; // no key: the notice stays up
        note = null;
        redraw = true;

        // A pending delete resolves on the very next key: ENTER cuts,
        // anything else — a second DELETE, the arrows, SPACE — cancels.
        // Ctrl-C still quits outright.
        if (confirming) |span| {
            confirming = null;
            const pressed: ?u8 = if (key == .byte) key.byte else null;
            if (pressed == '\r' or pressed == '\n') {
                // Cut in place and keep playing: the playhead maps through
                // the cut, the new file replaces the old, and the view
                // stays up — the note plus the shrunken waveform report it.
                const pos = p.positionSec();
                cut.cutIntervalFile(io, gpa, abs_path, span[0], span[1]) catch {
                    note = "Could not cut this recording; still playing";
                    continue :keys; // the recording is untouched
                };
                p.stop();
                p.deinit();
                audio.deinit(gpa);
                audio.* = cut.loadPcm(gpa, abs_path) catch {
                    leaveAlt(io, &alt_on, &esc_buf);
                    printStderr(io, "play: cannot reload after the cut\n");
                    exit_code = 1;
                    break :keys;
                };
                analysis = .{};
                tracker.deinit();
                tracker = waveform.Tracker.init(gpa, waveform.peakBlockBytes(audio.byteRate()));
                tracker.feed(audio.pcm);
                _ = tracker.view(&block_view) catch {};
                duration_sec = @as(f64, @floatFromInt(audio.pcm.len)) / @as(f64, @floatFromInt(audio.byteRate()));
                p.start(audio.pcm, audio.sample_rate, @intCast(audio.channels)) catch {
                    leaveAlt(io, &alt_on, &esc_buf);
                    printStderr(io, "play: cannot open the audio output device\n");
                    exit_code = 1;
                    break :keys;
                };
                _ = player_mod.ma.ma_device_set_master_volume(&p.device, settings.gain());
                const replay = replayAfterCut(pos, span, duration_sec, audio.sample_rate);
                p.seekSec(replay.sec);
                if (replay.pause or state == .paused) {
                    state = .paused;
                    p.setPaused(true);
                }
                mark_in = null;
                mark_out = null;
                note = cutNote(&note_buf, span);
                continue :keys;
            }
            if (pressed == 0x03) {
                exit_code = 130;
                break :keys;
            }
            continue :keys;
        }

        if (key == .byte and settings.key(key.byte)) {
            scroll = 0;
            _ = player_mod.ma.ma_device_set_master_volume(&p.device, settings.gain());
            continue;
        }
        if (key == .byte and key.byte >= '0' and key.byte <= '9') {
            p.seekSec(duration_sec * @as(f64, @floatFromInt(key.byte - '0')) / 10);
            continue;
        }
        if (viewport.navigate(&scroll, key, header.starts.items.len + document.starts.items.len, size.rows -| 1)) continue;
        switch (key) {
            .eof => break :keys,
            .byte => |c| switch (c) {
                ' ' => {
                    if (p.isDone()) p.seekSec(0);
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
                't', 'T', 'f', 'F', '\t' => {
                    const tab: audio_notes.Tab = switch (c) {
                        't', 'T' => .transcript,
                        'f', 'F' => .formatted,
                        else => if (notes.active == .transcript) .formatted else .transcript,
                    };
                    if (c == '\t') notes.active = tab else notes.select(io, tab);
                    document.width = 0;
                    settings.focus = false;
                    settings.help = false;
                    scroll = 0;
                },
                'j' => {
                    _ = viewport.navigate(&scroll, .down, header.starts.items.len + document.starts.items.len, size.rows -| 1);
                },
                'k' => {
                    _ = viewport.navigate(&scroll, .up, header.starts.items.len + document.starts.items.len, size.rows -| 1);
                },
                'q' => break :keys,
                0x03 => { // Ctrl-C byte: ISIG is off in raw mode
                    exit_code = 130;
                    break :keys;
                },
                else => {
                    note = markdown.shareKey(io, notes.raw(), c);
                },
            },
            .delete => {
                if (notes.job != null) {
                    note = "Wait for text generation before cutting the audio";
                    continue :keys;
                }
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
            else => {},
        }
    }

    p.stop();
    leaveAlt(io, &alt_on, &esc_buf);
    printStderr(io, "\n");
    return exit_code;
}

// --- the live view -----------------------------------------------------------

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

/// "cut 00:05–00:12" — the success note shown on the notes row after the
/// file is rewritten; the waveform shrinking beside it is the visual proof.
fn cutNote(buf: []u8, span: [2]f64) []const u8 {
    var n: usize = 0;
    appendStr(buf, &n, "cut ");
    _ = appendTime(buf, &n, span[0]);
    appendStr(buf, &n, "–");
    _ = appendTime(buf, &n, span[1]);
    return buf[0..n];
}

/// Where the playhead lands once the span is removed: before the span it
/// stays put, inside it jumps to the span's start, past it shifts back by
/// the removed length.
fn mapPosition(pos: f64, span: [2]f64) f64 {
    if (pos < span[0]) return pos;
    if (pos < span[1]) return span[0];
    return pos - (span[1] - span[0]);
}

const ReplayAfterCut = struct {
    sec: f64,
    pause: bool,
};

/// A tail cut can place the old playhead exactly at the new EOF. Park one
/// frame before that edge and pause so the shortened player remains visible.
fn replayAfterCut(pos: f64, span: [2]f64, duration_sec: f64, sample_rate: u32) ReplayAfterCut {
    const mapped = mapPosition(pos, span);
    if (mapped < duration_sec) return .{ .sec = mapped, .pause = false };
    const frame_sec = 1.0 / @as(f64, @floatFromInt(@max(sample_rate, 1)));
    return .{ .sec = @max(duration_sec - frame_sec, 0), .pause = true };
}

/// How many columns of the grid the playback has covered.
const playedCols = deck.playedCols;

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

/// Loads the sibling transcript (`<stem>.md`) when present. The caller owns
/// the returned bytes and keeps them alive for the whole player session.
fn loadTranscript(io: std.Io, gpa: std.mem.Allocator, recordings_path: []const u8, name: []const u8) ?[]u8 {
    var md_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const md_path = transcriptPath(recordings_path, name, &md_path_buf) orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, md_path, gpa, .limited(markdown.max_document_bytes)) catch null;
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

test "confirmNote spells out the region and the keys" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "delete 00:05–00:12? ENTER deletes, anything else cancels",
        confirmNote(&buf, .{ 5.1, 12.3 }),
    );
}

test "cutNote names the removed span" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("cut 00:05–00:12", cutNote(&buf, .{ 5.1, 12.3 }));
}

test "mapPosition carries the playhead through the cut" {
    const span = [2]f64{ 5, 10 };
    // Before the span: stays put.
    try std.testing.expectApproxEqAbs(@as(f64, 2), mapPosition(2, span), 1e-9);
    // Inside it: to the span's start.
    try std.testing.expectApproxEqAbs(@as(f64, 5), mapPosition(7, span), 1e-9);
    // Past it: shifts back by the removed length.
    try std.testing.expectApproxEqAbs(@as(f64, 15), mapPosition(20, span), 1e-9);
}

test "tail cuts keep the player visible at the shortened end" {
    const replay = replayAfterCut(1, .{ 1, 3 }, 1, 48000);
    try std.testing.expect(replay.pause);
    try std.testing.expectApproxEqAbs(@as(f64, 1) - 1.0 / 48000.0, replay.sec, 1e-9);
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
