const std = @import("std");
const keys = @import("keys.zig");
const llm = @import("llm.zig");
const transcribe = @import("transcribe.zig");

const probe_prompt = "Responda exatamente: OK";

/// `rec setup` — detects which coding-agent harnesses are installed AND
/// authenticated by running a real one-token probe through them, asks the
/// user to pick a harness and a model, validates that exact combination, and
/// persists it as rec's processing backend (`config.json`). Re-running the
/// command later is how the choice gets changed.
///
/// The probe-first design is deliberate: credential files and version strings
/// lie about usable sessions (quota exhausted, expired tokens, plan-gated
/// providers), so only an actual round-trip counts as "available".
pub fn run(io: std.Io, gpa: std.mem.Allocator, home_dir: []const u8) u8 {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_dir = llm.configDirPath(
        home_dir,
        llm.envValue("XDG_CONFIG_HOME"),
        &cfg_buf,
    ) orelse {
        printOut(io, "setup: não consegui determinar o diretório de configuração\n");
        return 1;
    };

    askDeepgramKey(io, gpa, config_dir);

    printOut(io, "\nrec setup — processamento de transcrições por LLM\n\n");
    printOut(io, "Procurando harnesses de agentes de código instalados e autenticados.\n");
    printOut(io, "Cada um recebe uma chamada real de teste; pode levar alguns segundos.\n");

    const Probe = struct { idx: usize, bin_path: []u8 };
    var candidates: std.ArrayList(Probe) = .empty;
    defer {
        for (candidates.items) |c| gpa.free(c.bin_path);
        candidates.deinit(gpa);
    }

    printOut(io, "\n");
    for (llm.registry, 0..) |h, i| {
        printOut(io, "  · ");
        printOut(io, h.label());

        const bin = llm.findBinary(io, gpa, h.binary) orelse {
            printOut(io, ": não está no PATH\n");
            continue;
        };
        printOut(io, ": testando chamada real...\n");

        if (ping(io, gpa, h.kind, bin, "", .anthropic)) {
            printOut(io, "     ✓ pronto\n");
            candidates.append(gpa, .{ .idx = i, .bin_path = bin }) catch {
                gpa.free(bin);
                printOut(io, "setup: sem memória\n");
                return 1;
            };
        } else {
            gpa.free(bin);
        }
    }

    if (candidates.items.len == 0) {
        printOut(io, "\nNenhum harness utilizável encontrado.\n");
        printOut(io, "Instale e autentique pelo menos um e rode `rec setup` novamente:\n");
        for (llm.registry) |h| {
            printOut(io, "  • ");
            printOut(io, h.label());
            printOut(io, " (`");
            printOut(io, h.binary);
            printOut(io, "`)\n");
        }
        return 1;
    }

    // Pick a harness; for claude also a provider (Anthropic, DeepSeek or
    // Z.AI GLM — same trick as the claudeseek/claudezai shell functions);
    // then a model inside a validating loop.
    while (true) {
        printOut(io, "\nQual harness deve processar as transcrições?\n");
        for (candidates.items, 1..) |c, n| {
            var row: [96]u8 = undefined;
            const row_s = std.fmt.bufPrint(&row, "  {d}. {s}\n", .{ n, llm.registry[c.idx].label() }) catch continue;
            printOut(io, row_s);
        }
        printOut(io, "  q. sair sem configurar\n");

        var line_buf: [64]u8 = undefined;
        const line = readLine(&line_buf) orelse return 130;
        if (isQuit(line)) return 130;

        const pick = parseChoice(line, candidates.items.len) orelse {
            printOut(io, "Opção inválida.\n");
            continue;
        };
        const chosen = candidates.items[pick - 1];
        const harness = llm.registry[chosen.idx];
        const provider = if (harness.kind == .claude)
            chooseProvider(io) orelse continue
        else
            .anthropic;
        if (!chooseModelAndSave(io, gpa, config_dir, harness, chosen.bin_path, provider)) {
            return 130;
        }
        return 0;
    }
}

