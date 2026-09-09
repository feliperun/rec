#!/usr/bin/env python3
"""Playback jobs against local HTTP and a synthetic LLM, never real credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import wave
import e2e_viewer
from e2e_viewer import Session


class Deepgram(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        self.server.requests += 1
        self.server.release.wait(15)
        payload = json.dumps({'results': {
            'channels': [{'detected_language': 'en'}],
            'utterances': [{'start': 0.0, 'end': 1.0, 'speaker': 0,
                            'transcript': 'Synthetic speech.'}],
        }}).encode()
        try:
            self.send_response(self.server.status)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Quitting playback cancels the request.

    def log_message(self, *args):
        pass


LLM = '''import os, pathlib, sys, time
root = pathlib.Path(os.environ['REC_NOTES_TEST_ROOT'])
prompt = sys.stdin.read()
with (root / 'calls').open('a') as log:
    log.write('refine\\n' if 'REFINE_TEST' in prompt else 'format\\n')
(root / 'started').write_text(str(os.getpid()))
while not (root / 'release').exists():
    time.sleep(.02)
if (root / 'fail').exists():
    print('PRIVATE_DIAGNOSTIC', file=sys.stderr)
    sys.exit(1)
print('# GENERATED_TRANSCRIPT' if 'REFINE_TEST' in prompt else '# GENERATED_FORMATTED')
'''


class Fixture:
    def __init__(self, root):
        self.root = root
        self.recs = root / 'recordings'
        self.recs.mkdir()
        self.cfg = root / '.config/rec'
        (self.cfg / 'templates').mkdir(parents=True)
        (self.cfg / 'update_state').write_text(str(int(time.time())))
        (self.cfg / 'config.json').write_text(json.dumps({'harness': 'claude', 'model': ''}))
        for name in ('refine', 'meeting'):
            (self.cfg / f'templates/{name}.md').write_text('REFINE_TEST' if name == 'refine' else 'FORMAT_TEST')
        with wave.open(str(self.recs / 'fixture.wav'), 'wb') as audio:
            audio.setparams((2, 2, 48000, 0, 'NONE', 'NONE'))
            audio.writeframes(b'\x00\x10\x00\x10' * 48000 * 8)
        fake_bin = root / 'bin'
        fake_bin.mkdir()
        runner = fake_bin / 'claude'
        runner.write_text(f'#!{sys.executable}\n' + LLM)
        runner.chmod(0o755)
        copier = fake_bin / 'pbcopy'
        copier.write_text('#!/bin/sh\ncat > "$REC_CLIPBOARD"\n')
        copier.chmod(0o755)
        for alias in ('xclip', 'wl-copy'):
            (fake_bin / alias).symlink_to(copier)
        self.clipboard = root / 'clipboard'
        self.env = {**os.environ, 'HOME': str(root), 'USERPROFILE': str(root),
                    'XDG_CONFIG_HOME': str(root / '.config'), 'NO_COLOR': '1',
                    'PATH': str(fake_bin) + os.pathsep + os.environ['PATH'],
                    'DEEPGRAM_API_KEY': 'synthetic-test-key',
                    'REC_NOTES_TEST_ROOT': str(root), 'REC_CLIPBOARD': str(self.clipboard)}
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Deepgram)
        self.server.requests = 0
        self.server.status = 200
        self.server.release = threading.Event()
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def reset(self):
        for name in ('fixture.md', 'fixture.meeting.md'):
            (self.recs / name).unlink(missing_ok=True)
        for name in ('calls', 'started', 'fail', 'release'):
            (self.root / name).unlink(missing_ok=True)
        self.server.status = 200
        self.server.requests = 0
        self.server.release.clear()

    def play(self):
        session = Session(['play', 'fixture.wav'], self.env)
        session.until(lambda: session.contains('No transcript yet'))
        session.key(b' ' + b'\x1b[D' * 8)
        session.until(lambda: session.contains('00:00 / 00:08'))
        return session

    def copy(self, session, name):
        session.key(b'y')
        expected = (self.recs / name).read_text()
        session.until(lambda: self.clipboard.exists() and self.clipboard.read_text() == expected)

    def intact(self, session):
        assert session.proc.poll() is None
        assert b'\x1b[?1049l' not in session.output, 'job closed the waveform'
        assert b'PRIVATE_DIAGNOSTIC' not in session.output
        assert b'Transcript saved to' not in session.output
        assert session.contains('00:08'), 'audio header disappeared'

    def close(self):
        self.server.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.worker.join()


def generate_and_switch(f):
    session = f.play()
    try:
        session.key(b'\t')
        session.until(lambda: session.contains('No formatted notes yet'))
        assert f.server.requests == 0, 'Tab navigation started transcription'
        session.key(b'\t')
        session.key(b'ttt')
        session.until(lambda: f.server.requests == 1 and session.contains('Transcribing...'))
        session.key(b'\x1b[C')
        session.until(lambda: session.contains('00:01 / 00:08'))
        f.intact(session)
        (f.root / 'release').touch()
        f.server.release.set()
        session.until(lambda: session.contains('GENERATED_TRANSCRIPT'))
        assert f.server.requests == 1, 'duplicate transcription'
        f.copy(session, 'fixture.md')
        (f.root / 'release').unlink()
        (f.root / 'started').unlink()
        session.key(b'fff')
        session.until(lambda: (f.root / 'started').exists() and session.contains('Formatting...'))
        session.key(b't')
        session.until(lambda: session.contains('GENERATED_TRANSCRIPT'))
        f.copy(session, 'fixture.md')
        session.key(b'\x1b[Cf')
        session.until(lambda: session.contains('00:02 / 00:08'))
        f.intact(session)
        (f.root / 'release').touch()
        session.until(lambda: session.contains('GENERATED_FORMATTED'))
        f.copy(session, 'fixture.meeting.md')
        assert (f.root / 'calls').read_text().splitlines() == ['refine', 'format']
        session.key(b'\t')
        session.until(lambda: session.contains('GENERATED_TRANSCRIPT'))
        f.intact(session)
    finally:
        session.close()


def format_without_transcript(f):
    f.reset()
    session = f.play()
    try:
        session.key(b'f')
        session.until(lambda: f.server.requests == 1 and session.contains('Transcribing, then formatting'))
        f.intact(session)
        (f.root / 'release').touch()
        f.server.release.set()
        session.until(lambda: session.contains('GENERATED_FORMATTED'))
        assert f.server.requests == 1
        assert (f.root / 'calls').read_text().splitlines() == ['refine', 'format']
        f.copy(session, 'fixture.meeting.md')
    finally:
        session.close()


def failures_and_retry(f):
    f.reset()
    session = f.play()
    try:
        f.server.status = 500
        f.server.release.set()
        session.key(b't')
        session.until(lambda: session.contains('Transcription failed'))
        f.intact(session)
        assert not (f.recs / 'fixture.md').exists()
        f.server.status = 200
        (f.root / 'release').touch()
        session.key(b't')
        session.until(lambda: session.contains('GENERATED_TRANSCRIPT'))
        (f.root / 'fail').touch()
        session.key(b'f')
        session.until(lambda: session.contains('Formatting failed'))
        f.intact(session)
        session.key(b't')
        session.until(lambda: session.contains('GENERATED_TRANSCRIPT'))
        f.copy(session, 'fixture.md')
        (f.root / 'fail').unlink()
        session.key(b'f')
        session.until(lambda: session.contains('GENERATED_FORMATTED'))
        f.copy(session, 'fixture.meeting.md')
    finally:
        session.close()


def quit_during_jobs(f):
    f.reset()
    session = f.play()
    session.key(b't')
    session.until(lambda: f.server.requests == 1)
    started = time.monotonic()
    session.close()
    assert time.monotonic() - started < 2, 'quit waited for transcription'
    f.server.release.set()
    assert not (f.recs / 'fixture.md').exists()
    (f.recs / 'fixture.md').write_text('# Synthetic transcript\n')
    session = Session(['play', 'fixture.wav'], f.env)
    try:
        session.until(lambda: session.contains('Synthetic transcript'))
        session.key(b'f')
        session.until(lambda: (f.root / 'started').exists())
        pid = int((f.root / 'started').read_text())
    finally:
        started = time.monotonic()
        session.close()
    assert time.monotonic() - started < 2, 'quit waited for formatting'
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('formatting process survived playback')
    assert not (f.recs / 'fixture.meeting.md').exists()


def run():
    with tempfile.TemporaryDirectory(prefix='rec-notes-jobs-') as folder:
        f = Fixture(Path(folder))
        try:
            prefix = f.root / 'build'
            subprocess.run(['zig', 'build', '-Dsilent-input=true', '--prefix', str(prefix),
                            f'-Dtest-listen-base=http://127.0.0.1:{f.server.server_port}/v1/listen?'], check=True)
            e2e_viewer.BIN = str(prefix / 'bin/rec')
            generate_and_switch(f)
            format_without_transcript(f)
            failures_and_retry(f)
            quit_during_jobs(f)
        finally:
            f.close()
    print('E2E_NOTES_JOBS_OK')


if __name__ == '__main__':
    run()
