# Filesystem and update audit (baseline 1a21cf271f98)

## Scope
- Recording library scanning, path joining, and selection resolution: `src/library.zig`.
- OKF note rendering (frontmatter/body construction, no filesystem I/O of note): `src/okf.zig`.
- Self-update: version check, download, and on-disk replacement of the running binary: `src/update.zig`.
- Shell installer: `install.sh`.
- Audio container handling: `src/m4a.zig` (macOS AudioToolbox bindings), `src/wav.zig` (RIFF/PCM16 parser and streaming writer), `src/audio_notes.zig` (transcript/notes document paths and loading).
- Supporting call sites read to establish provenance of path inputs: `src/record.zig` (temp-file/rename publish path), `src/playback.zig`, `src/cut.zig`, `.github/workflows/release.yml`.
- Not inspected: `zig build`/test execution (toolchain unavailable on this host, per node instructions — all findings below are static-source analysis); Windows-only code paths (`MoveFileExW` dance in `update.zig`) beyond reading the source, since there is no Windows host to exercise TOCTOU timing on; `install.ps1` (not in the read set and not requested); LLM/transcription HTTP code (out of this node's scope).

## Summary
- critical: 0 · major: 3 · minor: 2

## FINDING-UPD-01: Self-update replaces the running binary with an unverified download
- **Severity:** major
- **Class:** security
- **Location:** `src/update.zig:254`
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
- **Failure mode:** `downloadTo` (src/update.zig:302-331) fetches `r.url` — the `browser_download_url` a GitHub API JSON response supplied (src/update.zig:189-198) — straight into `tmp` via `curl -fsSL`, and `apply()` renames whatever bytes arrived directly over the live executable. Nothing in this path checks a checksum, a detached signature, or any second, independently-rooted trust anchor against the downloaded bytes; `curl -f` only guarantees a 2xx HTTP status, not that the payload is the artifact the project actually built. This runs unattended: `autoCheck` (src/update.zig:77-92) invokes the identical `checkAndApply`/`apply` path once a day before ordinary commands, with no user confirmation, so any entity able to place a file at that URL and answer with 2xx — a compromised release upload, a compromised or reissued TLS-terminating proxy/CA trusted by the host, or a compromised GitHub token used by the release workflow — gets its bytes executed as `rec` on the next invocation.
- **Impact:** Untrusted-code execution on every machine that runs `rec` if the release pipeline, the GitHub account publishing it, or the client's trust store is ever compromised, with no independent verification step to catch a tampered artifact before it replaces the binary the user runs daily.
- **Suggested fix:** Publish a signature (e.g. minisign/cosign) or checksum file alongside each release asset, embed the corresponding public key or a pinned checksum source in the client, and verify it in `apply()` before `renameAbsolute`/`MoveFileExW`, failing closed (returning `.apply_failed`) on any mismatch.

## FINDING-INST-01: install.sh installs the release binary with no integrity check
- **Severity:** major
- **Class:** security
- **Location:** `install.sh:42`
- **Evidence:**
  ```
  tmp_bin="$(mktemp)"
  trap 'rm -f "$tmp_bin"' EXIT

  echo "Downloading ${download_url}..."
  curl -fsSL -o "$tmp_bin" "$download_url"
  # mktemp creates the file 0600 and `chmod +x` honours the umask, which leaves
  # the install at 0711: every user but the installing one loses read access to
  # a binary whose whole point is to sit on a shared PATH.
  chmod 755 "$tmp_bin"
  ```
- **Failure mode:** `download_url` is scraped out of the same unauthenticated `curl | grep | sed` pipeline against the GitHub releases API (install.sh:30-35), and the fetched bytes are `chmod 755`'d and moved straight to `${INSTALL_DIR}/rec` (install.sh:56-61) — then executed immediately (`"$dest" --help`, install.sh:76) — with no checksum or signature check anywhere in the script. This script is the one the README's `curl -fsSL .../install.sh | sh` one-liner runs, so the same untrusted-artifact problem as FINDING-UPD-01 exists at first-install time, before the client-side updater in `src/update.zig` is ever reached.
- **Impact:** A tampered release asset (compromised publishing credentials, compromised CDN/redirect target behind `browser_download_url`, or a MITM against a host with a rogue trusted CA) is installed and executed with no independent verification, on the very first run of the tool.
- **Suggested fix:** Have the release workflow publish a checksum or signature file next to each binary asset, and have `install.sh` download and verify it (e.g. `sha256sum -c` against a value fetched over the same API response, or a signature check) before `chmod`/`mv`, aborting the install on failure.

## FINDING-UPD-02: Update temp file is deleted then recreated without O_EXCL, opening a symlink race in shared install directories
- **Severity:** minor
- **Class:** security
- **Location:** `src/update.zig:251`
- **Evidence:**
  ```
  // Leftovers of an interrupted previous update must not block this one.
  std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
  if (builtin.os.tag == .windows) std.Io.Dir.cwd().deleteFile(io, old) catch {};

  if (!downloadTo(io, gpa, url, tmp, verbose)) return false;
  ```
- **Failure mode:** `tmp` is the fixed, predictable path `"<exe>.update.tmp"` (src/update.zig:244-245). `deleteFile` unlinks whatever is at that path (following no symlink, since unlink never does), but the subsequent `downloadTo` writes to the same path through `curl -o <tmp>` (src/update.zig:303-307), and `curl`'s `-o` opens the destination with `O_CREAT` but not `O_EXCL`, so it follows a symlink placed at `tmp` in the window between the `deleteFile` and curl's own `open()`. In any install location where another local principal can write next to the `rec` binary (a shared `INSTALL_DIR` such as a group-writable `/opt/tools/bin` or a shared `$HOME/.local/bin` on a multi-user host), that principal can pre-plant `<exe>.update.tmp` as a symlink to an arbitrary file; the next `rec update` (or the silent daily `autoCheck`) then has curl overwrite the symlink's target with the downloaded release bytes, and `setPermissions(..., 0o755)` (src/update.zig:261) makes that arbitrary target executable.
- **Impact:** Local privilege abuse / arbitrary-file-overwrite in shared-directory installs: another local user can turn `rec`'s own self-update into a primitive that overwrites and `chmod 755`s a file of their choosing, provided they can write in the executable's directory.
- **Suggested fix:** Create the temp file with `O_CREAT | O_EXCL` (or the platform equivalent) instead of deleting-then-letting-curl-recreate, or write to a per-run unique filename and require the directory permissions be checked before writing there.

## FINDING-REC-01: Concurrent recordings started in the same second corrupt or silently overwrite each other
- **Severity:** major
- **Class:** bug
- **Location:** `src/wav.zig:182`
- **Evidence:**
  ```
  fn openNew(path: [*:0]const u8) c_int {
      if (is_windows) return _open(path, create_write_flags, @as(c_uint, 0o600)); // _S_IREAD|_S_IWRITE
      return open(path, create_write_flags, @as(c_uint, 0o644));
  }
  ```
  ```
  pub const create_write_flags: c_int = if (is_windows)
      0x0001 | 0x0100 | 0x0200 | 0x8000 // _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY
  else
      @bitCast(std.posix.O{
          .ACCMODE = .WRONLY,
          .CREAT = true,
          .TRUNC = true,
      });
  ```
- **Failure mode:** `record.zig`'s filename comes only from `localTimestamp` at one-second resolution — `YYYYMMDD-HHMMSS` (src/record.zig:406-420) — with no uniqueness suffix, lock file, or `O_EXCL` collision check anywhere in the write path; `create_write_flags` above is `O_WRONLY | O_CREAT | O_TRUNC` with no `O_EXCL`. Two `rec record` invocations started within the same wall-clock second (two terminal panes, a retried script, a hotkey double-fire) compute the identical `temp_path` (`<timestamp>.wav.part`) and identical final `path` (`<timestamp>.wav`). Both `Encoder.init` calls `openNew` the same `temp_path` with `O_TRUNC` and no exclusivity, so whichever opens second truncates the first process's in-progress audio out from under it; at the end, `publish()` (src/record.zig:328) renames each process's temp file onto the same shared final `path`, so whichever process finishes its `rename` last silently replaces the other's completed recording with no warning, prompt, or error surfaced to either user.
- **Impact:** Silent data loss of a completed recording (a good file is overwritten by an unrelated, possibly shorter or corrupted one) with no error reported to the user who made the recording that was destroyed — the opposite of the "finish-before-expose" guarantee the code comment at record.zig:321-323 claims for the single-recorder case.
- **Suggested fix:** Include a per-process uniqueness component in the filename (PID, a counter, or sub-second precision) and/or open the temp file with `O_EXCL` so a same-second collision fails loudly instead of truncating another recorder's data.

## FINDING-LIB-01: WAV recordings and update state are created world-readable by default
- **Severity:** minor
- **Class:** robustness
- **Location:** `src/wav.zig:184`
- **Evidence:**
  ```
  fn openNew(path: [*:0]const u8) c_int {
      if (is_windows) return _open(path, create_write_flags, @as(c_uint, 0o600)); // _S_IREAD|_S_IWRITE
      return open(path, create_write_flags, @as(c_uint, 0o644));
  }
  ```
- **Failure mode:** Every WAV recording (the default format on Linux/Windows per `src/okf.zig:22`) and its `.part` temp file during capture are created with mode `0o644`, world-readable modulo umask — unlike the Windows branch two lines above it, which explicitly requests `0600`/owner-only. A default `umask 022` leaves the file readable by every other local account on a shared machine for as long as the recording exists, including while it is still an in-progress `.part` file.
- **Impact:** On a multi-user host, any other local user can read another user's voice recordings (and, by extension, whatever transcripts/notes get derived from them) without needing any additional privilege, simply by listing `$HOME/recordings` if that directory itself is traversable (default `mkdir` permissions are similarly permissive) or by knowing the timestamp-derived filename.
- **Suggested fix:** Open WAV files (and the recordings directory) with an explicit `0600`/`0700` mode on POSIX, matching the `0600` behavior already used for Windows in the line directly above.

## Areas checked with no significant finding
- **Path construction and traversal in the recording library:** `library.recordingPath` (src/library.zig:71-86) bounds-checks every length before copying and never accepts a name longer than the caller's buffer; `library.resolveName` (src/library.zig:168-184) only ever returns a name that already exists in the scanned directory listing (or a literal digit index into it) — verified the one real call site, `playback.playSelection` → `audio_notes.Session.init` (src/playback.zig:63, src/playback.zig:193), always passes a `resolveName`-derived name, so no attacker-controlled path segment (e.g. `../`) reaches `audio_notes.zig`'s `std.fmt.allocPrint(gpa, "{s}/{s}.md", ...)` document-path construction.
- **WAV/M4A container parsing against attacker-controlled sizes:** `wav.parseWav` (src/wav.zig:124-158) and `library.parseDurationPrefix` (src/library.zig:270-311) both clamp every declared chunk size to the bytes actually present (`@min(size, image.len - body)` / `@min(size, present)`) before slicing, and their chunk-walking loop always advances (`next = off + 8 + size + ...` is strictly greater than `off`), so a crafted `RIFF` header with an oversized `data` chunk size cannot produce an out-of-bounds slice or an infinite loop. M4A parsing (`src/m4a.zig`) is delegated entirely to macOS's `ExtAudioFile`/`AudioFile` system APIs — this project's own code never walks the MP4 box structure, so a malformed `.m4a` is a system-framework concern, not an in-repo buffer-safety concern.
- **Good-data-not-replaced-by-partial-data in the single-recorder case:** `record.zig`'s `publish()` (src/record.zig:307-338) only renames the temp file onto the public name after `encoder.finish()` succeeds, and every early-return path (`init` failure, `write` failure, `finish` failure) deletes the temp file and never touches the public path — so a single interrupted recording never leaves a truncated file where a good one was (see FINDING-REC-01 for the concurrent-process case, which this single-process analysis does not cover).
- **`extractRelease`'s JSON handling:** `src/update.zig:167-201` only trusts fields it explicitly type-checks (`.string`/`.array`/`.object` on every field access) and returns `null` on any other shape, so a malformed or adversarial GitHub API response cannot desync the parser or read past a missing field — it degrades to "no update," not a crash or a wrong URL.
