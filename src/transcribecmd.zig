const std = @import("std");
const library = @import("library.zig");
const llm = @import("llm.zig");
const okf = @import("okf.zig");
const prompts = @import("prompts.zig");
const record = @import("record.zig");
const transcribe = @import("transcribe.zig");

const usage =
    \\Usage: rec transcribe <index|filename> [--language lg] [--out path]
    \\                       [--no-refine] [--context text]
    \\
    \\Transcribes a recording via Deepgram and refines it with the configured LLM.
    \\
;

/// Deepgram language used unless --language says otherwise.
const default_language = "pt-BR";

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
/// offline): the first non-flag token is the selection, flags consume the
/// following token (--no-refine takes none) and keep their last occurrence,
/// and anything else — unknown flags, missing values, extra positionals — is
/// invalid.
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
    if (!seen_selection) return .invalid;
    return .{ .ok = parsed };
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
) u8 {
    const ta = switch (parseTranscribeArgs(args)) {
        .invalid => {
            printStderr(io, usage);
            return 1;
        },
        .ok => |a| a,
    };

    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);

    library.scan(io, gpa, &entries, recordings_path) catch {
        printStderr(io, "transcribe: out of memory\n");
        return 1;
    };
    if (entries.items.len == 0) {
        printStderr(io, "No recordings yet.\n");
        return 1;
    }

    // Numeric selections index the newest-first order `list` shows; scan
    // returns directory order, so normalize before resolving.
    library.sortNewestFirst(entries.items);

    const name = library.resolveName(ta.selection, entries.items) orelse {
        printStderr(io, "transcribe: no recording matches '");
        printStderr(io, ta.selection);
        printStderr(io, "' (see `rec list`)\n");
        return 1;
    };

    const key = api_key orelse {
        printStderr(io, "transcribe: DEEPGRAM_API_KEY is not set\n");
        return 1;
    };
    if (key.len == 0) {
        printStderr(io, "transcribe: DEEPGRAM_API_KEY is not set\n");
        return 1;
    }

    // curl gets an absolute path so it never depends on our cwd.
    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const recording_path = library.recordingPath(recordings_path, name, &rel_buf) orelse {
        printStderr(io, "transcribe: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = std.Io.Dir.cwd().realPathFile(io, recording_path, &abs_buf) catch {
        printStderr(io, "transcribe: cannot resolve recordings/");
        printStderr(io, name);
        printStderr(io, "\n");
        return 1;
    };

    // Default artifact sits beside the recording in $HOME/recordings.
    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_len: usize = 0;
    if (ta.out) |p| {
        record.appendStr(&out_path_buf, &out_len, p);
    } else {
        const base = library.recordingPath(recordings_path, library.stripExt(name), &out_path_buf) orelse {
            printStderr(io, "transcribe: cannot write output path\n");
            return 1;
        };
        out_len = base.len;
        record.appendStr(&out_path_buf, &out_len, ".md");
    }
    const out_path: []const u8 = out_path_buf[0..out_len];

    var result: transcribe.TranscribeOutput = .{ .json = .empty };
    defer result.json.deinit(gpa);
    transcribe.transcribe(io, gpa, abs_buf[0..abs_len], key, ta.language, &result) catch |err| {
        switch (err) {
            error.CurlSpawnFailed => printStderr(io, "transcribe: cannot run curl\n"),
            error.RequestFailed => {
                printStderr(io, "transcribe: deepgram request failed (");
                printStderr(io, flattenTail(&result.err_tail, result.err_tail_len));
                printStderr(io, ")\n");
            },
            error.BadResponse => printStderr(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => printStderr(io, "transcribe: no speech found in recording\n"),
            error.OutOfMemory => printStderr(io, "transcribe: out of memory\n"),
        }
        return 1;
    };

    const utterances = transcribe.parseResponse(gpa, result.json.items) catch |err| {
        switch (err) {
            error.BadResponse => printStderr(io, "transcribe: unexpected response from deepgram\n"),
            error.NoSpeech => printStderr(io, "transcribe: no speech found in recording\n"),
            error.OutOfMemory => printStderr(io, "transcribe: out of memory\n"),
        }
        return 1;
    };
    defer transcribe.freeUtterances(gpa, utterances);

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
        .language = ta.language,
        .duration_sec = duration_sec,
    }, utterances) catch {
        printStderr(io, "transcribe: out of memory\n");
        return 1;
    };
    defer gpa.free(doc);

    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch {
        printStderr(io, "transcribe: cannot write ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return 1;
    };
    defer file.close(io);
    file.writeStreamingAll(io, doc) catch {
        printStderr(io, "transcribe: cannot write ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return 1;
    };

    printStderr(io, "Transcript saved to ");
    printStderr(io, out_path);
    printStderr(io, "\n");

    // Refinement never trades away the artifact: on any failure the raw
    // transcript stays exactly as saved and the command still exits 0.
    if (ta.no_refine) return 0;
    refineTranscript(io, gpa, home_dir, doc, ta.context, out_path);
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
) void {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_dir = llm.configDirPath(home_dir, llm.envValue("XDG_CONFIG_HOME"), &cfg_buf) orelse {
        printStderr(io, "refine: ignorado (sem diretório de configuração)\n");
        return;
    };

    const runner = switch (llm.resolveRunner(io, gpa, config_dir)) {
        .ok => |r| r,
        .none => |reason| {
            printStderr(io, "refine: ignorado (");
            printStderr(io, reason);
            printStderr(io, ")\n");
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
            printStderr(io, "refine: ignorado (sem memória)\n");
            return;
        };
    };
    defer gpa.free(template);

    const split = prompts.splitFrontmatter(doc);
    const prompt_doc = prompts.compose(gpa, template, context, split.body) catch {
        printStderr(io, "refine: ignorado (sem memória)\n");
        return;
    };
    defer gpa.free(prompt_doc);

    var describe_buf: [128]u8 = undefined;
    printStderr(io, "Refinando com ");
    printStderr(io, runner.describe(&describe_buf));
    printStderr(io, "...\n");

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
        printStderr(io, "refine: falhou (");
        printStderr(io, llm.failurePhrase(err));
        if (note_len > 0) {
            printStderr(io, ": ");
            printStderr(io, note[0..note_len]);
        }
        printStderr(io, "); transcrição original mantida\n");
        return;
    };
    defer invocation.deinit();

    var refined: std.ArrayList(u8) = .empty;
    defer refined.deinit(gpa);
    refined.appendSlice(gpa, split.head) catch return;
    refined.appendSlice(gpa, invocation.text()) catch return;
    refined.append(gpa, '\n') catch return;

    const file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch {
        printStderr(io, "refine: não consegui regravar ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, refined.items) catch {
        printStderr(io, "refine: não consegui regravar ");
        printStderr(io, out_path);
        printStderr(io, "\n");
        return;
    };

    printStderr(io, "Transcrição refinada: ");
    printStderr(io, out_path);
    printStderr(io, "\n");
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

fn printStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
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
    try std.testing.expectEqualStrings(default_language, a.language);
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

test "transcribe args: rejects a missing selection" {
    try transcribeArgsInvalid(&.{});
    try transcribeArgsInvalid(&.{ "--language", "en" });
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
