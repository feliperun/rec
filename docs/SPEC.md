# rec — Specification

Terminal audio recorder for meeting audio, written in Zig, for macOS.

## Problem

Record meetings from the microphone, keep them on disk, list them, and play
them back — without leaving the terminal and without hand-rolled device code.

## Functional requirements

### FR1 — Record
- Capture microphone audio and write it to disk as **WAV (PCM 16-bit, 48 kHz,
  stereo)**.
- One file per recording, named `YYYYMMDD-HHMMSS.wav`, stored under
  `~/recordings/` (created on demand).
- Recording stops on `Ctrl-C` (or `--duration <sec>` when given); the file must
  be finalized with a correct RIFF header even on interrupt.
- While recording, show elapsed time on the terminal (minimum: a ticking
  `HH:MM:SS` line).

### FR2 — List
- `rec list` prints the recordings in `~/recordings/` with index,
  filename, duration (parsed from the WAV header), and file size.
- Empty or missing directory prints a friendly empty state, not a crash.

### FR3 — Play
- `rec play <index|filename>` plays a recording through the default
  output device by invoking the system player `/usr/bin/afplay` as a child
  process (established macOS tool; no custom output device code).
- Playbacks are interruptible with `Ctrl-C` (child terminated, no zombies).

### FR4 — Interactive mode
- Running `rec` with no subcommand enters a minimal interactive menu:
  `r` start recording · `l` list · `<number>` + Enter plays · `q` quit.
- Raw terminal mode is restored on exit even after Ctrl-C (no broken terminal).

### FR5 — Transcribe
- `rec transcribe <index|filename>` resolves the selection exactly like
  `play` and sends the WAV to the Deepgram pre-recorded API through
  `/usr/bin/curl` as a child process.
- The transcript is written next to the WAV as **OKF markdown**
  (`~/recordings/NAME.wav` → `~/recordings/NAME.md`); `--language <code>`
  overrides the Deepgram language (default `pt-BR`) and `--out <path>` moves
  the artifact elsewhere.
- Credentials come from the `DEEPGRAM_API_KEY` environment variable; every
  failure prints a one-line `transcribe: …` error on stderr and exits 1.

## Non-functional requirements

- **Zig** (stable toolchain installed via Homebrew) — single binary, no
  runtime deps beyond the system player.
- Audio I/O via **miniaudio** (established single-file C library, vendored at
  `vendor/miniaudio.h`) compiled through `zig cc`; no hand-rolled CoreAudio.
- `zig build` must succeed with zero warnings-as-errors blockers; tests via
  `zig build test` cover the WAV writer and the list parser.
- Recordings live under `~/recordings/`, outside the repository; build
  outputs are git-ignored and the repo stays clean.

## Out of scope (MVP)

- Upload, formats other than WAV, input-device selection UI,
- cross-platform support beyond macOS, full-screen TUI framework.

## Acceptance (end-to-end)

1. `zig build` produces a working binary.
2. A scripted smoke run: record ~2 s → `list` shows the file with plausible
   duration → `play` exits 0 → cleanup. Verified with real microphone access
   (already granted to the host terminal).
3. `rec transcribe <index>` writes an `.md` transcript beside the recording.
   Verified manually with a live `DEEPGRAM_API_KEY` outside CI.
