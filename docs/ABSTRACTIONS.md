# Abstractions

> The vocabulary of this codebase: the core types/modules and the contracts
> between them. Read this before adding a new module — reuse an abstraction
> before inventing one.

## Core layers

| Layer | Modules | Single responsibility |
|-------|---------|----------------------|
| Transport / OS boundary | `capture.zig`, `player.zig`, `transcribe.zig` | Wrap one external producer/consumer (input device, output device, HTTP) |
| Format | `wav.zig`, `okf.zig` | Encode/decode one on-disk format each; no policy |
| Domain | `library.zig` | The recordings collection: scan, sort, resolve `index|filename` selections |
| Presentation | `main.zig`, `tui.zig` | CLI surface and interactive menu over the same verbs |

## External systems

| System | Boundary |
|--------|----------|
| Microphone (CoreAudio via miniaudio) | `capture.zig` |
| Speaker (CoreAudio via miniaudio) | `player.zig` |
| Deepgram pre-recorded API (`/usr/bin/curl`) | `transcribe.zig` |
| Filesystem (`~/recordings/`) | `library.zig` |

## Contracts & invariants

- A recording file on disk is always **complete** — headers finalized even when
  recording is interrupted (Ctrl-C included).
- Selection resolution (`index|filename`) is identical for `play` and
  `transcribe`; `library.zig` is the only place that implements it.
- Child processes are always reaped; interrupts forwarded, no zombies.
- Raw terminal mode is restored on every exit path.
- User-facing failures are one `rec <verb>: message` line on stderr + exit 1.

## Quality & governance

- Structural limits live in `.sentrux/rules.toml`; regression baseline in `.sentrux/baseline.json`.
- Architecture decisions are recorded as [ADRs](adr/README.md).

## Adding a new module — checklist

- [ ] Does an existing abstraction already cover this? Reuse it.
- [ ] Inputs/outputs validated at the boundary.
- [ ] Unit tests close to the change.
- [ ] `sentrux gate .` shows no degradation.
- [ ] ADR if it introduces a cross-cutting pattern or external dependency.
