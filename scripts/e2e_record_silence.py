#!/usr/bin/env python3
"""Exercise capture, encoding, publication and diagnostics without a microphone.

Run with a binary built using zig build -Dsilent-input=true --prefix <temp>.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="rec-silence-") as workspace:
    env = {**os.environ, "HOME": workspace, "USERPROFILE": workspace}
    # Closed stdin must still pace the loop. A timeout also bounds hangs.
    with tempfile.TemporaryFile() as log:
        result = subprocess.run(
            [binary, "record", "--duration", "11"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            env=env, timeout=25, check=False,
        )
        size = log.tell()
        assert size < 100_000, f"unpaced recording loop wrote {size} bytes"
        log.seek(0)
        output = log.read().decode()
    assert result.returncode == 0, output
    assert "Saved" in output, output
    warning = "warning: recorded audio stayed very quiet"
    assert output.count(warning) == 1, output
    assert output.index(warning) > output.index("Saved"), output
    recordings = list((Path(workspace) / "recordings").iterdir())
    assert len(recordings) == 1, recordings
    assert recordings[0].suffix in (".m4a", ".wav"), recordings
    assert recordings[0].stat().st_size > 0
    # The CLI must read the finalized container it just published.
    listing = subprocess.run(
        [binary, "list"], env=env, capture_output=True, text=True,
        timeout=10, check=True,
    )
    assert recordings[0].name in listing.stdout, listing
    assert "00:11" in listing.stdout, listing

print("E2E_RECORD_SILENCE_OK")
