---
type: ADR
id: "0006"
title: "Decode and split audio in-process"
status: superseded
date: 2026-08-28
superseded_by: "0007"
---

## Context

`rec play` needs a waveform of the recording (decoded PCM) and a keypress
(`S`) that cuts the audio at the current position. Nothing in the tree can
read audio back: recording and encoding go one way (ADR 0004), and `afplay`
is a black box that only plays. The two new capabilities — rendering a live
playback bar and splitting a recording — both require decoded PCM.

Splitting could shell out (`afconvert` decodes, `afplay`/`ffmpeg` re-encodes),
but that adds a runtime dependency, temp files, and second-guessing container
details the project already owns. AudioToolbox exposes the mirror image of
the encoder used in ADR 0004: `ExtAudioFileOpenURL` +
`ExtAudioFileSetProperty` (client format) + `ExtAudioFileRead` decode into
the canonical interleaved s16 / 48 kHz / stereo layout. Same framework,
same hand-declared-extern pattern, no new dependency.

## Decision

**Decoding and splitting happen in-process, in `rec` itself.**

- `src/m4a.zig` gains `decode`: opens any M4A with `ExtAudioFileOpenURL`,
  pins the client format to the canonical layout (s16 packed, 48 kHz,
  stereo — the capture layout, so the converter does any resampling),
  and reads in 1-second chunks into an owned buffer.
- `src/split.zig` owns cutting: `splitFile` decodes (or, for legacy `.wav`
  files, reads the `data` chunk), slices the PCM at a frame-aligned
  position, and re-encodes the two halves with the existing `m4a.encode`
  into `<stem>-part1.m4a` / `<stem>-part2.m4a`, then removes the original.
  The original is only deleted after both parts are on disk.
- `src/playback.zig` uses `decode` to build the waveform and the elapsed
  position for the interactive view; `afplay` still makes the sound.
- The WAV reader uses plain `read()` into owned memory rather than a
  memory-mapped file: the decoder lives in libc land and must not see the
  backing image freed or replaced while it walks the buffer.

### Gotcha that cost a debugging session

`defer` in Zig runs at the **end of the enclosing block**, not the end of
the function. A `defer gpa.free(image)` written inside an `if
(endsWith(".wav"))` block freed the decoded PCM slice (which pointed into
that image) the moment the block closed — the two `ExtAudioFileWrite`
calls then walked freed memory (`CrashIfClientProvidedBogusAudioBufferList`,
EXC_BAD_ACCESS). Keep the image alive for the whole function scope, and
never let a value inside a `defer`-freed allocation outlive its block.

## Options considered

- **`afconvert`/`ffmpeg` for decode+split** — no new dependency, but a
  subprocess round-trip per split, temp files to manage, and two codecs to
  second-guess. The encoder API is already in-tree and linkable.
- **Stream decode during playback** — decodes as audio is played instead of
  ahead of time; saves the whole-file PCM buffer at the cost of coupling
  decode to the play loop. Splitting needs the full PCM anyway, and
  `afplay` cannot be fed decoded PCM without re-encoding.
- **Pause afplay via SIGSTOP/SIGCONT** — not a decode/split alternative;
  adopted separately as the pause mechanism since `afplay` has no pause
  API.

## Consequences

- Splitting and waveform rendering are deterministic, testable offline
  (encode → decode → split round-trips in the unit suite), and need no
  external tool.
- A split materializes the full decoded PCM in RAM — O(duration), same
  profile as recording — and re-encodes both halves; fine for meeting-sized
  recordings, the only supported use.
- Decode runs roughly in real time or better; a split at the keypress costs
  decode + two encodes (~seconds).
- The canonical client format (s16, 48 kHz, stereo) is now shared by
  capture, encode, decode, and split — one layout, no conversion edges
  inside the tree.
- Playback TUI keys: `SPACE` pauses/resumes (SIGSTOP/SIGCONT on the
  `afplay` pid), `S` splits at the current position (guarded 0.2 s from the
  edges), `Q` stops. A `<stem>.md` sibling transcript is printed in full
  before the bar.
