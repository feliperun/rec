const std = @import("std");
const library = @import("library.zig");
const llm = @import("llm.zig");
const command_ui = @import("command_ui.zig");
const okf = @import("okf.zig");
const prompts = @import("prompts.zig");
const record = @import("record.zig");
const transcribe = @import("transcribe.zig");

const usage =
    \\Usage: rec transcribe [index|filename] [--language lg] [--out path]
    \\                       [--no-refine] [--context text]
    \\
    \\Transcribes a recording (the latest when none is named) via Deepgram and
    \\refines it with the configured LLM.
    \\
;

/// Deepgram language used unless --language says otherwise.
const default_language = "auto";

const no_speech_message =
    "transcribe: no speech was recognized in the recording\n" ++
    "Check that speech is clear during playback and that --language matches the spoken language.\n";

const TranscribeSelection = struct {
    selection: []const u8,
    language: []const u8,
    out: ?[]const u8 = null,
    /// Skip the built-in LLM refinement pass.
    no_refine: bool = false,
    /// Domain context forwarded to the refine prompt.
    context: ?[]const u8 = null,
};

const TranscribeArgs = union(enum) {
    invalid,
    ok: TranscribeSelection,
};

/// Pure argument parsing for `transcribe` (kept free of I/O so tests stay
/// offline): the first non-flag token is the selection (the latest
/// recording when there is none), flags consume the following token
/// (--no-refine takes none) and keep their last occurrence, and anything
/// else — unknown flags, missing values, extra positionals — is invalid.
fn parseTranscribeArgs(args: []const [:0]const u8) TranscribeArgs {
    var parsed = TranscribeSelection{ .selection = "", .language = default_language };
    var seen_selection = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--language")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.language = args[i];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.out = args[i];
        } else if (std.mem.eql(u8, args[i], "--context")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.context = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-refine")) {
            parsed.no_refine = true;
        } else if (!seen_selection and !std.mem.startsWith(u8, args[i], "-")) {
            parsed.selection = args[i];
            seen_selection = true;
        } else {
            return .invalid;
        }
    }
    if (!seen_selection) parsed.selection = library.latest_selection;
    return .{ .ok = parsed };
}

/// Builds the output path for the transcript: the explicit `--out` value as
/// given, or the recording's stem plus `.md` beside the recording. Returns
/// error.NoSpaceLeft when the result cannot fit `buf`, so the caller reports
/// the usage error instead of overrunning the stack buffer.
fn resolveOutPath(
    buf: []u8,
    out: ?[]const u8,
    recordings_path: []const u8,
    name: []const u8,
) error{NoSpaceLeft}![]const u8 {
    var n: usize = 0;
    if (out) |p| {
        try record.appendStr(buf, &n, p);
    } else {
        const base = library.recordingPath(recordings_path, library.stripExt(name), buf) orelse
            return error.NoSpaceLeft;
        n = base.len;
        try record.appendStr(buf, &n, ".md");
    }
    return buf[0..n];
}

/// Whether the `--out` candidate resolves to the recording being
/// transcribed. `resolved_out` is the candidate's `realPathFile` result; a
/// path that does not resolve does not exist yet, so it cannot be the
/// recording. Both inputs are absolute, already-resolved paths.
fn outIsRecording(resolved_out: ?[]const u8, recording_abs: []const u8) bool {
    const out = resolved_out orelse return false;
    return std.mem.eql(u8, out, recording_abs);
}

