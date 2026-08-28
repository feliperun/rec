---
type: ADR
id: "0007"
title: "Cut marked intervals in place"
status: active
date: 2026-08-28
supersedes: "0006"
---

## Context

ADR 0006 introduced a point split: a keypress (`S`) divides the recording at
the playback position into `<stem>-part1.m4a` / `<stem>-part2.m4a`. In use,
splitting in two is rarely what is wanted — the actual need is to *remove* a
piece (the start, the end, or a middle passage) and keep one recording. A
two-file split also changes the library shape (two entries for what was one
recording) and orphans the `<stem>.md` transcript, whose name no longer
matches either part.

## Decision

**`S` (split in two) is removed; `src/split.zig` becomes `src/cut.zig`, and
the play TUI cuts a marked interval in place.**

- `I` marks the interval start, `O` marks the interval end (playback
  seconds); pressing either again moves the mark; `R` clears both marks.
- `D` removes the marked interval `[min(I, O), max(I, O)]` and replaces the
  original file with the re-encoded remainder, via an atomic rename of a
  temp file — the library never lists a partial result. Only `O` cuts the
  head (`[0, O]`); only `I` cuts the tail (`[I, end]`).
- Guard: the removed span and the remaining audio must each be at least
  0.2 s; a cut outside the guard leaves the file untouched and says so.
- The `<stem>.md` transcript is left as-is: it describes the recording by
  name, and cutting never changes the filename. (The split it replaces, which
  renamed files, could not keep a transcript.)
- Legacy `.wav` files are cut into `<stem>.m4a` — the native format of
  ADR 0004 — and the `.wav` is removed afterwards.
- Playback ends after a successful cut: the audio the player has open was
  replaced on disk.

### Gotcha that cost a debugging session

`defer` in Zig runs at the **end of the enclosing block**, not the end of
the function. A `defer gpa.free(image)` written inside an `if
(endsWith(".wav"))` block freed the decoded PCM slice (which pointed into
that image) the moment the block closed — the subsequent encode walked
freed memory (`CrashIfClientProvidedBogusAudioBufferList`, EXC_BAD_ACCESS).
Keep the image alive for the whole function scope, and never let a value
inside a `defer`-freed allocation outlive its block.

## Options considered

- **Split in two (ADR 0006)** — removed: two entries per recording, an
  orphaned transcript, and the awkward join-to-remove workflow.
- **External audio editor** — out of scope: the TUI already owns decode and
  re-encode, and the mark-and-cut model is the simplest thing that removes
  start, end, and middle spans.

## Consequences

- One recording in, one recording out: the library table and the transcript
  stay valid after a cut.
- A cut costs decode + one re-encode — about the same seconds as the old
  split, minus the second half's encode.
- The canonical s16/48 kHz/stereo layout (ADR 0004, ADR 0006) is unchanged;
  cut reuses `decode`, the WAV reader, and `m4a.encode`.
- Play TUI keys: `SPACE` pause/resume, `I`/`O` mark, `D` cut, `R` reset
  marks, `Q`/`Ctrl-C` stop. The marked span shows in reverse video on the
  waveform bar; the status line shows `[MM:SS–MM:SS]` while marks are set.
