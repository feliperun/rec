#!/usr/bin/env python3
"""Real PTY regression: scrolling, burst input, resize, idle output, tail cuts.
Synthetic audio/documents only. Run after zig build (null audio backend on CI).
"""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
import wave
from e2e_resize import Screen, feed

BIN = str(Path(os.environ.get('REC_TEST_BIN', 'zig-out/bin/rec')).resolve())


class Session:
    def __init__(self, args, env):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        self.proc = subprocess.Popen([BIN, *args], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        self.fd = master
        self.screen = Screen(24, 80, False)
        self.output = bytearray()

    def drain(self, seconds=.15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([self.fd], [], [], .02)[0]:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                self.output.extend(chunk)
                feed(self.screen, chunk)

    def until(self, predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.drain(.05)
            if predicate():
                return
        raise AssertionError('\n'.join(self.screen.lines()))

    def contains(self, text):
        return any(text in line for line in self.screen.lines())

    def key(self, key):
        os.write(self.fd, key)
        self.drain()

    def close(self):
        try:
            self.key(b'q')
            self.until(lambda: self.proc.poll() is not None)
            assert self.proc.returncode == 0
            assert b'\x1b[?1006l' in self.output
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
            self.proc.wait()
            os.close(self.fd)


def run():
    with tempfile.TemporaryDirectory(prefix='rec-viewer-') as root:
        root = Path(root)
        env = {**os.environ, 'HOME': str(root), 'XDG_CONFIG_HOME': str(root / '.config'), 'NO_COLOR': '1'}
        cfg = root / '.config/rec'
        cfg.mkdir(parents=True)
        (cfg / 'update_state').write_text(str(int(time.time())))
        recs = root / 'recordings'
        recs.mkdir()
        doc = '---\ntitle: Synthetic document\n---\n# FIRST_MARKER\n' + ''.join(f'LINE_{i:04d} ' + 'wrapped text ' * 20 + '\n' for i in range(1000)) + 'LAST_MARKER\n'
        path = recs / 'fixture.md'
        path.write_text(doc)
        with wave.open(str(recs / 'fixture.wav'), 'wb') as audio:
            audio.setparams((2, 2, 48000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\x00\x10\x00\x10' * 48000 * 8)
        # macOS edits native M4A; Linux edits native WAV.
        name = 'fixture.wav'
        if os.uname().sysname == 'Darwin':
            subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', str(recs / name), str(recs / 'fixture.m4a')], check=True)
            name = 'fixture.m4a'
        # Capture clipboard writes without touching the user's clipboard.
        fake_bin = root / 'bin'
        fake_bin.mkdir()
        copier = fake_bin / 'pbcopy'
        copier.write_text('#!/bin/sh\ncat > "$REC_CLIPBOARD"\n')
        copier.chmod(0o755)
        for alias in ('xclip', 'wl-copy'):
            (fake_bin / alias).symlink_to(copier)
        clipboard = root / 'clipboard'
        env.update(PATH=str(fake_bin) + os.pathsep + env['PATH'], REC_CLIPBOARD=str(clipboard))
        for args in (['view', str(path)], ['play', name]):
            session = Session(args, env)
            try:
                session.until(lambda: session.contains('FIRST_MARKER'))
                if args[0] == 'play':
                    session.key(b' ')
                    session.until(lambda: session.contains('⏸'))
                session.drain(.3)  # drain the completed transition frame
                before = len(session.output)
                session.drain(.5)
                assert len(session.output) == before, 'idle view is continuously redrawn'
                session.key(b'y')
                session.until(lambda: clipboard.exists() and clipboard.read_text() == doc)
                session.key(b'\x1b[F')
                session.until(lambda: session.contains('LAST_MARKER'))
                assert not session.contains('FIRST_MARKER')
                # One read containing both sequences must retain both keys.
                session.key(b'\x1b[H\x1b[F')
                session.until(lambda: session.contains('LAST_MARKER'))
                session.key(b'\x1b[H')
                session.until(lambda: session.contains('FIRST_MARKER'))
                if args[0] == 'play':
                    assert session.contains('⏸'), 'Home did not restore audio'
                session.key(b'\x1b[<65;1;1M' * 10)
                session.until(lambda: not session.contains('FIRST_MARKER'))
                session.key(b'\x1b[H')
                session.until(lambda: session.contains('FIRST_MARKER'))
                fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 32, 0, 0))
                session.screen.resize(32)
                session.drain(.3)
                session.key(b'\x1b[F')
                session.until(lambda: session.contains('LAST_MARKER'))
                assert b'\x1b[25;' not in session.output, 'drawing below viewport'
                if args[0] == 'play':
                    session.key(b'\x1b[H\x1b[C')  # one second into paused audio
                    session.key(b'i\x7f\r')  # tail cut in one burst
                    session.until(lambda: session.contains('cut 00:01'))
                    assert session.proc.poll() is None, 'tail cut closed playback'
            finally:
                session.close()
    print('E2E_VIEWER_OK')


if __name__ == '__main__':
    run()