/// The transcribe command body, shaped like playSelection: resolve the
/// selection against the library, send the recording to Deepgram through
/// src/transcribe.zig, and write an OKF markdown transcript next to it.
/// Human messages go to stderr; stdout stays reserved for `list`. Returns
/// the exit code.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    args: []const [:0]const u8,
    api_key: ?[]const u8,
    home_dir: []const u8,
    recordings_path: []const u8,
    ui: command_ui.Mode,
) u8 {
    const ta = switch (parseTranscribeArgs(args)) {
        .invalid => {
            ui.print(io, usage);
            return 1;
        },
        .ok => |a| a,
    };

    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);

    library.scan(io, gpa, &entries, recordings_path) catch {
        ui.print(io, "transcribe: out of memory\n");
        return 1;
    };
    if (entries.items.len == 0) {
        ui.print(io, "No recordings yet.\n");
        return 1;
    }

    // Numeric selections index the newest-first order `list` shows; scan
    // returns directory order, so normalize before resolving.
    library.sortNewestFirst(entries.items);

    const name = library.resolveName(ta.selection, entries.items) orelse {
        ui.print(io, "transcribe: no recording matches '");
        ui.print(io, ta.selection);
        ui.print(io, "' (see `rec list`)\n");
        return 1;
    };

    // The environment wins; otherwise the key `rec setup` stored is what
    // makes transcription work with no shell exports at all.
    var key: []const u8 = "";
    var stored_key: ?[]u8 = null;
    defer if (stored_key) |sk| gpa.free(sk);
    if (api_key) |k| {
        if (k.len > 0) key = k;
    }
    if (key.len == 0) {
        var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (llm.configDirPath(home_dir, llm.envValue("XDG_CONFIG_HOME"), &cfg_buf)) |config_dir| {
            stored_key = transcribe.loadStoredKey(io, gpa, config_dir);
            if (stored_key) |sk| key = sk;
        }
    }
    if (key.len == 0) {
        ui.print(io, "transcribe: no Deepgram API key configured\n");
        ui.print(io, "export DEEPGRAM_API_KEY or run `rec setup`\n");
        return 1;
    }

    // curl gets an absolute path so it never depends on our cwd.
    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recording_path = library.recordingPath(recordings_path, name, &rel_buf) orelse {
        ui.print(io, "transcribe: cannot resolve recordings/");
        ui.print(io, name);
        ui.print(io, "\n");
        return 1;
    };

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, recording_path, &abs_buf) catch {
        ui.print(io, "transcribe: cannot resolve recordings/");
        ui.print(io, name);
        ui.print(io, "\n");
        return 1;
    };

    // Default artifact sits beside the recording in $HOME/recordings.
    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path = resolveOutPath(&out_path_buf, ta.out, recordings_path, name) catch {
        ui.print(io, "transcribe: caminho de saída longo demais\n");
        return 1;
    };

    // Creating the artifact would truncate the recording if --out names it,
    // so refuse before any network request or file creation. Both sides are
    // resolved; a candidate that does not resolve yet cannot be the source.
    var out_abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_abs: ?[]const u8 = if (std.Io.Dir.cwd().realPathFile(io, out_path, &out_abs_buf)) |n|
        out_abs_buf[0..n]
    else |_|
        null;
    if (outIsRecording(out_abs, abs_buf[0..abs_len])) {
        ui.print(io, "transcribe: --out não pode ser o próprio arquivo de entrada\n");
        return 1;
    }

    var result: transcribe.TranscribeOutput = .{ .json = .empty };
    defer result.json.deinit(gpa);
    transcribe.transcribe(io, gpa, abs_buf[0..abs_len], key, ta.language, &result) catch |err| {
        switch (err) {
            error.CurlSpawnFailed => ui.print(io, "transcribe: cannot run curl\n"),
            error.RequestFailed => {
                ui.print(io, "transcribe: deepgram request failed (");
                ui.print(io, flattenTail(&result.err_tail, result.err_tail_len));
                ui.print(io, ")\n");
            },
            error.BadResponse => ui.print(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => ui.print(io, no_speech_message),
            error.OutOfMemory => ui.print(io, "transcribe: out of memory\n"),
        }
        return 1;
    };

    const utterances = transcribe.parseResponse(gpa, result.json.items) catch |err| {
        switch (err) {
            error.BadResponse => ui.print(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => ui.print(io, no_speech_message),
            error.OutOfMemory => ui.print(io, "transcribe: out of memory\n"),
        }
        return 1;
    };
    defer transcribe.freeUtterances(gpa, utterances);

    const language = transcribe.responseLanguage(gpa, result.json.items, ta.language) catch {
        ui.print(io, "transcribe: cannot read the transcript language\n");
        return 1;
    };
    defer gpa.free(language);

    // The duration shown by `list` is already parsed from the header; reuse
    // it for the transcript's duration_sec frontmatter field.
    var duration_sec: ?f64 = null;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.name, name)) duration_sec = e.duration_sec;
    }

    var ts_buf: [20]u8 = undefined;
    okf.utcTimestamp(&ts_buf);

    const doc = okf.render(gpa, .{
        .title = library.stripExt(name),
        // The markdown is a sibling of the recording, so this remains a
        // valid relative link regardless of the caller's current directory.
        .resource = name,
        .timestamp = ts_buf[0..],
        .model = "nova-3",
        .language = language,
        .duration_sec = duration_sec,
    }, utterances) catch {
        ui.print(io, "transcribe: out of memory\n");
        return 1;
    };
    defer gpa.free(doc);

    // Once truncation starts, cancellation must not leave a partial document.
    io.checkCancel() catch return 1;
    {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch {
            ui.print(io, "transcribe: cannot write ");
            ui.print(io, out_path);
            ui.print(io, "\n");
            return 1;
        };
        defer file.close(io);
        file.writeStreamingAll(io, doc) catch {
            ui.print(io, "transcribe: cannot write ");
            ui.print(io, out_path);
            ui.print(io, "\n");
            return 1;
        };
    }

    ui.print(io, "Transcript saved to ");
    ui.print(io, out_path);
    ui.print(io, "\n");

    // Refinement never trades away the artifact: on any failure the raw
    // transcript stays exactly as saved and the command still exits 0.
    if (!ta.no_refine) refineTranscript(io, gpa, home_dir, doc, ta.context, out_path, ui);
    // The saved artifact is immediately opened in the same Markdown viewer
    // used by playback and `format`; pipes receive a non-interactive render.
    ui.open(io, gpa, out_path);
    return 0;
}