/// Asks once for the Deepgram key so `rec transcribe` works without any
/// shell exports. Enter keeps whatever is configured; an environment key
/// wins over the stored one and makes this step a no-op.
fn askDeepgramKey(io: std.Io, gpa: std.mem.Allocator, config_dir: []const u8) void {
    printOut(io, "\nA transcrição usa a API da Deepgram.\n");
    if (llm.envValue("DEEPGRAM_API_KEY")) |k| {
        if (k.len > 0) {
            printOut(io, "DEEPGRAM_API_KEY já vem do ambiente; nada a configurar aqui.\n");
            return;
        }
    }
    const stored = transcribe.loadStoredKey(io, gpa, config_dir);
    defer if (stored) |s| gpa.free(s);

    printOut(io, "Cole sua Deepgram API key");
    if (stored != null) printOut(io, " (Enter mantém a atual)");
    printOut(io, " [https://console.deepgram.com]: ");

    var line_buf: [256]u8 = undefined;
    const line = readLine(&line_buf) orelse return;
    const key = std.mem.trim(u8, line, " \t");
    if (key.len == 0) return;
    if (transcribe.storeKey(io, gpa, config_dir, key)) {
        printOut(io, "Chave salva em ");
        printOut(io, config_dir);
        printOut(io, "/deepgram_key\n");
    } else {
        printOut(io, "Não consegui salvar a chave.\n");
    }
}

/// Which backend drives the claude binary. Non-Anthropic providers need their
/// API key exported in the environment — exactly the prerequisite the
/// claudeseek/claudezai functions rely on — so the choice is refused here,
/// with the requirement spelled out, when the key is absent.
fn chooseProvider(io: std.Io) ?llm.Provider {
    const options = [_]llm.Provider{ .anthropic, .deepseek, .zai };
    while (true) {
        printOut(io, "\nQual provedor usa o Claude Code?\n");
        for (options, 1..) |p, n| {
            var row: [160]u8 = undefined;
            const need = if (p.keyEnvName()) |k| std.fmt.bufPrint(&row, "  {d}. {s} (precisa de {s} no ambiente)\n", .{ n, p.label(), std.mem.span(k) }) catch continue
            else std.fmt.bufPrint(&row, "  {d}. {s}\n", .{ n, p.label() }) catch continue;
            printOut(io, need);
        }
        printOut(io, "  q. voltar\n");

        var line_buf: [64]u8 = undefined;
        const line = readLine(&line_buf) orelse return null;
        if (isQuit(line)) return null;

        const pick = parseChoice(line, options.len) orelse {
            printOut(io, "Opção inválida.\n");
            continue;
        };
        const p = options[pick - 1];
        if (p.keyEnvName()) |key| {
            if (llm.envValue(key) == null) {
                printOut(io, "\nPara usar ");
                printOut(io, p.label());
                printOut(io, " você precisa ter a chave exportada no shell, ex.:\n\n  export ");
                printOut(io, std.mem.span(key));
                printOut(io, "=sk-...\n\n");
                printOut(io, "É a mesma variável que as funções claudeseek/claudezai do seu .zshrc usam.\n");
                continue;
            }
        }
        return p;
    }
}

/// Model selection UI + live validation + persistence. Returns false when the
/// user cancelled; failed validations loop back into the menu.
fn chooseModelAndSave(
    io: std.Io,
    gpa: std.mem.Allocator,
    config_dir: []const u8,
    harness: llm.Harness,
    bin_path: []const u8,
    provider: llm.Provider,
) bool {
    var listed = llm.listModels(io, gpa, bin_path, harness.kind) catch std.ArrayList([]u8).empty;
    defer llm.freeTemplateNames(gpa, &listed);

    while (true) {
        printOut(io, "\nModelos em ");
        printOut(io, harness.label());
        if (provider != .anthropic) {
            printOut(io, " (");
            printOut(io, provider.label());
            printOut(io, ")");
        }
        printOut(io, ":\n");
        printOut(io, "  d. padrão da conta do harness\n");
        for (listed.items, 1..) |m, n| {
            var row: [192]u8 = undefined;
            const row_s = std.fmt.bufPrint(&row, "  {d}. {s}\n", .{ n, m }) catch continue;
            printOut(io, row_s);
        }
        if (listed.items.len == 0) {
            const offset = listed.items.len + 1;
            for (llm.curatedModels(harness.kind, provider), 0..) |m, i| {
                var row: [192]u8 = undefined;
                const n = offset + i;
                const row_s = std.fmt.bufPrint(&row, "  {d}. {s}  (sugestão)\n", .{ n, m }) catch continue;
                printOut(io, row_s);
            }
        }
        printOut(io, "  o. outro id de modelo (digitado)\n");
        printOut(io, "  q. voltar\n");

        var line_buf: [128]u8 = undefined;
        const line = readLine(&line_buf) orelse return false;

        var chosen_model_buf: [200]u8 = undefined;
        var chosen_model: ?[]const u8 = null;
        if (isQuit(line)) return false;

        if (eql(line, "d")) {
            chosen_model = "";
        } else if (eql(line, "o")) {
            printOut(io, "Id do modelo (ex.: ");
            printOut(io, hintExample(harness.kind));
            printOut(io, "): ");
            var typed = readLine(&chosen_model_buf) orelse return false;
            typed = std.mem.trim(u8, typed, " \t");
            if (typed.len == 0) {
                printOut(io, "Id vazio.\n");
                continue;
            }
            chosen_model = typed;
        } else {
            const max_choice = listed.items.len + llm.curatedModels(harness.kind, provider).len;
            const pick = parseChoice(line, max_choice) orelse {
                printOut(io, "Opção inválida.\n");
                continue;
            };
            if (pick <= listed.items.len) {
                chosen_model = listed.items[pick - 1];
            } else {
                chosen_model = llm.curatedModels(harness.kind, provider)[pick - listed.items.len - 1];
            }
        }

        const model_ref = chosen_model.?;
        if (ping(io, gpa, harness.kind, bin_path, model_ref, provider)) {
            persist(io, gpa, config_dir, harness.kind, model_ref, provider);
            return true;
        }
        printOut(io, "Escolha outro modelo ou digite um id diferente.\n");
    }
}

