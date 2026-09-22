# Addendum to the rec audit synthesis

This addendum accompanies the `rec-audit-remediation` campaign. It corrects
three factual errors in `docs/audits/AUDIT-REPORT.md` that an independent review
found, and records three findings that the audit missed. The original document
is the historical record of what the audit found at baseline
`1a21cf271f98690ef93e09306e7ed9169a444f0f` and is not edited.

All line numbers below are from the remediation worktree (post-fix), not from
the baseline.

## Corrections

### C1. The de-duplication accounting undercounts and omits a critical

The synthesis says "All 25 findings across the six surface reports are accounted
for: 21 are retained 1:1 as FINDING-SYNTH-01, -02, -03, -05, -06, -07, -08,
-10, -11, -12, -13, -14, -15, -16, -17, -18, -19". The six surface reports hold
**22** findings, not 25:

| surface report | findings | count |
|---|---|---|
| `01-cli-and-input.md` | CLI-01..CLI-04 | 4 |
| `02-network-and-secrets.md` | NS-01..NS-04 | 4 |
| `03-filesystem-and-update.md` | UPD-01, UPD-02, INST-01, REC-01, LIB-01 | 5 |
| `04-audio-memory-safety.md` | AUD-01, AUD-02 | 2 |
| `05-terminal-and-rendering.md` | TERM-01..TERM-03 | 3 |
| `06-build-and-supply-chain.md` | BSC-01..BSC-04 | 4 |

Four findings (NS-04, UPD-01, INST-01, BSC-03) are merged into FINDING-SYNTH-09,
so **18** are retained 1:1, not 21. The enumerated id list also skips
**FINDING-SYNTH-04** (BSC-01, the unauthenticated Sentrux download, a critical),
which is neither merged into FINDING-SYNTH-09 nor one of the four merge inputs
and therefore has to appear in the 1:1 list.

### C2. FINDING-SYNTH-02 describes the wrong tty check

FINDING-SYNTH-02 says the non-interactive playback path is "taken whenever
stdout/stdin is not a TTY". `playSelection` never tests stdout; it tests stdin
and stderr:

```zig
// src/playback.zig:100-104
const is_tty = blk: {
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
    break :blk stdin_tty and stderr_tty;
};
```

The path is taken whenever **stdin or stderr** is not a tty. The distinction
matters because a pipeline that merely redirects stdin (`rec play x </dev/null`)
still lands on the non-interactive path while stderr remains the user's
terminal.

### C3. FINDING-SYNTH-01's "the one place that does not" claim is false

FINDING-SYNTH-01 says every other fixed-buffer path join bounds-checks first and
that the `--out` copy "is the one place that does not". That was not true at
baseline: `src/llm.zig` used the same unchecked byte-copy primitive in
`configDirPath` and `joinPath`, on the wider surface of `XDG_CONFIG_HOME`/`HOME`
rather than one CLI flag (see A.6.1 below). The primitive is now checked for
every caller: `record.appendStr` returns `error.NoSpaceLeft`
(`src/record.zig:725-730`) and `llm.appendStr` returns `bool`
(`src/llm.zig:1142-1147`).

## Late findings the audit missed

### A.6.1: `XDG_CONFIG_HOME` overruns a stack buffer via `llm.configDirPath`/`joinPath`

- **Class:** security / memory safety
- **Location:** `src/llm.zig:230-252` (`configDirPath`), `src/llm.zig:1130-1141`
  (`joinPath`)
- **Why it matters:** both functions copied an environment-derived string into
  a caller-supplied fixed buffer with an unchecked byte loop. A
  `XDG_CONFIG_HOME` (or `HOME`) longer than the caller's
  `[std.Io.Dir.max_path_bytes]u8` buffer overran the stack in every command
  that resolves the config directory, template path, or `config.json` path, and
  `joinPath` is also reached from `loadTemplate` and `templatesDirPath`. This
  is reachable from the environment alone, with no CLI argument and no
  recording needed, which is why it is wider than FINDING-SYNTH-01.
- **Remediation in this campaign:** `appendStr` now refuses a write that does
  not fit and both builders return `null` on overflow; `formatcmd.run` handles
  the null with its own usage error instead of a corrupt buffer
  (`src/formatcmd.zig:90-97`). Tests: `llm.configDirPath refuses a value that
  does not fit` and `llm.joinPath refuses a value that does not fit`
  (`src/llm.zig:1202-1227`). The residual `.?` at
  `src/transcribecmd.zig:333` is recorded under "Not fixed here" in
  `docs/campaigns/rec-audit-remediation/REMEDIATION.md`.

### A.6.2: `rec transcribe --out` truncates the source recording

- **Class:** bug / data loss
- **Location:** `src/transcribecmd.zig:80-107` (`resolveOutPath`,
  `outIsRecording`), used at `src/transcribecmd.zig:190-208`
- **Why it matters:** the artifact write creates/truncates its target, so
  `rec transcribe <recording> --out <recording>` (or any spelling `realpath`
  maps to it) destroyed the recording it had just transcribed, with no
  confirmation and no error. The original report's FINDING-SYNTH-06 fixed the
  same guard in `rec format` but not in `rec transcribe`.
- **Remediation in this campaign:** the `--out` candidate and the recording are
  both resolved with `realPathFile`; when they name the same file the command
  prints `transcribe: --out não pode ser o próprio arquivo de entrada` and
  returns before any network request or write. Test:
  `transcribe out must not be the source recording`
  (`src/transcribecmd.zig:559-566`).

### A.6.3: `library.appendRow`'s 512-byte line is bounded only by NAME_MAX

- **Class:** robustness / memory safety
- **Location:** `src/library.zig:204-209` (`max_row_bytes`, `max_name_field`),
  `src/library.zig:261-289` (`appendRow`)
- **Why it matters:** `appendRow` copied a filesystem-derived name into a fixed
  `[512]u8` row with the same unchecked primitive, and the only thing keeping
  the copy in bounds was the assumption that a name cannot exceed NAME_MAX. On
  filesystems that allow long multi-byte names (a 255-character Windows name
  expanded to UTF-8 can exceed 512 bytes), that assumption fails and the row
  overruns the stack buffer `listRecordings` owns.
- **Remediation in this campaign:** the row is assembled in a private
  `[max_row_bytes]u8` staging buffer, the name is stripped of control bytes and
  clipped to `max_name_field = max_row_bytes - 128`, and the finished row is
  copied into the caller's buffer with `@min(n, buf.len)`. Tests:
  `library row never overruns its line buffer` and
  `library row filters control bytes in a filename`
  (`src/library.zig:532-550`).

## Verification

The three campaign gates and their exact invocations, and the reason the GNU
target is required on this machine, are recorded in
`docs/campaigns/rec-audit-remediation/REMEDIATION.md`, section "How this was
verified".
