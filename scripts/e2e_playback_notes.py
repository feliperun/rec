#!/usr/bin/env python3
"""Audio note tabs and background generation, using isolated synthetic fixtures."""
import os
from pathlib import Path
import tempfile
import time
import wave
from e2e_viewer import Session


def run():
    with tempfile.TemporaryDirectory(prefix='rec-notes-') as folder:
        root = Path(folder)
        cfg = root / '.config/rec'
        cfg.mkdir(parents=True)
        (cfg / 'update_state').write_text(str(int(time.time())))
        recs = root / 'recordings'
        recs.mkdir()
        with wave.open(str(recs / 'fixture.wav'), 'wb') as audio:
            audio.setparams((2, 2, 48000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\x00\x10\x00\x10' * 48000 * 8)
        transcript = '# TRANSCRIPT_MARKER\nSynthetic transcript.\n'
        formatted = '# FORMATTED_MARKER\nSynthetic meeting notes.\n'
        (recs / 'fixture.md').write_text(transcript)
        (recs / 'fixture.meeting.md').write_text(formatted)
        fake_bin = root / 'bin'
        fake_bin.mkdir()
        copier = fake_bin / 'pbcopy'
        copier.write_text('#!/bin/sh\ncat > "$REC_CLIPBOARD"\n')
        copier.chmod(0o755)
        for alias in ('xclip', 'wl-copy'):
            (fake_bin / alias).symlink_to(copier)
        opener = fake_bin / 'open'
        opener.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$REC_SHARED\"\n")
        opener.chmod(0o755)
        (fake_bin / 'xdg-open').symlink_to(opener)
        shared = root / 'shared'
        clipboard = root / 'clipboard'
        env = {**os.environ, 'HOME': folder, 'USERPROFILE': folder,
               'XDG_CONFIG_HOME': str(root / '.config'), 'NO_COLOR': '1',
               'PATH': str(fake_bin) + os.pathsep + os.environ['PATH'],
               'REC_CLIPBOARD': str(clipboard), 'REC_SHARED': str(shared)}
        session = Session(['play', 'fixture.wav'], env)
        try:
            session.until(lambda: session.contains('TRANSCRIPT_MARKER'))
            session.key(b' ')
            session.key(b'z')
            session.until(lambda: session.contains('FOCUS'))
            session.key(b'f')
            session.until(lambda: session.contains('FORMATTED_MARKER'))
            assert session.contains('00:08'), 'tab switch hid the audio'
            session.key(b'y')
            session.until(lambda: clipboard.exists() and clipboard.read_text() == formatted)
            session.key(b'c')
            session.until(lambda: shared.exists())
            assert shared.read_text().strip() == 'https://chatgpt.com/'
            assert clipboard.read_text() == formatted
            session.key(b't')
            session.until(lambda: session.contains('TRANSCRIPT_MARKER'))
            session.key(b's')
            session.until(lambda: clipboard.exists() and clipboard.read_text() == transcript)
            assert b'\x1b[?1049l' not in session.output, 'tab switch left playback'
        finally:
            session.close()
    print('E2E_PLAYBACK_NOTES_OK')


if __name__ == '__main__':
    run()
