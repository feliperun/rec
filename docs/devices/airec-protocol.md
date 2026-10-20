# AIREC Bluetooth LE protocol

Reverse engineered on 2026-10-20 from an iOS PacketLogger capture of the
vendor app, then replayed from a Mac. Recorder firmware `1.3.0`, model
`A30A`. Implemented in `src/devices/airec/protocol.zig` and `session.zig`;
the design is [ADR 0022](../adr/0022-device-integrations-and-bluetooth-sync.md).

## Transport

- Advertises as `AIREC(BLE)`, with 16-bit service `AF43` in the
  advertisement. Connectable, no pairing or bonding.
- MTU 247 (the app asks for 527).
- GATT service `0011200A-2233-4455-6677-8899DFDEDDDC`:

| Characteristic | Properties | Use |
|----------------|------------|-----|
| `0011201A-2233-4455-6677-8899DFDEDDDC` | notify | live Opus packets during a connected recording |
| `0011202A-2233-4455-6677-8899DFDEDDDC` | write without response | commands |
| `0011203A-2233-4455-6677-8899DFDEDDDC` | notify | replies and events |
| `0011204A-2233-4455-6677-8899DFDEDDDC` | write without response, notify | recording bytes during a download |
| `0011206A-2233-4455-6677-8899DFDEDDDC` | write without response | not used by the app |

Subscribe to all three notifying characteristics before the first command.

## Framing

- Host to recorder: `55 aa <len> <cmd> <args>`, where `len` = 1 + args.
- Recorder to host: `aa 55 <len> <code> <data>`.
- Recording names are the recorder's local start time, 14 ASCII digits
  `YYYYMMDDHHMMSS`. Sizes and offsets are u32 big-endian.

## Session

The recorder ignores every command until `01`. The vendor app then sends,
in order: `20`, `0f`, `12`, `26`, `29`, `0b`, `0e`, `36`, `05`,
`02 <local time>`, `69 00`, `30`, `66 00`. Without this sequence a button
press while connected produces neither a recording nor an event. Which of
the steps matters is untested, so rec replays all of them.

## Commands

| Cmd | Args | Reply | Meaning |
|-----|------|-------|---------|
| `01` | none | `01 <15 ASCII digits>`, then `36 00` | open session; device serial |
| `02` | 14-digit time | `02` | set the clock |
| `05` | none | `05 <name> <size>` per recording, then `06` | list recordings |
| `07` | `<name> <offset>` | `07 <name> <size>`, bytes on `0011204A`, then `09` | download |
| `0b` | none | `0c <u32>`, `0d <u32>` | storage figures (units unknown) |
| `0e` | none | `0e <percent>` | battery |
| `12` | none | `12 "1.3.0"` | firmware version |
| `26` | none | `26 <13 bytes>` | settings |
| `29` | none | `29 "A30A"` | model |
| `30` | none | `30 <14-digit time>` | read the clock |
| `22` | u16 | `22` | writes a setting (the app sent 60 and 600); rec never sends it |
| `3a` | `01` / `00` | live audio on / off | the recorder also streams without it once the session is open |
| `0f`, `20`, `36`, `66`, `69` | see the session | | unknown |

## Events (unsolicited, on `0011203A`)

| Frame | Meaning |
|-------|---------|
| `03 <name>` | a recording started (one click on button A) |
| `04 <name> <size>` | the recording was saved |

## Recording bytes

A download streams the recording file exactly as a USB copy gives it: an
`.ops` file of back-to-back 80-byte CBR Opus packets (ADR 0021).
Throughput was about 45 KB/s for 1.7 MB; a 53 KB file took about 1 s.
