#!/usr/bin/env python3
"""Synthetic PTY acceptance for the listening room. No hardware or credentials.
Run after zig build -Dsilent-input=true, or set REC_TEST_BIN.
"""
import fcntl
import math
import re
import subprocess
import termios
import os
from pathlib import Path
import struct
import tempfile
import time
import wave
from e2e_viewer import Session, BIN
from e2e_resize import Screen


def fixture(root):
    env = {**os.environ, 'HOME': str(root), 'XDG_CONFIG_HOME': str(root / '.config'), 'TERM': 'xterm-256color'}
    env.pop('NO_COLOR', None)
    cfg = root / '.config/rec'
    cfg.mkdir(parents=True)
    (cfg / 'update_state').write_text(str(int(time.time())))
    recs = root / 'recordings'
    recs.mkdir()
    with wave.open(str(recs / 'Northern Lights.wav'), 'wb') as audio:
        audio.setparams((2, 2, 48000, 0, 'NONE', 'NONE'))
        for second in range(20):
            samples = bytearray()
            for i in range(48000):
                t = second + i / 48000
                envelope = .35 + .25 * math.sin(t * 4)
                left = envelope * math.sin(2 * math.pi * (220 + second * 35) * t)
                right = envelope * math.sin(2 * math.pi * 880 * t)
                samples.extend(struct.pack('<hh', int(left * 24000), int(right * 24000)))
            audio.writeframes(samples)
    return env


def run():
    with tempfile.TemporaryDirectory(prefix='rec-player-') as tmp:
        env = fixture(Path(tmp))
        session = Session(['play', 'Northern Lights.wav'], env)
        try:
            session.until(lambda: session.contains('AURORA'))
            assert session.contains('Northern Lights'), 'track title is missing'
            session.drain(.3)
            before = session.screen.lines()
            session.drain(.4)
            assert before != session.screen.lines(), 'audio visualization is static'
            session.key(b' ')
            session.until(lambda: session.contains('PAUSED'))
            session.drain(.3)
            before = len(session.output)
            session.drain(.5)
            assert before == len(session.output), 'paused player keeps repainting'
            session.key(b'v')
            session.until(lambda: session.contains('SPECTRUM'))
            session.key(b'v')
            session.until(lambda: session.contains('SCOPE'))
            session.key(b'v')
            session.until(lambda: session.contains('AURORA'))
            session.key(b'z')
            session.until(lambda: session.contains('FOCUS'))
            session.key(b'?')
            session.until(lambda: session.contains('CONTROLS'))
            assert session.contains('volume'), 'volume controls are undiscoverable'
            session.key(b'?z--')
            session.until(lambda: session.contains('90%'))
            session.key(b'm')
            session.until(lambda: session.contains('MUTED'))
            session.key(b'm5')
            session.until(lambda: session.contains('00:10'))
            assert session.contains('PAUSED'), 'seeking unexpectedly resumed playback'
            # Very small, tall, and wide viewports must remain usable.
            for rows, cols in ((12, 32), (6, 18), (1, 1), (24, 80), (40, 140)):
                fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
                session.screen = Screen(rows, cols, False)
                start = len(session.output)
                session.drain(.3)
                assert session.proc.poll() is None, f'player exited at {cols}x{rows}'
                positions = re.findall(rb'\x1b\[(\d+);(\d+)H', session.output[start:])
                assert all(1 <= int(r) <= rows and int(c) <= cols for r, c in positions)
            session.key(b' ')
            session.until(lambda: session.contains('PLAYING'))
            session.key(b'9\x1b[1;2C')
            session.until(lambda: session.contains('PAUSED') and session.contains('00:20'))
            session.key(b' ')
            session.until(lambda: session.contains('PLAYING') and session.contains('00:00'))
        finally:
            session.close()
        env['NO_COLOR'] = '1'
        session = Session(['play', 'Northern Lights.wav'], env)
        try:
            session.until(lambda: session.contains('AURORA'))
            assert b'38;5;' not in session.output and b'48;5;' not in session.output
            session.key(b' ')
            session.until(lambda: session.contains('PAUSED'))
        finally:
            session.close()
        assert b'\x1b[?25h' in session.output and b'\x1b[?1049l' in session.output
        with wave.open(str(Path(tmp) / 'recordings/short.wav'), 'wb') as audio:
            audio.setparams((1, 2, 8000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\0\0' * 800)
        result = subprocess.run([BIN, 'play', 'short.wav'], input=b'', capture_output=True, env=env, timeout=5)
        assert result.returncode == 0 and b'\x1b' not in result.stderr, 'piped playback must stay plain'
    print('E2E_PLAYER_OK')


if __name__ == '__main__':
    run()
