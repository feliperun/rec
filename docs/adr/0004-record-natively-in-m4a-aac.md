---
type: ADR
id: "0004"
title: "Record natively in M4A/AAC instead of WAV"
status: active
date: 2026-08-26
---

## Context

`rec` stores recordings as uncompressed WAV (PCM 16-bit, 48 kHz, stereo) —
192 000 bytes per second, ~67 MB for a 10-minute meeting and ~675 MB per hour.
That cost hits twice: disk usage grows without bound under `~/recordings/`,
and every `transcribe` call uploads the full uncompressed stream to Deepgram.

macOS ships a licensed AAC encoder in AudioToolbox, a framework the binary
already links (miniaudio's CoreAudio backend needs it). "Native" m4a support
therefore needs no new dependency, no vendored codec, and no external tool.

## Decision

**New recordings are written as M4A (AAC-LC) through the system encoder.**

- `src/m4a.zig` owns the format: `encode` drives `ExtAudioFileCreateWithURL`
  with file format `'m4af'` / data format `'aac '`, client format set to the
  captured interleaved s16 PCM (so the CoreAudio converter does the encoding),
  and the Apple software codec manufacturer pinned for deterministic output.
  Duration probing for `list` goes through `AudioFile` +
  `kAudioFilePropertyEstimatedDuration`. All bindings are hand-declared
  `extern "c"`s with fourccs verified against the macOS SDK headers.
- The capture pipeline is unchanged: miniaudio appends PCM to the in-memory
  buffer, and encoding happens once, on stop. A partial file is deleted if
  encoding fails, so the library never lists a corrupt recording.
- `list`, `play` and `transcribe` read both `.m4a` and pre-existing `.wav`
  files on disk (existing user recordings stay usable — afplay plays both and
  Deepgram accepts `audio/wav` and `audio/mp4`). The WAV *writer* is removed:
  nothing writes WAV anymore.
- `transcribe` picks the Deepgram content type from the extension:
  `audio/mp4` for `.m4a`, `audio/wav` for legacy `.wav`.

## Options considered

- **Keep WAV, convert after the fact with `afconvert`** — still materializes
  the full uncompressed file on disk and adds a second process per recording;
  the encoder is already linkable in-process.
- **Stream-encode during capture** — constant memory instead of the current
  whole-recording PCM buffer, but it couples the encoder to the audio callback
  path. The RAM profile is pre-existing and not the cost being fixed; can be
  revisited if long recordings become a problem.
- **Keep WAV** — the cost this decision exists to remove.

## Consequences

- ~10× smaller files and uploads (AAC ≈ 128 kbps vs 1536 kbps PCM) with no
  audible loss for meeting voice.
- Encoding depends on AudioToolbox at runtime (already a link dependency);
  unit tests for the encoder run only on macOS, which is the only supported
  platform and already the CI runner.
- AAC has codec priming/padding, so container-level durations are accurate to
  ~±20 ms — fine for `list` and transcript frontmatter.
- In-memory PCM capture remains O(duration); a 1-hour stereo recording still
  peaks around 690 MB of RAM (unchanged from the WAV pipeline).
