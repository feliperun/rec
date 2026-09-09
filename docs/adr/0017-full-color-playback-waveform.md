---
type: ADR
id: "0017"
title: "Keep every playback waveform column colored"
status: active
date: 2026-09-08
---

## Context

The play view used the playhead position as a second visual state and dimmed
all audio that had not played yet. That made one recording look partly like a
waveform and partly like a disabled track, especially after seeking or when a
playback was paused.

## Decision

**Playback always renders the audio with the VU color ramp.** The playhead is
the only playback-position marker; selection remains magenta and the anchors
remain visible. The recorder keeps its existing no-position overlay.

## Consequences

- The full shape and energy are visible before the speaker reaches it.
- `waveform.Overlay.played_cols` remains available for pure renderer tests and
  other callers, while playback passes the full width.
- `NO_COLOR` still removes ANSI colors as it does for every terminal view.
