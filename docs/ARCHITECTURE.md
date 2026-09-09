# Architecture

> Current-state summary. ADRs in [adr/](adr/README.md) hold the history and the
> *why*; this file reflects only **active** decisions. Update it in the same
> commit as any structural change.

## High-level flow

```
microphone ──miniaudio──▶ PCM frames in memory ──library.recording (platform format)──▶ .part ──rename──▶ ~/recordings/*
                                                                        │                          (macOS: .m4a · Linux/Windows: .wav)
                                   library.zig (scan, sort, table) ◀────┤
                                                                        │
              library.recording (decode, s16/48k/stereo) ◀── WAV/M4A on disk ◀┤
                        │                                               │
                        ├── waveform.zig + ruler.zig (peak/RMS blocks, ◀─┤
                        │        eighth-block grid, time ruler)          │
                        │        ▲ record live view · play view         │
                        │                                               │
                        ├── player.zig (playhead, pause, seek) ──▶ speaker
                        │        │                                      │
                        ├── playback.zig ── SPACE · ←→ seek · I/O · DEL cut│
                        │        └── cut.zig (remove interval → re-enc)  │
                        │                                               │
                        └── <stem>.md transcript ── Markdown viewer ────┤
                                                                        │
     transcribecmd.zig ──▶ transcribe.zig ──/usr/bin/curl──▶ Deepgram ──▶ okf.zig ──▶ *.md
                                               │                               │
                                               └── markdown.zig / share.zig ◀──┘
```

`main.zig` parses the verb and dispatches. Recording is the implied verb
(bare `rec` records) and the latest recording is the implied selection for
`play`, `transcribe`, and `format` (`library.latest_selection`).

## Components

