# Sentrux — structural quality gate

[Sentrux](https://github.com/sentrux/sentrux) is the structural-quality sensor
for this repo. It scores the dependency/call graph and **ratchets against
regression**, complementing (not replacing) type checks and tests.

## 1. Install

```bash
# macOS / Linux — pin the version to match CI (.github/workflows/quality.yml)
SENTRUX_VERSION=v0.5.7
mkdir -p "$HOME/.sentrux/bin"
curl -fsSL "https://github.com/sentrux/sentrux/releases/download/${SENTRUX_VERSION}/sentrux-$(uname -s | tr A-Z a-z)-$(uname -m)" \
  -o "$HOME/.sentrux/bin/sentrux" && chmod +x "$HOME/.sentrux/bin/sentrux"
export PATH="$HOME/.sentrux/bin:$PATH"
sentrux --version
```

## 2. What Sentrux measures

- **Coupling grade** (A–F) over the import graph.
- **Cycles** — import/dependency cycles (target: 0).
- **God files** — files doing too much.
- **Complexity** — per-function cyclomatic ceiling.
- **Quality signal** — an aggregate score to optimize against.

## 3. The two commands

| Command | Enforces | Config |
|---------|----------|--------|
| `sentrux check .` | absolute hard limits | `.sentrux/rules.toml` |
| `sentrux gate .` | no regression vs baseline | `.sentrux/baseline.json` |

```bash
sentrux check .           # exits 0 if rules pass, 1 if not
sentrux gate --save .     # snapshot baseline (run before a refactor)
sentrux gate .            # compare current vs baseline; fails on degradation
```

## 4. Our rules (`.sentrux/rules.toml`)

Absolute ceilings. Tighten as the codebase grows — **never loosen without an ADR.**

## 5. The baseline (`.sentrux/baseline.json`)

Committed reference for `gate`. Move it **up only** — re-saving to mask a
regression defeats the ratchet.

## 6. Daily workflow

```bash
# 1. Before touching existing files, capture where you started:
sentrux gate --save .
# 2. Do the work…
# 3. Before committing:
sentrux check . && sentrux gate .
```

Boy Scout Rule: every file you touch leaves with an equal-or-better score.
Never silence a rule to pass — fix the structure.

## 7. CI integration

`.github/workflows/quality.yml` installs the pinned Sentrux release, runs
`sentrux check .` on every push, and `sentrux gate .` on PRs. A failing gate
blocks merge.
