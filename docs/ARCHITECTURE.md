# Architecture

> Current-state summary. ADRs in [adr/](adr/README.md) hold the history and the
> *why*; this file reflects only **active** decisions. Update it in the same
> commit as any structural change.

## High-level flow

```
microphone ──miniaudio──▶ PCM frames in memory ──m4a.zig (AAC)──▶ ~/recordings/*.m4a
                                                                        │
                                   library.zig (scan, sort, table) ◀────┤
                                                                        │
                playback.zig ──/usr/bin/afplay──▶ speaker ◀─────────────┤
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
| `src/record.zig` | The record verb: capture loop, naming, encode-on-stop |
| `src/m4a.zig` | M4A/AAC encode via AudioToolbox's system encoder; container duration parse for `list` |
| `src/library.zig` | Scans `~/recordings/`, sorts newest-first, formats table |
| `src/playback.zig` | Spawns `/usr/bin/afplay`, forwards interrupts |
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
