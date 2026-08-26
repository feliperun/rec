---
description: Create a new Architecture Decision Record under docs/adr/
---

Create a new ADR in `docs/adr/` documenting a structural decision for rec.

## Steps

1. **Read [docs/adr/README.md](../../docs/adr/README.md)** for the format, lifecycle rules, and the current index. Note the next available number (max existing + 1, four-digit zero-padded).

2. **Confirm the decision is ADR-worthy.** ADRs document:
   - New dependencies that change the surface area (new backend, new external service, new provider).
   - Storage strategy or schema convention changes.
   - New platform target or distribution channel.
   - Core abstractions (new trait/protocol, new domain model, change to a central store).
   - Hosting or secrets strategy changes.
   - Cross-cutting patterns future contributors must follow.

   ADRs do **not** document bug fixes, behavior-preserving refactors, dependency version bumps, or formatting changes. If the change is one of those, do not create an ADR — explain why and stop.

3. **Gather the inputs** before writing. Ask the user (or read context) for:
   - A short title (≤ 70 chars).
   - The forces / constraints that led to the decision (context).
   - The decision in one or two sentences.
   - At least two alternatives considered, with the chosen one marked.
   - Consequences — what gets easier, what gets harder, what invariants the codebase must now hold, what would trigger re-evaluation.

4. **Create the file** at `docs/adr/NNNN-short-title.md` using the template from [docs/adr/0000-template.md](../../docs/adr/0000-template.md). Use `kebab-case` for the slug. Frontmatter:
   - `id: "NNNN"` (four-digit, quoted)
   - `status: active` (new ADRs default to `active` when the decision has been made; use `proposed` only if it's still under discussion)
   - `date: YYYY-MM-DD` (today)
   - Omit `superseded_by` unless this ADR supersedes a previous one (in which case also update the previous ADR to `status: superseded` + `superseded_by` link in the same commit).

5. **Update the index** in [docs/adr/README.md](../../docs/adr/README.md): add a row to the index table at the bottom in numeric order.

6. **Update [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) if the decision changes the active architecture state.** ARCHITECTURE.md reflects active decisions only — a superseded decision must be replaced, not appended.

7. **Commit in a single Conventional Commit** with the rest of the change that implements the decision:
   ```
   docs(adr): NNNN <short title>
   ```
   or as part of a `feat:` / `refactor:` commit if landing the implementation in the same change.

8. **Never edit an active ADR.** If the decision changes, create a new ADR that supersedes the previous one and update the previous ADR's frontmatter only to record `status: superseded` and `superseded_by`.
