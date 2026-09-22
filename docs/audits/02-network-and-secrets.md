# Network and secrets audit (baseline 1a21cf271f98)

## Scope
- Deepgram key handling and request construction: `src/transcribe.zig` (curl argv, response parsing, stored-key file).
- LLM harness key handling and request construction: `src/llm.zig` (DEEPSEEK_API_KEY / ZAI_API_KEY, provider env, child argv, output/timeout bounds).
- Self-update network calls: `src/update.zig` (GitHub Releases API fetch, asset download, binary replacement).
- Sharing/clipboard subprocess calls: `src/share.zig`, `src/sharecmd.zig`.
- Callers that source the Deepgram key from the environment/config and print diagnostics: `src/transcribecmd.zig`, `src/setupcmd.zig`, `src/main.zig`, `src/audio_notes.zig`.
- Cross-checked `std.process.run`'s actual default behavior (timeout/size limits) against `/home/frb/.local/opt/zig-x86_64-linux-0.16.0/lib/std/process.zig` to confirm which defaults `transcribe.zig` and `update.zig` inherit.
- Not inspected: the Deepgram/GitHub services themselves (out of repo control); the Zig standard library's TLS/curl internals beyond confirming curl is invoked without `-k`/`--insecure`; harness CLI binaries (`claude`, `codex`, etc.) are treated as trusted external tools per `keyEnvName()`'s own comment that the key "must be exported when rec runs".

## Summary
- critical: 1 · major: 2 · minor: 1

## FINDING-NS-01: Deepgram API key placed on curl's argv, visible via `ps`/`/proc`
- **Severity:** critical
- **Class:** security
- **Location:** `src/transcribe.zig:152-173`
- **Evidence:**
  ```
  const auth_header = std.fmt.allocPrint(gpa, "Authorization: Token {s}", .{api_key}) catch return error.OutOfMemory;
  defer gpa.free(auth_header);
  ...
  const argv = [_][]const u8{
      curl_path,
      "-fsS",
      "-X",
      "POST",
      "-H",
      auth_header,
      "-H",
      content_type_header: {
          var buf: [32]u8 = undefined;
          break :content_type_header std.fmt.bufPrint(&buf, "Content-Type: {s}", .{contentTypeFor(wav_abs_path)}) catch unreachable;
      },
      "--data-binary",
      data_arg,
      url,
  };
  ```
