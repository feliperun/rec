const std = @import("std");
const builtin = @import("builtin");
const prompts = @import("prompts.zig");

// ---------------------------------------------------------------------------
// Harness registry
//
// Every harness rec drives non-interactively gets an entry here plus branches
// in buildArgv()/extractAnswer(), and optionally a native model listing in
// listModels(). All invocations pipe the composed prompt into the child's
// stdin and read the answer back from stdout — codex via `-o <tmpfile>`
// because its stdout carries progress noise, gemini via --output-format json
// for the same reason.
//
// A real probe through this exact path is how `rec setup` decides what counts
// as installed *and* authenticated, so per-harness quirks fail loudly there
// instead of silently at transcribe time.
// ---------------------------------------------------------------------------

pub const Kind = enum {
    claude,
    codex,
    opencode,
    pi,
    gemini,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex CLI",
            .opencode => "OpenCode",
            .pi => "pi",
            .gemini => "Gemini CLI",
        };
    }
};

pub const Harness = struct {
    kind: Kind,
    /// Executable looked up on PATH.
    binary: []const u8,

    pub fn label(self: Harness) []const u8 {
        return self.kind.label();
    }
};

/// Which Anthropic-compatible backend drives the `claude` harness. `.anthropic`
/// is Claude's own account; the others mirror the `claudeseek`/`claudezai`
/// shell functions from ~/.zshrc — same base URL, same env-var contract, same
/// default models. The API key is never persisted: it is read from the
/// environment (DEEPSEEK_API_KEY / ZAI_API_KEY) at invocation time, exactly
/// like those functions do with `$DEEPSEEK_API_KEY`.
pub const Provider = enum {
    anthropic,
    deepseek,
    zai,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "Anthropic (conta padrão do Claude)",
            .deepseek => "DeepSeek",
            .zai => "Z.AI GLM",
        };
    }

    /// Stable name persisted in config.json.
    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .deepseek => "deepseek",
            .zai => "zai",
        };
    }

    pub fn parse(raw: []const u8) ?Provider {
        for (std.meta.tags(Provider)) |p| {
            if (std.mem.eql(u8, raw, p.name())) return p;
        }
        return null;
    }

    /// Env var that must be exported for this provider to work; null means
    /// "nothing to export" (Anthropic's own account).
    pub fn keyEnvName(self: Provider) ?[*:0]const u8 {
        return switch (self) {
            .anthropic => null,
            .deepseek => "DEEPSEEK_API_KEY",
            .zai => "ZAI_API_KEY",
        };
    }

    /// Anthropic-compatible base URL the `claude` binary should talk to.
    pub fn baseUrl(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => unreachable, // only consulted for non-anthropic
            .deepseek => "https://api.deepseek.com/anthropic",
            .zai => "https://api.z.ai/api/anthropic",
        };
    }

    /// Model used when the config carries no explicit choice ("account
    /// default"), mirroring the ANTHROPIC_MODEL of claudeseek/claudezai.
    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "",
            .deepseek => "deepseek-v4-flash",
            .zai => "glm-5.3[1m]",
        };
    }

    /// (opus, sonnet, haiku) fallbacks, mirroring the ANTHROPIC_DEFAULT_* of
    /// claudeseek/claudezai.
    pub fn modelDefaults(self: Provider) [3][]const u8 {
        return switch (self) {
            .anthropic => .{ "", "", "" },
            .deepseek => .{ "deepseek-v4-pro[1m]", "deepseek-v4-flash", "deepseek-v4-flash" },
            .zai => .{ "glm-5.3[1m]", "glm-5.3-flash", "glm-4.7" },
        };
    }
};

pub const registry = [_]Harness{
    .{ .kind = .claude, .binary = "claude" },
    .{ .kind = .codex, .binary = "codex" },
    .{ .kind = .opencode, .binary = "opencode" },
    .{ .kind = .pi, .binary = "pi" },
    .{ .kind = .gemini, .binary = "gemini" },
};

fn harnessOf(kind: Kind) Harness {
    for (registry) |h| {
        if (h.kind == kind) return h;
    }
    unreachable;
}

// --- PATH resolution -------------------------------------------------------

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
// The full process environment, for building the child's environ map.
extern "c" var environ: [*:null]?[*:0]u8;

// libc write/fcntl on the raw pipe fds: std.posix has read() but no partial
// write() in 0.16, and nonblocking feeding is what lets the poll loop drain
// stdout while the child is still consuming stdin. EAGAIN surfaces through
// the platform errno accessor (__error on macOS, __errno_location on Linux);
// its value and O_NONBLOCK's differ between them.
const einval_again: c_int = if (builtin.os.tag == .macos) 35 else 11;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern "c" fn __error() *c_int;
extern "c" fn __errno_location() *c_int;
const errno_ptr = if (builtin.os.tag == .macos) __error else __errno_location;
const f_getfl: c_int = 3;
const f_setfl: c_int = 4;
const o_nonblock: c_int = if (builtin.os.tag == .macos) 0o4 else 0o4000;
// Windows process-bound plumbing for the file-redirected harness run
// (analyzed only on Windows targets).
extern "kernel32" fn TerminateProcess(handle: std.os.windows.HANDLE, exit_code: u32) i32;
extern "kernel32" fn WaitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: u32) u32;

pub fn envValue(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return s;
}

