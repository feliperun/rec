# rec

[![CI](https://github.com/feliperun/rec/actions/workflows/ci.yml/badge.svg)](https://github.com/feliperun/rec/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/feliperun/rec)](https://github.com/feliperun/rec/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A terminal audio recorder for macOS, written in Zig. Capture microphone
audio, keep recordings as M4A (AAC) files on disk, list them, play them back,
and transcribe them — without leaving the terminal.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/feliperun/rec/main/install.sh | sh
```

Downloads the latest release and installs the `rec` binary to
`/usr/local/bin`. Apple Silicon only; no dependencies beyond the OS.

## Usage

### record

```sh
rec record [--duration <sec>]
```

Records from the default microphone to `~/recordings/YYYYMMDD-HHMMSS.m4a`
(AAC, 48 kHz, stereo, encoded by the system's AudioToolbox codec);
`~/recordings/` is created on demand. Without `--duration`, recording stops on
Ctrl-C; with `--duration <sec>` it stops automatically. The file is always a
complete, finalized container — a failed encode leaves no partial file
behind.

### list

```sh
rec list
```

Prints the recordings in `~/recordings/` (newest first) with index,
filename, duration parsed from the recording's container, and file size.
Both `.m4a` and pre-existing `.wav` files are listed.

### play

```sh
rec play <index|filename>
```

Plays a recording through the default output device via `/usr/bin/afplay`.
The selection can be an index from `list` or a filename (with or without the
`recordings/` prefix). Ctrl-C stops playback.

### transcribe

```sh
rec transcribe <index|filename> [--language <code>] [--out <path>]
```

Transcribes a recording through Deepgram's pre-recorded API and saves an
[Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing)
markdown file next to the recording (`~/recordings/NAME.m4a` →
`~/recordings/NAME.md`). The selection resolves exactly like `play`. Requires
`DEEPGRAM_API_KEY` in the environment. `--language` passes a Deepgram
language code (default `pt-BR`); `--out` writes to a different path. M4A
files are sent as `audio/mp4`, legacy WAV files as `audio/wav`. The document
pairs YAML frontmatter (type, title, resource, timestamp, model, language,
duration) with the transcript as plain paragraphs — one per speaker turn from
Deepgram's diarization; no timestamps or speaker labels in the text.

### Interactive mode

Running `rec` with no subcommand enters a minimal interactive menu:

- `r` — start recording (any key or Ctrl-C stops)
- `l` — list recordings
- `<number>` + Enter — play that recording
- `q` — quit

Raw terminal mode is restored on exit, including after Ctrl-C.

## Build from source

Prerequisites:

- macOS with a working microphone
- [Zig](https://ziglang.org) (stable toolchain via Homebrew): `brew install zig`

```sh
zig build
```

The binary lands at `zig-out/bin/rec`. Audio I/O uses the vendored
[miniaudio](https://miniaud.io) library; playback shells out to the system
player (`/usr/bin/afplay`).

## Development

```sh
zig build test              # unit tests (M4A encoder, list parser, URL builder, response parsing, OKF rendering, arg parsing)
bash scripts/e2e_smoke.sh    # scripted record -> list -> play smoke test
```

Releases are built in `ReleaseFast` mode to keep the binary small and fast;
see `.github/workflows/release.yml`.

## How it works

- **Capture** — `src/capture.zig` drives miniaudio's default input device,
  appending PCM frames to a growable buffer until stopped.
- **M4A** — `src/m4a.zig` encodes the captured PCM into an M4A/AAC container
  through AudioToolbox's system encoder (`ExtAudioFile`), and reads durations
  back out through the system's MP4 parser for `list`.
- **Library** — `src/library.zig` scans `~/recordings/`, sorts newest-first,
  and formats the table `list` prints.
- **Playback** — `src/playback.zig` spawns `/usr/bin/afplay` as a child
  process and forwards interrupts instead of reimplementing audio output.
- **Transcription** — `src/transcribe.zig` shells out to `/usr/bin/curl` to
  reach Deepgram's pre-recorded API; `src/okf.zig` renders the markdown
  bundle next to the recording.
- **TUI** — `src/tui.zig` puts the terminal in raw mode for the interactive
  menu and restores it on any exit path, including Ctrl-C.

See [`docs/SPEC.md`](docs/SPEC.md) for the full functional specification.

## Notes

- Recordings live outside the repository under `~/recordings/`; build outputs
  (`.zig-cache/`, `zig-out/`) remain git-ignored.
- New recordings are M4A/AAC (~10× smaller than the previous WAV output);
  WAV files recorded by older versions remain listed, playable and
  transcribable. This project targets Apple Silicon macOS only.

## License

[MIT](LICENSE)
