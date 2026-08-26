---
type: ADR
id: "0001"
title: "Record architecture decisions"
status: active
date: 2026-08-26
---

## Context

As rec grows with multiple contributors and AI agents, decisions get
scattered across chat history and commit messages, making it hard to know *why*
the system looks the way it does.

## Decision

**Record every structural choice as an Architecture Decision Record in
`docs/adr/`.** Each decision gets its own numbered, immutable file; a changed
decision supersedes the prior ADR instead of editing it.

## Options considered

- **ADR folder with frontmatter** (chosen): versioned alongside the code it
  explains, so a decision and its implementation move together; the frontmatter
  is machine-readable, which lets agents filter by status; the index lives in
  `README.md`.
- **Only a learnings doc**: lightweight but mixes incidents with irreversible
  architecture choices.
- **Wiki / external docs**: fine for product, poor for version-controlled
  coupling to code.

## Consequences

- New structural work adds or supersedes an ADR in the same PR.
- `docs/ARCHITECTURE.md` summarizes current state; ADRs hold the history.
- Agents read `docs/adr/` before large refactors (see `AGENTS.md`).