/// The built-in second pass over a fresh transcript: the bundled `refine`
/// prompt (user-customizable in ~/.config/rec/templates/) runs through the
/// harness chosen by `rec setup`, and the file is rewritten with its
/// frontmatter kept and the prose replaced by the model's corrected version.
/// Every failure path prints a warning and leaves the original untouched.
fn refineTranscript(
    io: std.Io,
    gpa: std.mem.Allocator,
    home_dir: []const u8,
    doc: []const u8,
    context: ?[]const u8,
    out_path: []const u8,
    ui: command_ui.Mode,
) void {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_dir = llm.configDirPath(home_dir, llm.envValue("XDG_CONFIG_HOME"), &cfg_buf) orelse {
        ui.print(io, "refine: ignorado (sem diretório de configuração)\n");
        return;
    };

    const runner = switch (llm.resolveRunner(io, gpa, config_dir)) {
        .ok => |r| r,
        .none => |reason| {
            ui.print(io, "refine: ignorado (");
            ui.print(io, reason);
            ui.print(io, ")\n");
            return;
        },
    };
    defer gpa.free(runner.bin_path);

    var tpl_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const templates_dir = llm.templatesDirPath(config_dir, &tpl_buf).?;
    llm.materializeTemplates(io, templates_dir);

    // Customized template wins; the embedded copy covers missing/read-only.
    const template: []u8 = tpl: {
        if (llm.loadTemplate(io, gpa, templates_dir, "refine")) |t| break :tpl t else |_| {}
        break :tpl gpa.dupe(u8, prompts.refine_md) catch {
            ui.print(io, "refine: ignorado (sem memória)\n");
            return;
        };
    };
    defer gpa.free(template);

    const split = prompts.splitFrontmatter(doc);
    const prompt_doc = prompts.compose(gpa, template, context, split.body) catch {
        ui.print(io, "refine: ignorado (sem memória)\n");
        return;
    };
    defer gpa.free(prompt_doc);

    var describe_buf: [128]u8 = undefined;
    ui.print(io, "Refinando com ");
    ui.print(io, runner.describe(&describe_buf));
    ui.print(io, "...\n");

    var note: [llm.max_note_bytes]u8 = undefined;
    var note_len: usize = 0;
    var invocation = llm.run(
        io,
        gpa,
        runner.kind,
        runner.bin_path,
        runner.model,
        runner.provider,
        prompt_doc,
        llm.job_timeout_ns,
        &note,
        &note_len,
    ) catch |err| {
        ui.print(io, "refine: falhou (");
        ui.print(io, llm.failurePhrase(err));
        if (note_len > 0) {
            ui.print(io, ": ");
            ui.print(io, note[0..note_len]);
        }
        ui.print(io, "); transcrição original mantida\n");
        return;
    };
    defer invocation.deinit();

    var refined: std.ArrayList(u8) = .empty;
    defer refined.deinit(gpa);
    refined.appendSlice(gpa, split.head) catch return;
    refined.appendSlice(gpa, invocation.text()) catch return;
    refined.append(gpa, '\n') catch return;

    io.checkCancel() catch return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch {
        ui.print(io, "refine: não consegui regravar ");
        ui.print(io, out_path);
        ui.print(io, "\n");
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, refined.items) catch {
        ui.print(io, "refine: não consegui regravar ");
        ui.print(io, out_path);
        ui.print(io, "\n");
        return;
    };

    ui.print(io, "Transcrição refinada: ");
    ui.print(io, out_path);
    ui.print(io, "\n");
}

