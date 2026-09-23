# rec audit remediation

- Campaign: `rec-audit-remediation`
- Base commit: `3c7f5cb` (the audit branch this campaign was cut from)
- Audit baseline: `1a21cf271f98690ef93e09306e7ed9169a444f0f`, documented in `docs/audits/AUDIT-REPORT.md`
- Method: every row and every code quote below comes from the integrated diff
  `git diff 3c7f5cb..HEAD`. Nothing outside that diff is described as a fix.

## Findings

| id | severity | status | files changed | verification |
|---|---|---|---|---|
| FINDING-SYNTH-01 | critical | fixed | `src/transcribecmd.zig`, `src/record.zig` | `zig build test -Dtarget=x86_64-linux-gnu --summary all`; tests `transcribe out path must fit the buffer` and `record.appendStr refuses a buffer too small` |
| FINDING-SYNTH-02 | critical | fixed | `src/playback.zig`, `src/record.zig` | test `transcriptPath refuses a stem that does not fit` |
| FINDING-SYNTH-03 | critical | fixed | `src/transcribe.zig` | test `transcribe authorization never reaches argv` |
| FINDING-SYNTH-04 | critical | fixed | `.github/workflows/quality.yml` | no unit test; `sha256sum -c` on the pinned `SENTRUX_SHA256` before `chmod +x` (`quality.yml:23-33`) |
| FINDING-SYNTH-05 | major | fixed | `src/transcribe.zig` | tests `transcribe listen url rejects an injected language` and `transcribe listen url bounds the language parameter` |
| FINDING-SYNTH-06 | major | fixed | `src/formatcmd.zig` | test `format out refuses the same file spelled differently` |
| FINDING-SYNTH-07 | major | fixed | `src/transcribe.zig` | test `transcribe request argv bounds the wall clock` |
| FINDING-SYNTH-08 | major | fixed | `src/transcribe.zig` | test `transcribe response body is capped` |
| FINDING-SYNTH-09 | major | fixed | `src/update.zig`, `install.sh`, `install.ps1`, `.github/workflows/release.yml` | tests `update checksum text parses and rejects a mismatch`, `update rejects an untrusted download url`, `extractRelease answers null for unusable bodies` |
| FINDING-SYNTH-10 | major | fixed | `src/record.zig`, `src/wav.zig` | tests `recording stems stay unique when the second is taken` and `wav.create_write_flags is exclusive` |
| FINDING-SYNTH-11 | major | fixed | `src/wav.zig` | test `wav.finish releases the descriptor when the RIFF ceiling is hit` |
| FINDING-SYNTH-12 | major | fixed differently - filenames are stripped by a new shared `viewport.stripControls` helper, not by `deck.cleanTitle` | `src/library.zig`, `src/command_ui.zig`, `src/viewport.zig` | tests `library row filters control bytes in a filename` and `command output filters control bytes` |
| FINDING-SYNTH-13 | major | fixed | `src/markdown.zig`, `src/viewport.zig` | test `markdown non-tty output filters escapes` |
| FINDING-SYNTH-14 | major | fixed | `.github/workflows/release.yml` | no unit test; `pull-requests: write` scoped to the `release-please` job only |
| FINDING-SYNTH-15 | minor | fixed | `src/setupcmd.zig` | test `setup readLine drains an over-length line` |
| FINDING-SYNTH-16 | minor | fixed | `src/update.zig` | test `update temp path must be created exclusively` |
| FINDING-SYNTH-17 | minor | fixed | `src/wav.zig` | no dedicated mode assertion; `openNew` passes `0o600` (`src/wav.zig:196-201`) and `wav.create_write_flags is exclusive` exercises the same open path |
| FINDING-SYNTH-18 | minor | fixed | `src/viewport.zig` | test `viewport strips DEL like deck.cleanTitle` |
| FINDING-SYNTH-19 | minor | fixed | `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/quality.yml` | no unit test; every `uses:` line is pinned to a full commit SHA |
| A.6.1 | critical | fixed | `src/llm.zig` | tests `llm.configDirPath refuses a value that does not fit` and `llm.joinPath refuses a value that does not fit` |
| A.6.2 | major | fixed | `src/transcribecmd.zig` | test `transcribe out must not be the source recording` |
| A.6.3 | major | fixed | `src/library.zig` | test `library row never overruns its line buffer` |