/// The directory for rec's scratch files (codex output; on Windows the whole
/// harness stdio). TMPDIR on POSIX; TEMP/TMP with the system fallback there.
fn tempDir() []const u8 {
    if (envValue("TMPDIR")) |d| return d;
    if (builtin.os.tag == .windows) {
        if (envValue("TEMP")) |d| return d;
        if (envValue("TMP")) |d| return d;
        return "C:/Windows/Temp";
    }
    return "/tmp";
}

/// Absolute path of an executable `name` found on PATH (execute permission
/// checked); null when absent everywhere. Caller owns the bytes. Reading PATH
/// through libc mirrors main.zig's time()/localtime_r() idiom: libc is already
/// linked and callers do not thread the raw environ down here.
pub fn findBinary(io: std.Io, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    const windows = builtin.os.tag == .windows;
    const path_sep: u8 = if (windows) ';' else ':';
    const dir_sep: u8 = if (windows) '\\' else '/';
    // Windows: CreateProcess wants the .exe spelling when none is given.
    const dot_exe: []const u8 = if (windows and std.mem.indexOfScalar(u8, name, '.') == null) ".exe" else "";

    var it = std.mem.splitScalar(u8, envValue("PATH") orelse return null, path_sep);
    while (it.next()) |dir_raw| {
        // Empty components mean "current directory" in POSIX terms; never an
        // execution source we want.
        const dir = std.mem.trimEnd(u8, dir_raw, "/\\");
        if (dir.len == 0) continue;

        const candidate = gpa.alloc(u8, dir.len + 1 + name.len + dot_exe.len) catch return null;
        @memcpy(candidate[0..dir.len], dir);
        candidate[dir.len] = dir_sep;
        @memcpy(candidate[dir.len + 1 ..][0..name.len], name);
        @memcpy(candidate[dir.len + 1 + name.len ..], dot_exe);

        std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
            gpa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

// --- Configuration ---------------------------------------------------------

/// The persisted choice made by `rec setup`. An empty `model` means "use the
/// harness's account default".
pub const Config = struct {
    harness: Kind,
    model: []const u8 = "",
    /// Backend behind a `claude` harness; ignored by the other harnesses.
    provider: Provider = .anthropic,
};

pub const ConfigError = error{ OutOfMemory, BadJson };

/// `$XDG_CONFIG_HOME/rec` when XDG_CONFIG_HOME is set and absolute, else
/// `~/.config/rec`; null when neither base is usable. Result points into buf.
pub fn configDirPath(home_dir: []const u8, xdg_config_home: ?[]const u8, buf: []u8) ?[]const u8 {
    var base: ?[]const u8 = null;
    if (xdg_config_home) |xdg| {
        if (xdg.len > 0 and xdg[0] == '/') base = xdg;
    }

    var n: usize = 0;
    if (base) |root| {
        appendStr(buf, &n, root);
        if (buf[n - 1] != '/') {
            buf[n] = '/';
            n += 1;
        }
        appendStr(buf, &n, "rec");
    } else {
        if (home_dir.len == 0) return null;
        appendStr(buf, &n, home_dir);
        if (buf[n - 1] != '/') {
            buf[n] = '/';
            n += 1;
        }
        appendStr(buf, &n, ".config/rec");
    }
    return buf[0..n];
}

const ConfigJson = struct {
    harness: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
};

/// Reads `<config dir>/config.json`. Missing/unreadable ⇒ null (nothing
/// configured yet); an unknown harness or provider name also yields null so
/// stale configs can never select something unsupported. A missing `provider`
/// field means the config predates providers and defaults to Anthropic.
pub fn loadConfig(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) ConfigError!?Config {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = joinPath(dir_path, "config.json", &buf) orelse return error.OutOfMemory;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(ConfigJson, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();

    const harness_name = parsed.value.harness orelse return null;
    for (registry) |h| {
        if (!std.mem.eql(u8, h.binary, harness_name)) continue;
        const provider = if (parsed.value.provider) |p|
            Provider.parse(p) orelse return null
        else
            .anthropic;
        return .{
            .harness = h.kind,
            .model = try gpa.dupe(u8, parsed.value.model orelse ""),
            .provider = provider,
        };
    }
    return null;
}

/// Writes config.json, creating the directory on demand. IO errors propagate;
/// callers decide how fatal that is.
pub fn saveConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir_path: []const u8,
    config: Config,
) !void {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const model_json = try jsonEscape(gpa, config.model);
    defer gpa.free(model_json);

    const doc = try std.fmt.allocPrint(
        gpa,
        "{{\"harness\":\"{s}\",\"model\":{s},\"provider\":\"{s}\"}}\n",
        .{ harnessOf(config.harness).binary, model_json, config.provider.name() },
    );
    defer gpa.free(doc);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = joinPath(dir_path, "config.json", &buf) orelse return error.NameTooLong;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = doc });
}

// --- Templates -------------------------------------------------------------

pub const TemplateError = error{
    InvalidName,
    NotFound,
    OutOfMemory,
    FileSystem,
    NameTooLong,
};

/// Template names are bare directory components — lowercase ascii, digits,
/// dash and underscore only, which also rules out traversal.
pub fn validTemplateName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}

/// Directory holding user-editable transformation templates
/// (`<config dir>/templates/NAME.md`). Bundled defaults are copied there on
/// first use so users can customize them or add their own.
pub fn templatesDirPath(config_dir_path: []const u8, buf: []u8) ?[]const u8 {
    return joinPath(config_dir_path, "templates", buf);
}

