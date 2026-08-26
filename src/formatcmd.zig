const std = @import("std");
const library = @import("library.zig");
const llm = @import("llm.zig");
const prompts = @import("prompts.zig");

/// Name picked when the user passes no --template: the bundled meeting
/// structuring prompt, materialized into the user's templates directory.
pub const default_template = "meeting";

const max_transcript_bytes = 16 * 1024 * 1024;

// --- argument parsing (pure, unit-tested below) -----------------------------

pub const FormatArgs = struct {
    selection: []const u8,
    template: []const u8 = default_template,
    out: ?[]const u8 = null,
    context: ?[]const u8 = null,
};

pub const ParsedFormatArgs = union(enum) {
    ok: FormatArgs,
    invalid,
};

/// Same discipline as the transcribe parser in main.zig: one positional, flags
/// consume a following token, last occurrence wins, everything else invalid.
pub fn parseArgs(args: []const [:0]const u8) ParsedFormatArgs {
    var parsed = FormatArgs{ .selection = "" };
    var seen_selection = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--template")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.template = args[i];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.out = args[i];
        } else if (std.mem.eql(u8, args[i], "--context")) {
            i += 1;
            if (i >= args.len) return .invalid;
            parsed.context = args[i];
        } else if (!seen_selection and !std.mem.startsWith(u8, args[i], "-")) {
            parsed.selection = args[i];
            seen_selection = true;
        } else {
            return .invalid;
        }
    }
    if (!seen_selection or !llm.validTemplateName(parsed.template)) return .invalid;
    return .{ .ok = parsed };
}

// --- command body ------------------------------------------------------------

pub const usage =
    \\rec format <index|filename|path> [--template meeting] [--out path] [--context text]
;

/// `rec format` body. The selection resolves either as an explicit markdown
/// path (anything containing '/') or against the recordings library exactly
/// like `play`/`transcribe`, landing on the transcript beside the WAV. The
/// named template comes from ~/.config/rec/templates/ with the bundled
/// meeting/refine defaults materialized on first use, and the transformation
/// runs through the harness chosen by `rec setup`.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    args: []const [:0]const u8,
    home_dir: []const u8,
    recordings_path: []const u8,
) u8 {
    const fa = switch (parseArgs(args)) {
        .invalid => {
            printErr(io, "uso: ");
            printErr(io, usage);
            printErr(io, "\n");
            return 1;
        },
        .ok => |a| a,
    };

    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_dir = llm.configDirPath(home_dir, llm.envValue("XDG_CONFIG_HOME"), &cfg_buf) orelse {
        printErr(io, "format: não consegui determinar o diretório de configuração\n");
        return 1;
    };
    var tpl_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const templates_dir = llm.templatesDirPath(config_dir, &tpl_buf).?;

    // Defaults must exist before resolution so a fresh install finds `meeting`.
    llm.materializeTemplates(io, templates_dir);

    const runner = switch (llm.resolveRunner(io, gpa, config_dir)) {
        .ok => |r| r,
        .none => |reason| {
            printErr(io, "format: ");
            printErr(io, reason);
            printErr(io, "\n");
            return 1;
        },
    };
    defer gpa.free(runner.bin_path);

    // Resolve the source transcript.
    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = resolveSource(
        io,
        gpa,
        &src_buf,
        fa.selection,
        recordings_path,
    ) orelse {
        printErr(io, "format: nenhuma gravação corresponde a '");
        printErr(io, fa.selection);
        printErr(io, "' (veja `rec list`) ou o caminho informado não existe\n");
        return 1;
    };

    const transcript_bytes = std.Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .limited(max_transcript_bytes)) catch {
        printErr(io, "format: não consegui ler ");
        printErr(io, source_path);
        printErr(io, "\n");
        return 1;
    };
    defer gpa.free(transcript_bytes);

    // Template: the user-editable file wins so local edits apply; when it is
    // missing/unreadable and the name is one of the bundled ones, the embedded
    // copy keeps the command working from a read-only config dir.
    const template_content: []u8 = tpl: {
        if (llm.loadTemplate(io, gpa, templates_dir, fa.template)) |t| break :tpl t else |err| switch (err) {
            error.InvalidName => {
                printErr(io, "format: nome de template inválido (use minúsculas, dígitos, - ou _)\n");
                return 1;
            },
            error.OutOfMemory => {
                printErr(io, "format: sem memória\n");
                return 1;
            },
            // NotFound and FileSystem fall through to the embedded copies.
            else => {},
        }

        const embedded = prompts.embeddedTemplate(fa.template) orelse {
            printErr(io, "format: template '");
            printErr(io, fa.template);
            printErr(io, "' não encontrado em ");
            printErr(io, templates_dir);
            printErr(io, "\n");
            listAvailable(io, gpa, templates_dir);
            return 1;
        };
        const copy = gpa.dupe(u8, embedded) catch {
            printErr(io, "format: sem memória\n");
            return 1;
        };
        printErr(io, "format: usando a cópia embutida do template '");
        printErr(io, fa.template);
        printErr(io, "'\n");
        break :tpl copy;
    };
    defer gpa.free(template_content);

    const split = prompts.splitFrontmatter(transcript_bytes);
    const composed = prompts.compose(gpa, template_content, fa.context, split.body) catch {
        printErr(io, "format: sem memória ao montar o prompt\n");
        return 1;
    };
    defer gpa.free(composed);

    var note: [llm.max_note_bytes]u8 = undefined;
    var note_len: usize = 0;
    var describe_buf: [128]u8 = undefined;
    printErr(io, "format: processando com ");
    printErr(io, runner.describe(&describe_buf));
    printErr(io, "...\n");

    var invocation = llm.run(
        io,
        gpa,
        runner.kind,
        runner.bin_path,
        runner.model,
        runner.provider,
        composed,
        llm.job_timeout_ns,
        &note,
        &note_len,
    ) catch |err| {
        printErr(io, "format: o modelo falhou (");
        printErr(io, llm.failurePhrase(err));
        if (note_len > 0) {
            printErr(io, ": ");
            printErr(io, note[0..note_len]);
        }
        printErr(io, ")\n");
        return 1;
    };
    defer invocation.deinit();

    // Where the result lands: explicit --out, else NEXT TO the source named
    // after the template — recordings/x.md + meeting → recordings/x.meeting.md.
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path: []const u8 = blk: {
        if (fa.out) |p| {
            // Overwriting the input with the transformed text is never what
            // "save to this path" means.
            if (std.mem.eql(u8, p, source_path)) {
                printErr(io, "format: --out não pode ser o próprio arquivo de entrada\n");
                return 1;
            }
            break :blk p;
        }
        const stem_len = if (std.mem.endsWith(u8, source_path, ".md"))
            source_path.len - ".md".len
        else
            source_path.len;
        const joined = std.fmt.bufPrint(
            &out_buf,
            "{s}.{s}.md",
            .{ source_path[0..stem_len], fa.template },
        ) catch {
            printErr(io, "format: caminho de saída longo demais\n");
            return 1;
        };
        break :blk joined;
    };

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = invocation.text(),
    }) catch {
        printErr(io, "format: não consegui gravar ");
        printErr(io, out_path);
        printErr(io, "\n");
        return 1;
    };

    printErr(io, "Documento salvo em ");
    printErr(io, out_path);
    printErr(io, "\n");
    return 0;
}