| Module | Responsibility |
|--------|----------------|
| `src/main.zig` | Arg parsing, subcommand dispatch, exit codes |
| `src/capture.zig` | miniaudio default-input device → growable PCM buffer |
| `src/record.zig` | The record verb: capture loop, SPACE pause (paused audio is dropped), ESC/Ctrl-C stop, naming, chunked encode and atomic publication; the live view scrolls the wave in from the right edge over a moving time ruler. `main.zig` opens an explicitly interrupted take in playback when the recording ran on a terminal |
| `src/library.zig` | Scans `~/recordings/`, sorts newest-first, formats table; hosts the `recording` facade — `ext`, streaming `Encoder`, `encode`/`decode`/`durationSec`, the single switch point of the platform recording format (M4A on macOS, WAV elsewhere) ([ADR 0012](adr/0012-recording-format-per-platform.md)) |
| `src/m4a.zig` | M4A/AAC encode via AudioToolbox's system encoder (macOS only); container duration parse for `list`; `decode` back to canonical s16/48k/stereo PCM via `ExtAudioFileRead` ([ADR 0004](adr/0004-record-natively-in-m4a-aac.md)) |
| `src/wav.zig` | PCM16 WAV streaming encoder (sizes patched on `finish`) and `parseWav` reader ([ADR 0012](adr/0012-recording-format-per-platform.md)) |
| `src/player.zig` | In-process playback of decoded PCM on miniaudio's default output device: atomic playhead/paused/done, sample-accurate seek, silence-gated pause ([ADR 0010](adr/0010-play-audio-in-process.md)) |
| `src/playback.zig` | Interactive play: raw-mode TUI over `player.zig` — one composed frame per tick (hidden cursor, sync bracket) with the colored layered waveform at the start of one scrollable page, the playhead line, the time ruler, the complete wrapped body of the selected Markdown document below it, SPACE pause, ←/→ and SHIFT+←/→ seek, ↑/↓/PgUp/PgDn/Home/End transcript scroll, I/O region anchors (the span recolored between two anchor lines), DELETE with ENTER confirmation cutting via `cut.zig`, R reset, T/F select or generate transcript/formatted notes without leaving playback, Tab switches documents, Y copies and S shares the active document, Q cancels pending work and stops; a confirmed cut reloads the shortened audio and keeps the player open; blocking fallback off a tty |
| `src/audio_notes.zig` | Owns transcript/formatted tabs and a single cancellable generation future; reloads completed artifacts on the UI thread and queues transcription before formatting when needed ([ADR 0019](adr/0019-audio-note-sessions.md)) |
| `src/command_ui.zig` | Explicit terminal/background presentation for command bodies: background jobs never write to the terminal or open viewers |
| `src/waveform.zig` | Peak and RMS per 100 ms block of PCM, block→column layout (`fit` for the player, `tail` for the recorder's scroll) and the shared mirrored eighth-block grid — sqrt scale, RMS core inside the peak halo, VU ramp by row, full-color playback waveform, magenta marked span, `│` anchors and `┃` playhead, adaptive height, terminal geometry ([ADR 0015](adr/0015-layered-eighth-block-waveform.md)) |
| `src/ruler.zig` | The time ruler under a waveform: round tick intervals, `┬` ticks on a `─` line, time labels; one column→time axis serves the scrolling recorder and the fitted player ([ADR 0015](adr/0015-layered-eighth-block-waveform.md)) |
| `src/keys.zig` | Raw stdin keystrokes for the live views: plain bytes, arrows, paging, Home/End, and SHIFT+arrows parsed from escape sequences, Delete (backspace and `ESC[3~`) |
| `src/live.zig` | Alternate-screen vocabulary for the live views: enter/leave (hardware cursor hidden while a view is up), synchronized-update brackets, absolute cursor positioning, line and screen erase, row-wrap math ([ADR 0009](adr/0009-alternate-screen-live-views.md)) |
| `src/cut.zig` | Removes a marked time interval in place: decode (or read WAV) → frame-aligned slice → re-encode the remainder → replace the original |
| `src/transcribe.zig` | Spawns `/usr/bin/curl` against Deepgram pre-recorded API |
| `src/transcribecmd.zig` | The transcribe verb: resolve the selection, send the recording to Deepgram, render timestamped OKF markdown, run the LLM refine pass (shared by the CLI and the play view's `T`), then open the Markdown viewer for terminal commands; playback owns presentation for background jobs |
| `src/okf.zig` | Renders the OKF markdown transcript (frontmatter + timestamped speaker turns) |
| `src/viewport.zig` | Indexed display rows, UTF-8/ANSI wrapping, viewport clipping, wheel/navigation handling, deduplicated synchronized frames ([ADR 0018](adr/0018-scrollable-terminal-documents.md)) |
| `src/markdown.zig` | Renders rec's Markdown/frontmatter subset, wraps it to the terminal, and provides the non-flickering scrollable viewer |
| `src/share.zig` / `src/sharecmd.zig` | Copy Markdown to the host clipboard and optionally open ChatGPT, Claude, or Gemini for pasting; expose `rec share` |
| `src/miniaudio.c` + `vendor/miniaudio.h` | Vendored single-file audio I/O |

## Runtime & hosting

Local CLI on macOS (Apple Silicon and Intel), Linux, and Windows. Built as a
single static `rec` binary per target with one zig toolchain (`zig build`,
ReleaseFast in CI); each native platform runs `zig build test` on its own CI
runner, the other targets cross-compile ([ADR 0013](adr/0013-cross-platform-builds.md)).
Releases ship `rec-<os>-<arch>` binaries, installed via `install.sh` (macOS,
Linux) or `install.ps1` (Windows). Released with release-please
(Conventional Commits). Installed binaries update themselves from the
latest release — an explicit `rec update`, plus a silent once-a-day check
before other commands ([ADR 0014](adr/0014-self-update-from-github-releases.md)).

## Observability & quality

- `zig build test` (compile + unit tests) on every push — see
  [Getting Started](GETTING-STARTED.md).
- Structural health gated by [Sentrux](sentrux.md).
- Errors/telemetry: one-line `<subcommand>: …` messages on stderr, exit 1. No
  stack traces or env-var names in user-facing copy.

## Security model

- No authn/authz — local single-user tool.
- `DEEPGRAM_API_KEY` is read from the environment at call time, never stored
  or logged; the pre-commit hook scans the staged diff for secrets.
- Recordings stay on the user's disk; nothing is uploaded except the explicit
  `transcribe` call to Deepgram.

## Related docs

- [Vision](VISION.md) · [Abstractions](ABSTRACTIONS.md) · [ADRs](adr/README.md) · [Sentrux](sentrux.md)
