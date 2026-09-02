---
type: ADR
id: "0008"
title: "Finalize recordings incrementally and atomically"
status: active
date: 2026-09-02
---

## Context

The AAC encoder writes the M4A `moov` atom only when `ExtAudioFileDispose`
finishes the file. Encoding the entire in-memory recording in one blocking call
after Ctrl-C made that finalization take long enough for a user to terminate the
process, leaving a headerless AAC payload that no player could open. This
supersedes the capture-pipeline mechanics in ADR 0004; that ADR's M4A/AAC
format decision remains active.

## Decision

**Encode PCM in bounded chunks while capture is running, and publish the M4A
only after explicit finalization succeeds.**

- `m4a.Encoder` owns the open AudioToolbox file and accepts multiple PCM writes.
- The recording command writes to a `.part` work file as its capture loop drains
  PCM, then calls `finish` explicitly after the device stops.
- The work file is renamed to the public `.m4a` path only after `finish` returns
  successfully. Aborted or failed runs remove the work file.
- The SIGINT handler remains cooperative: it requests stop, while the main
  thread stops capture and performs the short final dispose.

## Options considered

- **Encode the complete PCM buffer after capture** — simpler, but leaves a long
  non-interruptible finalization window and exposes a partial container if the
  process is terminated.
- **Encode from the audio callback** — couples file I/O and AudioToolbox work to
  the real-time audio thread; the main thread can drain bounded chunks instead.
- **Write directly to the public `.m4a` path** — makes an interrupted run
  visible as a corrupt library entry; the work-file rename avoids that state.

## Consequences

- Ctrl-C no longer starts a potentially minutes-long final encode; only the
  already-open encoder needs to flush its container metadata.
- A process killed during capture can leave at most an ignored `.part` file,
  never a corrupt public recording.
- PCM is still retained by the capture recorder for the live view and summary;
  this decision addresses finalization latency and publication safety, not the
  existing recording-memory profile.
