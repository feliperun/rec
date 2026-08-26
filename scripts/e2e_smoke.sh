#!/usr/bin/env bash
set -euo pipefail
REPO="$PWD"
T="$(mktemp -d)"
cd "$T"
export HOME="$T"
"$REPO/.runs/zig-out/bin/rec" record --duration 2
F="$(ls "$HOME"/recordings/*.m4a | head -1)"
test -s "$F"
"$REPO/.runs/zig-out/bin/rec" list | grep "$(basename "$F")"
"$REPO/.runs/zig-out/bin/rec" play "$(basename "$F")"
cd "$REPO"
rm -rf "$T"
echo E2E_OK
