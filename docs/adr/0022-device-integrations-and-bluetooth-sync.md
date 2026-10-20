---
type: ADR
id: "0022"
title: "Device integrations, with Bluetooth sync for the AIREC recorder"
status: active
date: 2026-10-20
---

## Context

rec records from the computer's microphone. Recordings also come from
dedicated devices, and the first one in use is the AIREC smart voice recorder
(ADR 0021 covers its `.ops` file format). The goal is that a recording saved
on the device shows up in the library, transcribed and formatted, without a
cable and without the vendor app.

The recorder speaks Bluetooth LE through a vendor protocol with no public
documentation. It was reverse engineered from an iOS PacketLogger capture of
the AIREC app, then replayed from a Mac (firmware 1.3.0, model A30A); the
frame reference is [docs/devices/airec-protocol.md](../devices/airec-protocol.md).
Three findings shape the design:

- There is no pairing and no authentication. A session must begin with
  command `01`, and the recorder ignores everything before it.
- With only `01` sent, a button press while connected records nothing. After
  the app's full opening sequence (queries, set clock, `69 00`, `30`,
  `66 00`) the recorder raises `03 <name>` when a recording starts and
  `04 <name> <size>` when it is saved.
- A download (`07 <name> <offset>`) streams exactly the bytes of the `.ops`
  file a USB copy gives (verified on 1,743,808 bytes), so ADR 0021's decoder
  applies unchanged.

On macOS, Bluetooth LE means CoreBluetooth, an Objective-C-only framework.

## Decision

**Devices are integrations behind one verb, `rec device <name> <action>`,
and the AIREC integration syncs over Bluetooth LE from Zig, driving
CoreBluetooth through a handful of hand-declared Objective-C runtime
calls.**

- `src/devices.zig` is the verb. It lists the integrations and dispatches to
  modules that expose `name`, `description`, and `run`.
- `src/devices/ingest.zig` holds what every integration shares: publish PCM
  as `<stem><ext>` through a `.part` file and an atomic rename (ADR 0008),
  skip a stem already in the library, then transcribe and format through the
  existing `transcribecmd`/`formatcmd` in background mode, as the play view
  does (ADR 0019).
- `src/devices/airec/` holds the AIREC integration: `ops.zig` (format),
  `protocol.zig` (frame encode/parse, no I/O), `session.zig` (open, list,
  download, events; generic over the link), `fake.zig` (a simulated
  recorder), and `airec.zig` (the `import`, `sync`, and `watch` actions).
- `src/ble.zig` is a device-agnostic BLE central: scan for an advertised
  service, connect, subscribe to every notifying characteristic, write
  without response, and receive notifications by characteristic index.
  On macOS it runs CoreBluetooth on the main run loop, pumped only while
  the link waits, so a process holds one link at a time. Other platforms
  return `error.Unsupported`.
- `src/objc.zig` declares the Objective-C runtime entry points by hand
  (`objc_getClass`, `sel_registerName`, `objc_msgSend` cast per call,
  class-pair creation for the delegate, and autorelease pools), as
  `m4a.zig` does for AudioToolbox. `build.zig` links Foundation,
  CoreBluetooth, and libobjc on macOS.
- `sync` opens the session, downloads every recording the library lacks
  (oldest first), disconnects, then transcribes and formats them.
  `watch` does the same on every connection, then stays connected: each `04`
  event downloads, publishes, and processes that recording. It reconnects
  whenever the recorder comes back in range. `--no-notes` stops after the
  import.
- Recording names from the device become file names, so `protocol.zig`
  accepts only 14 ASCII digits.
- `zig build -Dfake-airec=true` swaps the radio for `fake.DirLink`, which
  serves `<name>.ops` files from a directory. `scripts/e2e_airec.py` runs
  `import` and `sync` against it in CI on all three platforms.

## Options considered

- **A Swift helper binary.** CoreBluetooth is natural in Swift, but it adds a
  second language and toolchain, a separate macOS-only binary, and a process
  boundary between the helper and rec. The Objective-C surface needed is
  about ten runtime symbols. Rejected.
- **The `zig-objc` package.** Its Zig 0.16 release runs `translate-c` over
  the SDK's runtime headers with a patch for a translate-c bug: the
  brittleness this repo avoids for Apple headers. For ten symbols it is more
  machinery than code. Rejected.
- **BlueZ (Linux) and WinRT (Windows) backends now.** No user needs them yet,
  and each is its own integration. `ble.Link` is the seam where they plug in.
  Deferred.
- **A USB-volume watcher.** It needs the cable this work removes. Copying
  files and running `rec device airec import` still covers USB.

## Consequences

- One binary and one language. The integration builds everywhere, and
  Bluetooth reports itself unsupported outside macOS.
- While rec holds the connection, the AIREC phone app cannot connect: the
  recorder takes one central at a time. `sync` releases it right away;
  `watch` holds it by design.
- macOS grants Bluetooth to the terminal that runs rec. Running `watch` as a
  launchd agent would need an embedded Info.plist with
  `NSBluetoothAlwaysUsageDescription` and its own TCC grant. Not done yet.
- The protocol is reverse engineered. A firmware update can change it.
  Commands whose meaning is unknown (`0f`, `20`, `36`, `66`, `69`) are sent
  only because the app sends them in the same order; the vendor's
  settings command (`22`) is never sent.
- Live audio streams on its own characteristic during a connected recording.
  It is ignored; the saved file is the source of truth.
- Watch mode transcribes on the same thread that pumps Bluetooth. Events
  queue while a transcription runs, and the next one is handled after it.
