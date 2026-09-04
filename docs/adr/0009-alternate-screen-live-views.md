---
type: ADR
id: "0009"
title: "Draw live views on the alternate screen"
status: active
date: 2026-09-04
---

## Context

The live views (the recorder's meter, the player's status + waveform bar) were
drawn with cursor-relative sequences: `\r` to the line start, CUU to climb over
previously wrapped rows, EL to erase. Row counts came from `rowsSpanned`, which
models how the terminal wraps a line — but after a resize the terminal also
*reflows* existing content (xterm-style rewrap) or clamps the cursor (Ghostty-
style), and the program's model of where the cursor sits diverges from reality.
Every following tick then writes one row too low: the display stacks a new copy
of the live line ten times a second until the recording ends (observed in real
use). Any amount of row math can be defeated by a terminal whose reflow or
cursor-clamp differs from the model — relative redraw is structurally unable to
survive a resize.

## Decision

**Each live view takes over the terminal's alternate screen and repaints by
absolute cursor position; `src/live.zig` is the escape-sequence vocabulary.**

- `\x1b[?1049h` on start, `\x1b[?1049l` on exit (as vim/htop/less do): the
  user's scrollback is untouched while recording or playing, and whatever the
  terminal did to its grid during a resize is irrelevant — the next tick
  corrects it.
- Every tick positions the cursor absolutely (CUP `\x1b[{row};{col}H`) and
  erases each row it owns (EL `\x1b[2K`) before writing. No CUU climbing, no
  reliance on where the previous draw left the cursor.
- A terminal-width change repaints the whole view: erase the previous view's
  rows (header rows *and* the live row — clearing only the header's span orphans
  the old live line on grow), rewrite the header at row 1, let the live row
  follow it via `rowsSpanned`.
- `src/live.zig` exports `enter`/`leave`/`moveTo`/`clearLine` and the pure
  `rowsSpanned` row-wrap math; I/O stays with the callers.
- The alternate screen is used only when stderr is a tty. The piped path keeps
  `\r` + EL so redirected stderr stays greppable (`^Recording to `, the
  `Saved …` summary).
- The player's on-screen keys and marks are unchanged; its notes line is just a
  third absolutely-positioned row.

### Gotcha that cost a debugging session

On macOS, a pty master **discards its buffered output if no one is draining it
while the child closes the slave**. The resize E2E (`scripts/e2e_resize.py`)
must read the master concurrently and only reap with `waitpid` after EOF — a
`waitpid` before the final drain silently loses the `Saved` summary and made the
test fail in the wrong place.

## Options considered

- **Better relative-redraw model** — rejected: unprovable. Any model is one
  terminal implementation away from the screenshot that started this ADR.
- **Query the real cursor position (CPR)** — rejected: adds a request/response
  round trip per tick and still only repairs after the damage is on screen.
- **Alternate screen + absolute repaint (chosen)** — the pattern every
  established full-screen TUI uses; robust under any reflow model, and the
  smallest correct thing.

## Consequences

- Resizes are self-healing: worst case one tick (100 ms) looks wrong.
- Live views no longer appear in scrollback; the only residue after the run is
  the `Recording to …`/`Saved …` summary on the normal screen.
- Full-screen takeover is visible while the view runs — acceptable for the two
  views that draw continuously, and the exit always restores the screen.
- `scripts/e2e_resize.py` pins the invariant: under both a reflowing and a
  clipping emulator, during a shrink and a grow, the screen holds exactly one
  header plus one live line, and the normal screen gets the summary back.
