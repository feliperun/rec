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

# exactly one .m4a under ~/recordings/
set -- "$HOME"/recordings/*.m4a
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "expected exactly one .m4a in $HOME/recordings, found: $*" >&2
  exit 1
fi

size="$(stat -f %z "$1")"
# 2 s of AAC ≈ tens of KiB; silence would still frame out well above this.
if [ "$size" -lt 4000 ]; then
  echo "m4a too small: $size bytes" >&2
  exit 1
fi

# afinfo must report a duration for the finalized file
afinfo "$1" 2>&1 | grep -i 'estimated duration'

echo RECORD_SMOKE_OK
