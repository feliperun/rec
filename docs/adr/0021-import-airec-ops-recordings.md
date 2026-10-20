---
type: ADR
id: "0021"
title: "Import AIREC .ops recordings through libopus"
status: active
date: 2026-10-20
---

## Context

The AIREC smart voice recorder writes `<YYYYMMDDHHMMSS>.ops` files. Its
manual advertises "16 kHz, WAV", but the files carry no RIFF, Ogg, or MP4
header. Analysis of a real recording showed:

- Back-to-back 80-byte records. 89% start with `4b 41`, and the rest with
  `4b 01` or `48`.
- Read as Opus packets, those are TOC `0x4b` (SILK wideband, 20 ms, mono,
  code 3) plus a frame-count byte `0x41` (CBR, padding present, one frame),
  or TOC `0x48` (code 0, one frame, no padding). The byte after `0x41` is
  the padding length, and the record ends in exactly that many zeros.
- Payload entropy is about 8 bits per byte, as range-coded Opus is.
- libopus decodes all 21,797 packets of the sample with no error: 435.94 s
  of audio. A trailing 48-byte partial packet is a recording cut off
  mid-write.
- libopus in CBR mode at 32 kbps / 20 ms / 16 kHz mono produces the same
  packet framing (`4b 41 …`).

So `.ops` is raw Opus at a constant 32 kbps with no container and no
per-packet length. The fixed packet size is the only framing. Nothing in the
tree decodes Opus. miniaudio decodes WAV/FLAC/MP3 only, and AudioToolbox is
macOS-only.

The user wants these recordings to open, play, cut, and transcribe like any
other.

## Decision

**`rec device airec import <file.ops>...` decodes `.ops` files with libopus
and writes each one into `~/recordings/` in the platform's recording format
(ADR 0012). It does not teach the library a third on-disk format.** The verb
lives in the device integration layer of [ADR 0022](0022-device-integrations-and-bluetooth-sync.md),
which also brings the same files in over Bluetooth.

- libopus 1.6.1 comes from the `allyourcodebase/opus` package
  (`build.zig.zon`), compiled from source by zig for every target. No
  system library is involved, and cross-compilation and the dynamic-glibc
  Linux gate are unchanged. `build.zig` links the package's **static**
  artifact. The package installs a static and a shared library under the
  same name, so `Dependency.artifact` is ambiguous.
- `src/devices/airec/ops.zig` owns the format: `packet_bytes = 80`, `packetCount` (drops a
  trailing partial packet), and a `Decoder` pinned to the canonical
  s16 / 48 kHz / stereo layout. libopus resamples and upmixes the mono SILK
  stream itself. Bindings are hand-declared externs, as elsewhere in the
  tree.
- `src/devices/airec/airec.zig` holds the verb. It streams packet by packet
  into the platform encoder through `src/devices/ingest.zig` (memory is
  bounded by one packet of PCM), writes a `.part` file, and renames it
  atomically (ADR 0008). The stem is kept
  (`20241231221356.ops` becomes `20241231221356.m4a` or `.wav`). An existing
  recording of that name is skipped, so re-importing a device is idempotent.
  The source file is never modified.
- Accepted only by extension (`.ops`, any case). A packet libopus rejects
  fails the whole import. Nothing is published half-decoded.

## Options considered

- **Native `.ops` in the library** (scan, decode facade, transcribe upload,
  cut). Every format-aware path would gain a third branch, transcription
  would need an on-the-fly WAV conversion for Deepgram, and a cut would
  still have to rewrite the file in another format (rec has no Opus
  encoder). Rejected: one conversion at the edge reaches the same features
  with one new module instead of five touched ones.
- **Shell out to ffmpeg.** No raw-Opus demuxer reads this framing, a new
  runtime dependency, and not present on most user machines. Rejected.
- **Link the system libopus.** Breaks the single self-contained binary and
  cross-compilation. Rejected.
- **Vendor libopus sources into `vendor/`.** Same result as the package,
  plus ~250 files and a hand-maintained source list and config header.
  Rejected in favor of the maintained zig build.

## Consequences

- Imported recordings are ordinary recordings. `list`, `play`, cut,
  `transcribe`, `format`, and `share` need no change.
- One new build dependency, fetched by zig on first build (cached in the
  global package cache; the project-local `zig-pkg/` is gitignored).
- The 80-byte packet size is the AIREC recorder's 32 kbps CBR setting. A
  device or firmware writing another bitrate would decode as garbage or fail.
  If one appears, the packet size becomes a parameter detected from the
  framing.
- The imported file's mtime is the import time, so a fresh import is the
  latest recording and `rec play` / `rec transcribe` with no selection act
  on it.
- On Linux and Windows the import is WAV: about 80 MiB for 7 minutes, against
  1.7 MiB of `.ops`. On macOS it is AAC (about 5.6 MiB). This is the
  ADR 0012 trade-off, unchanged.
