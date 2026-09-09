---
type: ADR
id: "0016"
title: "Use one terminal Markdown viewer for notes and sharing"
status: active
date: 2026-09-08
---

## Context

Transcripts and formatted notes were previously printed as raw prose or handed
to an editor. That hid frontmatter, discarded the timing information needed by
formatting, and gave playback, `transcribe`, and `format` different ways to
read the same artifact. Users also need to move the resulting Markdown into
other applications without leaving the terminal.

## Decision

**`src/markdown.zig` is the single terminal renderer and viewer for Markdown
artifacts. `src/share.zig` provides clipboard output and explicit application
destinations, while `src/sharecmd.zig` exposes them as `rec share`.**

The OKF body keeps one timestamp range and speaker label for every Deepgram
utterance. Frontmatter is rendered as a metadata panel. A terminal viewer is
dismissible with `q`/`ESC`, wraps to the terminal, and scrolls with arrows,
paging, Home, and End; it draws only on input or resize so idle content does
not flicker. Non-tty invocations render once and return so scripts remain
pipeable. Playback embeds the wrapped transcript below its waveform and offers
the same scroll keys plus copy/share keys (clipboard, ChatGPT, Claude, or
Gemini). Clipboard is the default share target; the other destinations use
a fixed website URL after copying the complete text for pasting. No undocumented
prompt URL scheme is assumed, and nothing is submitted automatically.

## Consequences

- `transcribe` and `format` open the artifact they just wrote.
- A transcript is visible alongside audio playback and keeps exact timing for
  prompt templates.
- Clipboard availability follows the host (`pbcopy`, `xclip`/`xsel`/`wl-copy`,
  or `clip.exe`); application destinations also need a browser.
- The viewer deliberately implements the Markdown subset rec emits rather
  than embedding a full Markdown parser or TUI framework.
