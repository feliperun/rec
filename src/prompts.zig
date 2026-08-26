const std = @import("std");

/// Bundled LLM prompt templates, shipped verbatim from metalscribe's docs.
/// `refine` is applied automatically by `rec transcribe`; `meeting` is the
/// default transformation template behind `rec format`.
pub const refine_md = @embedFile("prompts/refine.md");
pub const meeting_md = @embedFile("prompts/meeting.md");

/// The bundled template bodies addressable without touching the filesystem —
/// the fallback when the user's templates dir is missing or read-only.
pub fn embeddedTemplate(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "meeting")) return meeting_md;
    if (std.mem.eql(u8, name, "refine")) return refine_md;
    return null;
}

/// The one placeholder refine.md knows about; everything else in the file is
/// sent through untouched.
const domain_placeholder = "{{DOMAIN_CONTEXT}}";

/// Fills a template's {{DOMAIN_CONTEXT}} placeholder with the caller's
/// context (or an explicit "not provided" line when none was given), appends
/// the transcript as a clearly delimited payload, and — when the user gave a
/// context but the template has no placeholder slot — surfaces it as its own
/// trailing section instead of dropping it. Caller frees the result.
pub fn compose(
    gpa: std.mem.Allocator,
    template: []const u8,
    domain_context: ?[]const u8,
    transcript: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const has_slot = std.mem.indexOf(u8, template, domain_placeholder) != null;
    const filled = try replacePlaceholder(
        gpa,
        template,
        domain_context orelse "(nenhum contexto fornecido)",
    );
    defer gpa.free(filled);
    try out.appendSlice(gpa, filled);

    // User-provided context must never vanish just because this particular
    // template predates the placeholder convention.
    if (domain_context != null and !has_slot) {
        try appendDivider(gpa, &out);
        try out.appendSlice(gpa, "## CONTEXTO FORNECIDO PELO USUÁRIO\n\n");
        try out.appendSlice(gpa, domain_context.?);
        try out.append(gpa, '\n');
    }

    try appendDivider(gpa, &out);
    try out.appendSlice(gpa, "## TRANSCRIÇÃO\n\n");
    try out.appendSlice(gpa, transcript);
    try out.append(gpa, '\n');

    return out.toOwnedSlice(gpa);
}

/// The `---` section divider, preceded by exactly one blank line whether or
/// not the accumulated text already ends in a newline.
fn appendDivider(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    const sep: []const u8 = if (out.items.len > 0 and out.items[out.items.len - 1] == '\n')
        "\n---\n\n"
    else
        "\n\n---\n\n";
    try out.appendSlice(gpa, sep);
}

/// Single-pass replacement; the placeholder occurs exactly once in the
/// bundled templates but every match would be replaced anyway.
fn replacePlaceholder(
    gpa: std.mem.Allocator,
    template: []const u8,
    value: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = template;
    while (std.mem.indexOf(u8, rest, domain_placeholder)) |at| {
        try out.appendSlice(gpa, rest[0..at]);
        try out.appendSlice(gpa, value);
        rest = rest[at + domain_placeholder.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// Splits rendered OKF markdown into frontmatter (with trailing `\n---\n`)
/// and body. A missing frontmatter block means an empty head and the whole
/// input as the body.
pub fn splitFrontmatter(doc: []const u8) struct { head: []const u8, body: []const u8 } {
    if (!std.mem.startsWith(u8, doc, "---\n")) return .{ .head = "", .body = doc };
    const end = std.mem.indexOfPos(u8, doc, 4, "\n---\n") orelse return .{ .head = "", .body = doc };
    return .{ .head = doc[0 .. end + 5], .body = doc[end + 5 ..] };
}

test "compose substitutes the placeholder and delimits the transcript" {
    const doc = try compose(std.testing.allocator, "A\n{{DOMAIN_CONTEXT}}\nB\n", "reunião médica", "fala 1.\n\nfala 2.");
    defer std.testing.allocator.free(doc);
    try std.testing.expectEqualStrings(
        "A\nreunião médica\nB\n\n---\n\n## TRANSCRIÇÃO\n\nfala 1.\n\nfala 2.\n",
        doc,
    );
}

test "compose explains an absent domain context so the template's rule fires" {
    const doc = try compose(std.testing.allocator, "{{DOMAIN_CONTEXT}}x", null, "t.");
    defer std.testing.allocator.free(doc);
    try std.testing.expectEqualStrings("(nenhum contexto fornecido)x\n\n---\n\n## TRANSCRIÇÃO\n\nt.\n", doc);
}

test "compose keeps user context visible on placeholderless templates" {
    const doc = try compose(std.testing.allocator, "# Plantão de hoje\n", "projeto Phoenix", "fala solta");
    defer std.testing.allocator.free(doc);
    try std.testing.expectEqualStrings(
        \\# Plantão de hoje
        \\
        \\---
        \\
        \\## CONTEXTO FORNECIDO PELO USUÁRIO
        \\
        \\projeto Phoenix
        \\
        \\---
        \\
        \\## TRANSCRIÇÃO
        \\
        \\fala solta
        \\
    , doc);
}

test "splitFrontmatter separates the yaml block from the prose" {
    const head = "---\ntype: Recording Transcript\ntitle: t\n---\n";
    const doc = head ++ "Fala um.\n\nFala dois.\n";
    const split = splitFrontmatter(doc);
    try std.testing.expectEqualStrings(head, split.head);
    try std.testing.expectEqualStrings("Fala um.\n\nFala dois.\n", split.body);
}

test "splitFrontmatter treats documents without frontmatter as all body" {
    const split = splitFrontmatter("only prose\n");
    try std.testing.expectEqualStrings("", split.head);
    try std.testing.expectEqualStrings("only prose\n", split.body);

    // An unterminated frontmatter block is not frontmatter either.
    const unterminated = splitFrontmatter("---\ntitle: t\nprose");
    try std.testing.expectEqualStrings("", unterminated.head);
    try std.testing.expectEqualStrings("---\ntitle: t\nprose", unterminated.body);
}
