# Architecture

> Current-state summary. ADRs in [adr/](adr/README.md) hold the history and the
> *why*; this file reflects only **active** decisions. Update it in the same
> commit as any structural change.

## High-level flow

```
microphone ──miniaudio──▶ PCM frames in memory ──m4a.zig (chunked AAC)──▶ .part ──rename──▶ ~/recordings/*.m4a
                                                                        │
                                   library.zig (scan, sort, table) ◀────┤
                                                                        │
              m4a.zig (decode, s16/48k/stereo) ◀── WAV/M4A on disk ◀────┤
                        │                                               │
                        ├── waveform.zig (peaks, live bar) ◀── record   │
                        │                                               │
                        ├── playback.zig ──/usr/bin/afplay──▶ speaker   │
                        │        │ SPACE pause · I/O mark · D cut · Q    │
                        │        └── cut.zig (remove interval → re-enc)  │
                        │                                               │
                        └── <stem>.md transcript ── printed in full ────┤
                                                                        │
                transcribe.zig ──/usr/bin/curl──▶ Deepgram ──▶ okf.zig ──▶ *.md
```

`main.zig` parses the subcommand and dispatches; `tui.zig` wraps the same
verbs in a raw-mode interactive menu.

## Components

| Module | Responsibility |
|--------|----------------|
| `src/main.zig` | Arg parsing, subcommand dispatch, exit codes |
| `src/capture.zig` | miniaudio default-input device → growable PCM buffer |
| `src/record.zig` | The record verb: capture loop, naming, chunked encode and atomic publication |
| `src/m4a.zig` | M4A/AAC encode via AudioToolbox's system encoder; container duration parse for `list`; `decode` back to canonical s16/48k/stereo PCM via `ExtAudioFileRead` |
| `src/library.zig` | Scans `~/recordings/`, sorts newest-first, formats table |
| `src/playback.zig` | Interactive play: raw-mode TUI over `/usr/bin/afplay` — live waveform, SPACE pause (SIGSTOP/SIGCONT), I/O marks, D cut, R reset marks, Q stop; prints the `<stem>.md` transcript in full; blocking fallback off a tty |
| `src/waveform.zig` | Peak accumulation over PCM (100 ms blocks) and one-line Unicode block-bar rendering with played-column dimming and reverse-video selection; terminal width |
| `src/live.zig` | Resize-safe in-place redraw: row-wrap math and the escape sequence that erases a drawn line block under the current terminal width |
| `src/cut.zig` | Removes a marked time interval in place: decode (or read WAV) → frame-aligned slice → re-encode the remainder → replace the original |
| `src/transcribe.zig` | Spawns `/usr/bin/curl` against Deepgram pre-recorded API |
| `src/okf.zig` | Renders the OKF markdown transcript (frontmatter + prose) |
| `src/tui.zig` | Raw-mode interactive menu; restores terminal on every exit path |
| `src/miniaudio.c` + `vendor/miniaudio.h` | Vendored single-file audio I/O |

## Runtime & hosting

Local CLI on Apple Silicon macOS. Built as a single `rec` binary
(`zig build`, ReleaseFast in CI), installed via `install.sh` to
`/usr/local/bin`. Released with release-please (Conventional Commits).

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
