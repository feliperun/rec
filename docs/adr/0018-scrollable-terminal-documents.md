---
type: ADR
id: "0018"
title: "Indexed scrollable terminal documents"
status: active
date: 2026-09-09
---

## Context

The first reader repeatedly printed an entire document or scanned from its
beginning for each visible line. Playback reserved a small fixed text panel,
and overflowing footers could scroll the terminal itself. The input reader
consumed an entire burst but returned only its first key. These combined into
lost navigation, flicker, and an interface that appeared stuck.

## Decision

Keep the existing alternate-screen and synchronized-update conventions from
ADR 0009. `viewport.zig` owns indexed display rows and viewport painting, shared
by Markdown reading and playback. Wrap text only when width changes. Count ANSI
styles separately from glyph cells, preserve UTF-8 boundaries, and clip every
output row. Paint only when the composed visible frame changes.

Audio rows precede the transcript in one scrollable document. Arrows, paging,
Home/End, and SGR mouse-wheel events move the viewport. T jumps to existing text
without stopping playback; Home restores the audio view. Reaching EOF pauses the
player rather than dismissing the reader. SPACE can replay from the beginning.
The keyboard reader consumes exactly one complete sequence, retaining subsequent
keys in the OS input queue. Exit restores mouse reporting and terminal state.

## Consequences

Long documents cost one layout pass per width and constant-time line lookup.
Idle or off-screen audio changes do not rewrite an identical screen. There is
no terminal-scrollback dependency and no new package dependency. The shared PTY
E2E exercises both standalone reading and playback using synthetic fixtures,
including resize, burst input, wheel navigation, and tail-cut persistence.
