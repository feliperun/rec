#!/usr/bin/env bash
# While `rec` records, plays the demo fixture through the speakers so
# the live waveform has a visible signal. Only used to regenerate
# docs/demo.gif — `vhs scripts/demo.tape` from the repo root.
set -euo pipefail
afplay -v 10 "$HOME/recordings/20260904-093001.m4a" &
sleep 0.3
exec rec --duration 5
