---
type: ADR
id: "0013"
title: "Cross-platform builds: one zig toolchain, three native test runners"
status: active
date: 2026-09-04
---

## Context

`rec` was macOS-only until [ADR 0012](0012-recording-format-per-platform.md)
split the recording format per platform, removing the last AudioToolbox
dependency from non-macOS builds. CI still tested and released only on
`macos-14` (Apple Silicon), so Linux and Windows support existed only where a
developer happened to cross-compile by hand — nothing kept those builds
compiling, tested, or shipped.

The build already crosses freely: zig 0.16 cross-compiles every target from
any host, and `build.zig` picks platform frameworks and link libraries per
target. GitHub hosts macOS (ARM), Linux, and Windows runners, so each native
platform can run the unit tests; Intel macOS has no reliable hosted runner
left (the release workflow's comment records why `macos-13` was retired), but
cross-compiling `x86_64-macos` from an ARM runner is the same zig invocation
as every other target.

## Decision

**One zig invocation per release target, three native runners for the unit
tests, and a `rec-<os>-<arch>` artifact name that installers resolve by
detection.**

- **CI** runs two jobs. `test` runs `zig build test` natively on `macos-14`,
  `ubuntu-latest`, and `windows-latest` — the compiler's typecheck plus the
  full suite on every OS that runs the binary. `build` cross-compiles all
  five release targets (`aarch64-macos`, `x86_64-macos`, `x86_64-linux`,
  `aarch64-linux`, `x86_64-windows`) and uploads each binary as a named
  artifact, so a PR that breaks any platform fails its own check.
- **Releases** repeat the build matrix with `-Doptimize=ReleaseFast` on the
  release tag and `gh release upload` each binary as
  `rec-macos-arm64` / `rec-macos-intel` / `rec-linux-x64` /
  `rec-linux-arm64` / `rec-windows-x64.exe`. The names are the install
  contract: the install script maps `uname -s`/`uname -m` to them, the
  PowerShell installer maps `$env:PROCESSOR_ARCHITECTURE` to the `.exe`.
- **Intel macOS is cross-compiled, never natively hosted** — there is no
  hosted runner for it. Its correctness story is the macOS-native test run
  (same sources, same zig) plus real hardware: the maintainer's Intel Mac
  pulls each release over SSH and runs a smoke test.

## Options considered

- **Native build per platform, zig only for Intel mac and aarch64-linux** —
  mixes toolchains for no benefit: native clang/msvc builds still need zig to
  cross the two gaps anyway, and two build systems means two places where a
  target can drift. Rejected.
- **Build all five targets from a single `ubuntu-latest` runner** — smallest
  matrix, but Windows and macOS tests would never run in CI, and the tests
  are where the platform shims (termios vs console API, pipes vs temp files)
  actually get exercised. Rejected.
- **Publish tarballs/zip per platform** — the product is a single static
  binary; a container adds an extraction step for every installer. Raw
  binaries with encoded names are what the installers fetch. Rejected.

## Consequences

- Every platform build compiles on every CI run, and a red platform is a red
  PR — the same gate macOS had alone.
- Release assets are fixed-name binaries: the installers are string-matching
  scripts, not release-API parsers, and `gh release upload --clobber` makes
  re-shipments idempotent.
- Intel macOS ships with native tests only on the source level; a regression
  that only misbehaves on x86_64 Mac hardware shows up in the maintainer's
  smoke test, not CI. Accepted until a hosted Intel runner returns or the
  platform drops below one supported release.
