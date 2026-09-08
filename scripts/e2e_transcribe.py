#!/usr/bin/env python3
"""Offline CLI regression: request language, audio upload and saved transcript."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlparse
import wave


requests = []


class Deepgram(BaseHTTPRequestHandler):
    def do_POST(self):
        query = parse_qs(urlparse(self.path).query)
        body = self.rfile.read(int(self.headers["Content-Length"]))
        requests.append((query, body, self.headers["Content-Type"]))
        # Synthetic English fixture: forcing Portuguese reproduces no speech.
        spoken = query.get("detect_language") == ["true"] or query.get("language") == ["en"]
        if query.get("language") == ["fr"]:
            results = {"utterances": []}
        elif spoken:
            results = {
                "channels": [{"detected_language": "en"}],
                "utterances": [{"start": 0.0, "end": 1.0, "speaker": 0,
                                "transcript": "Synthetic English speech."}],
            }
        else:
            results = {"utterances": []}
        payload = json.dumps({"results": results}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


with tempfile.TemporaryDirectory(prefix="rec-transcribe-") as workspace:
    root = Path(workspace)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Deepgram)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        prefix = root / "build"
        subprocess.run([
            "zig", "build", "--prefix", str(prefix),
            f"-Dtest-listen-base=http://127.0.0.1:{server.server_port}/v1/listen?",
        ], check=True)
        binary = prefix / "bin" / ("rec.exe" if os.name == "nt" else "rec")
        recordings = root / "recordings"
        recordings.mkdir()
        audio = io.BytesIO()
        with wave.open(audio, "wb") as wav:
            wav.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0" * 48000 * 4)
        name = "20000101-120000.wav"
        (recordings / name).write_bytes(audio.getvalue())
        env = {**os.environ, "HOME": workspace, "USERPROFILE": workspace,
               "XDG_CONFIG_HOME": str(root / "config"), "DEEPGRAM_API_KEY": "synthetic-test-key"}
        for args in ([], ["--language", "auto"], ["--language", "en"]):
            result = subprocess.run(
                [str(binary), "transcribe", name, "--no-refine", *args],
                env=env, capture_output=True, text=True, timeout=10,
            )
            assert result.returncode == 0, result.stderr
            doc = (recordings / "20000101-120000.md").read_text()
            assert "language: en\n" in doc, doc
            assert "Synthetic English speech." in doc, doc
            query, body, content_type = requests[-1]
            assert body == audio.getvalue(), "uploaded audio was changed"
            assert content_type == "audio/wav", content_type
            assert query["model"] == ["nova-3"]
            assert query["utterances"] == ["true"]
            if args == ["--language", "en"]:
                assert query["language"] == ["en"] and "detect_language" not in query
            else:
                assert query["detect_language"] == ["true"] and "language" not in query
        transcript = recordings / "20000101-120000.md"
        before = transcript.read_bytes()
        result = subprocess.run(
            [str(binary), "transcribe", name, "--no-refine", "--language", "fr"],
            env=env, capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 1, result
        assert "no speech was recognized" in result.stderr, result.stderr
        assert transcript.read_bytes() == before, "failed transcription replaced the existing one"
    finally:
        server.shutdown()
        server.server_close()
        worker.join()

print("E2E_TRANSCRIBE_OK")
