#!/usr/bin/env python3
# E2E: the record view's keys. SPACE pauses (the UI flips to ⏸ /
# SPACE=resume and the timer freezes), SPACE again resumes, ESC stops and
# saves — and the saved duration counts recorded time only, so the paused
# second must not be in the file. Reuses the pty terminal emulator from
# e2e_resize.py. Run from the repo root, after `zig build`.
import fcntl
import importlib.util
import os
import pty
import re
import select
import signal
import struct
import termios
import time

BIN = os.path.join(os.getcwd(), "zig-out/bin/rec")

_spec = importlib.util.spec_from_file_location(
    "e2e_resize", os.path.join(os.path.dirname(os.path.abspath(__file__)), "e2e_resize.py"))
er = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(er)
Screen, feed, check = er.Screen, er.feed, er.check


def spawn(rows, cols, home):
    mfd, sfd = pty.openpty()
    fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(mfd)
        os.setsid()
        fcntl.ioctl(sfd, termios.TIOCSCTTY, 0)
        os.dup2(sfd, 0)
        os.dup2(sfd, 1)
        os.dup2(sfd, 2)
        if sfd > 2:
            os.close(sfd)
        env = dict(os.environ, HOME=home, TERM="xterm-256color")
        os.execvpe(BIN, [BIN, "record"], env)
    os.close(sfd)
    return pid, mfd


def drain(screen, mfd, seconds):
    """Consume output for `seconds`; False when the child exited."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        r, _, _ = select.select([mfd], [], [], 0.05)
        if r:
            data = os.read(mfd, 65536)
            if not data:
                return False
            feed(screen, data)
    return True


def status(screen):
    for l in screen.lines():
        if "⏺" in l or "⏸" in l:
            return l.strip()
    return ""


def main():
    home = "/tmp/rec-e2e-keys-home"
    os.makedirs(os.path.join(home, "recordings"), exist_ok=True)
    screen = Screen(24, 100, reflow=False)
    pid, mfd = spawn(24, 100, home)
    try:
        assert drain(screen, mfd, 1.6), "rec exited before the first key"
        check(screen, "recording")  # the grid invariants hold mid-recording

        os.write(mfd, b" ")  # SPACE: pause
        assert drain(screen, mfd, 0.4), "exited after SPACE"
        paused = status(screen)
        assert "⏸" in paused and "SPACE=resume" in paused, f"pause UI missing: {paused!r}"
        drain(screen, mfd, 0.8)
        still = status(screen)
        assert still == paused, f"timer kept running while paused: {paused!r} -> {still!r}"

        os.write(mfd, b" ")  # SPACE: resume
        assert drain(screen, mfd, 1.4), "exited after resume"
        check(screen, "resumed")

        os.write(mfd, b"\x1b")  # ESC stops, like Ctrl-C
        deadline = time.monotonic() + 6
        while drain(screen, mfd, 0.1):
            assert time.monotonic() < deadline, "timeout waiting for rec to exit after ESC"
        _, wstatus = os.waitpid(pid, 0)
        assert os.WIFEXITED(wstatus) and os.WEXITSTATUS(wstatus) == 0, f"exit status {wstatus}"

        # After leaving the alternate screen the summary is on the normal
        # screen: "Saved <path> (<sec>.<cs> s, ...)".
        saved = [l for l in screen.lines() if "Saved" in l]
        assert saved, f"no Saved summary on the normal screen: {screen.lines()[:5]}"
        m = re.search(r"\((\d+)\.(\d\d) s,", saved[0])
        assert m, f"cannot parse the duration from {saved[0]!r}"
        dur = int(m.group(1)) + int(m.group(2)) / 100
        # ~1.5 s before the pause + ~1.4 s after the resume, minus device
        # startup. The paused 1.2 s is dropped: a pause bug shows as ~4 s.
        assert 1.7 <= dur <= 3.2, f"duration {dur} s not in [1.7, 3.2]"
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(mfd)
    print("E2E_RECORD_KEYS_OK")


if __name__ == "__main__":
    main()
