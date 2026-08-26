# Getting Started

## Prerequisites

- macOS on Apple Silicon with a working microphone (CoreAudio access for the
  host terminal).
- [Zig](https://ziglang.org) 0.16.0 — `brew install zig`.
- [Sentrux CLI](sentrux.md#install) for the structural quality gate.

## Quick start

```bash
zig build                    # compile; binary at zig-out/bin/rec
zig build test               # unit tests
./zig-out/bin/rec record --duration 2   # smoke-record 2 s
./scripts/e2e_smoke.sh       # record → list → play end-to-end
```

No `.env` is needed for recording; `DEEPGRAM_API_KEY` is only required when
running `rec transcribe`.

## Daily commands

```bash
zig build test            # compile + unit tests (zig build is the typecheck)
sentrux check .           # architectural rules
sentrux gate .            # no structural regression
```

## Worktree workflow

```bash
# Create a worktree for a task (keeps main clean):
git worktree add ../rec-<task> -b <dev>/<issue>-<slug>
```

## Documentation map

- [Vision](VISION.md) — why this exists
- [Architecture](ARCHITECTURE.md) — current-state structure
- [Abstractions](ABSTRACTIONS.md) — the vocabulary
- [ADRs](adr/README.md) — decision history
- [Sentrux](sentrux.md) — the quality gate
- [AGENTS.md](../AGENTS.md) — the contributor/agent playbook

## First contribution checklist

- [ ] Read [AGENTS.md](../AGENTS.md).
- [ ] Run the check suite locally and confirm it's green.
- [ ] `sentrux gate --save .` before touching existing files.