/// Copies the bundled prompts into the user's templates directory unless a
/// file with that name already exists — user edits survive upgrades. IO
/// failures are swallowed by design: a read-only config dir must not block
/// transcription, it just means the defaults stay embedded-only.
pub fn materializeTemplates(io: std.Io, templates_dir: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, templates_dir) catch return;

    const Defaults = struct { name: []const u8, content: []const u8 };
    const defaults = [_]Defaults{
        .{ .name = "meeting", .content = prompts.meeting_md },
        .{ .name = "refine", .content = prompts.refine_md },
    };
    for (defaults) |d| {
        var name_buf: [128]u8 = undefined;
        const file_name = std.fmt.bufPrint(&name_buf, "{s}.md", .{d.name}) catch continue;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = joinPath(templates_dir, file_name, &buf) orelse continue;
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = d.content }) catch {};
        };
    }
}

/// Loads `<templates dir>/<name>.md`; caller owns the returned bytes.
pub fn loadTemplate(io: std.Io, gpa: std.mem.Allocator, templates_dir: []const u8, name: []const u8) TemplateError![]u8 {
    if (!validTemplateName(name)) return error.InvalidName;
    var file_buf: [128]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_buf, "{s}.md", .{name}) catch return error.InvalidName;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = joinPath(templates_dir, file_name, &buf) orelse return error.NameTooLong;

    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.FileSystem,
    };
}

/// Names (sans .md) of every template in the user's directory, sorted. Free
/// with freeTemplateNames; a missing directory yields the empty list.
pub fn listTemplates(io: std.Io, gpa: std.mem.Allocator, templates_dir: []const u8) error{OutOfMemory}!std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |nm| gpa.free(nm);
        names.deinit(gpa);
    }

    var dir = std.Io.Dir.cwd().openDir(io, templates_dir, .{ .iterate = true }) catch return names;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const nm = try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".md".len]);
        try names.append(gpa, nm);
    }
    sortNameSlices(names.items);
    return names;
}

fn sortNameSlices(items: [][]u8) void {
    const Ctx = struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]u8, items, {}, Ctx.less);
}

pub fn freeTemplateNames(gpa: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |nm| gpa.free(nm);
    names.deinit(gpa);
}

// --- Model discovery -------------------------------------------------------

/// Suggestions offered by `rec setup` for harnesses without a native listing
/// command. Tiny on purpose: for those, typed free-form ids are the honest
/// option ("whatever id your account accepts"). Claude's suggestions depend
/// on the provider behind it — the claudeseek/claudezai model sets.
pub fn curatedModels(kind: Kind, provider: Provider) []const []const u8 {
    return switch (kind) {
        .claude => switch (provider) {
            .anthropic => &.{ "sonnet", "opus", "haiku" },
            .deepseek => &.{ "deepseek-v4-flash", "deepseek-v4-pro[1m]" },
            .zai => &.{ "glm-5.3[1m]", "glm-5.3-flash", "glm-4.7" },
        },
        else => &.{},
    };
}

/// Models the harness itself reports available for the signed-in account: a
/// native listing where one exists (pi's `--list-models` table, opencode's
/// `models` command), an empty list otherwise. Parse failures degrade to that
/// same empty list — discovery is best-effort by design. Free with
/// freeTemplateNames.
pub fn listModels(
    io: std.Io,
    gpa: std.mem.Allocator,
    bin_path: []const u8,
    kind: Kind,
) error{OutOfMemory}!std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |nm| gpa.free(nm);
        names.deinit(gpa);
    }

    var args: [2][]const u8 = .{ bin_path, "" };
    switch (kind) {
        .pi => args[1] = "--list-models",
        .opencode => args[1] = "models",
        else => return names,
    }

    const result = std.process.run(gpa, io, .{ .argv = &args }) catch return names;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) return names;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const first = cols.next() orelse continue;
        switch (kind) {
            // Table rows: provider model context ... — skip the header row.
            .pi => {
                if (std.mem.eql(u8, first, "provider")) continue;
                const model_id = cols.next() orelse continue;
                if (std.mem.indexOfScalar(u8, model_id, '/') == null) continue;
                try putUnique(gpa, &names, model_id);
            },
            // Rows like "provider/model description...".
            .opencode => {
                if (std.mem.indexOfScalar(u8, first, '/') == null) continue;
                try putUnique(gpa, &names, first);
            },
            else => return names,
        }
    }
    return names;
}

fn putUnique(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []const u8) error{OutOfMemory}!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, s)) return;
    }
    try list.append(gpa, try gpa.dupe(u8, s));
}

// --- Invocation ------------------------------------------------------------

/// Size of the caller-supplied buffer receiving the child's stderr tail
/// (flattened to one line) on failure.
pub const max_note_bytes = 512;

pub const max_prompt_bytes: usize = 4 * 1024 * 1024;
pub const max_output_bytes: usize = 8 * 1024 * 1024;

pub const InvokeError = error{
    /// The harness binary was not found at `bin_path`.
    BinaryMissing,
    SpawnFailed,
    TimedOut,
    OutputTooLarge,
    ChildFailed,
    EmptyOutput,
    OutOfMemory,
    NameTooLong,
    /// The provider's API key env var is not exported (DEEPSEEK_API_KEY /
    /// ZAI_API_KEY).
    MissingKey,
};