/// curl's stderr tail flattened to a single line — newlines become one
/// space, edges trimmed — so every `transcribe:` message stays one line.
fn flattenTail(tail: []u8, len: usize) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (tail[0..@min(len, tail.len)]) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            pending_space = n != 0;
            continue;
        }
        if (pending_space) {
            tail[n] = ' ';
            n += 1;
            pending_space = false;
        }
        tail[n] = ch;
        n += 1;
    }
    return tail[0..n];
}

// --- tests -------------------------------------------------------------------

test "stripExt removes recording extensions only" {
    try std.testing.expectEqualStrings("20260826-143000", library.stripExt("20260826-143000.m4a"));
    try std.testing.expectEqualStrings("20260826-143000", library.stripExt("20260826-143000.wav"));
    try std.testing.expectEqualStrings("notes", library.stripExt("notes"));
}

// Pure checks of the transcribe argument parser: no I/O, so they stay
// offline and deterministic.

fn transcribeArgsOk(args: []const [:0]const u8) !TranscribeSelection {
    return switch (parseTranscribeArgs(args)) {
        .ok => |a| a,
        .invalid => error.TestUnexpectedResult,
    };
}

fn transcribeArgsInvalid(args: []const [:0]const u8) !void {
    try std.testing.expect(switch (parseTranscribeArgs(args)) {
        .invalid => true,
        .ok => false,
    });
}

test "transcribe args: bare selection gets the default language and output" {
    const a = try transcribeArgsOk(&.{"3"});
    try std.testing.expectEqualStrings("3", a.selection);
    try std.testing.expectEqualStrings("auto", a.language);
    try std.testing.expect(a.out == null);
}

test "transcribe args: custom language" {
    const a = try transcribeArgsOk(&.{ "1", "--language", "en-US" });
    try std.testing.expectEqualStrings("1", a.selection);
    try std.testing.expectEqualStrings("en-US", a.language);
    try std.testing.expect(a.out == null);
}

test "transcribe args: custom output path" {
    const a = try transcribeArgsOk(&.{ "1", "--out", "/tmp/notes.md" });
    try std.testing.expectEqualStrings("/tmp/notes.md", a.out.?);
}

test "transcribe args: both flags together, in any order" {
    const a = try transcribeArgsOk(&.{ "--language", "en-US", "2", "--out", "/tmp/x.md" });
    try std.testing.expectEqualStrings("2", a.selection);
    try std.testing.expectEqualStrings("en-US", a.language);
    try std.testing.expectEqualStrings("/tmp/x.md", a.out.?);
}

