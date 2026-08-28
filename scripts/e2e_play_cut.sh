#!/usr/bin/env bash
# E2E: interactive play on a pty — the transcript is printed in full, the
# waveform bar appears, and marking the piece with O then cutting it with D
# removes the head of the recording, replacing the original in place.
# Deterministic: the fixture is generated with ffmpeg (no microphone), and
# HOME is isolated.
set -euo pipefail
REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"

command -v ffmpeg >/dev/null || { echo "E2E_SKIP: ffmpeg not installed"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/recordings"

ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=6" \
  -c:a aac -b:a 128k -f mp4 "$HOME/recordings/e2e-cut.m4a"

cat > "$HOME/recordings/e2e-cut.md" <<'EOF'
---
duration: 6.0
language: pt-BR
---
MARKER_LINE_ALPHA
segunda linha do transcript
EOF

# Play on a pty, mark the end of the piece to cut at ~1.5 s (so the head
# [0..~1.5] is removed) and cut at ~2.1 s. Interactive play ends on its own
# once the cut succeeds (the original is replaced), so no quit key is needed.
( sleep 1.5; printf 'o'; sleep 0.6; printf 'd' ) | script -q /dev/null \
  "$BIN" play e2e-cut.m4a > "$T/pty.log" 2>&1

# The transcript was printed in full and the interactive bar drew (the
# ASCII key legend is part of the live status line).
grep -q "MARKER_LINE_ALPHA" "$T/pty.log"
grep -q "segunda linha do transcript" "$T/pty.log"
grep -q "SPACE=pause I=mark O=mark D=delete Q=stop" "$T/pty.log"
# With the mark set, the status line shows the span and R=reset appears.
grep -q "R=reset Q=stop" "$T/pty.log"
grep -q "Cut e2e-cut.m4a" "$T/pty.log"

# D cut [0..~1.5] of 6 s: the original is replaced in place (no part files),
# roughly 4-5 s remain, and the transcript beside it is untouched.
test -s "$HOME/recordings/e2e-cut.m4a"
test ! -e "$HOME/recordings/e2e-cut-part1.m4a"
test ! -e "$HOME/recordings/e2e-cut-part2.m4a"
grep -q "MARKER_LINE_ALPHA" "$HOME/recordings/e2e-cut.md"
"$BIN" list | grep -E "e2e-cut\.m4a[[:space:]]+00:0[45]"

echo E2E_PLAY_CUT_OK
