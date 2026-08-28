#!/usr/bin/env bash
# E2E: interactive play on a pty — the transcript is printed in full, the
# waveform bar appears, and pressing S splits the recording at the current
# position (removing the original). Deterministic: the fixture is generated
# with ffmpeg (no microphone), and HOME is isolated.
set -euo pipefail
REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"

command -v ffmpeg >/dev/null || { echo "E2E_SKIP: ffmpeg not installed"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/recordings"

ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=6" \
  -c:a aac -b:a 128k -f mp4 "$HOME/recordings/e2e-split.m4a"

cat > "$HOME/recordings/e2e-split.md" <<'EOF'
---
duration: 6.0
language: pt-BR
---
MARKER_LINE_ALPHA
segunda linha do transcript
EOF

# Play on a pty and press S at ~1.5 s. Interactive play ends on its own
# once the split succeeds (the original is gone), so no quit key is needed.
( sleep 1.5; printf 's' ) | script -q /dev/null \
  "$BIN" play e2e-split.m4a > "$T/pty.log" 2>&1

# The transcript was printed in full and the interactive bar drew (the
# ASCII key legend is part of the live status line).
grep -q "MARKER_LINE_ALPHA" "$T/pty.log"
grep -q "segunda linha do transcript" "$T/pty.log"
grep -q "SPACE=pause S=split Q=stop" "$T/pty.log"

# S split at ~1.5 s of 6 s: both parts exist, the original is gone.
test -s "$HOME/recordings/e2e-split-part1.m4a"
test -s "$HOME/recordings/e2e-split-part2.m4a"
test ! -e "$HOME/recordings/e2e-split.m4a"
"$BIN" list | grep -q "e2e-split-part1"
"$BIN" list | grep -q "e2e-split-part2"

echo E2E_PLAY_SPLIT_OK
