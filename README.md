# rec

[![CI](https://github.com/feliperun/rec/actions/workflows/ci.yml/badge.svg)](https://github.com/feliperun/rec/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/feliperun/rec)](https://github.com/feliperun/rec/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A terminal audio recorder for macOS, written in Zig. Capture microphone
audio, keep recordings as WAV files on disk, list them, and play them back —
without leaving the terminal.

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

Records from the default microphone to `./recordings/YYYYMMDD-HHMMSS.wav`
(PCM 16-bit, 48 kHz, stereo); `recordings/` is created on demand. Without
`--duration`, recording stops on Ctrl-C; with `--duration <sec>` it stops
automatically. The file is always finalized with a correct RIFF header, even
on interrupt.

### list

```sh
rec list
```

Prints the recordings in `./recordings/` (newest first) with index,
filename, duration parsed from the WAV header, and file size.

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
markdown file next to the WAV (`recordings/NAME.wav` → `recordings/NAME.md`).
The selection resolves exactly like `play`. Requires `DEEPGRAM_API_KEY` in
the environment. `--language` passes a Deepgram language code (default
`pt-BR`); `--out` writes to a different path. The document pairs YAML
frontmatter (type, title, resource, timestamp, model, language, duration)
with `# Utterances` (timestamped speaker table) and `# Text` sections.

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
zig build test              # unit tests (WAV writer, list parser, URL builder, response parsing, OKF rendering, arg parsing)
bash scripts/e2e_smoke.sh    # scripted record -> list -> play smoke test
```

Releases are built in `ReleaseFast` mode to keep the binary small and fast;
see `.github/workflows/release.yml`.

## How it works

- **Capture** — `src/capture.zig` drives miniaudio's default input device,
  appending PCM frames to a growable buffer until stopped.
- **WAV** — `src/wav.zig` writes the RIFF header up front and rewrites it on
  finalize with the real data size; the same module parses duration back out
  for `list`.
- **Library** — `src/library.zig` scans `recordings/`, sorts newest-first,
  and formats the table `list` prints.
- **Playback** — `src/playback.zig` spawns `/usr/bin/afplay` as a child
  process and forwards interrupts instead of reimplementing audio output.
- **Transcription** — `src/transcribe.zig` shells out to `/usr/bin/curl` to
  reach Deepgram's pre-recorded API; `src/okf.zig` renders the markdown
  bundle next to the WAV.
- **TUI** — `src/tui.zig` puts the terminal in raw mode for the interactive
  menu and restores it on any exit path, including Ctrl-C.

See [`docs/SPEC.md`](docs/SPEC.md) for the full functional specification.

## Notes

- `recordings/` is git-ignored, together with build outputs (`.zig-cache/`,
  `zig-out/`).
- WAV is the only supported format; this project targets Apple Silicon macOS
  only.

## License

[MIT](LICENSE)