/// One PT-BR clause per failure mode, shared by every command that surfaces an
/// invocation error so wording stays identical across setup/transcribe/format.
pub fn failurePhrase(err: InvokeError) []const u8 {
    return switch (err) {
        error.BinaryMissing => "binário do harness desapareceu",
        error.SpawnFailed => "falha ao iniciar o processo",
        error.TimedOut => "tempo esgotado",
        error.OutputTooLarge => "saída grande demais",
        error.ChildFailed => "o harness terminou com erro",
        error.EmptyOutput => "resposta vazia",
        error.OutOfMemory => "sem memória",
        error.NameTooLong => "caminho longo demais",
        error.MissingKey => "chave de API do provedor não está no ambiente",
    };
}

/// One model answer. Every byte lives in a single arena; deinit frees it all
/// — the stderr diagnostic meanwhile traveled back through the caller's own
/// note buffer, so nothing else needs owning here.
pub const Invocation = struct {
    arena_state: std.heap.ArenaAllocator,
    _text: []const u8 = "",

    pub fn deinit(self: *Invocation) void {
        self.arena_state.deinit();
    }

    pub fn text(self: *const Invocation) []const u8 {
        return self._text;
    }
};

/// Wall-clock bounds, one place so CLI wording can quote them consistently.
pub const probe_timeout_ns: i96 = 90 * std.time.ns_per_s;
pub const job_timeout_ns: i96 = 30 * 60 * std.time.ns_per_s;

/// A validated LLM execution path: which harness, where its binary lives,
/// which model ("" = account default), and which provider backs a `claude`
/// harness. Produced by resolveRunner for every command that talks to an LLM.
pub const Runner = struct {
    kind: Kind,
    bin_path: []u8,
    model: []const u8,
    provider: Provider = .anthropic,

    pub fn describe(self: Runner, buf: []u8) []const u8 {
        if (self.provider != .anthropic) {
            if (self.model.len == 0)
                return std.fmt.bufPrint(buf, "{s} · {s}", .{ self.kind.label(), self.provider.label() }) catch self.kind.label();
            return std.fmt.bufPrint(buf, "{s} · {s} ({s})", .{ self.kind.label(), self.provider.label(), self.model }) catch self.kind.label();
        }
        if (self.model.len == 0)
            return std.fmt.bufPrint(buf, "{s}", .{self.kind.label()}) catch self.kind.label();
        return std.fmt.bufPrint(buf, "{s} · {s}", .{ self.kind.label(), self.model }) catch self.kind.label();
    }
};

pub const ResolveOutcome = union(enum) {
    ok: Runner,
    /// Nothing configured yet, or the binary vanished from PATH.
    none: []const u8, // static reason for stderr
};

/// Reads config.json and re-verifies the chosen executable still exists on
/// PATH. `.none` carries a static one-line reason for stderr.
pub fn resolveRunner(
    io: std.Io,
    gpa: std.mem.Allocator,
    config_dir_path: []const u8,
) ResolveOutcome {
    const maybe_cfg = loadConfig(io, gpa, config_dir_path) catch |err| switch (err) {
        error.BadJson => return .{ .none = "config.json inválido — rode `rec setup` novamente" },
        error.OutOfMemory => return .{ .none = "sem memória ao ler a configuração" },
    };
    const cfg = maybe_cfg orelse
        return .{ .none = "nenhum modelo configurado — rode `rec setup` primeiro" };

    const bin = findBinary(io, gpa, harnessOf(cfg.harness).binary) orelse
        return .{ .none = "o binário do harness configurado sumiu do PATH — rode `rec setup`" };

    return .{ .ok = .{ .kind = cfg.harness, .bin_path = bin, .model = cfg.model, .provider = cfg.provider } };
}

