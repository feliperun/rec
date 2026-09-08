---
type: ADR
id: "0015"
title: "Layered eighth-block waveform with a scrolling recorder and a time ruler"
status: active
date: 2026-09-08
---

## Context

The half-block grid ([ADR 0011](0011-waveform-half-block-grid.md)) gave the
live views a shape, but the user called both views clunky, and they were:

- Two levels per character row made every envelope a staircase, and each
  column was painted one flat VU color — a patchwork of green, yellow and red
  cells rather than a waveform.
- The recorder drew the whole take compressed into the width, so the shape
  kept re-scaling as the recording grew; nothing on screen said *where in
  time* anything was.
- The player marked a region with reverse video (a blocky negative of the
  wave), the playhead was a solid white column hiding the audio under it, and
  a recording shorter than the grid's block count drew in its first columns
  while the cursor walked the full width.
- The grid was a fixed 10 rows whatever the terminal's height.

Terminal fonts ship eight lower-block glyphs (`▁▂▃▄▅▆▇█`) that quadruple the
vertical resolution of a cell — but only growing upward from the bottom
edge. The mirror image (a cell filled from its top edge) has no glyph; it
does have a rendering: the complementary lower block in reverse video swaps
ink and ground, and the terminal paints the upper part in the foreground
color. Audio editors and DJ software layer two envelopes — the RMS energy
inside the peak envelope — and put a time ruler under the track; iOS Voice
Memos scrolls the live waveform in from the right edge.

## Decision

**`src/waveform.zig` renders a layered, mirrored eighth-block waveform;
`src/ruler.zig` draws a time ruler under it; the recorder scrolls, the
player fits, and both size the grid to the terminal.**

- **Blocks carry peak and RMS.** `Tracker` accumulates both per 100 ms block
  (the RMS as the sum of squares). `layoutColumns` maps blocks to columns two
  ways: `fit` stretches or compresses the whole recording across the width
  (peak by max, RMS by its true aggregate); `tail` right-aligns the newest
  blocks, one per column.
- **Eighth-block cells, mirrored.** A column's extent is measured in eighths
  of a row on each side of the midline (`half · 8` levels, sqrt-scaled as
  before). Top-half cells fill from their bottom edge with a lower block;
  bottom-half cells draw the complementary lower block in reverse video, so
  the wave is symmetric at eighth-row resolution.
- **Two layers, one glyph per cell.** The RMS core draws in the row's core
  tone, the peak halo around it in the row's halo tone. A cell holding the
  core's edge is split by its glyph: the block in the core color over a
  background in the halo color (reversed on the bottom half, which swaps them
  back). Without color the core layer is dropped and the shape stays.
- **Color by row, not by column.** The VU ramp runs from the midline outward
  (blue → cyan → green → yellow → orange-red, 256-color indexes with a darker
  halo per stop), so speech sits blue and cyan and only loud audio reaches
  the warm rows. Unplayed columns are two grays; a region marked for cutting
  is recolored magenta on both layers; its anchors are thin `│` lines; the
  playhead is a heavy `┃` in the terminal's default foreground, visible on
  any theme. The 16-color, theme-following codes stay for text
  (`src/style.zig`).
- **A time ruler under the grid.** `ruler.zig` picks the first round
  interval (1 s … 1 h) whose ticks sit at least 12 columns apart, draws `┬`
  ticks on a `─` line and the time under each. The axis is a column→time
  mapping, so the recorder's ruler scrolls with its wave (negative origin
  before time zero) and the player's spans the recording.
- **The recorder scrolls.** The newest block is the last column and the wave
  moves left one column per tick — the take is never re-scaled.
- **Adaptive height.** `viewHeight` takes the rows left after each view's
  chrome (header, status, ruler, notes, hints): even, at least 4, at most
  12. A geometry change erases the screen (`live.clearScreen`) and redraws;
  every tick still positions rows absolutely ([ADR 0009](0009-alternate-screen-live-views.md)).
- Off a tty the recorder prints one row of lower blocks by peak, with no
  escapes at all (`renderStrip`).

## Options considered

- **Keep half-blocks, add colors** — rejected: two levels per row is the
  staircase itself; no palette fixes the shape.
- **Braille (`⣿`) cells** — rejected again: four dots per row are still
  coarser than eighths, render unevenly across fonts, and read as dot matrix.
- **Sixel / Kitty graphics** — rejected: not portable across the terminals rec
  targets.
- **True color (24-bit) gradients** — rejected: Terminal.app has no true
  color; the 256-color cube is universal and enough for seven stops.
- **Reverse-video selection kept** — rejected: it negates the wave; recoloring
  the doomed span is what says "this part goes".
- **Recorder keeps the compressed overview** — rejected: constant re-scaling
  reads as jitter and hides the live edge; the scroll is the established
  live-recording pattern.

## Consequences

- `waveform.PeakTracker`/`Peak` become `Tracker`/`Block`; the old
  `renderRow` overlay names stay (`played_cols`, `sel`, `sel_edges`,
  `cursor_col`, `color`).
- Frames grow: every colored cell may carry a full SGR respecification
  (`rowBufferLen` is 32 bytes per column). Still one write per tick behind
  the synchronized-update bracket.
- The reverse-video trick emits SGR 7 even under `NO_COLOR`; dimming of the
  unplayed part (SGR 2) is likewise an attribute, not a color. Neither is
  emitted off a tty.
- The E2E terminal emulator (`scripts/e2e_resize.py`) accepts the new glyph
  set under the status line: eighth blocks, the ruler's `─┬`, and digits.
- [ADR 0011](0011-waveform-half-block-grid.md) is superseded.
