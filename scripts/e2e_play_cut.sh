#!/usr/bin/env bash
# E2E: interactive play on a pty — the transcript viewer is visible, the
# waveform bar appears, and anchoring the region with O then deleting it
# with DELETE (confirmed by ENTER) removes the head of the recording,
# replacing the original in place. A second run presses T, which opens the
# existing transcript in the Markdown viewer. Deterministic: the fixture is generated
# with ffmpeg (no microphone), and HOME is isolated.
set -euo pipefail
REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"

command -v ffmpeg >/dev/null || { echo "E2E_SKIP: ffmpeg not installed"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
export XDG_CONFIG_HOME="$T/.config"
mkdir -p "$XDG_CONFIG_HOME/rec"
date +%s > "$XDG_CONFIG_HOME/rec/update_state"
mkdir -p "$HOME/recordings"

ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=6" \
  -c:a aac -b:a 128k -f mp4 "$HOME/recordings/e2e-cut.m4a"
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=3" \
  -c:a aac -b:a 96k -f mp4 "$HOME/recordings/e2e-tail.m4a"

cat > "$HOME/recordings/e2e-cut.md" <<'EOF'
---
duration: 6.0
language: pt-BR
---
MARKER_LINE_ALPHA
segunda linha do transcript
EOF
for n in $(seq 1 40); do printf 'linha longa de teste %02d\n' "$n" >> "$HOME/recordings/e2e-cut.md"; done

# Play on a pty, anchor the region's end at ~1.5 s (so the head [0..~1.5]
# is removed), press DELETE at ~2.1 s and confirm with ENTER at ~2.6 s.
# The view stays up and playback continues on the shorter recording; the
# cut note is still on the notes row when End scrolls the transcript and Q
# quits at ~4.6 s.
( sleep 1.5; printf 'o'; sleep 0.6; printf '\x7f'; sleep 0.5; printf '\r'; sleep 1.5; printf '\033[F'; sleep 0.5; printf 'q' ) | \
  script -q /dev/null "$BIN" play e2e-cut.m4a > "$T/pty.log" 2>&1

# The transcript viewer and hints row drew.
grep -q "MARKER_LINE_ALPHA" "$T/pty.log"
grep -q "segunda linha do transcript" "$T/pty.log"
grep -q "linha longa de teste 40" "$T/pty.log"
# With the anchor set, the hints offer the reset.
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
"$BIN" list > "$T/list.log"
grep -E "e2e-cut\.m4a[[:space:]]+00:0[45]" "$T/list.log"

# A tail cut (I only) keeps playback open after the replacement; Q exits the
# still-live player explicitly.
( sleep 1; printf 'i'; sleep 0.4; printf '\x7f'; sleep 0.4; printf '\r'; sleep 1; printf 'q' ) | \
  script -q /dev/null "$BIN" play e2e-tail.m4a > "$T/tail.log" 2>&1
grep -q "Cut e2e-tail.m4a" "$T/tail.log"
test -s "$HOME/recordings/e2e-tail.m4a"

# T with a transcript on disk opens the Markdown viewer, scrolls to the end,
# returns to the top, and exits cleanly. The last line proves the viewport
# moved; Home proves it can return to the start without a full-screen redraw
# loop while idle.
( sleep 2; printf 't'; sleep 0.5; printf '\033[F'; sleep 0.5; printf '\033[H'; sleep 0.5; printf 'q' ) | script -q /dev/null \
  "$BIN" play e2e-cut.m4a > "$T/pty2.log" 2>&1
grep -q "METADATA" "$T/pty2.log"
grep -q "linha longa de teste 40" "$T/pty2.log"

echo E2E_PLAY_CUT_OK
