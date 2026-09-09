---
type: ADR
id: "0019"
title: "Generate and read audio notes inside playback"
status: active
date: 2026-09-09
---

## Context

Playback exited its alternate screen before transcribing, and had no way to
format or read formatted notes in the same session. Commands coupled generation
to progress printing and a separate Markdown viewer. Running them synchronously
inside the player would keep the screen open but block its controls.

## Decision

`audio_notes.zig` owns the transcript and default `meeting` document for the
recording. T and F select an existing document or request the missing one. Tab
only changes selection. Formatting without a transcript queues transcription
first. There is at most one generation job per audio session.

Run the existing command bodies in a cancellable `std.Io.concurrent` future,
with a worker-owned arena. `command_ui.zig` separates terminal presentation from
background execution: background commands never print or open another viewer.
The worker signals completion atomically; only the playback thread reloads
artifacts and updates view state. Errors remain in the tab and can be retried.
Quitting cancels and joins the future; LLM process polling checks cancellation
at bounded intervals and kills/reaps its child on exit. Finite document writes
block cancellation from truncation through completion, so quitting cannot leave
a partially written artifact.

Retain the indexed scrolling and deduplicated painting of ADR 0018. Selecting a
tab returns to the audio header with its text below. The footer identifies the
active tab even when scrolled. Playback renders the document body without its
technical frontmatter; copy/share uses that tab's complete saved Markdown.
Pause, seek, scrolling and tab changes remain available during generation.
Cuts wait for generation to finish so the source cannot change during upload.

This replaces ADR 0018's T-to-text jump with tab selection and extends ADR 0016's
command reader behavior with an explicit background presentation mode. Standalone
transcribe/format commands retain their terminal viewer.

## Consequences

No new dependencies, subprocess command protocol, or duplicate generation logic.
Long jobs do not own the terminal. A formatted document survives reopening, and
an unsuccessful job leaves playback and existing documents available. Synthetic
PTY tests exercise tab-specific copy/share, delayed generation, queued formatting,
failures and retries, duplicate keys, and quitting during both job types.
