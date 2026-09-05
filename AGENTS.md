# AGENTS.md — rec

> [Architecture](docs/ARCHITECTURE.md) · [Abstractions](docs/ABSTRACTIONS.md) · [Vision](docs/VISION.md) · [Getting Started](docs/GETTING-STARTED.md) · [ADRs](docs/adr/README.md) · [Sentrux](docs/sentrux.md)

Write the minimum code that runs. No fluff, no gold-plating.

- Do not preserve backward compatibility. Remove obsolete paths instead of adding
  compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements.
  Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end,
  and add each new capability on top of a product that already works. Never trade a
  working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity
  or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own
  implementation or adding packages. Do not assume a library lacks a capability
  without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only
  works for now and is meant to be replaced later.
- Study how established products solve the problem before designing a solution. Adopt
  their proven patterns and conventions rather than inventing an approach from scratch.

## Repository rules

- **`AGENTS.md` is the single source of guidance.** `CLAUDE.md`, `GEMINI.md`,
  `CURSOR.md` and `AGENT.md` are symlinks to it.
  Never edit a symlink; never let one drift into a real file.
- **Continuity beats restart.** Before starting new work, check `.runs/` and the
  managed signal block at the bottom of this file: an active campaign or a
  non-terminal run is work to continue — read its `HANDOFF.md`/`STATUS.md`,
  re-attach the session, and `resume` or `supervise` — not to redo.
- **Never commit secrets.** Tokens, credentials, and service-account JSON stay in a
  secret manager or a gitignored `.env`. The `pre-commit` hook scans the staged diff;
  do not work around it.
- **No personal or production-derived data in source**, migrations, fixtures, tests,
  or docs. Committed fixtures are synthetic. User-specific values belong in runtime
  configuration.
- **Never expose internals to users.** No stack traces, internal URLs, or env var
  names in user-facing copy.
- **Conventional Commits required.** `feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`. One logical change per commit; one bounded scope per PR. Release tooling
  parses them — a break in a published contract ships as `feat!:` or carries a
  `BREAKING CHANGE:` footer, never as a plain `feat:`.
- **Never `--no-verify`.** If a hook blocks, fix the underlying issue.
- **Code, comments, and identifiers in English.** Surgical changes — no opportunistic
  refactors in feature PRs, no suppression comments to silence a linter.
- **Shell scripts** run under `set -euo pipefail` and are idempotent — re-running
  completes what is missing instead of duplicating or destroying.

## Workflow

- Check `docs/adr/` before any structural choice. Branch from `main`.
- **TDD for behavior changes**: red → green → refactor → commit. Bug fixes start with
  a failing regression test. Exception: pure docs, formatting, or copy changes.
- **E2E for key features**: any user-visible change to a primary workflow adds or
  updates a deterministic E2E scenario, isolated from real data and credentials.
  Unit tests do not replace it.
- **ADRs** live in `docs/adr/`, one decision per file, created in the same commit as
  the code (`/create-adr`). Never edit an active ADR — supersede it. Required for a
  new dependency that changes surface area, a storage or schema convention, a core
  abstraction, a hosting or secrets strategy, or a cross-cutting pattern. Not for
  behavior-preserving fixes, refactors, version bumps, or copy tweaks. After a
  structural change, update `docs/ARCHITECTURE.md` in the same commit — it reflects
  **active** decisions only.
- **Destructive actions** — merging, force-pushing, changing repository permissions,
  dropping schema, deleting data — require explicit human sign-off in the moment.
  An agent that hits this gate hands off to the user rather than routing around it.

## Gates

```bash
zig build test            # compile + unit tests (zig build is the typecheck)
sentrux check .           # absolute limits (.sentrux/rules.toml)
sentrux gate .            # no structural regression vs .sentrux/baseline.json
```

Build+test runs on CI in `.github/workflows/ci.yml` (macOS runner — CoreAudio
frameworks); Sentrux runs in `.github/workflows/quality.yml`. Before touching existing files run
`sentrux gate --save .` to capture the baseline; before committing run `sentrux gate .`
— degradation on a touched file means refactor, not commit. New files pass
`sentrux check .` clean. **Never silence a rule to pass** — the gate is a ratchet, and
every file you touch leaves with an equal-or-better score.

Done means: gates pass locally, CI is green, no secrets or personal data in the diff,
`README.md` updated if a public contract changed, ADR written if a structural decision
was made.

## rec gotchas

Record every failure that cost real debugging time, with the invariant that prevents
it and a link to the ADR or code that must not be undone. Highest-value part of this
file — keep appending.

- CoreFoundation's `Boolean` is `UInt8`, **not** C `bool` — declare externs like
  `CFURLCreateFromFileSystemRepresentation` with a `u8` parameter or the varargs
  ABI corrupts the call. See `src/m4a.zig` and [ADR 0004](docs/adr/0004-record-natively-in-m4a-aac.md).
- `ExtAudioFileDispose` is what flushes the MP4 `moov` atom — skipping it after
  `ExtAudioFileWrite` leaves a headerless body that no player can open.
- AudioToolbox/CoreFoundation bindings are hand-declared externs whose fourccs
  were verified against the macOS SDK headers (`xcrun --show-sdk-path`), not
  `@cImport` — translate-c over Apple framework headers is brittle. Re-verify
  constants there before adding new ones.
- Zig `defer` runs at the **end of the enclosing block**, not the end of the
  function — a `defer gpa.free(x)` inside an `if` block frees at the `}`.
  Anything that aliases inside `x` (a `pcm` slice pointing into a freed
  WAV image) goes dangling silently and crashes later in libc, e.g.
  `CrashIfClientProvidedBogusAudioBufferList`. Hoist frees to function scope
  and keep the image alive for the whole scope that uses it. See [ADR 0007](docs/adr/0007-cut-marked-intervals-in-place.md)
  and `src/cut.zig`.
- std's Windows rename (`Dir.renameAbsolute`) asks the kernel for
  **POSIX rename semantics**, and `ACCESS_DENIED` never falls back to plain
  `FileRenameInformation` — so renaming the **running executable** (active
  image section) always fails, even though `MoveFileExW` handles it fine.
  Self-replacement must go through `MoveFileExW` (see `src/update.zig`);
  verify cross-platform file surgery on a real machine, CI runners can't
  catch it.
- **`cp zig-out/bin/rec*` on a Windows runner stages the PDB, not the exe**:
  the glob matches `rec.exe` and `rec.pdb`, and pwsh's `Copy-Item` then
  copies the last match under the artifact name — the v1.7.0/v1.8.0
  `rec-windows-x64.exe` release assets were program databases. Copy the
  exact binary per matrix column and execute the staged artifact before
  upload (the `sanity` step in `.github/workflows/release.yml`).

---

Adapted from [Marcos Hernanz](https://x.com/MarcosHernanz/status/2083954734487212511).
Structural gate by [Sentrux](https://github.com/sentrux/sentrux).
`CLAUDE.md`, `GEMINI.md`, `CURSOR.md` and `AGENT.md`
are symlinks to this file — edit `AGENTS.md` only.