/// One real round-trip with exactly this harness+model pair; prints nothing.
fn ping(
    io: std.Io,
    gpa: std.mem.Allocator,
    kind: llm.Kind,
    bin_path: []const u8,
    model: []const u8,
    provider: llm.Provider,
) bool {
    var note: [llm.max_note_bytes]u8 = undefined;
    var note_len: usize = 0;
    const outcome = llm.run(
        io,
        gpa,
        kind,
        bin_path,
        model,
        provider,
        probe_prompt,
        llm.probe_timeout_ns,
        &note,
        &note_len,
    );
    if (outcome) |inv_var| {
        var inv = inv_var;
        inv.deinit();
        return true;
    } else |err| {
        // Surface through stdout (setup has no stderr-only contract).
        printOut(io, "     ✗ indisponível (");
        printOut(io, llm.failurePhrase(err));
        if (note_len > 0) {
            printOut(io, ": ");
            printOut(io, note[0..note_len]);
        }
        printOut(io, ")\n");
        return false;
    }
}

fn persist(io: std.Io, gpa: std.mem.Allocator, config_dir: []const u8, kind: llm.Kind, model: []const u8, provider: llm.Provider) void {
    llm.saveConfig(io, gpa, config_dir, .{ .harness = kind, .model = model, .provider = provider }) catch {
        printOut(io, "\nNão consegui gravar ");
        printOut(io, config_dir);
        printOut(io, "/config.json\n");
        return;
    };
    printOut(io, "\nConfiguração salva em ");
    printOut(io, config_dir);
    printOut(io, "/config.json\n");
    printOut(io, "A partir de agora `rec transcribe` refina automaticamente e `rec format`\n");
    printOut(io, "estrutura transcrições usando este modelo");
    if (provider != .anthropic) {
        printOut(io, " via ");
        printOut(io, provider.label());
    }
    printOut(io, ".\n");
}

fn hintExample(kind: llm.Kind) []const u8 {
    return switch (kind) {
        .claude => "sonnet",
        .codex => "gpt-5-codex",
        .opencode => "anthropic/claude-sonnet-4-5",
        .pi => "anthropic/claude-opus-4-6",
        .gemini => "gemini-2.5-pro",
    };
}

// --- output helpers ---------------------------------------------------------

fn printOut(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

// --- stdin helpers ----------------------------------------------------------

/// One cooked-mode line from stdin (the kernel handles echo/editing); null at
/// EOF. Bytes land in `buf`; the caller must keep it alive while using the
/// returned slice.
pub fn readLine(buf: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var byte: [1]u8 = undefined;
        if (!keys.readByte(&byte[0])) {
            if (n == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] != '\r') {
            buf[n] = byte[0];
            n += 1;
        }
    }
    return buf[0..n];
}

fn isQuit(line: []const u8) bool {
    return eql(line, "q") or eql(line, "Q") or eql(line, "sair");
}

fn parseChoice(line: []const u8, max: usize) ?usize {
    if (line.len == 0) return null;
    const v = std.fmt.parseInt(usize, line, 10) catch return null;
    if (v < 1 or v > max) return null;
    return v;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
