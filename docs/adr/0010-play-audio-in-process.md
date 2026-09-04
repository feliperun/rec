---
type: ADR
id: "0010"
title: "Play audio in-process instead of spawning afplay"
status: active
date: 2026-09-04
---

## Context

Playback shelled out to `/usr/bin/afplay` and steered it with signals: pause
was SIGSTOP/SIGCONT, stop was a kill. That put the playback timeline outside
the process — `afplay` exposes no seek, so the player UI could not implement
arrow-key seeking, and the waveform's playhead was a wall-clock estimate
rather than the decoder's position. Meanwhile `cut.loadPcm` already decodes
the whole recording to canonical s16 PCM in-process to draw the waveform, so
the audio bytes were in memory and idle.

## Decision

**`src/player.zig` plays the decoded PCM on miniaudio's default output
device in-process; `afplay` is no longer used.**

- The same `loadPcm` decode serves the waveform and the speaker — one decode,
  no child process, no extra memory beyond what playback already needed.
- The miniaudio data callback copies frames from the borrowed PCM at the
  playhead and advances it. The playhead (`pos`), the paused flag and the
  done flag are atomics, so the audio callback stays lock-free and the UI
  thread reads position without locks.
- **Seek is a store** to the playhead (frame = sec × sample_rate, clamped):
  sample-accurate, immediate, no decoder restart.
- **Pause is a gate** in the callback: output silence and the playhead
  freezes — no signals, no device reconfig, the hardware clock keeps the
  stream alive.
- miniaudio resamples to the hardware rate, so any decoded recording plays
  on any output device.
- The player is never moved after `start` (the callback holds its address);
  `stop`/`deinit` join the callback thread before the PCM borrow ends.

## Options considered

- **Keep afplay + wall-clock cursor** — rejected: no seek at all; pause by
  SIGSTOP stalls inside the audio server and the cursor lies.
- **AVFoundation/AVAudioPlayer bindings** — rejected: a second audio API in
  the codebase for capabilities miniaudio already provides.
- **In-process miniaudio playback (chosen)** — the library is already
  vendored for capture; zero new dependencies, one callback for the whole
  timeline.

## Consequences

- Arrow/SHIFT-arrow seeking, a truthful playhead, and signal-free pause/resume
  are now plain function calls on `Player`.
- Playback holds the recording's PCM in memory for the session (tens of MiB
  per hour of AAC at 128 kbps) — already true for the waveform.
- `play` no longer works on systems without a CoreAudio output device even
  for the non-interactive path — it is a player now, not a file checker.
- Off a tty, playback still plays to completion and reports Ctrl-C as 130;
  it just does it in-process.
