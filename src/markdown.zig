//! Small terminal Markdown viewer used by transcribe, format and playback.
//! It deliberately handles the subset produced by rec: YAML frontmatter,
//! headings, lists, emphasis, code fences and ordinary paragraphs. TTY output
//! is wrapped and scrollable, with one redraw per input or resize.

const std = @import("std");
const keys = @import("keys.zig");
const live = @import("live.zig");
const share = @import("share.zig");
const style = @import("style.zig");
const viewport = @import("viewport.zig");
const waveform = @import("waveform.zig");

pub const max_document_bytes = 16 * 1024 * 1024;

pub const Parts = struct {
    frontmatter: []const u8,
    body: []const u8,
};

/// Splits a document only when the opening and closing YAML fences are both
/// present. An unfinished fence remains ordinary Markdown.
pub fn splitFrontmatter(doc: []const u8) Parts {
    if (!std.mem.startsWith(u8, doc, "---\n")) return .{ .frontmatter = "", .body = doc };
    const end = std.mem.indexOfPos(u8, doc, 4, "\n---\n") orelse return .{ .frontmatter = "", .body = doc };
    return .{ .frontmatter = doc[4..end], .body = doc[end + 5 ..] };
}

/// Renders the document for a terminal. Frontmatter is shown as a metadata
/// block instead of raw YAML fences, and Markdown markers receive terminal
/// styles where the output is a tty.
pub fn render(gpa: std.mem.Allocator, doc: []const u8, color: bool) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const parts = splitFrontmatter(doc);

    if (parts.frontmatter.len > 0) {
        try appendStyled(gpa, &out, color, style.bold, "METADATA\n");
        var it = std.mem.splitScalar(u8, parts.frontmatter, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                try appendStyled(gpa, &out, color, style.cyan, key);
                try out.appendSlice(gpa, ": ");
                try appendYamlDisplay(gpa, &out, value, color);
                try out.append(gpa, '\n');
            } else {
                try appendInline(gpa, &out, trimmed, color, false);
                try out.append(gpa, '\n');
            }
        }
        try out.append(gpa, '\n');
    }

    var in_code = false;
    var lines = std.mem.splitScalar(u8, parts.body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, std.mem.trim(u8, trimmed, " \t"), "```")) {
            in_code = !in_code;
            if (in_code) try appendStyled(gpa, &out, color, style.dim, "┌─ code ─\n") else try appendStyled(gpa, &out, color, style.dim, "└────────\n");
            continue;
        }
        if (in_code) {
            try appendStyled(gpa, &out, color, style.dim, "│ ");
            try out.appendSlice(gpa, trimmed);
            try out.append(gpa, '\n');
            continue;
        }
        const left = std.mem.trim(u8, trimmed, " \t");
        if (left.len > 0 and left[0] == '#') {
            var hashes: usize = 0;
            while (hashes < left.len and left[hashes] == '#') : (hashes += 1) {}
            if (hashes < left.len and left[hashes] == ' ') hashes += 1;
            try appendStyled(gpa, &out, color, style.bold, left[hashes..]);
            try out.append(gpa, '\n');
        } else if (std.mem.startsWith(u8, left, "- ") or std.mem.startsWith(u8, left, "* ")) {
            try appendStyled(gpa, &out, color, style.cyan, "• ");
            try appendInline(gpa, &out, left[2..], color, false);
            try out.append(gpa, '\n');
        } else {
            try appendInline(gpa, &out, trimmed, color, false);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Reads and displays a file. A tty gets a dismissible alternate-screen viewer
/// with vertical scrolling; pipes receive the rendered text and never block.
pub fn showFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) u8 {
    const doc = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_document_bytes)) catch {
        write(io, "Could not open document\n");
        return 1;
    };
    defer gpa.free(doc);
    return show(io, gpa, doc);
}

