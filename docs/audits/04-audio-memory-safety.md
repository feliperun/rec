# Audio core memory-safety audit (baseline 1a21cf271f98)

## Scope
- Inspected: `src/record.zig`, `src/capture.zig`, `src/playback.zig`, `src/cut.zig`,
  `src/spectrum.zig`, `src/visualizer.zig`, `src/waveform.zig`, `src/wav.zig`,
  `src/m4a.zig`, plus `src/library.zig`, `src/player.zig`, `src/deck.zig`,
  `src/style.zig`, and `src/spectrum_test.zig` for cross-references (untrusted
  filename/WAV-header flow, device-callback contracts, the fixed-size-buffer
  pattern the codebase otherwise uses).
- Traced two untrusted-length classes end to end: (1) WAV/M4A container header
  fields (`sample_rate`, `channels`, chunk `size`) from `wav.parseWav` and
  `library.parseDurationPrefix` through `cut.cutPcm`, `spectrum.Analysis.update`,
  and `waveform.Tracker`; (2) recording filenames from `library.scan` (no length
  cap — anything ending `.wav`/`.m4a` under `~/recordings/`) through
  `library.resolveName` into `playback.zig` and `deck.zig`.
- Reviewed `capture.zig`/`player.zig` miniaudio data-callback arithmetic
  (`frame_count`-driven byte counts) against the AGENTS.md gotcha about
  `@min`-narrowed intermediates overflowing a later multiply.
- Reviewed `defer`-scoping in `cut.zig`/`wav.zig`/`m4a.zig` against the
  documented ADR-0007 incident (a freed WAV image aliased by a live `pcm`
  slice) for any reintroduced instance.
- This is a static, source-level review only: the Zig toolchain is not
  installed on this host, so nothing here was compiled, run, or exercised
  against a live microphone/output device.
- Not inspected: the AudioToolbox/CoreFoundation internals `m4a.zig` calls
  into (its own parsing of an M4A/AAC container is Apple's system framework,
  outside this repository); `keys.zig`, `viewport.zig`, `live.zig`,
  `audio_notes.zig` bodies (only grepped for the same fixed-buffer pattern,
  not independently audited); the vendored `vendor/miniaudio.h` C source
  itself.

## Summary
- critical: 1 · major: 1 · minor: 0

## FINDING-AUD-01: Stack buffer overflow building the sibling-transcript path from an unbounded recording filename
- **Severity:** critical
- **Class:** bug / security
- **Location:** `src/playback.zig:577-583` (and the unchecked helper it calls, `src/record.zig:616-621`)
- **Evidence:**
  ```zig
  // src/playback.zig:577-583
  fn transcriptPath(recordings_path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
      var md_name_buf: [80]u8 = undefined;
      var md_len: usize = 0;
      record.appendStr(&md_name_buf, &md_len, library.stripExt(name));
      record.appendStr(&md_name_buf, &md_len, ".md");
      return library.recordingPath(recordings_path, md_name_buf[0..md_len], buf);
  }
  ```
  ```zig
  // src/record.zig:616-621
  pub fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
      for (s) |ch| {
          buf[n.*] = ch;
          n.* += 1;
      }
  }
  ```
- **Failure mode:** `library.scan` (`src/library.zig:109-150`) enumerates every
  file under `~/recordings/` ending in `.wav`/`.m4a` with **no length check**
  and hands the raw filename back through `library.resolveName`. `playback.zig`'s
  non-interactive path (`playSelection`, `src/playback.zig:110-111`, taken
  whenever stdout/stdin is not a TTY, e.g. `rec play <name> | cat`) calls
  `loadTranscript` → `transcriptPath` with that filename. `record.appendStr`
  performs an unbounded byte-by-byte copy with **no bounds check against
  `buf.len`**, so once `library.stripExt(name).len + ".md".len` exceeds 80
  (i.e. a recording filename stem of 78+ bytes — well inside the ~255-byte
  `NAME_MAX` every common filesystem allows, reachable via a synced/received
  file or a simple rename), the writes run past `md_name_buf` on the stack.
  `.github/workflows/release.yml:57` builds shipped binaries with
  `-Doptimize=ReleaseFast`, which elides Zig's bounds-check panics, so in the
  released binary this is real memory corruption, not a caught safety panic.
- **Impact:** attacker/user-controlled bytes (the filename itself) overwrite
  stack memory adjacent to `md_name_buf` in the `rec play` command, driven by
  nothing more than a recording's filename length — a genuine stack-smashing
  primitive in the ReleaseFast binaries the project ships.
