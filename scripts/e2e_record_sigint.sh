#!/usr/bin/env bash
# E2E: stop a real short capture with SIGINT and verify atomic M4A publication.
# Run from the repo root, after `zig build` (binary at zig-out/bin/rec).
set -euo pipefail

REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/recordings"

"$BIN" record >"$T/record.log" 2>&1 &
pid=$!
for _ in {1..50}; do
  if grep -q '^Recording to ' "$T/record.log"; then
    break
  fi
  sleep 0.1
done
if ! grep -q '^Recording to ' "$T/record.log"; then
  cat "$T/record.log" >&2
  echo "record did not start" >&2
  exit 1
fi

kill -INT "$pid"
wait "$pid"

shopt -s nullglob
files=("$HOME"/recordings/*.m4a)
parts=("$HOME"/recordings/*.part)
if [ "${#files[@]}" -ne 1 ] || [ ! -s "${files[0]}" ]; then
  echo "expected one non-empty finalized M4A" >&2
  cat "$T/record.log" >&2
  exit 1
fi
if [ "${#parts[@]}" -ne 0 ]; then
  echo "unfinished .part file was published" >&2
  exit 1
fi

afinfo "${files[0]}" 2>&1 | grep -i 'estimated duration'

echo E2E_RECORD_SIGINT_OK