test "transcribe args: repeated flags keep the last occurrence" {
    const a = try transcribeArgsOk(&.{ "1", "--language", "en", "--language", "fr", "--out", "a.md", "--out", "b.md" });
    try std.testing.expectEqualStrings("fr", a.language);
    try std.testing.expectEqualStrings("b.md", a.out.?);
}

test "transcribe args: rejects unknown flags, missing values, and extra tokens" {
    try transcribeArgsInvalid(&.{"--bogus"}); // unknown flag, no selection
    try transcribeArgsInvalid(&.{ "1", "--bogus" });
    try transcribeArgsInvalid(&.{ "1", "-x" });
    try transcribeArgsInvalid(&.{ "1", "--language" }); // missing flag value
    try transcribeArgsInvalid(&.{ "1", "--out" }); // missing flag value
    try transcribeArgsInvalid(&.{ "1", "--context" }); // missing flag value
    try transcribeArgsInvalid(&.{ "1", "2" }); // extra positional
}

test "transcribe args: refinement defaults off and flags parse together" {
    const plain = try transcribeArgsOk(&.{"2"});
    try std.testing.expect(!plain.no_refine);
    try std.testing.expect(plain.context == null);

    const refined = try transcribeArgsOk(&.{ "1", "--no-refine", "--context", "consulta cardiológica" });
    try std.testing.expect(refined.no_refine);
    try std.testing.expectEqualStrings("consulta cardiológica", refined.context.?);

    // Repeated --context keeps the last occurrence, like every other flag.
    const repeated = try transcribeArgsOk(&.{ "1", "--context", "a", "--context", "b" });
    try std.testing.expectEqualStrings("b", repeated.context.?);
}

test "transcribe args: a missing selection means the latest recording" {
    const bare = try transcribeArgsOk(&.{});
    try std.testing.expectEqualStrings(library.latest_selection, bare.selection);
    const flags_only = try transcribeArgsOk(&.{ "--language", "en" });
    try std.testing.expectEqualStrings(library.latest_selection, flags_only.selection);
    try std.testing.expectEqualStrings("en", flags_only.language);
}

test "flattenTail collapses curl's multiline stderr into one line" {
    const sample = "curl: (22) The requested URL returned error: 401\n\ncheck headers\n";
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..sample.len], sample);
    try std.testing.expectEqualStrings(
        "curl: (22) The requested URL returned error: 401 check headers",
        flattenTail(&buf, sample.len),
    );
    // An empty tail stays empty, not a stray space.
    var empty: [512]u8 = undefined;
    try std.testing.expectEqualStrings("", flattenTail(&empty, 0));
}

test "transcribe out path must fit the buffer" {
    var small: [8]u8 = undefined;
    // The explicit --out must fit whole; one byte too many is refused.
    try std.testing.expectError(
        error.NoSpaceLeft,
        resolveOutPath(&small, "123456789", "recs", "a"),
    );
    try std.testing.expectEqualStrings(
        "12345678",
        try resolveOutPath(&small, "12345678", "recs", "a"),
    );

    // The default sibling path appends ".md" through the same checked copy.
    var tight: [8]u8 = undefined; // "recs/a" + ".md" does not fit
    try std.testing.expectError(
        error.NoSpaceLeft,
        resolveOutPath(&tight, null, "recs", "a"),
    );
    var roomy: [9]u8 = undefined;
    try std.testing.expectEqualStrings(
        "recs/a.md",
        try resolveOutPath(&roomy, null, "recs", "a"),
    );
}

test "transcribe out must not be the source recording" {
    const recording: []const u8 = "/home/u/recordings/20260826-143000.m4a";
    // The same resolved path is refused; a different one is not.
    try std.testing.expect(outIsRecording(recording, recording));
    try std.testing.expect(!outIsRecording("/home/u/recordings/20260826-143000.md", recording));
    // A candidate that does not exist yet cannot be the recording.
    try std.testing.expect(!outIsRecording(null, recording));
}