/// Runs `prompt` through the harness (`model` == "" means the account's
/// default) with a hard wall-clock bound. stdin feeding and stdout/stderr
/// draining all proceed through poll(), so a large prompt cannot deadlock
/// against a child that streams output before finishing its input — which the
/// coding-agent CLIs do. On any failure the flattened stderr tail (when there
/// was one) lands in `note_buf` for the CLI's message.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    kind: Kind,
    bin_path: []const u8,
    model: []const u8,
    provider: Provider,
    prompt: []const u8,
    timeout_ns: i96,
    note_buf: *[max_note_bytes]u8,
    note_len: *usize,
) InvokeError!Invocation {
    note_len.* = 0;
    if (prompt.len > max_prompt_bytes) return error.OutputTooLarge;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    // codex drops its final answer here; the other kinds ignore it.
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var tmp_out_path: ?[]const u8 = null;
    if (kind == .codex) {
        tmp_out_path = std.fmt.bufPrint(
            &tmp_buf,
            "{s}/rec-codex-{d}.out",
            .{ std.mem.trimEnd(u8, tempDir(), "/"), nextTempId() },
        ) catch return error.NameTooLong;
    }

    const argv = buildArgv(arena, kind, bin_path, model, tmp_out_path) catch return error.OutOfMemory;

    // Non-Anthropic providers ride the claude binary the same way the
    // claudeseek/claudezai shell functions do: point ANTHROPIC_BASE_URL at the
    // provider and feed it ANTHROPIC_AUTH_TOKEN from the environment. The key
    // is never stored — it must be exported when rec runs.
    var environ_map: std.process.Environ.Map = undefined;
    var provider_env_applied = false;
    // Function-scoped so it outlives the `if` block: the spawn below reads the
    // map, and a block-scoped defer would free it first.
    defer if (provider_env_applied) environ_map.deinit();
    if (provider != .anthropic and kind == .claude) {
        const api_key = envValue(provider.keyEnvName().?) orelse return error.MissingKey;
        // POSIX reads the libc environ global; Windows reads the PEB block
        // (createMap ignores the passed slice there).
        environ_map = std.process.Environ.createMap(
            if (builtin.os.tag == .windows)
                .{ .block = .global }
            else
                .{ .block = .{ .slice = std.mem.sliceTo(environ, null) } },
            gpa,
        ) catch return error.OutOfMemory;
        applyProviderEnv(&environ_map, provider, model, api_key) catch return error.OutOfMemory;
        provider_env_applied = true;
    }

    var out_bytes: std.ArrayList(u8) = .empty;
    var err_bytes: std.ArrayList(u8) = .empty;
    const started = std.Io.Timestamp.now(io, .awake);
    const deadline = started.addDuration(.{ .nanoseconds = timeout_ns });

    if (builtin.os.tag == .windows) {
        // Windows pipe handles cannot poll(); the child runs with its stdio
        // redirected through temp files instead.
        try runChildViaFiles(io, arena, argv, if (provider_env_applied) &environ_map else null, prompt, deadline, &out_bytes, &err_bytes);
    } else {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = if (provider_env_applied) &environ_map else null,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.BinaryMissing,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        // kill() reaps when id is still live, so early returns above never
        // leak children; after wait() below it is a no-op.
        defer child.kill(io);
        if (child.stdin) |f| setNonblocking(f.handle);

        // All three pipe ends start open on our side; each closes once fully
        // consumed or once the far end hangs up. When none remain the loop ends.
        var written: usize = 0;
        var stdin_open = true;
        var stdout_open = true;
        var stderr_open = true;

        while (stdin_open or stdout_open or stderr_open) {
            if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) {
                return error.TimedOut;
            }

            var pfds: [3]std.posix.pollfd = undefined;
            var n_slots: usize = 0;
            var w_slot: ?usize = null;
            var o_slot: ?usize = null;
            var e_slot: ?usize = null;
            if (stdin_open) {
                w_slot = n_slots;
                pfds[n_slots] = .{ .fd = child.stdin.?.handle, .events = std.posix.POLL.OUT, .revents = 0 };
                n_slots += 1;
            }
            if (stdout_open) {
                o_slot = n_slots;
                pfds[n_slots] = .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 };
                n_slots += 1;
            }
            if (stderr_open) {
                e_slot = n_slots;
                pfds[n_slots] = .{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 };
                n_slots += 1;
            }

            const ready = std.posix.poll(pfds[0..n_slots], 200) catch return error.SpawnFailed;
            if (ready == 0) continue;

            // Feed stdin in bounded chunks; partial writes are expected and fine.
            if (w_slot) |s| {
                if (pfds[s].revents != 0) feedStdin(io, &child, prompt, &written, &stdin_open);
            }
            if (o_slot) |s| {
                if (pfds[s].revents != 0) {
                    drainPipe(io, &child.stdout, &out_bytes, arena, max_output_bytes, &stdout_open) catch |err| switch (err) {
                        error.OutputTooLarge => return error.OutputTooLarge,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                }
            }
            if (e_slot) |s| {
                if (pfds[s].revents != 0) {
                    drainPipe(io, &child.stderr, &err_bytes, arena, max_output_bytes, &stderr_open) catch |err| switch (err) {
                        error.OutputTooLarge => {}, // diagnostics: keep whatever arrived first
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                }
            }
        }

        const posix_term = child.wait(io) catch return error.SpawnFailed;
        switch (posix_term) {
            .exited => |code| {
                if (code != 0) return error.ChildFailed;
            },
            else => return error.ChildFailed,
        }
    }

    flattenTail(note_buf, note_len, keepTail(err_bytes.items, max_note_bytes));

    const extracted_raw = extractAnswer(io, arena, kind, tmp_out_path, out_bytes.items) catch |err| switch (err) {
        error.EmptyOutput => return error.EmptyOutput,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const text_final = stripCodeFences(std.mem.trim(u8, extracted_raw, " \t\r\n"));
    if (text_final.len == 0) return error.EmptyOutput;

    return .{ .arena_state = arena_state, ._text = text_final };
}

/// Windows: pipe handles cannot poll(), so the harness runs with its stdio
/// redirected through temp files — `prompt` as the child's stdin,
/// stdout/stderr captured and handed back to the caller. `child.id` on
/// Windows is the process handle, which WaitForSingleObject bounds by the
/// same wall-clock deadline as the POSIX poll loop.
fn runChildViaFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: ?*std.process.Environ.Map,
    prompt: []const u8,
    deadline: std.Io.Timestamp,
    out_bytes: *std.ArrayList(u8),
    err_bytes: *std.ArrayList(u8),
) InvokeError!void {
    const wait_object_0: u32 = 0;

    const id = nextTempId();
    var in_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var err_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = std.mem.trimEnd(u8, tempDir(), "/");
    const in_path = std.fmt.bufPrint(&in_buf, "{s}/rec-run-{d}-in.txt", .{ base, id }) catch return error.NameTooLong;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}/rec-run-{d}-out.txt", .{ base, id }) catch return error.NameTooLong;
    const err_path = std.fmt.bufPrint(&err_buf, "{s}/rec-run-{d}-err.txt", .{ base, id }) catch return error.NameTooLong;
    defer {
        std.Io.Dir.deleteFileAbsolute(io, in_path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, out_path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, err_path) catch {};
    }

    // The prompt becomes the child's stdin file: written up front, so the
    // nonblocking feeding loop disappears entirely.
    {
        var f = std.Io.Dir.createFileAbsolute(io, in_path, .{}) catch return error.SpawnFailed;
        f.writeStreamingAll(io, prompt) catch {
            f.close(io);
            return error.SpawnFailed;
        };
        f.close(io);
    }

    const in_file = std.Io.Dir.openFileAbsolute(io, in_path, .{}) catch return error.SpawnFailed;
    const out_file = std.Io.Dir.createFileAbsolute(io, out_path, .{}) catch {
        in_file.close(io);
        return error.SpawnFailed;
    };
    const err_file = std.Io.Dir.createFileAbsolute(io, err_path, .{}) catch {
        out_file.close(io);
        in_file.close(io);
        return error.SpawnFailed;
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = in_file },
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
        .environ_map = environ_map,
    }) catch |err| {
        in_file.close(io);
        out_file.close(io);
        err_file.close(io);
        return switch (err) {
            error.FileNotFound => error.BinaryMissing,
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };
    };
    // The child holds its own inherited handles now.
    in_file.close(io);
    out_file.close(io);
    err_file.close(io);

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= deadline.nanoseconds) {
            _ = TerminateProcess(child.id.?, 1);
            _ = child.wait(io) catch {};
            return error.TimedOut;
        }
        const remaining_ns: u64 = @intCast(deadline.nanoseconds - now.nanoseconds);
        const ms: u32 = @intCast(@min(remaining_ns / 1_000_000, std.math.maxInt(u32)));
        if (WaitForSingleObject(child.id.?, ms) == wait_object_0) break;
    }
    switch (child.wait(io) catch return error.SpawnFailed) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }

    const out_data = std.Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(max_output_bytes)) catch "";
    out_bytes.appendSlice(arena, out_data) catch return error.OutOfMemory;
    const err_data = std.Io.Dir.cwd().readFileAlloc(io, err_path, arena, .limited(max_note_bytes)) catch "";
    err_bytes.appendSlice(arena, err_data) catch return error.OutOfMemory;
}

