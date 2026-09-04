# rec — Product Vision

## Why this, why now

Meeting audio capture shouldn't require a GUI app or a cloud subscription. A
terminal is already open before every meeting; recording should be one command
away, with the artifacts (files, transcripts) staying on the user's disk.

## The problem

People who live in the terminal need to record meetings and later search them.
Existing options are heavyweight GUI recorders that scatter files in
app-specific containers, or `sox`-style tools that demand hand-tuned device
flags and produce enormous uncompressed files.

## The insight

macOS already ships everything needed: CoreAudio for capture and playback, the
system AAC encoder, and a pre-recorded transcription API. `rec` is only the
thin, composable glue — a single Zig binary with no runtime dependencies, where
every subcommand maps to one verb (record, list, play, transcribe).

## Principles

- Single binary, zero runtime deps beyond the OS — if the system can do it,
  shell out or link the framework instead of reimplementing.
- Recordings are plain files under `~/recordings/`, never app-managed storage.
- One verb per subcommand; the interactive menu is sugar, not a TUI framework.

## Near-term horizon

Recordings move from WAV (large, costly to keep and upload) to compressed
M4A/AAC, cutting storage and transcription upload costs by ~10x while keeping
the same CLI surface.

## Non-goals (for now)

- Cross-platform beyond Apple Silicon macOS.
- Input-device selection UI, cloud sync, editing, full-screen TUI.

## Related docs

- [Architecture](ARCHITECTURE.md) · [Abstractions](ABSTRACTIONS.md) · [ADRs](adr/README.md)
