#!/usr/bin/env python3
"""The AIREC integration end to end, isolated from real devices and data.

`import` converts .ops files copied off the recorder; `sync` talks the
recorder's Bluetooth protocol, here to the simulated recorder a
`zig build -Dfake-airec=true` binary serves from REC_FAKE_AIREC_DIR.

The fixture is synthetic: a 3 s 440 Hz tone encoded the way the recorder
does it (16 kHz mono Opus, 20 ms packets at a constant 32 kbps, 80 bytes
each, stored back to back). Usage: e2e_airec.py <rec binary built with
-Dfake-airec=true>
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import wave


binary = str(Path(sys.argv[1]).resolve())
fixture = Path(__file__).resolve().parent / "fixtures" / "20250101-120000.ops"


def rec(*args, env):
    return subprocess.run(
        [binary, *args], env=env, capture_output=True, encoding="utf-8",
        timeout=60, check=False,
    )


def names(library):
    return sorted(p.name for p in library.iterdir())


def check_import(workspace, env):
    library = Path(workspace) / "recordings"
    # A trailing partial packet, as a recording cut off mid-write leaves,
    # is dropped instead of failing the import.
    source = Path(workspace) / "device" / "20250101-120000.OPS"
    source.parent.mkdir()
    shutil.copyfile(fixture, source)
    with open(source, "ab") as f:
        f.write(b"\x4b\x41" + bytes(46))

    first = rec("device", "airec", "import", str(source), env=env)
    assert first.returncode == 0, first
    assert "Imported" in first.stderr and "(00:03)" in first.stderr, first
    recordings = names(library)
    assert recordings in (["20250101-120000.m4a"], ["20250101-120000.wav"]), recordings
    imported = library / recordings[0]
    assert source.stat().st_size == fixture.stat().st_size + 48, "source changed"

    if imported.suffix == ".wav":
        with wave.open(str(imported)) as w:
            assert (w.getframerate(), w.getnchannels()) == (48000, 2)
            frames = w.readframes(w.getnframes())
        samples = memoryview(frames).cast("h")
        assert max(abs(s) for s in samples) > 4000, "the tone did not survive"

    listing = rec("list", env=env)
    assert imported.name in listing.stdout and "00:03" in listing.stdout, listing

    # Importing the same device again adds nothing.
    again = rec("device", "airec", "import", str(source), env=env)
    assert again.returncode == 0 and "Skipped" in again.stderr, again
    assert names(library) == [imported.name]

    # Anything but an .ops file is refused without touching the library.
    other = Path(workspace) / "note.txt"
    other.write_text("not audio")
    refused = rec("device", "airec", "import", str(other), env=env)
    assert refused.returncode == 1, refused
    assert "is not an .ops recording" in refused.stderr, refused
    assert names(library) == [imported.name]
    return imported.suffix


def check_sync(workspace, env, ext):
    library = Path(workspace) / "recordings"
    # No recorder in range: a clear message, nothing imported.
    missing = rec("device", "airec", "sync", env=env)
    assert missing.returncode == 1 and "no AIREC recorder found" in missing.stderr, missing

    recorder = Path(workspace) / "recorder"
    recorder.mkdir()
    shutil.copyfile(fixture, recorder / "20250102130000.ops")
    shutil.copyfile(fixture, recorder / "20250103140000.ops")
    env = {**env, "REC_FAKE_AIREC_DIR": str(recorder)}

    synced = rec("device", "airec", "sync", "--no-notes", env=env)
    assert synced.returncode == 0, synced
    assert synced.stderr.count("Imported") == 2, synced
    assert "20250102130000" + ext in names(library), names(library)
    assert "20250103140000" + ext in names(library), names(library)
    assert not any(n.endswith(".md") for n in names(library)), "--no-notes transcribed"

    again = rec("device", "airec", "sync", "--no-notes", env=env)
    assert again.returncode == 0 and "Up to date" in again.stderr, again

    # With notes on, a new recording is still imported when transcription
    # cannot run (no API key here), and the failure is reported.
    (library / ("20250103140000" + ext)).unlink()
    noted = rec("device", "airec", "sync", env=env)
    assert noted.returncode == 0, noted
    assert "Imported 20250103140000" in noted.stderr, noted
    assert "transcription failed" in noted.stderr, noted
    assert "20250103140000" + ext in names(library), names(library)


with tempfile.TemporaryDirectory(prefix="rec-airec-") as workspace:
    env = {**os.environ, "HOME": workspace, "USERPROFILE": workspace}
    env.pop("DEEPGRAM_API_KEY", None)
    env.pop("REC_FAKE_AIREC_DIR", None)
    config = Path(workspace) / ".config" / "rec"
    config.mkdir(parents=True)
    env["XDG_CONFIG_HOME"] = str(config.parent)
    # Mark today's update check as done so no network call runs.
    (config / "update_state").write_text(f"{int(time.time())}\n")

    ext = check_import(workspace, env)
    check_sync(workspace, env, ext)

print("E2E_AIREC_OK")
