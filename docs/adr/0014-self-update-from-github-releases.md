# 14. Self-update from GitHub Releases

Date: 2026-09-05

## Status

active

## Context

rec ships as prebuilt binaries attached to GitHub Releases
(`rec-<os>-<arch>[.exe]`, the same artifacts the installers download), and
its version is embedded at build time from `build.zig.zon` (ADR 0013's
release-please flow bumps it on every release). Nothing tells an installed
`rec` that a newer release exists: users would have to watch the repository
and rerun the installer by hand.

## Decision

rec updates itself from GitHub Releases, in two modes over one shared code
path (`src/update.zig`):

- **`rec update`** — explicit, verbose: fetch the latest release, compare,
  download this platform's asset, replace the running binary.
- **Startup check** — before dispatching any command except `record` and
  `update` itself, at most once every 24 hours (timestamp in
  `<config_dir>/update_state`, written before checking so an offline
  machine never pays a network stall on every command). On a newer release
  it applies the update silently and prints one line ("rec: atualizado
  para X — vale na próxima execução"); every failure is mute.

Mechanics:

- The latest release comes from `GET /releases/latest` via the system curl
  (the same dependency transcribe uses); the asset is chosen by the exact
  artifact name for the running platform, the same contract the installers
  follow.
- The comparison uses the embedded `build.zig.zon` version against the tag
  (leading `v` stripped) as strict semver. An unparseable tag never
  triggers an update, and a locally newer build is never downgraded.
- Replacement is a rename next to the running executable: plain
  `rename(tmp, exe)` on POSIX (the running image keeps its inode); on
  Windows the running exe steps aside as `.old` first (renaming a running
  image is allowed, deleting is not), with rollback if the second rename
  fails. The downloaded file is made executable before the POSIX rename.
- The process keeps running the old image; the new version wins on the
  next invocation.

## Consequences

- An installed `rec` stays current with no user action and no package
  manager; the installers remain the one-time bootstrap.
- The 24-hour gate bounds network cost to one short curl per day per
  machine; `rec update` bypasses it for immediate needs.
- Updates inherit whatever permissions the install location allows: writing
  next to the binary is the installer's layout guarantee
  (`/usr/local/bin` via sudo, or a user-owned bin dir). A permission
  failure is reported by `rec update` and silent in the startup check.
- There is no rollback channel beyond reinstalling; releases are immutable
  artifacts, which is the safety property the rename scheme relies on.