- **Suggested fix:** bound the copies in `transcriptPath` exactly like
  `library.recordingPath` already does elsewhere (reject or truncate a name
  that doesn't fit `md_name_buf` before copying), or build the path with a
  bounds-checked call such as `std.fmt.bufPrint`/heap `allocPrint` the way
  `audio_notes.zig:57-59` already does for the same sibling-`.md` path.

## FINDING-AUD-02: `wav.Encoder.finish()` leaks the file descriptor on every error path, disabling the `abort()` fallback
- **Severity:** major
- **Class:** bug
- **Location:** `src/wav.zig:83-104`
- **Evidence:**
  ```zig
  pub fn finish(self: *Encoder) Error!void {
      if (self.closed) return;
      self.closed = true;
      // RIFF is a u32-sized container; a longer body cannot be published.
      if (self.data_bytes > std.math.maxInt(u32) - 36) return error.FinalizeFailed;
      const data_bytes: u32 = @intCast(self.data_bytes);

      var patch: [4]u8 = undefined;
      std.mem.writeInt(u32, &patch, 36 + data_bytes, .little);
      if (cpwrite(self.fd, &patch, 4) != 4) return error.FinalizeFailed;
      std.mem.writeInt(u32, &patch, data_bytes, .little);
      if (cpwrite(self.fd, &patch, 40) != 4) return error.FinalizeFailed;

      if (cclose(self.fd) != 0) return error.FinalizeFailed;
  }

  /// Closes an unfinished encoder without making its file valid.
  pub fn abort(self: *Encoder) void {
      if (self.closed) return;
      self.closed = true;
      _ = cclose(self.fd);
  }
  ```
- **Failure mode:** `finish()` sets `self.closed = true` on entry, before the
  file descriptor is actually closed. Every one of its three error returns —
  the 4 GiB RIFF ceiling check, or either `cpwrite` call failing (ENOSPC, EIO,
  a device/disk fault while patching the header) — returns `error.FinalizeFailed`
  with `self.fd` still open. Because `closed` is already `true`, every
  caller's cleanup fallback, `abort()`, is now a no-op (`if (self.closed)
  return;`) and never closes the descriptor either. The 4 GiB path is not a
  rare corner case: it fires deterministically for any capture whose PCM body
  exceeds `maxInt(u32) - 36` bytes (a several-hours-long 48 kHz stereo
  recording), and the project's own regression test ("finish rejects bodies
  past the 4 GiB RIFF limit", `src/wav.zig:361-370`) exercises exactly this
  return without checking the descriptor was closed.
- **Impact:** a leaked OS file descriptor per failed `finish()`, accumulating
  across repeated failures in a long-lived process; on Windows the still-open
  handle also blocks `record.zig`'s own cleanup (`deleteFile` on the `.part`
  temp path in its `encoder_open` defer, `src/record.zig:118-123`), leaving a
  stray partially-written recording behind after what looks like a clean
  failure.
- **Suggested fix:** close the descriptor (or otherwise release the resource)
  unconditionally before returning any error from `finish()`, mirroring
  `m4a.zig`'s `finish()` (`src/m4a.zig:201-207`), which calls
  `ExtAudioFileDispose`/`CFRelease` first and only inspects the status
  afterward.

## Areas checked with no significant finding
- **`capture.zig`/`player.zig` miniaudio data callbacks:** `frame_count` is
  multiplied by a fixed `channels`/`2` (u32) with no explicit ceiling, but
  `CaptureConfig`/`Player.start` channel counts are always the compiled-in
  defaults (2) — never taken from a CLI flag or file — and unsigned overflow
  here can only *shrink* the computed byte count, never grow it past the
  buffer miniaudio actually sized for the callback, so it cannot itself
  produce an out-of-bounds read; it is the same trust-the-callback-contract
  pattern every miniaudio/CoreAudio/ALSA host uses.
- **`spectrum.zig`/`visualizer.zig` narrowing gotcha (AGENTS.md):** every
  `@min`/count intermediate that feeds a later multiply or index
  (`spectrum.zig:21-28`, `visualizer.zig:46,118-119,163,172`) is already typed
  explicit `usize`/float before use, and `src/spectrum_test.zig` exercises
  empty/incomplete PCM and seek discontinuities; no residual narrowing
  instance was found in the read files.
- **`wav.parseWav` / `library.parseDurationPrefix` chunk walkers:** both bound
  every read to `off + 8 <= len`, clamp `data` chunk bodies with
  `@min(size, len - body)`, and advance `off` by a `u64` intermediate before
  re-checking against `len`, so a crafted `size` field cannot walk the parser
  past the buffer.
- **`cut.cutPcm` frame-boundary arithmetic:** start/end are clamped in float
  space against `pcm_len` before any `@intFromFloat`, specifically to avoid
  the panic an out-of-range float would cause, and the resulting `usize`
  offsets are always frame-aligned sub-slices of the same buffer.
- **`cut.zig`/`wav.zig` `defer`-scoping (ADR-0007 class):** the WAV `image`
  that backs a decoded `pcm` slice is only freed via `errdefer` on the load's
  own error path, or later through `Loaded.deinit`, which is always followed
  immediately by reassigning the whole struct (`playback.zig:329-337`) before
  the stale `pcm` field could be read — no dangling alias found.
- **Capture/Playback device lifecycle:** `Recorder`/`Player` `start()` use
  `errdefer` chains that uninit exactly what was initialized on each failure
  branch, and `started` is only set `true` after the last step succeeds, so
  `deinit()` never double-frees or double-uninits the `ma_context`/`ma_device`.
- **`m4a.zig` encode/decode resource paths:** `Encoder.finish()` disposes the
  `ExtAudioFileRef` and releases the `CFURL` unconditionally before inspecting
  the status code (contrast with FINDING-AUD-02); `decode()`/`durationSec()`
  use plain `defer` for both handles, so every early return still releases
  them.
