#!/usr/bin/env python3
# E2E: the live recording view survives terminal resizes. A pty runs
# `rec record` while the window shrinks and grows; a minimal terminal
# emulator replays the output under both reflow models real terminals use
# (xterm-style rewrap, Ghostty-style clip) and asserts the view stays
# exactly one header plus one live line. Run from the repo root, after
# `zig build` (binary at zig-out/bin/rec).
import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import time

BIN = os.path.join(os.getcwd(), "zig-out/bin/rec")

CSI = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")


class Screen:
    """A tiny ANSI grid: CR/LF/BS, CUP, EL, ED, alt-screen, optional reflow."""

    def __init__(self, rows, cols, reflow):
        self.rows, self.cols, self.reflow = rows, cols, reflow
        self.grid = [[" "] * cols for _ in range(rows)]
        self.soft = [False] * rows  # row created by wrapping
        self.cy = self.cx = 0
        self.pending = False
        self.alt = False
        self.main = None

    def scroll_up(self):
        del self.grid[0], self.soft[0]
        self.grid.append([" "] * self.cols)
        self.soft.append(False)

    def putc(self, ch):
        if self.pending:
            self.pending = False
            self.cx = 0
            self.cy += 1
            if self.cy >= self.rows:
                self.cy = self.rows - 1
                self.scroll_up()
            else:
                self.soft[self.cy] = True
        self.grid[self.cy][self.cx] = ch
        if self.cx + 1 >= self.cols:
            self.cx, self.pending = self.cols - 1, True
        else:
            self.cx += 1

    def newline(self):
        self.pending = False
        self.cy += 1
        if self.cy >= self.rows:
            self.cy = self.rows - 1
            self.scroll_up()

    def resize(self, cols):
        if self.reflow and not self.alt:
            self._reflow(cols)
            return
        self.cols = cols
        self.grid = [r[:cols] + [" "] * max(0, cols - len(r)) for r in self.grid]
        self.pending = False
        self.cy = min(self.cy, self.rows - 1)
        self.cx = min(self.cx, cols - 1)

    def _reflow(self, cols):
        logical, cur = [], []
        for row, soft in zip(self.grid, self.soft):
            cur.append("".join(row).rstrip())
            if not soft:
                logical.append(cur)
                cur = []
        if cur:
            logical.append(cur)
        grid, soft = [], []
        for chunk in logical:
            merged = "".join(chunk)
            while len(merged) > cols:
                grid.append(list(merged[:cols]))
                soft.append(True)
                merged = merged[cols:]
            grid.append(list(merged.ljust(cols)))
            soft.append(False)
        if len(grid) > self.rows:
            grid, soft = grid[-self.rows:], soft[-self.rows:]
        while len(grid) < self.rows:
            grid.insert(0, [" "] * cols)
            soft.insert(0, False)
        self.grid, self.soft, self.cols = grid, soft, cols
        self.pending = False
        self.cy = self.rows - 1
        self.cx = min(len("".join(self.grid[self.cy]).rstrip()), cols - 1)

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]


def utf8_len(b):
    """Bytes in the UTF-8 sequence started by lead byte `b`."""
    if b >= 0xF0:
        return 4
    if b >= 0xE0:
        return 3
    if b >= 0xC0:
        return 2
    return 1


def skip_osc(data, i):
    """Index past an OSC sequence: a BEL or ST terminator, whichever comes first."""
    ends = []
    bel = data.find(b"\x07", i)
    st = data.find(b"\x1b\\", i)
    if bel != -1:
        ends.append(bel + 1)
    if st != -1:
        ends.append(st + 2)  # ST is two bytes: ESC \
    return min(ends) if ends else len(data)


def feed_plain(screen, b, data, i):
    """Consume one non-escape byte; returns how many bytes it swallowed
    (the UTF-8 width for printable text, 1 otherwise)."""
    if b == 0x0D:
        screen.cx, screen.pending = 0, False
    elif b == 0x0A:
        screen.newline()
    elif b == 0x08:
        screen.cx = max(0, screen.cx - 1)
        screen.pending = False
    elif b >= 0x20:
        n = utf8_len(b)
        screen.putc(data[i : i + n].decode("utf-8", "replace"))
        return n
    return 1


def feed(screen, data):
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1B:
            m = CSI.match(data, i)
            if m:
                handle_csi(screen, m.group(1).decode(), m.group(2).decode())
                i = m.end()
                continue
            if data[i + 1 : i + 2] == b"]":  # OSC: title etc., no screen effect
                i = skip_osc(data, i)
                continue
            i += 1  # lone escape byte
            continue
        i += feed_plain(screen, b, data, i)