pub fn show(io: std.Io, gpa: std.mem.Allocator, doc: []const u8) u8 {
    const color = style.detect(io, .stderr());
    const rendered = render(gpa, doc, color) catch return 1;
    defer gpa.free(rendered);
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stderr_tty = std.Io.File.stderr().isTty(io) catch false;
    const tty = stdin_tty and stderr_tty;
    if (!tty) {
        const buf = gpa.alloc(u8, rendered.len) catch {
            write(io, "Out of memory\n");
            return 1;
        };
        defer gpa.free(buf);
        write(io, filterForPipe(rendered, buf));
        return 0;
    }

    const raw = keys.enableRaw() orelse {
        write(io, rendered);
        return 0;
    };
    defer keys.restoreRaw(raw);
    var esc: [32]u8 = undefined;
    write(io, live.enter(&esc));
    write(io, viewport.mouse_on);
    defer {
        write(io, viewport.mouse_off);
        write(io, live.leave(&esc));
    }
    var document = viewport.Document{};
    defer document.deinit(gpa);
    var screen = viewport.Screen{};
    defer screen.deinit(gpa);
    const head = viewport.Document{};
    var offset: usize = 0;
    var status: []const u8 = "↑↓/wheel scroll · PgUp/PgDn · Home/End · Y copy · S share · Q close";
    while (true) {
        const size = waveform.termSize();
        if (document.width != size.cols) document.set(gpa, rendered, size.cols) catch return 1;
        screen.paint(io, gpa, &head, &document, &offset, size.rows, size.cols, status) catch return 1;
        const key = keys.readKey(io, 100);
        if (viewport.navigate(&offset, key, document.starts.items.len, size.rows -| 1)) continue;
        switch (key) {
            .eof => return 0,
            .byte => |c| switch (c) {
                'q', 'Q', 0x1b, 0x03 => return 0,
                'j' => {
                    _ = viewport.navigate(&offset, .down, document.starts.items.len, size.rows -| 1);
                },
                'k' => {
                    _ = viewport.navigate(&offset, .up, document.starts.items.len, size.rows -| 1);
                },
                ' ', 'b' => {
                    _ = viewport.navigate(&offset, if (c == ' ') .page_down else .page_up, document.starts.items.len, size.rows -| 1);
                },
                else => {
                    if (shareKey(io, doc, c)) |message| status = message;
                },
            },
            else => {},
        }
    }
}

/// Shared copy/share controls; the status always explains what happened.
pub fn shareKey(io: std.Io, doc: []const u8, key: u8) ?[]const u8 {
    const destination: share.Destination = switch (key) {
        'y', 'Y', 's', 'S' => .clipboard,
        'c', 'C' => .chatgpt,
        'l', 'L' => .claude,
        'g', 'G' => .gemini,
        else => return null,
    };
    if (doc.len == 0) return "No text to share";
    return if (share.shareText(io, doc, destination)) if (destination == .clipboard) "Copied · C ChatGPT · L Claude · G Gemini" else "Copied · Paste in the opened app" else "Could not share · Y copies the text";
}

fn appendYamlDisplay(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, color: bool) std.mem.Allocator.Error!void {
    var v = value;
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
    try appendInline(gpa, out, v, color, false);
}

fn appendInline(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, color: bool, _: bool) std.mem.Allocator.Error!void {
    var i: usize = 0;
    var bold = false;
    var code = false;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            bold = !bold;
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            code = !code;
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and text[i] != '`' and !(i + 1 < text.len and text[i] == '*' and text[i + 1] == '*')) : (i += 1) {}
        const piece = text[start..i];
        if (code) try appendStyled(gpa, out, color, style.cyan, piece) else if (bold) try appendStyled(gpa, out, color, style.bold, piece) else try out.appendSlice(gpa, piece);
    }
    if (color and (bold or code)) try out.appendSlice(gpa, style.reset);
}

fn appendStyled(gpa: std.mem.Allocator, out: *std.ArrayList(u8), color: bool, code: []const u8, text: []const u8) std.mem.Allocator.Error!void {
    if (color) try out.appendSlice(gpa, code);
    try out.appendSlice(gpa, text);
    if (color) try out.appendSlice(gpa, style.reset);
}

fn write(io: std.Io, bytes: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, bytes) catch {};
}

/// The bytes the non-tty branch writes: `rendered` with control bytes and
/// escape sequences from the document stripped while line structure survives.
/// `buf` must hold `rendered.len`; returns the used prefix.
fn filterForPipe(rendered: []const u8, buf: []u8) []const u8 {
    return viewport.stripControls(rendered, "\n\t", buf);
}

test "markdown non-tty output filters escapes" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "title]0;pwned\nbody\tkept",
        filterForPipe("title\x1b]0;pwned\x07\nbody\tkept", &buf),
    );
}

test "splitFrontmatter keeps a complete YAML block separate" {
    const p = splitFrontmatter("---\ntitle: Hello\n---\n# Body\n");
    try std.testing.expectEqualStrings("title: Hello", p.frontmatter);
    try std.testing.expectEqualStrings("# Body\n", p.body);
}

test "render presents metadata and markdown without raw fences" {
    const rendered = try render(std.testing.allocator, "---\ntitle: Hello\ntimestamp: 2026-01-01T00:00:00Z\n---\n# Heading\n- **one**\n", false);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "METADATA\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "title: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "---") == null);
}
