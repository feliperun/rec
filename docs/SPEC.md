# rec — Specification

Terminal audio recorder for meeting audio, written in Zig, for macOS.

## Problem

Record meetings from the microphone, keep them on disk, list them, and play
them back — without leaving the terminal and without hand-rolled device code.

## Functional requirements

### FR1 — Record
- Capture microphone audio and write it to disk as **M4A (AAC-LC, 48 kHz,
  stereo)**, encoded by the system's AudioToolbox codec.
- One file per recording, named `YYYYMMDD-HHMMSS.m4a`, stored under
  `~/recordings/` (created on demand).
- Recording stops on `Ctrl-C`, `ESC`, or `--duration <sec>` when given; on a
  terminal `SPACE` pauses and resumes, and paused audio is dropped (the file
  keeps only recorded time). The file must be a complete, finalized container
  even on interrupt, and a failed encode must leave no partial file behind.
- While recording, show a live view on a terminal: elapsed time plus a
  multi-row waveform of the sound as it happens.

### FR2 — List
- `rec list` prints the recordings in `~/recordings/` with index,
  filename, duration (parsed from the recording's container), and file size.
- Both `.m4a` and pre-existing `.wav` recordings are listed; empty or missing
  directory prints a friendly empty state, not a crash.

### FR3 — Play
- `rec play <index|filename>` plays a recording through the default output
  device in-process: the recording is decoded to canonical PCM once and the
  same samples feed the waveform and the speaker (miniaudio playback).
- On a terminal playback is interactive: a multi-row waveform opens at the
  terminal width with a playhead cursor. `SPACE` pauses/resumes; `←`/`→`
  seek ±1 s and `SHIFT`+`←`/`→` seek ±5 s; `I`/`O` anchor the region to cut
  (two full-height cursors with the span reversed between them), `DELETE`
  asks for confirmation and `ENTER` cuts it out in place (any other key
  cancels) — playback continues on the shortened recording with a note
  confirming the cut —, `R` resets the anchors, `T` transcribes the
  recording or opens its transcript when one exists, `Q`/`Ctrl-C` stops.
- Off a terminal, playback runs to completion and is interruptible with
  `Ctrl-C`.

### FR4 — Interactive mode
- Running `rec` with no subcommand enters a minimal interactive menu:
  `r` start recording · `l` list · `<number>` + Enter plays · `q` quit.
- Raw terminal mode is restored on exit even after Ctrl-C (no broken terminal).

### FR5 — Transcribe
- `rec transcribe <index|filename>` resolves the selection exactly like
  `play` and sends the recording to the Deepgram pre-recorded API through
  `/usr/bin/curl` as a child process — M4A as `audio/mp4`, legacy WAV as
  `audio/wav`.
- The transcript is written next to the recording as **OKF markdown**
  (`~/recordings/NAME.m4a` → `~/recordings/NAME.md`); `--language <code>`
  overrides the Deepgram language (default `pt-BR`) and `--out <path>` moves
  the artifact elsewhere.
- Credentials come from the `DEEPGRAM_API_KEY` environment variable; every
  failure prints a one-line `transcribe: …` error on stderr and exits 1.

### FR6 — LLM processing backend (`setup`)
- A subset of locally installed coding-agent CLIs (Claude Code, Codex CLI,
  OpenCode, pi, Gemini CLI) doubles as rec's text-processing engine, driven
  non-interactively with the composed prompt on stdin.
- `rec setup` (alias `configure-llm`) probes each harness **with a real test
  call** — file presence alone does not prove auth/quota/plan — lists the
  usable ones and their available models, asks for a choice, validates that
  exact combination once more, and persists it to
  `$XDG_CONFIG_HOME/rec/config.json` (default `~/.config/rec/`). An empty
  model means the account default. Re-running changes the choice.
- A Claude Code setup can additionally pick an **Anthropic-compatible
  provider**: DeepSeek (`DEEPSEEK_API_KEY`) or Z.AI GLM (`ZAI_API_KEY`), the
  same override the `claudeseek`/`claudezai` shell functions apply. The key
  must be exported in the environment — it is never persisted — and rec
  refuses the provider until the probe succeeds against it.

### FR7 — Native refinement in transcribe
- After saving the raw transcript, `rec transcribe` runs it through the
  bundled **refine** prompt (metalscribe lineage) using the FR6 backend,
  fixing mistranscribed hard-to-hear words, and rewrites the same `.md`
  keeping frontmatter.
- Refinement degrades gracefully: missing config/unusable harness/model
  failure prints a stderr notice, leaves the raw transcript intact, and
  still exits 0. `--no-refine` skips it; `--context <text>` forwards domain
  context.

### FR8 — Format via user templates (`format`)
- `rec format <index|filename|path>` transforms a transcript markdown using
  a named prompt template: user-editable files under `<config dir>/templates/`,
  created on first use from copies embedded in the binary (`meeting` is the
  structuring template behind the default; `refine` backs FR7). Embedded
  copies also serve when the directory is missing/read-only; user edits are
  never overwritten by upgrades. Custom templates can be added freely.
- Default output name is `<source-stem>.<template>.md` beside the input;
  `--out` overrides (and refuses to equal the input), `--context` feeds the
  template's `{{DOMAIN_CONTEXT}}` slot or an appended context section.
- Formatting hard-requires the FR6 backend (exit 1 with guidance when
  absent) and reports the saved path on success.

## Non-functional requirements

- **Zig** (stable toolchain installed via Homebrew) — single binary, no
  runtime deps beyond the system player and the user's own coding-agent CLI.
- Audio I/O via **miniaudio** (established single-file C library, vendored at
  `vendor/miniaudio.h`) compiled through `zig cc`; no hand-rolled CoreAudio.
- `zig build` must succeed with zero warnings-as-errors blockers; tests via
  `zig build test` cover the M4A encoder, the list parser, prompt
  composition, config/template naming, and argument parsers.
- Recordings live under `~/recordings/`, outside the repository; build
  outputs are git-ignored and the repo stays clean.

## Out of scope (MVP)

- Upload, recording formats other than M4A (legacy WAV stays read-only),
  input-device selection UI,
- cross-platform support beyond macOS, full-screen TUI framework.

## Acceptance (end-to-end)

1. `zig build` produces a working binary.
2. A scripted smoke run: record ~2 s → `list` shows the file with plausible
   duration → `play` exits 0 → cleanup. Verified with real microphone access
   (already granted to the host terminal).
3. `rec transcribe <index>` writes an `.md` transcript beside the recording.
   Verified manually with a live `DEEPGRAM_API_KEY` outside CI.