def csi_param(ps, idx, default):
    return ps[idx] if len(ps) > idx and ps[idx] else default


def csi_cursor(screen, params, final):
    """CUU / EL / ED / CUP."""
    ps = [int(x) for x in params.replace("?", "").split(";") if x]
    if final == "A":
        screen.pending = False
        screen.cy = max(0, screen.cy - max(1, csi_param(ps, 0, 1)))
    elif final == "K":
        start = screen.cx if csi_param(ps, 0, 0) == 0 else 0
        row = screen.grid[screen.cy]
        for c in range(start, screen.cols):
            row[c] = " "
        screen.pending = False
    elif final == "J" and csi_param(ps, 0, 0) == 2:
        screen.grid = [[" "] * screen.cols for _ in range(screen.rows)]
        screen.pending = False
    elif final == "H":
        screen.pending = False
        screen.cy = max(0, min(csi_param(ps, 0, 1) - 1, screen.rows - 1))
        screen.cx = max(0, min(csi_param(ps, 1, 1) - 1, screen.cols - 1))


def csi_screen_mode(screen, params, final):
    """Alternate screen 1049 enter/leave; anything else is ignored."""
    if "1049" not in params:
        return
    if final == "h" and not screen.alt:
        screen.main = (screen.grid, screen.soft, screen.cy, screen.cx)
        screen.alt = True
        screen.grid = [[" "] * screen.cols for _ in range(screen.rows)]
        screen.soft = [False] * screen.rows
        screen.cy = screen.cx = 0
    elif final == "l" and screen.alt:
        screen.grid, screen.soft, screen.cy, screen.cx = screen.main
        screen.alt = False
        screen.main = None


def handle_csi(screen, params, final):
    if final in ("A", "K", "J", "H"):
        csi_cursor(screen, params, final)
    else:
        csi_screen_mode(screen, params, final)


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
        os.execvpe(BIN, [BIN, "record", "--duration", "4"], env)
    os.close(sfd)
    return pid, mfd


def winsize(mfd, rows, cols):
    fcntl.ioctl(mfd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


GRID_CHARS = set("▀▄█ ")


def check(screen, at):
    lines = screen.lines()
    live = [i for i, l in enumerate(lines) if "⏺" in l or "⏸" in l]
    assert len(live) == 1, f"t={at}: expected exactly one status line, saw {len(live)}"
    header = [i for i, l in enumerate(lines) if l.startswith("Recording to ")]
    assert len(header) == 1, f"t={at}: expected exactly one header, saw {len(header)}"
    assert header[0] < live[0], f"t={at}: status line above the header"
    below = [l for i, l in enumerate(lines) if i > live[0] and l]
    garbage = [l for l in below if not set(l) <= GRID_CHARS]
    assert not garbage, f"t={at}: garbage below the status line: {garbage[:3]}"


def run_due(screen, checks, steps, now):
    """Fire the checks/resizes scheduled at or before `now`; True = a resize
    fired and the caller should skip its read tick."""
    while checks and now >= checks[0]:
        check(screen, checks.pop(0))
    if steps and now >= steps[0][0]:
        steps.pop(0)[1]()
        return True
    return False


def read_tick(screen, mfd):
    """Drain whatever the child produced this round; False when it exited.
    On macOS a pty master loses buffered output if nobody reads it while the
    child closes the slave, so this must never stop before the EOF."""
    r, _, _ = select.select([mfd], [], [], 0.05)
    if not r:
        return True
    data = os.read(mfd, 65536)
    if not data:  # EOF: the child exited
        return False
    feed(screen, data)
    return True


def scenario(reflow):
    home = "/tmp/rec-e2e-resize-home"
    os.makedirs(os.path.join(home, "recordings"), exist_ok=True)
    screen = Screen(30, 200, reflow=reflow)
    pid, mfd = spawn(30, 200, home)
    steps = [
        (1.5, lambda: winsize(mfd, 30, 80)),  # shrink: the killer case
        (2.5, lambda: winsize(mfd, 30, 130)),  # grow back
    ]
    checks = [1.0, 2.0, 3.0]
    start = time.monotonic()
    try:
        while True:
            now = time.monotonic() - start
            if run_due(screen, checks, steps, now):
                continue
            if not read_tick(screen, mfd):
                break
            if now > 10:
                raise AssertionError("timeout waiting for rec to exit")
        _, status = os.waitpid(pid, 0)
        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, f"exit status {status}"
        # Leaving the view restores the normal screen, where the summary lands.
        assert any("Saved" in l for l in screen.lines()), "no Saved summary on the normal screen"
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(mfd)


if __name__ == "__main__":
    scenario(reflow=True)
    scenario(reflow=False)
    print("E2E_RESIZE_OK")
