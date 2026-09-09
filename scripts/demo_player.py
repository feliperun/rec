#!/usr/bin/env python3
"""Play an original, synthetic ambient loop in an isolated temporary library."""
import argparse
import math
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import time
import wave


def prepare(root):
    root = Path(root)
    recs = root / 'recordings'
    recs.mkdir(parents=True, exist_ok=True)
    config = root / '.config/rec'
    config.mkdir(parents=True, exist_ok=True)
    (config / 'update_state').write_text(str(int(time.time())))
    path = recs / 'Northern Lights.wav'
    if path.exists():
        return
    rng = random.Random(7)
    rate = 48000
    notes = [146.832, 174.614, 220.000, 261.626, 293.665, 261.626, 220.000, 174.614]
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((2, 2, rate, 0, 'NONE', 'NONE'))
        for second in range(48):
            chunk = bytearray()
            for i in range(rate):
                t = second + i / rate
                beat = t % .375
                note = notes[int(t / .375) % len(notes)]
                phrase = .55 + .3 * math.sin(t * .7)
                pluck = math.exp(-beat * 9) * sum(math.sin(math.tau * note * n * t) / n for n in range(1, 8)) * .15
                bass = math.sin(math.tau * 73.416 * t) * (.09 + .06 * math.exp(-beat * 12))
                shimmer = (rng.random() - .5) * math.exp(-beat * 50) * .08
                fade = min(t / 2, (48 - t) / 3, 1)
                for detune in (.998, 1.002):
                    pad = sum(math.sin(math.tau * f * detune * t) for f in (146.832, 220, 349.228)) * .04
                    sample = (pluck + bass + pad + shimmer) * phrase * fade
                    chunk.extend(struct.pack('<h', int(max(-1, min(1, sample)) * 32767)))
            audio.writeframes(chunk)


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', type=Path, help='Only generate the synthetic library at this path')
    args = parser.parse_args()
    if args.prepare:
        prepare(args.prepare)
        return
    binary = Path(os.environ.get('REC_TEST_BIN', 'zig-out/bin/rec')).resolve()
    if not binary.exists():
        parser.error('Build the player first with: zig build')
    with tempfile.TemporaryDirectory(prefix='rec-aurora-demo-') as tmp:
        print('Composing Northern Lights…', flush=True)
        prepare(tmp)
        env = {**os.environ, 'HOME': tmp, 'XDG_CONFIG_HOME': str(Path(tmp) / '.config')}
        subprocess.run([str(binary), 'play', 'Northern Lights.wav'], env=env, check=True)


if __name__ == '__main__':
    run()
