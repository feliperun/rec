#!/usr/bin/env bash
# E2E: `rec record` with a closed stdin (scripted/cron use) must still tick
# at its 100 ms cadence instead of spinning on the EOF. The live view writes
# one line per tick to stderr, so a ~3 s run's log stays a few KB when paced
# and would balloon to tens of MB when the poll window is skipped.
# Run from the repo root, after `zig build` (binary at zig-out/bin/rec).
set -euo pipefail

REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/recordings"

"$BIN" record --duration 3 < /dev/null > "$T/record.log" 2>&1

shopt -s nullglob
files=("$HOME"/recordings/*.m4a)
if [ "${#files[@]}" -ne 1 ] || [ ! -s "${files[0]}" ]; then
  echo "expected one non-empty M4A" >&2
  cat "$T/record.log" >&2
  exit 1
fi

size=$(wc -c < "$T/record.log")
if [ "$size" -gt 1000000 ]; then
  echo "record.log grew to $size bytes: the key loop spun on the closed stdin" >&2
  head -c 2000 "$T/record.log" >&2
  exit 1
fi

echo "E2E_RECORD_STDIN_CLOSED_OK (log ${size} B)"
