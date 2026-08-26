# PRD: Audio Transcription with Deepgram

Status: Approved · 2026-08-25
Campaign: `deepgram-transcription` (plan-runner)

## Problem

`rec` captures audio and stops there: the WAV files it produces are opaque
unless someone replays them. Recordings are most useful as text — searchable,
pasteable into notes, readable by agents. Speech-to-text today requires
leaving the terminal and juggling a vendor web UI.

## Goal

Add a `rec transcribe` command that sends a recording to the
[Deepgram](https://developers.deepgram.com) pre-recorded API and writes the
result next to the audio as an Open Knowledge Format (OKF) markdown bundle
file, so transcripts become first-class, agent-readable artifacts beside the
WAVs they describe.

## User stories

- As a user, I run `rec transcribe 3` (or `rec transcribe 20260825-143000.wav`)
  and get `~/recordings/20260825-143000.md` without leaving the terminal.
- As a user, I open the transcript file in any editor or feed it to an agent;
  the YAML frontmatter tells it what the document is without parsing prose.
- As a user without a Deepgram key, I get a clear one-line error telling me
  exactly which environment variable to export.

## Requirements

1. `rec transcribe <index|filename>` resolves the selection against
   `recordings/` exactly like `play` does (1-based index from `list`, filename
   with or without the `recordings/` prefix).
2. Transcription uses the Deepgram pre-recorded API (`POST /v1/listen`) with
   the same parameter profile proven in CueMe: `model=nova-3`,
   `smart_format=true`, `punctuate=true`, `utterances=true`,
   `diarize_model=latest`, `mip_opt_out=true`.
3. `--language <code>` overrides the language; default `pt-BR` (nova-3
   supports `pt-BR` natively).
4. Output is written to `<recording-name>.md` next to the WAV, following the
   [Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing):
   YAML frontmatter whose mandatory `type` field is `Recording Transcript`,
   plus a free markdown body.
5. `DEEPGRAM_API_KEY` is the single credential source (same fallback CueMe
   uses for local runs and CI).
6. All unit tests run offline: HTTP is behind a seam and response parsing is
   exercised against fixture JSON captured from real Deepgram responses.

## Non-goals

- Streaming/live transcription while recording (pre-recorded API only).
- Keychain or config-file credential storage (env var only in v1).
- Interactive-menu entry point (`r`/`l`/number stay as-is).
- Speaker naming beyond Deepgram diarization indices.
- Translation, summarization, or any LLM post-processing.

## Success criteria

- `zig build test` passes with new unit tests covering URL building, response
  parsing, and OKF rendering (round-trip against fixtures).
- A real recording transcribes end-to-end with a key present.
- Released as `1.1.0` and installed globally via `install.sh`.

## References

- CueMe Deepgram client (request/response shape):
  `~/dev/frb/cueme/CueMe/STT/DeepgramPrerecorded.swift`
- OKF notation: [Google Cloud blog](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing)
- Engineering design: [`SPEC-deepgram-transcription.md`](SPEC-deepgram-transcription.md)
