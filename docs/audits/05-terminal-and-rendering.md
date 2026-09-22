# Terminal rendering audit (baseline 1a21cf271f98)

## Scope
- Untrusted text reaching the terminal: recording filenames (`src/library.zig`), transcript/markdown documents and LLM output (`src/markdown.zig`), and the interactive player chrome (`src/deck.zig`, `src/viewport.zig`).
- The escape/control-character filters that exist (`viewport.Document.set`, `deck.cleanTitle`) and every render path that writes text to a terminal stream without going through one of them (`src/library.zig`, `src/command_ui.zig`, `src/transcribecmd.zig`, `src/formatcmd.zig`, `src/markdown.zig`).
- Width/wrap arithmetic in `src/viewport.zig` (`tokenLen`, `cellWidth`, `clipped`, `Document.set`) and `src/ruler.zig`.
- Terminal-state sequences (alternate screen, cursor visibility, mouse reporting) in `src/live.zig` and their `defer`-based restoration in `src/playback.zig` / `src/markdown.zig`.
- Static, source-only analysis (baseline `1a21cf271f98690ef93e09306e7ed9169a444f0f`); the Zig toolchain was not used, nothing was built or executed.
- Not inspected in depth: `src/waveform.zig`, `src/visualizer.zig` (pure numeric layout, no untrusted text), `src/spectrum.zig` (confirmed to be pure numeric FFT/PCM analysis with no text output), `src/player.zig` (PCM audio engine, no rendering).

## Summary
- critical: 0 · major: 2 · minor: 1

## FINDING-TERM-01: Recording filenames reach the terminal with no control-character or escape filtering
- **Severity:** major
- **Class:** security
- **Location:** `src/library.zig:246`, `src/library.zig:365`, `src/library.zig:423`
- **Evidence:**
  ```
  fn appendRow(buf: []u8, name: []const u8, duration: ?f64, size: u64, idx: usize, name_w: usize, color: bool) []const u8 {
      var n: usize = 0;
      style.begin(buf, &n, color, style.dim);
      appendUintPadded(buf, &n, idx, 3);
      style.end(buf, &n, color);
      appendStr(buf, &n, "  ");
      appendStr(buf, &n, name);
      appendSpaces(buf, &n, name_w - name.len);
  ```
  ```
  fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
      for (s) |ch| {
          buf[n.*] = ch;
          n.* += 1;
      }
  }

  fn printStdout(io: std.Io, msg: []const u8) void {
      std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
  }
  ```
- **Failure mode:** `scan()` (`src/library.zig:109-149`) enumerates every `.wav`/`.m4a` file in the recordings directory and stores the raw `entry.name` byte string (`src/library.zig:141`) with no validation. `rec list` (`listRecordings`, `src/library.zig:202`) formats each entry through `appendRow`/`appendStr`, which is a byte-for-byte copy loop, then writes the buffer straight to stdout via `printStdout`. No code path between the filesystem read and the terminal write strips bytes below 32, byte 127, or ANSI/OSC escape sequences. The same unfiltered `name` is also echoed by `transcribecmd.zig:116,146,154` and `formatcmd.zig:121` through `command_ui.zig`'s `Mode.print`, which is an unconditional `stderr().writeStreamingAll(io, text)` with no filtering at all (`src/command_ui.zig:9-11`). Any file dropped into the recordings directory — from a synced folder, an extracted archive, or a shared `.wav`/`.m4a` — with a crafted name such as `evil\x1b]0;pwned\x07.wav` or one using `\r` to overwrite an earlier column reaches the real terminal verbatim the next time the user runs `rec list`, `rec transcribe <bad-selection>`, or `rec format <bad-selection>`.
  This is a genuine bypass of an intended control: `deck.zig`'s `cleanTitle` (`src/deck.zig:236-249`) exists specifically to strip `token[0] < 32 or token[0] == 127` from a recording's title before it reaches the interactive player's chrome, and has a dedicated test asserting "a recording title cannot inject terminal commands or extra rows" (`src/deck.zig:264-267`) — but that filter is applied only inside the interactive player. The non-interactive `list`/`transcribe`/`format` paths use the same untrusted filenames without ever calling it.
- **Impact:** A crafted filename can inject arbitrary CSI/OSC sequences into the user's terminal on an ordinary `rec list` — window-title spoofing, screen/scrollback manipulation, cursor-position tricks to overwrite or hide prior output, and on terminals that honor OSC 52, a silent write to the system clipboard (which a user could later paste into a shell).
- **Suggested fix:** Route every filename through the same control/escape stripping `cleanTitle` already performs (or funnel `list`/`transcribe`/`format` output through `viewport.Document.set`) before it is written to stdout/stderr.

## FINDING-TERM-02: `rec view` / `markdown.show()` writes untrusted documents to the terminal unfiltered when stdin is not a tty
- **Severity:** major
- **Class:** security
- **Location:** `src/markdown.zig:103-119`
- **Evidence:**
  ```
  pub fn show(io: std.Io, gpa: std.mem.Allocator, doc: []const u8) u8 {
      const color = style.detect(io, .stderr());
      const rendered = render(gpa, doc, color) catch return 1;
      defer gpa.free(rendered);
      const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
      const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
      const tty = stdin_tty and stderr_tty;
      if (!tty) {
          write(io, rendered);
          return 0;
      }
  ```
  `render()` copies untrusted document text into `rendered` byte-for-byte outside of markdown markers (`src/markdown.zig:181-202`, e.g. `try out.appendSlice(gpa, piece);` at line 199) with no control-character or escape-sequence stripping anywhere in `render`.
