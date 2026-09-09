---
type: ADR
id: "0020"
title: "An audio-reactive listening room over decoded PCM"
status: active
date: 2026-09-09
---

## Context

The fitted waveform is useful for navigation and cutting, but barely moves during
playback. Listening needs a live visual counterpart without an additional audio
capture device, another decoding pass, or work on the real-time audio callback.
[CAVA](https://github.com/karlstav/cava) establishes the useful conventions:
logarithmic frequency bands, smooth release, and visual responsiveness rather than
laboratory measurement.

## Decision

Keep `player.zig` as the audio transport. Read its atomic sample position once per
frame and analyze the preceding 4,096 frames of the existing immutable PCM on the
UI thread. `spectrum.zig` uses the **vendored miniaudio band-pass biquads** for 40
logarithmically spaced bands from 45 Hz to the lesser of 16 kHz or 45% of the
sample rate. Discard the filters' warm-up, sum stereo energy without downmixing,
and map RMS logarithmically over a fixed −60–0 dB range. No new dependency or FFT
implementation is necessary. These bands are an aesthetic energy display, not a
calibrated spectrum analyzer.

`visualizer.zig` draws three views of these measurements:

- **Aurora:** cyan-to-rose Braille contours of recent band energy, with decaying
  trails and a reflected contour.
- **Spectrum:** half-block bars with falling peak markers.
- **Scope:** separate left/right Braille traces, aligned to a rising zero crossing,
  with bounded automatic display gain for quiet recordings.

Braille provides two horizontal and four vertical samples per cell for thin
contours. It supplements the block overview; it does not replace the recorder's
waveform or the playback waveform defined by ADRs 0015 and 0017. The light field
uses 256-color SGR and Unicode, including on Terminal.app. `NO_COLOR` removes
colors while preserving the shapes. It needs no graphics protocol or patched font.

`deck.zig` owns responsive layout and visual settings. Normal mode retains the
complete recording overview, cut anchors, time ruler, and transcript in one
scrollable document. Focus mode expands the visualization. Small terminals show a
compact transport. V cycles visuals, Z toggles focus, ? opens controls, +/− and M
adjust the miniaudio device's stream volume, and 0–9 seek to a percentage. Settings
last for the session, including after a cut; they do not alter system volume or
the recording. Analysis shows source energy before the volume control.

Keep the indexed viewport and synchronized output from ADR 0018. Budget each tick
for 33 ms including rendering. Paused and off-screen scenes skip recomposition;
resize and input invalidate the frame. Freeze history while the playhead is
unchanged and reset it after a seek discontinuity or cut. Every row stays clipped
and input bursts remain queued. EOF holds the player open; SPACE replays it.

## Consequences

Analysis uses fixed-size stack buffers and the biquads' preallocated API. Its
memory is independent of recording duration; the existing decoder still owns the
whole PCM. There is no animation clock pretending to be sound. Silence produces
no spectrum, and opposite-phase stereo remains visible.

Synthetic unit tests cover frequency response, stereo phase, silence, boundaries,
seek/history, visual cell limits, and volume bounds. PTY tests cover the complete
listening workflow, paused output, resize down to 1×1, burst input, cuts,
transcripts, replay, terminal restoration, and plain piped playback. CI runs those
PTY scenarios on macOS and Linux, with miniaudio's null backend. Windows retains
native unit tests and compilation. `scripts/demo_player.py` creates an original
synthetic ambient loop in an isolated temporary library for manual visual review.
