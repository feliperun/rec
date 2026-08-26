#!/usr/bin/env bash
# Layer-3 check: list shows a fixture WAV and play exits 0 on it.
set -euo pipefail

REPO="$PWD"
T="$(mktemp -d)"
mkdir -p "$T/recordings"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo -t 1 -c:a pcm_s16le "$T/recordings/fixture.wav"
cd "$T"
export HOME="$T"
"$REPO/.runs/zig-out/bin/rec" list | grep fixture.wav
"$REPO/.runs/zig-out/bin/rec" play fixture.wav
echo LIST_PLAY_OK
rm -rf "$T"
