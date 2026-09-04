---
type: ADR
id: "0011"
title: "Render waveforms as a multi-row half-block grid"
status: active
date: 2026-09-04
---

## Context

The waveform was a single terminal row of Unicode blocks — a VU meter, not a
waveform. Speech (where sqrt-scale peaks sit around 1/3 of full scale) read
as a flat low strip; there was no shape to follow, no place for a playhead to
stand out, and the user called it what it was: "8 bits". A terminal cell is
two characters tall if you use the half-block trick: `▀` paints the upper
half, `▄` the lower, `█` both, space neither — one row carries two rows of
resolution for free, in every terminal font, with no graphics protocol.

## Decision

**`src/waveform.zig` renders the waveform as a symmetric multi-row grid
built from half-blocks; record and playback share it.**

- `view_height = 10` rows × 2 half-cells = 20 levels of vertical resolution,
  mirrored around the midline like an oscilloscope/Audacity track.
- Columns come from the same 100 ms peak tracker, scaled **perceptually**:
  `fraction = √(peak / 32768)` — speech occupies the middle of the grid
  instead of hugging the floor.
- Each cell picks its glyph by how much of its half-row band the column's
  envelope covers: `█` fills the band, `▀`/`▄` fill top/bottom halves, space
  is outside the envelope.
- Overlays render in one pass with fixed priority: the playback cursor is a
  full-height bright-white column, the marked span is reverse video, columns
  at/past the playhead are dim, and with color each column keeps the VU ramp
  (green → yellow → red).
- The grid opens at the terminal's width (capped at 512 columns) and both
  views draw it on the alternate screen ([ADR 0009](0009-alternate-screen-live-views.md))
  with absolute positioning, so a resize heals on the next tick.
- Off a tty, the view degrades to one mid-grid row — still a real slice of
  the wave, greppable-free but shaped.

## Options considered

- **Braille/shade characters (`⣿`, `▒`, `░`)** — rejected: font- and
  terminal-dependent rendering, muddy at waveform scale, and the established
  spectrum-analyzer pattern is half-blocks.
- **Per-row proportional blocks (the old bar, taller)** — rejected: block
  elements quantize to whole cells, so 10 rows give 10 levels, not 20; and a
  center-mirrored envelope needs half-cell granularity to look smooth.
- **Sixel/Kitty graphics protocol** — rejected: not portable across the
  terminals rec targets; characters work everywhere.
- **Half-block symmetric grid (chosen)** — double resolution from existing
  glyphs, zero dependencies, the pattern proven by established TUI audio
  tools.

## Consequences

- Both live views gained 10 rows; the status line sits above the grid and
  (for playback) a notes row below it.
- Column math (`columnFractions`, `renderRow`, `rowBufferLen`) is pure and
  unit-tested; the views only position rows.
- `NO_COLOR` keeps the shape and the white cursor, dropping only the VU
  colors and dimming — the waveform never becomes unreadable.
