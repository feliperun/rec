---
type: ADR
id: "0002"
title: "Root-managed AI guidance files"
status: active
date: 2026-08-26
---

## Context

Multiple AI tools (Cursor, Claude Code, Gemini CLI) each expect their own
instruction file at the repository root. Maintaining `CLAUDE.md`, `GEMINI.md`, and
`CURSOR.md` as separate documents means every guardrail change has to land in each
of them; in practice one gets updated and the rest drift, so different agents end
up working under different rules in the same repo.

## Decision

**`AGENTS.md` at the repo root is the canonical AI + contributor guidance.
Tool-specific files (`CLAUDE.md`, `GEMINI.md`, `CURSOR.md`, `AGENT.md`)
are symlinks to `AGENTS.md`.** Update guidance in
one place only.

## Options considered

- **AGENTS.md canonical + symlinks** (chosen): one source of truth, and drift is
  impossible by construction rather than by discipline; `AGENTS.md` is the name
  the ecosystem is converging on.
- **CLAUDE.md only**: works for Claude; other tools miss shared guardrails.
- **Separate full files per tool**: guaranteed drift.

## Consequences

- PRs that change workflow, checks, or guardrails edit `AGENTS.md` once.
- Coding agents prefer links into `docs/` over inflating the root file.
- A broken symlink on a platform without symlink support falls back to a regen
  step (`init-agentkit --force`).
