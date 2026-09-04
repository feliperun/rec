#!/usr/bin/env bash
# Colors are a tty-only affordance: a pty (script) sees ANSI codes, a pipe
# does not — piped output must stay plain for scripts. NO_COLOR opts out.
set -euo pipefail
REPO="$PWD"
REC="$REPO/zig-out/bin/rec"
T="$(mktemp -d)"
cd "$T"
export HOME="$T"

"$REC" record --duration 1 >/dev/null 2>&1
F="$(ls "$HOME"/recordings/*.m4a | head -1)"

# A pipe is not a tty: no ANSI escapes.
if "$REC" list | grep -q $'\x1b'; then
  echo "E2E_FAIL: piped output carries ANSI escapes" >&2
  exit 1
fi
"$REC" list | grep "$(basename "$F")" >/dev/null

# A pty is: the list table is styled.
if ! script -q /dev/null "$REC" list | grep -q $'\x1b\['; then
  echo "E2E_FAIL: tty output carries no ANSI escapes" >&2
  exit 1
fi

# NO_COLOR opts out even on a pty.
if script -q /dev/null env NO_COLOR=1 "$REC" list | grep -q $'\x1b\['; then
  echo "E2E_FAIL: NO_COLOR did not suppress escapes" >&2
  exit 1
fi

cd "$REPO"
rm -rf "$T"
echo E2E_OK