/// Writes as much of `prompt` as the nonblocking pipe accepts per call;
/// closes the end when done or when the child went away before reading it
/// all. EAGAIN is not an error — the poll loop retries next tick.
fn feedStdin(io: std.Io, child: *std.process.Child, prompt: []const u8, written: *usize, stdin_open: *bool) void {
    const fd: c_int = @intCast(child.stdin.?.handle);
    while (written.* < prompt.len) {
        const end = @min(written.* + 64 * 1024, prompt.len);
        const rc = write(fd, prompt[written.*..end].ptr, end - written.*);
        if (rc < 0) {
            if (errno_ptr().* == einval_again) return;
            // Anything else (BrokenPipe etc.): the child died before
            // consuming input; stop feeding and let the drains surface it.
            break;
        }
        written.* += @intCast(rc);
    }
    if (child.stdin) |f| f.close(io);
    child.stdin = null;
    stdin_open.* = false;
}

/// Puts one fd into nonblocking mode so a full pipe returns EAGAIN instead of
/// parking this single thread behind a child that is not reading yet.
fn setNonblocking(fd: std.posix.fd_t) void {
    const cfd: c_int = @intCast(fd);
    const flags = fcntl(cfd, f_getfl, 0);
    _ = fcntl(cfd, f_setfl, flags | o_nonblock);
}

const DrainError = error{ OutputTooLarge, OutOfMemory };

fn drainPipe(
    io: std.Io,
    file_slot: *?std.Io.File,
    sink: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    cap: usize,
    open_flag: *bool,
) DrainError!void {
    const file = file_slot.* orelse return;
    var local: [8192]u8 = undefined;
    const nread = std.posix.read(file.handle, &local) catch 0;
    if (nread == 0) {
        file.close(io);
        file_slot.* = null;
        open_flag.* = false;
        return;
    }
    if (sink.items.len + nread > cap) return error.OutputTooLarge;
    try sink.appendSlice(arena, local[0..nread]);
}

var temp_counter = std.atomic.Value(u32).init(0);

fn nextTempId() u32 {
    return temp_counter.fetchAdd(1, .monotonic);
}

/// Overlays the env vars claudeseek/claudezai set for their provider onto the
/// child environment. `model` "" resolves to the provider's own default so the
/// ANTHROPIC_MODEL slot always points at something the provider accepts.
fn applyProviderEnv(
    map: *std.process.Environ.Map,
    provider: Provider,
    model: []const u8,
    api_key: []const u8,
) std.mem.Allocator.Error!void {
    const model_eff = if (model.len > 0) model else provider.defaultModel();
    const defaults = provider.modelDefaults();
    try map.put("ANTHROPIC_BASE_URL", provider.baseUrl());
    try map.put("ANTHROPIC_AUTH_TOKEN", api_key);
    try map.put("ANTHROPIC_MODEL", model_eff);
    try map.put("ANTHROPIC_DEFAULT_OPUS_MODEL", defaults[0]);
    try map.put("ANTHROPIC_DEFAULT_SONNET_MODEL", defaults[1]);
    try map.put("ANTHROPIC_DEFAULT_HAIKU_MODEL", defaults[2]);
}

