#!/usr/bin/env bash
# Dev smoke: one real 2 s capture through the built binary.
# Run from the repo root, after `zig build` (binary at .runs/zig-out/bin).
set -euo pipefail

REPO="$PWD"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T"
export HOME="$T"

"$REPO/.runs/zig-out/bin/rec" record --duration 2

# exactly one .wav under ~/recordings/
set -- "$HOME"/recordings/*.wav
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "expected exactly one .wav in $HOME/recordings, found: $*" >&2
  exit 1
fi

size="$(stat -f %z "$1")"
if [ "$size" -lt 100000 ]; then
  echo "wav too small: $size bytes" >&2
  exit 1
fi

# afinfo must report a duration for the finalized file
afinfo "$1" 2>&1 | grep -i 'estimated duration'

echo RECORD_SMOKE_OK
