#!/usr/bin/env bash
# Layer-3 check: list shows fixture recordings (M4A and legacy WAV) and play
# exits 0 on both.
set -euo pipefail

REPO="$PWD"
T="$(mktemp -d)"
mkdir -p "$T/recordings"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo -t 1 -c:a aac "$T/recordings/fixture.m4a"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo -t 1 -c:a pcm_s16le "$T/recordings/fixture.wav"
cd "$T"
export HOME="$T"
"$REPO/.runs/zig-out/bin/rec" list | grep fixture.m4a
"$REPO/.runs/zig-out/bin/rec" list | grep fixture.wav
"$REPO/.runs/zig-out/bin/rec" play fixture.m4a
"$REPO/.runs/zig-out/bin/rec" play fixture.wav
echo LIST_PLAY_OK
rm -rf "$T"
