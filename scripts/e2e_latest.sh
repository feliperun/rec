#!/usr/bin/env bash
# E2E: the implied verb and the implied selection. Bare `rec --duration 1`
# records (no `record` verb), and `rec play` / `rec transcribe` / `rec
# format` with no selection act on the latest recording — the newest file,
# not the first one scanned. Deterministic fixtures (ffmpeg), isolated HOME;
# the one real capture needs a microphone, like e2e_colors.sh.
set -euo pipefail
REPO="$PWD"
BIN="$REPO/zig-out/bin/rec"

command -v ffmpeg >/dev/null || { echo "E2E_SKIP: ffmpeg not installed"; exit 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/recordings"

# Two fixtures; the "newest" one is scanned second on purpose, so a scan
# order mistake would pick the wrong file.
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a aac -f mp4 "$HOME/recordings/older.m4a"
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=880:duration=1" \
  -c:a aac -f mp4 "$HOME/recordings/newest.m4a"
touch -t 202601010000 "$HOME/recordings/older.m4a"
touch -t 202606010000 "$HOME/recordings/newest.m4a"

# play with no selection names the newest (piped stderr: the blocking path).
"$BIN" play 2>"$T/play.log" </dev/null
grep -q "Playing newest.m4a" "$T/play.log"

# transcribe with no selection resolves to the newest before needing a key:
# the error names the missing key, not a missing selection or usage.
if env -u DEEPGRAM_API_KEY XDG_CONFIG_HOME="$T/cfg" "$BIN" transcribe 2>"$T/tr.log"; then
  echo "E2E_FAIL: transcribe succeeded without a key" >&2; exit 1
fi
grep -q "no Deepgram API key configured" "$T/tr.log"
if grep -q "Usage:" "$T/tr.log"; then
  echo "E2E_FAIL: transcribe without a selection printed the usage" >&2; exit 1
fi

# format with no selection lands on the newest transcript: with no LLM
# configured it stops at the runner, never at the selection.
printf -- "---\nduration: 1.0\n---\nolá\n" > "$HOME/recordings/newest.md"
if XDG_CONFIG_HOME="$T/cfg" "$BIN" format 2>"$T/fmt.log"; then
  echo "E2E_FAIL: format succeeded without an LLM" >&2; exit 1
fi
if grep -q "nenhuma gravação corresponde\|uso:" "$T/fmt.log"; then
  echo "E2E_FAIL: format without a selection did not resolve the latest" >&2; exit 1
fi

# The implied record verb: a leading flag records.
"$BIN" --duration 1 >/dev/null 2>&1
test "$(ls "$HOME"/recordings/*.m4a | wc -l)" -eq 3

# help is a verb and a flag.
"$BIN" help | grep -q "^Usage: rec"
"$BIN" --help | grep -q "^Usage: rec"

echo E2E_LATEST_OK