/// Child argv per harness. Every entry lives in `arena`, so nothing here needs
/// individual freeing — the invocation's arena reclaims it wholesale.
/// `tmp_out_path` is only consumed by the codex branch.
fn buildArgv(
    arena: std.mem.Allocator,
    kind: Kind,
    bin_path: []const u8,
    model: []const u8,
    tmp_out_path: ?[]const u8,
) error{OutOfMemory}![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const put = struct {
        fn lit(al: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) error{OutOfMemory}!void {
            try list.append(al, try al.dupe(u8, s));
        }
    }.lit;

    try put(arena, &parts, bin_path);

    switch (kind) {
        .claude => {
            try put(arena, &parts, "-p");
            try put(arena, &parts, "--output-format");
            try put(arena, &parts, "text");
            if (model.len > 0) {
                try put(arena, &parts, "--model");
                try put(arena, &parts, model);
            }
        },
        .codex => {
            try put(arena, &parts, "exec");
            try put(arena, &parts, "--ephemeral");
            try put(arena, &parts, "--skip-git-repo-check");
            try put(arena, &parts, "--color");
            try put(arena, &parts, "never");
            try put(arena, &parts, "-s");
            try put(arena, &parts, "read-only");
            if (model.len > 0) {
                try put(arena, &parts, "-m");
                try put(arena, &parts, model);
            }
            try put(arena, &parts, "-o");
            try put(arena, &parts, tmp_out_path orelse "");
            // "-" makes codex read its instructions from stdin.
            try put(arena, &parts, "-");
        },
        .opencode => {
            try put(arena, &parts, "run");
            if (model.len > 0) {
                try put(arena, &parts, "--model");
                try put(arena, &parts, model);
            }
        },
        .pi => {
            try put(arena, &parts, "-p");
            try put(arena, &parts, "--no-session");
            try put(arena, &parts, "-nt");
            if (model.len > 0) {
                try put(arena, &parts, "--model");
                try put(arena, &parts, model);
            }
        },
        .gemini => {
            try put(arena, &parts, "--approval-mode");
            try put(arena, &parts, "plan");
            try put(arena, &parts, "--output-format");
            try put(arena, &parts, "json");
            if (model.len > 0) {
                try put(arena, &parts, "-m");
                try put(arena, &parts, model);
            }
            // gemini appends this argument after whatever came from stdin, so
            // the composed document stays first and intact.
            try put(arena, &parts, "-p");
            try put(arena, &parts, gemini_suffix_prompt);
        },
    }
    return parts.toOwnedSlice(arena);
}

const gemini_suffix_prompt = "Produza apenas o conteúdo final solicitado nas instruções acima.";

/// Kind-specific answer extraction from what the child produced: codex leaves
/// its final message behind a `-o <tmpfile>` and deletes the file on read;
/// gemini answers hide inside a JSON envelope; everyone else speaks plainly
/// on stdout.
fn extractAnswer(
    io: std.Io,
    arena: std.mem.Allocator,
    kind: Kind,
    tmp_out_path: ?[]const u8,
    raw_stdout: []const u8,
) error{ EmptyOutput, OutOfMemory }![]const u8 {
    switch (kind) {
        .codex => {
            const p = tmp_out_path orelse return error.EmptyOutput;
            var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            @memcpy(pbuf[0..p.len], p);
            const answer = std.Io.Dir.cwd().readFileAlloc(io, pbuf[0..p.len], arena, .limited(max_output_bytes)) catch "";
            // The Absolute helpers take the io handle directly — no Dir self.
            std.Io.Dir.deleteFileAbsolute(io, pbuf[0..p.len]) catch {};
            if (answer.len == 0) return error.EmptyOutput;
            return answer;
        },
        .gemini => {
            const Parsed = struct { response: ?[]const u8 = null };
            const parsed: ?Parsed = std.json.parseFromSliceLeaky(Parsed, arena, raw_stdout, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |p| {
                if (p.response) |resp| {
                    if (resp.len > 0) return resp;
                }
            }
            if (raw_stdout.len == 0) return error.EmptyOutput;
            return raw_stdout;
        },
        else => {
            if (raw_stdout.len == 0) return error.EmptyOutput;
            return raw_stdout;
        },
    }
}

// Post-processing -------------------------------------------------------------

/// Drops a wrapping ``` fence (with optional language tag) models add around
/// markdown despite being told not to, then trims edges.
pub fn stripCodeFences(s: []const u8) []const u8 {
    var body = s;
    if (std.mem.startsWith(u8, body, "```")) {
        const first_nl = std.mem.indexOfScalar(u8, body, '\n') orelse return std.mem.trim(u8, body, " \t\r\n");
        body = body[first_nl + 1 ..];
        if (std.mem.endsWith(u8, body, "\n```")) {
            body = body[0 .. body.len - 4];
        } else if (std.mem.endsWith(u8, body, "```")) {
            body = body[0 .. body.len - 3];
        }
    }
    return std.mem.trim(u8, body, " \t\r\n");
}

fn keepTail(bytes: []const u8, want: usize) []const u8 {
    if (bytes.len <= want) return bytes;
    return bytes[bytes.len - want ..];
}

/// Newlines/tabs become spaces, runs collapse — matches main.zig's flattenTail
/// so diagnostics stay single-line everywhere.
fn flattenTail(buf: *[max_note_bytes]u8, len: *usize, tail: []const u8) void {
    len.* = 0;
    var pending_space = false;
    for (tail) |raw| {
        const ch: u8 = switch (raw) {
            '\n', '\r', '\t' => ' ',
            else => raw,
        };
        if (ch == ' ') {
            pending_space = len.* != 0;
            continue;
        }
        if (pending_space) {
            buf[len.*] = ' ';
            len.* += 1;
            pending_space = false;
        }
        buf[len.*] = ch;
        len.* += 1;
    }
}

// Shared small utilities ------------------------------------------------------

fn joinPath(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    if (dir.len == 0) return null;
    var n: usize = 0;
    appendStr(buf, &n, dir);
    if (buf[n - 1] != '/') {
        buf[n] = '/';
        n += 1;
    }
    appendStr(buf, &n, name);
    return buf[0..n];
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

/// Minimal JSON string escaper for the strings rec writes itself (config).
pub fn jsonEscape(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => {
            if (ch < 0x20) {
                var hex: [6]u8 = undefined;
                hex[0] = '\\';
                hex[1] = 'u';
                _ = std.fmt.bufPrint(hex[2..], "{x:0>4}", .{ch}) catch unreachable;
                try out.appendSlice(gpa, &hex);
            } else {
                try out.append(gpa, ch);
            }
        },
    };
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

// Tests -----------------------------------------------------------------------

test "putUnique dedupes model ids" {
    var list: std.ArrayList([]u8) = .empty;
    defer freeTemplateNames(std.testing.allocator, &list);
    try putUnique(std.testing.allocator, &list, "anthropic/claude-haiku-4-5");
    try putUnique(std.testing.allocator, &list, "anthropic/claude-haiku-4-5");
    try putUnique(std.testing.allocator, &list, "google/gemini-3-pro");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}

test "config dir prefers absolute XDG override" {
    var buf: [128]u8 = undefined;
    const via_xdg = configDirPath("/Users/e", "/custom/cfg", &buf).?;
    try std.testing.expectEqualStrings("/custom/cfg/rec", via_xdg);

    const plain = configDirPath("/Users/e", null, &buf).?;
    try std.testing.expectEqualStrings("/Users/e/.config/rec", plain);

    // Relative XDG values are ignored rather than misjoined: fall back to the
    // classic location.
    const fallback = configDirPath("/Users/e", "relative", &buf).?;
    try std.testing.expectEqualStrings("/Users/e/.config/rec", fallback);
    try std.testing.expect(configDirPath("", null, &buf) == null);
}

test "validTemplateName blocks traversal and odd characters" {
    try std.testing.expect(validTemplateName("meeting"));
    try std.testing.expect(validTemplateName("retro-2026_v2"));
    try std.testing.expect(!validTemplateName(""));
    try std.testing.expect(!validTemplateName("../evil"));
    try std.testing.expect(!validTemplateName("sub/dir"));
    try std.testing.expect(!validTemplateName("Espaço"));
}

test "stripCodeFences removes a wrapped markdown block and trims edges" {
    const samples = [_][]const u8{
        "```markdown\n# Título\n\ncorpo\n```",
        "```\n# Só uma cerca\n```",
        "  \nsem cerca \t",
    };
    for (samples) |sample| {
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..sample.len], sample);
        _ = stripCodeFences(buf[0..sample.len]);
    }
}