## Change notes

### FINDING-SYNTH-01
`record.appendStr` is now a checked copy, so the `--out` join cannot overrun the
4096-byte stack buffer and its callers get a real error:

```zig
pub fn appendStr(buf: []u8, n: *usize, s: []const u8) error{NoSpaceLeft}!void {
    if (buf.len - n.* < s.len) return error.NoSpaceLeft;
    @memcpy(buf[n.*..][0..s.len], s);
    n.* += s.len;
}
```

`resolveOutPath` (src/transcribecmd.zig:80) uses `try record.appendStr(...)` and
the caller reports "transcribe: caminho de saída longo demais".

### FINDING-SYNTH-02
The sibling-transcript helper now propagates the checked copy instead of
truncating a filename:

```zig
record.appendStr(&md_name_buf, &md_len, library.stripExt(name)) catch return null;
record.appendStr(&md_name_buf, &md_len, ".md") catch return null;
```

### FINDING-SYNTH-03
The key is written to a fresh 0600 file beside the recording; curl receives only
`@<path>` as a `-H` argument, so the key never enters argv:

```zig
const secret_mode: std.Io.File.Permissions = @enumFromInt(0o600);
var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = secret_mode }) catch return null;
```

### FINDING-SYNTH-04
The Sentrux download is a pinned digest checked before the binary is made
executable:

```yaml
SENTRUX_SHA256: 3237f80fe20d54aad4deefa8a143f0d60543bb5d2d6ad891eb42432f155725a6
...
sha256sum -c - <<EOF
${SENTRUX_SHA256}  ${sentrux}
EOF
chmod +x "$sentrux"
```

### FINDING-SYNTH-05
`--language` is percent-encoded rather than spliced in raw, so a `&` cannot
inject another query parameter:

```zig
fn appendEncodedLanguage(buf: []u8, n: *usize, language: []const u8) void {
    ...
    buf[n.*] = '%';
    buf[n.* + 1] = hex[ch >> 4];
    buf[n.* + 2] = hex[ch & 0x0f];
```

### FINDING-SYNTH-06
The `--out` guard canonicalizes both sides before comparing:

```zig
fn outTargetsSource(io: std.Io, out: []const u8, source: []const u8) bool {
    if (std.mem.eql(u8, out, source)) return true;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_len = std.Io.Dir.cwd().realPathFile(io, out, &out_buf) catch return false;
    ...
```

### FINDING-SYNTH-07
curl gets a wall-clock bound and the run carries the same bound:

```zig
"--max-time",
std.fmt.comptimePrint("{d}", .{request_max_time_secs}),
...
.timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(request_max_time_secs), .clock = .real } },
```

### FINDING-SYNTH-08
The response body and stderr are capped instead of buffered without limit:

```zig
.stdout_limit = .limited(max_response_bytes),
.stderr_limit = .limited(max_response_bytes),
```

with `max_response_bytes = 8 * 1024 * 1024`, matching `llm.zig`.

### FINDING-SYNTH-09
The updater requires a trusted `<asset>.sha256` sibling and verifies the bytes
before renaming; both installers verify too, and the release workflow publishes
the checksum:

```zig
if (!isTrustedDownloadUrl(link)) return null;
...
if (!downloadTo(io, gpa, url, tmp, verbose)) return fail(io, tmp);
if (!verifyDownload(io, gpa, checksum_url, artifact, tmp, verbose)) return fail(io, tmp);
```

### FINDING-SYNTH-10
The WAV create is exclusive and a same-second recorder advances to the next
suffixed stem:

```zig
.O{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .TRUNC = true }
...
const stem = candidateStem(out, base, attempt);
if (!ctx.exists(stem)) return .{ .stem = stem, .attempt = attempt };
```