/// Selection semantics: '/' anywhere means a real filesystem path (relative
/// paths join against cwd); otherwise it is resolved through the recordings
/// library to `<stem>.md` beside the WAV. Result points into `buf` when it is
/// derived, or IS the selection itself for direct paths that already fit it.
fn resolveSource(
    io: std.Io,
    gpa: std.mem.Allocator,
    buf: []u8,
    selection: []const u8,
    recordings_path: []const u8,
) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, selection, '/') != null) {
        // Direct path (absolute or relative): existence decides.
        std.Io.Dir.cwd().access(io, selection, .{}) catch return null;
        if (selection.len <= buf.len) {
            @memcpy(buf[0..selection.len], selection);
            return buf[0..selection.len];
        }
        return null;
    }

    var entries: std.ArrayList(library.Entry) = .empty;
    defer library.freeEntries(gpa, &entries);
    library.scan(io, gpa, &entries, recordings_path) catch return null;
    library.sortNewestFirst(entries.items);
    if (entries.items.len == 0) return null;

    const name = library.resolveName(selection, entries.items) orelse return null;
    const stem = stripExt(name);
    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = library.recordingPath(recordings_path, stem, &rel_buf) orelse return null;
    if (rel.len + ".md".len > buf.len) return null;
    var joined_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var jn: usize = 0;
    appendStr(&joined_buf, &jn, rel);
    appendStr(&joined_buf, &jn, ".md");
    @memcpy(buf[0..jn], joined_buf[0..jn]);
    return buf[0..jn];
}

/// A recording's stem: the name without its .m4a/.wav extension, so the
/// transcript lookup matches what transcribe wrote next to either container.
fn stripExt(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".m4a")) return name[0 .. name.len - ".m4a".len];
    if (std.mem.endsWith(u8, name, ".wav")) return name[0 .. name.len - ".wav".len];
    return name;
}

fn listAvailable(io: std.Io, gpa: std.mem.Allocator, templates_dir: []const u8) void {
    var names = llm.listTemplates(io, gpa, templates_dir) catch return;
    defer llm.freeTemplateNames(gpa, &names);
    if (names.items.len == 0) return;
    printErr(io, "Templates disponíveis:");
    for (names.items) |nm| {
        printErr(io, " ");
        printErr(io, nm);
    }
    printErr(io, "\n");
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

fn printErr(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

// --- tests -------------------------------------------------------------------

test "parse format args: defaults and flags" {
    const ok = switch (parseArgs(&.{"3"})) {
        .ok => |a| a,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("3", ok.selection);
    try std.testing.expectEqualStrings(default_template, ok.template);
    try std.testing.expect(ok.out == null);
    try std.testing.expect(ok.context == null);

    const full = switch (parseArgs(&.{ "--template", "retro", "x.md", "--out", "y.md", "--context", "projeto z" })) {
        .ok => |a| a,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("x.md", full.selection);
    try std.testing.expectEqualStrings("retro", full.template);
    try std.testing.expectEqualStrings("y.md", full.out.?);
    try std.testing.expectEqualStrings("projeto z", full.context.?);
}

test "parse format args rejects bad usage" {
    const cases = [_][]const [:0]const u8{
        &.{"--template"}, // missing value
        &.{}, // no selection
        &.{ "-t", "x" }, // unknown flag
        &.{ "a", "b" }, // two positionals
        &.{ "--template", "../evil", "f" }, // traversal attempt via template name
    };
    for (cases) |c| {
        try std.testing.expect(switch (parseArgs(c)) {
            .invalid => true,
            .ok => false,
        });
    }
}
