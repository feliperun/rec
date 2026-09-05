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
                        ├── waveform.zig (peaks, half-block grid) ◀─────┤
                        │        ▲ record live view · play view         │
                        │                                               │
                        ├── player.zig (playhead, pause, seek) ──▶ speaker
                        │        │                                      │
                        ├── playback.zig ── SPACE · ←→ seek · I/O · DEL cut│
                        │        └── cut.zig (remove interval → re-enc)  │
                        │                                               │
                        └── <stem>.md transcript ── printed in full ────┤
                                                                        │
     transcribecmd.zig ──▶ transcribe.zig ──/usr/bin/curl──▶ Deepgram ──▶ okf.zig ──▶ *.md
```

`main.zig` parses the subcommand and dispatches; `tui.zig` wraps the same
verbs in a raw-mode interactive menu.

## Components

| Module | Responsibility |
|--------|----------------|
| `src/main.zig` | Arg parsing, subcommand dispatch, exit codes |
| `src/capture.zig` | miniaudio default-input device → growable PCM buffer |
| `src/record.zig` | The record verb: capture loop, SPACE pause (paused audio is dropped), ESC/Ctrl-C stop, naming, chunked encode and atomic publication |
| `src/library.zig` | Scans `~/recordings/`, sorts newest-first, formats table; hosts the `recording` facade — `ext`, streaming `Encoder`, `encode`/`decode`/`durationSec`, the single switch point of the platform recording format (M4A on macOS, WAV elsewhere) ([ADR 0012](adr/0012-recording-format-per-platform.md)) |
| `src/m4a.zig` | M4A/AAC encode via AudioToolbox's system encoder (macOS only); container duration parse for `list`; `decode` back to canonical s16/48k/stereo PCM via `ExtAudioFileRead` ([ADR 0004](adr/0004-record-natively-in-m4a-aac.md)) |
| `src/wav.zig` | PCM16 WAV streaming encoder (sizes patched on `finish`) and `parseWav` reader ([ADR 0012](adr/0012-recording-format-per-platform.md)) |
| `src/player.zig` | In-process playback of decoded PCM on miniaudio's default output device: atomic playhead/paused/done, sample-accurate seek, silence-gated pause ([ADR 0010](adr/0010-play-audio-in-process.md)) |
| `src/playback.zig` | Interactive play: raw-mode TUI over `player.zig` — one composed frame per tick (hidden cursor, sync bracket) with the waveform grid and playhead cursor, SPACE pause, ←/→ and SHIFT+←/→ seek, I/O region anchors, DELETE with ENTER confirmation cutting via `cut.zig`, R reset, T transcribe-or-open transcript, Q stop; prints the `<stem>.md` transcript in full; blocking fallback off a tty |
| `src/waveform.zig` | Peak accumulation over PCM (100 ms blocks) and the shared multi-row half-block waveform grid — sqrt scale, VU colors, played-column dimming, reverse-video selection, full-height cursor and selection anchors ([ADR 0011](adr/0011-waveform-half-block-grid.md)) |
| `src/keys.zig` | Raw stdin keystrokes for the live views: plain bytes, arrow keys and SHIFT+arrows parsed from escape sequences, Delete (backspace and `ESC[3~`) |
| `src/live.zig` | Alternate-screen vocabulary for the live views: enter/leave (hardware cursor hidden while a view is up), synchronized-update brackets, absolute cursor positioning, line erase, row-wrap math ([ADR 0009](adr/0009-alternate-screen-live-views.md)) |
| `src/cut.zig` | Removes a marked time interval in place: decode (or read WAV) → frame-aligned slice → re-encode the remainder → replace the original |
| `src/transcribe.zig` | Spawns `/usr/bin/curl` against Deepgram pre-recorded API |
| `src/transcribecmd.zig` | The transcribe verb: resolve the selection, send the recording to Deepgram, render the OKF markdown, and run the LLM refine pass (shared by the CLI and the play view's `T`) |
| `src/okf.zig` | Renders the OKF markdown transcript (frontmatter + prose) |
| `src/tui.zig` | Raw-mode interactive menu; restores terminal on every exit path |
| `src/miniaudio.c` + `vendor/miniaudio.h` | Vendored single-file audio I/O |

## Runtime & hosting

Local CLI on macOS (Apple Silicon and Intel), Linux, and Windows. Built as a
single static `rec` binary per target with one zig toolchain (`zig build`,
ReleaseFast in CI); each native platform runs `zig build test` on its own CI
runner, the other targets cross-compile ([ADR 0013](adr/0013-cross-platform-builds.md)).
Releases ship `rec-<os>-<arch>` binaries, installed via `install.sh` (macOS,
Linux) or `install.ps1` (Windows). Released with release-please
(Conventional Commits).

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