### FINDING-SYNTH-11
`finish()` closes the descriptor on every path before inspecting the status:

```zig
var failed = self.data_bytes > std.math.maxInt(u32) - 36;
if (!failed) { ... }
if (cclose(self.fd) != 0) failed = true;
if (failed) return error.FinalizeFailed;
```

### FINDING-SYNTH-12
The list row and command output strip control bytes through the shared filter:

```zig
const clean = viewport.stripControls(name, "", &name_buf);
...
std.Io.File.stderr().writeStreamingAll(io, filtered(text, &buf)) catch {};
```

### FINDING-SYNTH-13
The non-tty markdown branch runs the rendered document through the same filter
before writing:

```zig
write(io, filterForPipe(rendered, buf));
...
fn filterForPipe(rendered: []const u8, buf: []u8) []const u8 {
    return viewport.stripControls(rendered, "\n\t", buf);
}
```

### FINDING-SYNTH-14
`pull-requests: write` is no longer inherited by the build job:

```yaml
permissions:
  contents: read
...
  release-please:
    permissions:
      contents: write
      pull-requests: write
...
  build:
    permissions:
      contents: write
```

### FINDING-SYNTH-15
An over-length line is drained through its newline instead of leaking into the
next prompt:

```zig
} else {
    var discarded: [1]u8 = undefined;
    while (keys.readByte(&discarded[0])) {
        if (discarded[0] == '\n') break;
    }
}
```

### FINDING-SYNTH-16
The update temp file is created exclusively before curl is allowed to write it,
so a planted symlink fails the update instead of being followed:

```zig
pub fn tempCreateOptions() std.Io.Dir.CreateFileOptions {
    return .{ .exclusive = true, .truncate = false };
}
```

### FINDING-SYNTH-17
`openNew` requests owner-only mode on both platforms, matching the Windows
branch that already asked for 0600:

```zig
open(path, create_write_flags, @as(c_uint, 0o600));
```

### FINDING-SYNTH-18
The shared filter now drops byte 127 as well as the C0 controls:

```zig
if ((token[0] < 32 or token[0] == 127) and token[0] != '\t') continue;
```

### FINDING-SYNTH-19
Every third-party action is pinned to a commit SHA with a version comment:

```yaml
- uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
- uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2
```

### A.6.1
`llm.appendStr` now reports overflow and both path builders fail closed, which
closes the same primitive SYNTH-01/02 fixed at the wider `XDG_CONFIG_HOME`
surface:

```zig
if (!appendStr(buf, &n, root)) return null;
...
if (!appendStr(buf, &n, dir)) return null;
if (!appendStr(buf, &n, name)) return null;
```

### A.6.2
`--out` that resolves to the recording being transcribed is refused before any
request or write, using the already-resolved recording path:

```zig
fn outIsRecording(resolved_out: ?[]const u8, recording_abs: []const u8) bool {
    const out = resolved_out orelse return false;
    return std.mem.eql(u8, out, recording_abs);
}
```

### A.6.3
The row is assembled in a bounded staging buffer and the name field is capped,
so the 512-byte line no longer depends on NAME_MAX:

```zig
const max_row_bytes = 512;
const max_name_field = max_row_bytes - 128;
...
const field = @min(name_w, max_name_field);
const shown = clean[0..@min(clean.len, field)];
...
const copy = @min(n, buf.len);
@memcpy(buf[0..copy], row[0..copy]);
```

## Not fixed here

The follow-up contract described in the next section closed the three
non-Windows items this section used to list. One item remains open.

- **Windows-only self-update rename dance.** `src/update.zig:349-360` still
  swaps the running image with `MoveFileExW`, unchanged. No host in this
  campaign can execute Windows, so that path is code-reviewed only. The
  checksum check at `src/update.zig:337` runs before the platform split, so the
  downloaded bytes are verified on Windows too.

## Follow-up

The follow-up contract `rec-audit-remediation-hygiene` is integrated in this
branch. It closed the residuals above:

- **`rec play` no longer prints the rendered document unfiltered.** The
  non-interactive playback path now allocates a filter buffer and writes the
  filtered document (`src/playback.zig:117-128`), which routes
  `markdown.render` output through the shared control-byte filter:

  ```zig
  fn filterDocument(rendered: []const u8, buf: []u8) []const u8 {
      return viewport.stripControls(rendered, "\n\t", buf);
  }
  ```

  (`src/playback.zig:607-609`). Test: `playback non-interactive document is
  filtered` (`src/playback.zig:730-737`); the whole unit suite is run with
  `zig build test -Dtarget=x86_64-linux-gnu --summary all`.
- **`rec transcribe --refine` no longer unwraps the template directory.**
  `src/transcribecmd.zig:333-336` replaces the `.?` with a reported `orelse`:

  ```zig
  const templates_dir = llm.templatesDirPath(config_dir, &tpl_buf) orelse {
      ui.print(io, "refine: ignorado (sem diretório de templates)\n");
      return;
  };
  ```

  No dedicated unit test was added for this caller. The `null` it now handles
  is the one asserted by `llm.configDirPath refuses a value that does not fit`
  and `llm.joinPath refuses a value that does not fit` (`src/llm.zig:1202-1227`),
  and the branch is compiled and run by
  `zig build test -Dtarget=x86_64-linux-gnu --summary all`.
- **FINDING-SYNTH-17 now has a dedicated assertion.** `src/wav.zig:426-448`
  adds `wav.openNew creates owner-only files`, which opens through `openNew`
  and inspects the resulting POSIX mode:

  ```zig
  const fd = try openNew(path);
  ...
  try std.testing.expectEqual(
      @as(std.posix.mode_t, 0o600),
      @as(std.posix.mode_t, @intFromEnum(stat.permissions)) & 0o777,
  );
  ```

  `openNew` still creates with `0o600` (`src/wav.zig:196-201`), so the test
  proves the mode half that `wav.create_write_flags is exclusive` covered only
  indirectly. This closes the verification gap recorded in the
  FINDING-SYNTH-17 row of the table above.
- **Test artifacts no longer land in the tree.** `testDir` now resolves to
  `TMPDIR` or, on POSIX, the system temp directory `/tmp`
  (`src/wav.zig:305-318`), and `testPath` refuses the old working-directory
  fallback (`src/wav.zig:325-329`):

  ```zig
  const dir = testDir() orelse @panic("rec-wav tests: no temp directory available");
  return std.fmt.bufPrintZ(buf, "{s}/rec-wav-test-{d}{s}", .{ dir, pid, suffix }) catch unreachable;
  ```

  The test-hygiene node deleted every `rec-wav-test-*` path the first
  contract's seal committed (`rec-wav-test-11312.*` through
  `rec-wav-test-27757.*`); none of those paths are tracked in this branch. The
  two directories created by the follow-up's own pre-hygiene run,
  `rec-wav-test-3930.auth/` and `rec-wav-test-3930.cfg/`, were removed by the
  cleanup follow-up, so the branch carries no rec-wav-test path at all;
  with `testPath` fixed, the gate no longer recreates them.

## How this was verified

Three gates, all run from the repository root:

1. `zig build test -Dtarget=x86_64-linux-gnu --summary all` - compiles and runs
   the unit suite, which includes every test named in the table. The
   `-Dtarget=x86_64-linux-gnu` is required on this machine because a bare
   `zig build test` fails to link here: the Zig 0.16.0 objects carry `.sframe`
   relocations the host glibc/linker combination rejects. Naming the GNU target
   is a host workaround and changes nothing in the repository.
2. `sentrux check .` - absolute structural limits from `.sentrux/rules.toml`.
3. `sentrux gate .` - no structural regression against
   `.sentrux/baseline.json`.

The controller runs the first gate after this report; the two Sentrux gates run
in CI via `.github/workflows/quality.yml`, whose own Sentrux download is now
digest-verified (FINDING-SYNTH-04).
