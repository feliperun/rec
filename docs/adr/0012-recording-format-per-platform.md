---
type: ADR
id: "0012"
title: "Recording format follows the platform: M4A on macOS, WAV elsewhere"
status: active
date: 2026-09-04
---

## Context

[ADR 0004](0004-record-natively-in-m4a-aac.md) chose M4A/AAC because macOS
ships a licensed AAC encoder in AudioToolbox, a framework `rec` already links.
That argument is macOS-only: Linux and Windows ship no system AAC encoder, and
adding a codec dependency (fdk-aac, ffmpeg) just to record is exactly the
external weight ADR 0004 avoided.

`rec` is growing Linux and Windows builds (see [ADR 0013](0013-cross-platform-builds.md)),
so the recording format can no longer be hardwired to the macOS encoder. The
rest of the pipeline already speaks both languages: `library.zig` scans `.wav`
and parses WAV durations from chunk headers, `cut.zig` reads WAV payloads
without a decode pass, `player.zig` plays raw PCM, and miniaudio's decoders
cover WAV natively on every platform. Only the writer was missing.

## Decision

**The recording format follows the platform: M4A where macOS provides the
encoder, plain PCM16 WAV everywhere else. The `recording` facade in
`src/library.zig` is the single switch point and no caller branches on the OS.**

- The facade is a namespace in `src/library.zig` (`library.recording`): `ext`
  (`.m4a` / `.wav`), `format_name`
  (user-facing copy), `Encoder` (streaming: `init`/`write`/`finish`/`abort`),
  `encode`, `decode`, `durationSec`, and `m4a_supported`. The platform branch
  is comptime, so non-macOS builds never analyze `m4a.zig` — AudioToolbox's
  symbols stay out of the binary and `build.zig` links the CoreAudio
  frameworks only for macOS targets.
- `src/wav.zig` owns the WAV format: a streaming encoder shaped exactly like
  `m4a.Encoder` (44-byte canonical PCM16 header written upfront, RIFF/data
  sizes patched by `finish` via `pwrite`), the `parseWav` reader (moved from
  `cut.zig`), and one-shot `encode`. libc-only, like every format binding in
  the project.
- `record`, `cut`, and `library` consume only the facade. On macOS behavior is
  unchanged; on Linux/Windows recordings are `.wav`, `scan` skips `.m4a`
  (nothing there can decode it), and a `cut` of a `.wav` stays `.wav` in
  place — the "legacy .wav becomes M4A" rule is macOS's alone.
- Transcription is unaffected: Deepgram already receives `audio/wav` for
  `.wav` ([ADR 0004] kept that path alive for legacy files).

## Options considered

- **M4A everywhere via a vendored encoder** — a new codec dependency on two
  platforms to preserve a size saving that only matters against ADR 0004's
  per-platform trade-off. Rejected.
- **WAV everywhere** — would regress macOS: 10× bigger files and uploads for
  the platform where the encoder already exists. Rejected ([ADR 0004] stands
  on macOS).
- **OS branches at each call site** — scatters `if (builtin.os.tag)` through
  `record`/`cut`/`library` and keeps `m4a.zig` reachable from non-macOS
  builds, where any accidental reference is a link error. Rejected for the
  facade.

## Consequences

- Linux/Windows recordings are uncompressed (192 KB/s stereo): disk and
  transcription-upload cost return to the pre-ADR-0004 profile on those
  platforms. Acceptable — the alternative is a codec dependency or no
  builds at all.
- The `Encoder` interface is the contract both formats satisfy; a future
  format (opus, flac) is one more branch in the facade.
- WAV files are lossless and header-trivial, so `cut` on Linux/Windows works
  without any decode step, and durations parse from the header prefix without
  reading the file body.