- **Failure mode:** `rec view <path.md>` (`src/main.zig:94-99`) reads an arbitrary, fully attacker-suppliable file and calls `markdown.showFile` → `show`. `show` only routes `rendered` through the escape-filtering `viewport.Document.set` (`src/markdown.zig:136`) when *both* stdin and stderr are a tty. Whenever stdin is not a tty — for example `rec view notes.md </dev/null`, a cron/CI invocation, or any pipeline that redirects stdin while stderr still points at the user's real terminal — `write(io, rendered)` (`src/markdown.zig:111`, `write` = `std.Io.File.writeStreamingAll(.stderr(), io, bytes)` at line 210-212) sends the fully rendered document straight to the terminal with none of `Document.set`'s stripping of control bytes or non-SGR escape sequences applied. The same unfiltered `render()` output also reaches this code path for transcripts and LLM-formatted notes opened via `command_ui.zig:14` (`ui.open`, called after every `rec transcribe`/`rec format`) and `playback.zig:115`.
- **Impact:** Any transcript, LLM-formatted note, or arbitrary shared `.md` file containing raw ANSI/OSC bytes (embedded directly, or produced by an LLM asked/tricked into emitting them) is written verbatim to the terminal — the same class of escape injection as FINDING-TERM-01, but reachable through a plain file argument rather than a crafted filename, and without requiring anything unusual beyond the common `stdin` redirection.
- **Suggested fix:** Always filter `rendered` through the same control/escape stripping used by the tty branch (`viewport.Document.set`, or an equivalent pass) before writing it in the `!tty` branch, rather than only clipping/wrapping in the interactive case.

## FINDING-TERM-03: `viewport.Document.set`'s control-character filter omits byte 127 (DEL)
- **Severity:** minor
- **Class:** robustness
- **Location:** `src/viewport.zig:45`
- **Evidence:**
  ```
          if (token[0] < 32 and token[0] != '\t') continue;
  ```
  compare with the intended filter in `src/deck.zig:243`:
  ```
          if (token[0] < 32 or token[0] == 127) continue;
  ```
- **Failure mode:** `Document.set` — the shared filter used by the interactive player (`playback.zig:283`) and the markdown viewer's tty branch (`markdown.zig:136`) to sanitize transcript/note/document text before painting — strips bytes 0-31 (other than `\t`/`\n`, handled separately) but not byte 127. A transcript or note containing a literal DEL byte passes `cellWidth`'s `utf8Decode` (a valid single-byte codepoint, matching none of the zero/double-width ranges) and is copied into the rendered viewport unfiltered, unlike `deck.cleanTitle`, which explicitly filters both `< 32` and `== 127`.
- **Impact:** A DEL byte reaching the terminal is rendered or interpreted inconsistently across emulators (some show a placeholder glyph, some treat it as a destructive backspace that erases the previously drawn cell), corrupting the display of the line it's on. It is a narrower version of the same missing-filter class as FINDING-TERM-01/02, not an escape-sequence injection by itself.
- **Suggested fix:** Change the condition to `token[0] < 32 or token[0] == 127` (matching `deck.cleanTitle`) — or `token[0] < 32 or token[0] == 127) and token[0] != '\t'`.

## Areas checked with no significant finding
- `deck.zig`'s `Canvas.line`/`Canvas.print`: these call `viewport.clipped()` directly with no control-character stripping, which looks unfiltered in isolation, but every `deck.draw` frame is re-passed through `viewport.Document.set` via `header.set(gpa, frame.items, size.cols)` (`playback.zig:304`) before it is ever painted to the screen, so the interactive player's chrome (status, note, tabs) is filtered before display despite `deck.zig` not filtering it itself.
- `viewport.tokenLen`/`Document.set`'s handling of OSC and other non-CSI escape sequences: `tokenLen` only recognizes `ESC [ ... final-byte` as a multi-byte token; any other `ESC`-led sequence (e.g. `ESC ]` for OSC, `ESC c`, `ESC P`) is tokenized as the lone `ESC` byte, which `Document.set` then drops (it only appends CSI tokens ending in `m`), leaving the sequence's remaining bytes to render as inert literal text rather than being reinterpreted as an escape by the terminal — this correctly defuses OSC/DCS injection for anything that goes through `Document.set`.
- `viewport.clipped`/`tokenLen`/`cellWidth`: multi-byte UTF-8 sequences are always measured and included as a whole token (`cells` is computed for the full sequence before the width check), so truncation at the column boundary never splits a codepoint mid-sequence; a truncated/invalid trailing sequence falls back to `utf8Decode` failing and being counted as 1 cell, a display quirk rather than a security issue.
- `src/live.zig`: `enter`/`leave`/`sync_begin`/`sync_end`/`moveTo` are pure buffer-formatting functions with fixed, hard-coded escape sequences (no user data embedded), and are covered by exact-string tests.
- Terminal-state restoration: `playback.zig`'s interactive loop enters the alt screen and mouse reporting then immediately establishes `defer leaveAlt(...)` (`playback.zig:202-209`) and `defer printStderr(io, viewport.mouse_off)` (`playback.zig:244`), and `markdown.show`'s tty branch does the same for raw mode, the alt screen, and mouse reporting (`markdown.zig:119-126`) — all run on every return path, including early `return` on error, so terminal state is restored even when the loop exits abnormally.
- `src/ruler.zig`: `renderTicks`/`renderLabels`/`fmtTime` are pure numeric column math over fixed characters (box-drawing glyphs, digits, `:`), with no untrusted text and no path that can index outside `width`/`buf`; behavior is covered by several width/edge-case tests.
- `src/style.zig`: SGR codes are compile-time constants; `appendStyled`/`begin`/`end` never interpolate untrusted text into an escape sequence.
- `src/spectrum.zig`: pure PCM/FFT analysis (`Analysis.update`/`measure`/`trace`) with no text formatting or terminal output of any kind.