test "flattenTail produces single-line tails without leading spaces" {
    var buf: [max_note_bytes]u8 = undefined;
    var len: usize = 0;
    flattenTail(&buf, &len, "\nlinha 1\n\nlinha\t2\t");
    try std.testing.expectEqualStrings("linha 1 linha 2", buf[0..len]);
}

test "jsonEscape quotes control characters and specials" {
    const e = try jsonEscape(std.testing.allocator, "a\"b\\c\nd\te\x01");
    defer std.testing.allocator.free(e);
    try std.testing.expect(e[e.len - 1] == '"');
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", e);
}

test "provider names round-trip through parse and name" {
    for (std.meta.tags(Provider)) |p| {
        try std.testing.expectEqual(p, Provider.parse(p.name()).?);
    }
    try std.testing.expect(Provider.parse("nonexistent") == null);
    try std.testing.expect(Provider.parse("") == null);
}

test "provider curated models match the claudeseek/claudezai sets" {
    const anthropic = curatedModels(.claude, .anthropic);
    try std.testing.expectEqual(@as(usize, 3), anthropic.len);

    const deepseek = curatedModels(.claude, .deepseek);
    try std.testing.expectEqualStrings("deepseek-v4-flash", deepseek[0]);
    try std.testing.expectEqualStrings("deepseek-v4-pro[1m]", deepseek[1]);

    const zai = curatedModels(.claude, .zai);
    try std.testing.expectEqualStrings("glm-5.3[1m]", zai[0]);
    try std.testing.expectEqualStrings("glm-5.3-flash", zai[1]);
    try std.testing.expectEqualStrings("glm-4.7", zai[2]);

    // Non-claude harnesses get no suggestions; the provider is irrelevant.
    try std.testing.expectEqual(@as(usize, 0), curatedModels(.codex, .deepseek).len);
}

test "provider defaults and env contract mirror the zshrc functions" {
    try std.testing.expectEqualStrings("deepseek-v4-flash", Provider.deepseek.defaultModel());
    try std.testing.expectEqualStrings("https://api.deepseek.com/anthropic", Provider.deepseek.baseUrl());
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", std.mem.span(Provider.deepseek.keyEnvName().?));
    try std.testing.expectEqualStrings("https://api.z.ai/api/anthropic", Provider.zai.baseUrl());
    try std.testing.expectEqualStrings("glm-5.3[1m]", Provider.zai.defaultModel());
    try std.testing.expectEqualStrings("ZAI_API_KEY", std.mem.span(Provider.zai.keyEnvName().?));
    try std.testing.expect(Provider.anthropic.keyEnvName() == null);
}
