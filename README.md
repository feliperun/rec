# rec

[![CI](https://github.com/feliperun/rec/actions/workflows/ci.yml/badge.svg)](https://github.com/feliperun/rec/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/feliperun/rec)](https://github.com/feliperun/rec/releases/latest)
[![Made with Zig](https://img.shields.io/badge/Zig-0.16-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Record. Transcribe. Understand.** A meeting recorder for macOS that lives
entirely in your terminal — capture microphone audio as M4A with one
keypress, transcribe it to markdown through Deepgram, and let a local
coding-agent LLM clean up the transcript or turn it into structured meeting
notes. One small Zig binary, no Electron, no servers of its own.

```
$ rec list
  #  name                 time  size
  1  20260826-093000.m4a  42:15   38.9 MiB
  2  20260825-140000.m4a  55:30   50.8 MiB

$ rec transcribe 1 --context "sprint planning for the payments team"
Transcript saved to ~/recordings/20260826-093000.md
Refinando com Claude Code...
Transcrição refinada: ~/recordings/20260826-093000.md

$ rec format 1
format: processando com Claude Code...
Documento salvo em ~/recordings/20260826-093000.meeting.md
```

## Why you might like it

- **Zero-friction capture** — `rec` opens the mic immediately; recordings
  land in `~/recordings/` as real M4A files encoded by macOS's own
  AudioToolbox codec (compact AAC, not gigantic WAVs).
- **Honest transcripts** — Deepgram nova-3 diarization rendered as clean,
  plain-prose OKF markdown: YAML frontmatter for machines, readable
  paragraphs for humans.
- **A second pass by an LLM that's already on your machine** — rec drives
  coding-agent CLIs you already have and are already authenticated with
  (Claude Code, Codex CLI, OpenCode, pi, Gemini CLI). It detects which ones
  actually *work* on your machine right now — quota, plan gates and expired
  tokens included — by running a real probe call, never by trusting
  credential files.
- **Templates you own** — meeting notes come from an editable prompt file in
  `~/.config/rec/templates/meeting.md`. Change it, rewrite it, add your own
  templates (`retro`, `standup`, whatever) and run them with `--template`.
- **Nothing is silently lost** — refinement failing never damages the raw
  transcript; the artifact is always on disk before any LLM touches it.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/feliperun/rec/main/install.sh | sh
```

Downloads the latest release and installs the `rec` binary to
`/usr/local/bin`. Apple Silicon only; no dependencies beyond the OS.

For transcript processing, install at least one supported coding agent and
authenticate it the way you normally would, then run `rec setup`.

## First run

```sh
rec setup    # pick which coding-agent LLM processes your transcripts
```

`rec setup` probes every installed harness with a genuine test call, shows
only the usable ones, lists their available models where the harness can tell
us, validates your exact harness+model pick once more, and saves it to
`~/.config/rec/config.json`. Run it again any time to switch.

Requires `DEEPGRAM_API_KEY` in your environment for transcription itself.

## Usage

### record

```sh
rec record [--duration <sec>]
```

Records from the default microphone to `~/recordings/YYYYMMDD-HHMMSS.m4a`
(AAC-LC, 48 kHz, stereo, via AudioToolbox); `~/recordings/` is created on
demand. Without `--duration`, recording stops on Ctrl-C; with `--duration
<sec>` it stops automatically. The container is always finalized — a failed
encode leaves no partial file behind.

### list

```sh
rec list
```

Prints the recordings in `~/recordings/` (newest first) with index,
filename, duration parsed from the recording's container, and file size.
Both `.m4a` and pre-existing `.wav` recordings are listed.

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
               [--no-refine] [--context <text>]
```

Transcribes a recording through Deepgram's pre-recorded API and saves an
[Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing)
markdown file next to the recording (`NAME.m4a` → `NAME.md`; M4A goes over
the wire as `audio/mp4`, legacy WAV as `audio/wav`). The selection resolves
exactly like `play`. `--language` passes a Deepgram language code (default
`pt-BR`); `--out` writes elsewhere.

Then, by default, **the refine pass runs**: the transcript travels through
your configured LLM together with the bundled *refine* prompt, which fixes
hard-to-hear words that ASR got wrong and rewrites the same `.md`, keeping
its frontmatter.

- `--context "<text>"` gives the model domain context — project names, team
  jargon, attendee names — dramatically improving fixes.
- `--no-refine` keeps just the raw transcript.
- Any LLM failure prints a one-line notice and exits 0 with the raw
  transcript untouched.

### format

```sh
rec format <index|filename|path> [--template meeting] [--out <path>] [--context <text>]
```

Turns an existing transcript into a structured document with a prompt
template. Without `--out`, the result lands beside the source named after
the template:

```
~/recordings/planning.m4a → planning.md → planning.meeting.md
```

The bundled **meeting** template produces speaker tables, an executive
summary, decisions, and action items from a raw transcript. Templates are
plain markdown prompts under `~/.config/rec/templates/` — `meeting.md` and
`refine.md` are copied there on first use so you can edit them freely;
upgrades never overwrite your edits. Add a `retro.md` and it instantly
becomes `rec format 1 --template retro`. Unknown names list what's
available; a read-only config dir falls back to the embedded copies.

### setup

```sh
rec setup        # alias: rec configure-llm
```

Chooses which coding-agent CLI processes transcripts. Supported today:
Claude Code, Codex CLI, OpenCode, pi, Gemini CLI. See [First run](#first-run).

### Interactive mode

Running `rec` with no subcommand enters a minimal interactive menu:

- `r` — start recording (any key or Ctrl-C stops)
- `l` — list recordings
- `<number>` + Enter — play that recording
- `q` — quit

Raw terminal mode is restored on exit, including after Ctrl-C.

## Build from source

Prerequisites:

- macOS Apple Silicon with a working microphone
- [Zig](https://ziglang.org) (stable toolchain via Homebrew): `brew install zig`

```sh
zig build
zig build test     # unit tests: encoder, parsers, prompts, arg parsing
```

The binary lands at `zig-out/bin/rec`. Audio I/O uses the vendored
[miniaudio](https://miniaud.io) library; playback shells out to the system
player; releases are built in `ReleaseFast` mode (see
`.github/workflows/release.yml`).

## How it works

- **Capture** — `src/capture.zig` drives miniaudio's default input device,
  appending PCM frames to a growable buffer until stopped.
- **M4A** — `src/m4a.zig` encodes captured PCM into an M4A/AAC container
  through AudioToolbox's system encoder and reads durations back out via the
  system MP4 parser.
- **Library** — `src/library.zig` scans `~/recordings/` (M4A + legacy WAV),
  sorts newest-first, and formats what `list` prints; numeric selections are
  always relative to this order across every command.
- **Playback** — `src/playback.zig` spawns `/usr/bin/afplay` and forwards
  interrupts instead of reimplementing audio output.
- **Transcription** — `src/transcribe.zig` shells out to `/usr/bin/curl` for
  Deepgram's pre-recorded API; `src/okf.zig` renders the markdown bundle.
- **LLM processing** — `src/llm.zig` drives coding-agent CLIs
  non-interactively: the composed prompt streams into the child's stdin
  through a single-thread poll loop (nonblocking feed + deadline), answers
  come back per-harness (Claude/pi/OpenCode stdout, codex `-o` tmpfile,
  gemini JSON envelope). Config and user templates live under
  `~/.config/rec/`; `src/setupcmd.zig` and `src/formatcmd.zig` implement
  `setup` and `format`.
- **Prompts** — `src/prompts.zig` embeds the bundled templates verbatim in
  the binary; composition fills `{{DOMAIN_CONTEXT}}` and delimits the
  transcript payload.
- **TUI** — `src/tui.zig` handles raw mode for the interactive menu and
  restores it on any exit path.

See [`docs/SPEC.md`](docs/SPEC.md) for the functional specification.

## Notes

- Recordings live outside the repository under `~/recordings/`; build
  outputs stay git-ignored.
- Transcription quality follows Deepgram; refinement quality follows
  whichever coding agent you point rec at. Both degrade independently and
  gracefully.
- This project targets Apple Silicon macOS only.

## License

[MIT](LICENSE)
