#!/usr/bin/env bash
# E2E: interactive play on a pty — the transcript is printed in full, the
# waveform bar appears, and anchoring the region with O then deleting it
# with DELETE (confirmed by ENTER) removes the head of the recording,
# replacing the original in place. A second run presses T, which opens the
# existing transcript in $EDITOR. Deterministic: the fixture is generated
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
  -c:a aac -b:a 128k -f mp4 "$HOME/recordings/e2e-cut.m4a"

cat > "$HOME/recordings/e2e-cut.md" <<'EOF'
---
duration: 6.0
language: pt-BR
---
MARKER_LINE_ALPHA
segunda linha do transcript
EOF

# Play on a pty, anchor the region's end at ~1.5 s (so the head [0..~1.5]
# is removed), press DELETE at ~2.1 s and confirm with ENTER at ~2.6 s.
# The view stays up and playback continues on the shorter recording; the
# cut note is still on the notes row when Q quits at ~4.1 s.
( sleep 1.5; printf 'o'; sleep 0.6; printf '\x7f'; sleep 0.5; printf '\r'; sleep 1.5; printf 'q' ) | \
  script -q /dev/null "$BIN" play e2e-cut.m4a > "$T/pty.log" 2>&1

# The transcript was printed in full and the hints row drew.
grep -q "MARKER_LINE_ALPHA" "$T/pty.log"
grep -q "segunda linha do transcript" "$T/pty.log"
grep -q "SPACE=pause ←→=1s SHIFT+←→=5s I=in O=out DEL=delete T=transcribe Q=stop" "$T/pty.log"
# With the anchor set, the hints offer the reset.
grep -q "DEL=delete R=reset T=transcribe Q=stop" "$T/pty.log"
# DELETE asked before cutting, and the success note confirmed the cut
# while the view was still up.
grep -q "? ENTER deletes, anything else cancels" "$T/pty.log"
grep -q "cut 00:00" "$T/pty.log"
grep -q "Cut e2e-cut.m4a" "$T/pty.log"

# The confirmed cut removed [0..~1.5] of 6 s: the original is replaced in
# place (no part files), roughly 4-5 s remain, and the transcript beside it
# is untouched.
test -s "$HOME/recordings/e2e-cut.m4a"
test ! -e "$HOME/recordings/e2e-cut-part1.m4a"
test ! -e "$HOME/recordings/e2e-cut-part2.m4a"
grep -q "MARKER_LINE_ALPHA" "$HOME/recordings/e2e-cut.md"
"$BIN" list | grep -E "e2e-cut\.m4a[[:space:]]+00:0[45]"

# T with a transcript on disk opens it in $EDITOR and exits cleanly. The
# editor is a stub that leaves a file behind — no editor suite on CI.
printf '#!/bin/sh\ntouch "$0.opened"\n' > "$T/fake-editor"
chmod +x "$T/fake-editor"
( sleep 2; printf 't' ) | EDITOR="$T/fake-editor" script -q /dev/null \
  "$BIN" play e2e-cut.m4a > "$T/pty2.log" 2>&1
test -e "$T/fake-editor.opened"

echo E2E_PLAY_CUT_OK
