# Architecture Decision Records

Architecture Decision Records (ADRs) for **rec**.

## Format

Each ADR is markdown with YAML frontmatter:

```markdown
---
type: ADR
id: "0001"
title: "Short decision title"
status: proposed        # proposed | active | superseded | retired
date: YYYY-MM-DD
superseded_by: "0007"  # only if status: superseded
---

## Context
...

## Decision
**What was decided.**

## Options considered
...

## Consequences
...
```

### Status lifecycle

```
proposed → active → superseded
                 ↘ retired
```

## Rules

- One decision per file.
- Files named `NNNN-short-title.md` (monotonic numbering).
- Once `active`, never edit — supersede instead.
- [../ARCHITECTURE.md](../ARCHITECTURE.md) reflects active decisions only.

## Index

| ID | Title | Status |
|----|-------|--------|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | active |
| [0002](0002-root-managed-ai-guidance.md) | Root-managed AI guidance files | active |
| [0003](0003-sentrux-structural-quality-gates.md) | Sentrux structural quality gates | active |
| [0004](0004-record-natively-in-m4a-aac.md) | Record natively in M4A/AAC instead of WAV | active |
| [0006](0006-decode-and-split-audio-in-process.md) | Decode and split audio in-process | superseded |
| [0007](0007-cut-marked-intervals-in-place.md) | Cut marked intervals in place | active |
| [0008](0008-finalize-recordings-incrementally-and-atomically.md) | Finalize recordings incrementally and atomically | active |
| [0009](0009-alternate-screen-live-views.md) | Draw live views on the alternate screen | active |
| [0010](0010-play-audio-in-process.md) | Play audio in-process instead of spawning afplay | active |
| [0011](0011-waveform-half-block-grid.md) | Render waveforms as a multi-row half-block grid | active |
| [0012](0012-recording-format-per-platform.md) | Recording format follows the platform: M4A on macOS, WAV elsewhere | active |
| [0013](0013-cross-platform-builds.md) | Cross-platform builds: one zig toolchain, three native test runners | active |