- **Failure mode:** `transcribe()` passes the full `Authorization: Token <DEEPGRAM_API_KEY>` string as a literal element of curl's `argv`. `std.process.run` spawns curl with `execve`, so for the lifetime of the request (which, per FINDING-NS-02, has no timeout and can run for as long as the upload/response takes) the plaintext key is visible to any local user or process that can read `/proc/<pid>/cmdline` or run `ps auxww` on the same host — including other users on a shared machine, container sidecars, crash/monitoring agents, and shell history tools that snapshot process lists.
- **Impact:** Full disclosure of the user's Deepgram API key to any local observer of the process table while `rec transcribe` is running, without needing file-system access to the `deepgram_key` file (which is correctly written 0600) or to the environment.
- **Suggested fix:** Do not put the Authorization header value on argv. Write it to a curl config passed via `-K -`/`--config` (or a temporary 0600 header file consumed with curl's `@file` header syntax) fed over stdin/a restricted-permission temp file instead of as a command-line argument, mirroring the 0600 handling already used for `storeKey` in the same file.

## FINDING-NS-02: Deepgram request has no timeout, so `rec transcribe` can hang forever
- **Severity:** major
- **Class:** robustness
- **Location:** `src/transcribe.zig:158-184`
- **Evidence:**
  ```
  const argv = [_][]const u8{
      curl_path,
      "-fsS",
      "-X",
      "POST",
      "-H",
      auth_header,
      ...
  };
  ...
  const result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
      error.OutOfMemory => return error.OutOfMemory,
      // Limits are unlimited and no timeout is set, so every remaining
      // error means curl itself could not be launched or its streams broke.
      else => return error.CurlSpawnFailed,
  };
  ```
- **Failure mode:** The curl argv carries no `--max-time`/`--connect-timeout`, and the `std.process.run(gpa, io, .{ .argv = &argv })` call passes no `timeout` field, so `RunOptions.timeout` defaults to `.none` (confirmed in `lib/std/process.zig:485`). A stalled TCP connection, a slow-loris response from a compromised/MITM endpoint, or a Deepgram outage that accepts the connection but never completes the response leaves `rec transcribe` blocked indefinitely with no way for the user to know it is hung versus still uploading. This is the same class of bug `src/update.zig:218` and `:307` already guard against with an explicit `--max-time` argument, confirming the omission here is inconsistent with the rest of the codebase rather than intentional.
- **Impact:** A single unresponsive or malicious network peer can wedge the `transcribe` command (and, via `audio_notes.zig`, whatever background job drives it) with no bound, forcing the user to kill the process manually.
- **Suggested fix:** Add `--max-time` to the curl argv (as `update.zig` does) and/or pass a `timeout` in the `std.process.run` call.

## FINDING-NS-03: Deepgram response body is read with no size limit
- **Severity:** major
- **Class:** robustness
- **Location:** `src/transcribe.zig:179-198`
- **Evidence:**
  ```
  const result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
      error.OutOfMemory => return error.OutOfMemory,
      else => return error.CurlSpawnFailed,
  };
  defer gpa.free(result.stdout);
  defer gpa.free(result.stderr);
  ...
  out.json.appendSlice(gpa, result.stdout) catch return error.OutOfMemory;
  ```
- **Failure mode:** `RunOptions.stdout_limit`/`stderr_limit` default to `.unlimited` (`lib/std/process.zig:460-461`), and this call site sets neither, so curl's entire stdout is buffered in memory before `transcribe()` ever sees it, then copied again into `out.json`. Any endpoint able to answer the POST — a compromised Deepgram deployment, a captured DNS/proxy redirection to an attacker-controlled HTTPS host presenting a trusted certificate, or simply a buggy Deepgram response — can return an arbitrarily large body and force `rec` to allocate without bound, unlike `llm.zig`'s harness calls which cap output at `max_output_bytes` (8 MiB, `src/llm.zig:515`) via `drainPipe`'s explicit `cap` check.
- **Impact:** Unbounded memory growth / OOM kill of the `rec` process from an oversized HTTP response, with no cap analogous to the one already used for LLM harness output.
- **Suggested fix:** Pass an explicit `stdout_limit`/`stderr_limit` (e.g. `Io.Limit` sized like `llm.zig`'s `max_output_bytes`) to `std.process.run`, or add curl's `--max-filesize`/read the body through a size-capped path as `llm.zig` does for the harness children.

## FINDING-NS-04: Self-update replaces the running binary with no integrity check on the downloaded asset
- **Severity:** minor
- **Class:** security
- **Location:** `src/update.zig:254-263`
- **Evidence:**
  ```
  if (!downloadTo(io, gpa, url, tmp, verbose)) return false;

  if (builtin.os.tag != .windows) {
      // curl writes 0644 through the umask; the replacement must stay
      // executable. Windows has no exec bit.
      var file = std.Io.Dir.cwd().openFile(io, tmp, .{}) catch return fail(io, tmp);
      defer file.close(io);
      file.setPermissions(io, @enumFromInt(0o755)) catch {};
      std.Io.Dir.renameAbsolute(tmp, exe, io) catch return fail(io, tmp);
      return true;
  }
  ```
- **Failure mode:** `apply()` downloads the asset URL taken verbatim from the GitHub Releases API JSON (`extractRelease`, `src/update.zig:167-201`) and, once curl exits 0, marks the file executable and renames it directly over the running binary — there is no checksum or signature comparison anywhere in `update.zig` (confirmed by grep: no `sha256`/`checksum`/`signature`/`verify` token in the file) before the swap. If a release asset is ever served or cached incorrectly (e.g. a compromised publishing token used to overwrite a release asset, or a poisoned CDN edge/cache in front of `objects.githubusercontent.com`), `rec` installs and later executes that binary with no independent integrity check, silently.
- **Impact:** A tampered release asset becomes trusted, persisted code executed on every future `rec` invocation, with the only protection being transport-level TLS to GitHub/its CDN.
- **Suggested fix:** Verify the downloaded asset against a checksum or signature published alongside the release (e.g. a `.sha256`/detached signature asset) before renaming it over the running executable.

## Areas checked with no significant finding
- **LLM harness key transport (`src/llm.zig:659-699`):** `DEEPSEEK_API_KEY`/`ZAI_API_KEY` are read once via `envValue()` and placed only into a child `Environ.Map` (`ANTHROPIC_AUTH_TOKEN`) passed through `std.process.spawn`'s `.environ_map`; the key is never interpolated into `argv` or into any printed diagnostic (`note_buf`, error branches), so it does not reach `ps`, crash output, or the rendered UI.
- **LLM harness timeout/output bounds (`src/llm.zig:636`, `:748-760`, `:773`, `:878-881`):** every path enforces `max_prompt_bytes` on input, a hard wall-clock `deadline` checked in both the POSIX poll loop and the Windows `WaitForSingleObject` loop, and `max_output_bytes`/`max_note_bytes` caps on stdout/stderr via `drainPipe`'s explicit `cap` check — this is the pattern FINDING-NS-02/03 shows is missing in `transcribe.zig`.
- **TLS/redirect posture of all curl invocations (`src/transcribe.zig:159-173`, `src/update.zig:218`, `:307`):** none pass `-k`/`--insecure`, so default certificate verification stays on; `transcribe.zig`'s curl call has no `-L`, so it cannot silently follow a redirect to an attacker host, and `update.zig`'s `-L` is bounded to the fixed, HTTPS-only `api.github.com` and `browser_download_url` values from a trusted API response.
- **Deepgram/LLM JSON response parsing (`src/transcribe.zig:72-116`, `src/llm.zig` gemini branch at `:1065-1075`):** both use `std.json.parseFromSlice`/`parseFromSliceLeaky` with `.ignore_unknown_fields = true` into narrow structs with defaulted optional fields, so malformed or unexpected JSON shapes deterministically fall through to `error.BadResponse`/`error.NoSpeech` (or, for gemini, fall back to raw stdout) rather than panicking or indexing out of bounds; `test "parse rejects malformed json distinctly from silence"` and `test "missing, absent, and empty utterance lists all mean no speech"` in `transcribe.zig` exercise this directly.
- **Stored Deepgram key file (`src/transcribe.zig:307-347`):** written with an explicit `0o600` `Permissions` value (not relying on umask subtraction alone) and read back through a `.limited(4096)` allocation, so it cannot be over-read or left world-readable on POSIX.
- **Retry/duplicate-side-effect risk (`src/update.zig:42-127`, `src/transcribe.zig:147-199`):** neither the transcription POST nor the self-update check/download/apply path retries automatically on failure — each is a single attempt that returns an error to the caller — so there is no risk of a hidden retry duplicating the Deepgram POST or re-applying an update.
- **Share/clipboard subprocesses (`src/share.zig:24-88`, `src/sharecmd.zig`):** `openUrl`'s `argv` destinations are fixed string literals selected by an enum (`Destination`), never built from network or transcript content, and `copyText`'s child receives untrusted transcript text only over its stdin pipe, never as an argv element, so there is no argv-injection path from transcript/network content here.
