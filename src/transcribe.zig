const std = @import("std");

const curl_path = "/usr/bin/curl";

// Query parameters are fixed by the spec and their order is pinned by tests;
// only `language` is spliced in, verbatim.
const listen_base = "https://api.deepgram.com/v1/listen?";
const listen_query_before_language = "model=nova-3&language=";
const listen_query_after_language = "&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true";

/// Bytes `buildListenUrl` needs in its buffer for a language code of the
/// given length.
pub fn listenUrlLen(language_len: usize) usize {
    return listen_base.len + listen_query_before_language.len + language_len + listen_query_after_language.len;
}

/// Writes the Deepgram listen URL for `language` into `buf` (size it with
/// listenUrlLen) and returns the filled slice. Parameter order is part of the
/// request contract, not cosmetic.
pub fn buildListenUrl(buf: []u8, language: []const u8) []const u8 {
    std.debug.assert(buf.len >= listenUrlLen(language.len));
    var n: usize = 0;
    appendStr(buf, &n, listen_base);
    appendStr(buf, &n, listen_query_before_language);
    appendStr(buf, &n, language);
    appendStr(buf, &n, listen_query_after_language);
    return buf[0..n];
}

/// One diarized segment of speech, times in seconds. `text` is owned by the
/// allocator passed to parseResponse; release everything with
/// freeUtterances.
pub const Utterance = struct {
    start_sec: f64,
    end_sec: f64,
    speaker: u32,
    text: []u8,
};

pub fn freeUtterances(gpa: std.mem.Allocator, utterances: []Utterance) void {
    for (utterances) |u| gpa.free(u.text);
    gpa.free(utterances);
}

pub const ParseError = error{ BadResponse, NoSpeech, OutOfMemory };

// Only the subset of the Deepgram response we consume; unknown fields are
// ignored so API additions never break parsing.
const ApiUtterance = struct {
    start: f64 = 0,
    end: f64 = 0,
    transcript: []const u8 = "",
    speaker: u32 = 0,
};

const ApiResults = struct {
    utterances: ?[]const ApiUtterance = null,
};

const ApiResponse = struct {
    results: ?ApiResults = null,
};

/// Parses a listen response into owned utterances (free with
/// freeUtterances). Silence and breakage stay distinct: an empty or missing
/// utterance list is error.NoSpeech, unparsable JSON is error.BadResponse.
pub fn parseResponse(gpa: std.mem.Allocator, json_bytes: []const u8) ParseError![]Utterance {
    const parsed = std.json.parseFromSlice(ApiResponse, gpa, json_bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    defer parsed.deinit();

    const list = if (parsed.value.results) |r| r.utterances orelse return error.NoSpeech else return error.NoSpeech;
    if (list.len == 0) return error.NoSpeech;

    const out = try gpa.alloc(Utterance, list.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |u| gpa.free(u.text);
        gpa.free(out);
    }
    for (list, 0..) |u, i| {
        out[i] = .{
            .start_sec = u.start,
            .end_sec = u.end,
            .speaker = u.speaker,
            .text = gpa.dupe(u8, u.transcript) catch return error.OutOfMemory,
        };
        done = i + 1;
    }
    return out;
}

pub const TranscribeError = error{
    CurlSpawnFailed,
    RequestFailed,
    BadResponse,
    NoSpeech,
    OutOfMemory,
};

/// Request artifacts handed back to the caller: the captured response body
/// for parseResponse, plus a bounded stderr tail so the CLI can quote what
/// curl reported on failure. Initialize with `.{ .json = .empty }`.
pub const TranscribeOutput = struct {
    json: std.ArrayList(u8),
    err_tail: [512]u8 = [_]u8{0} ** 512,
    err_tail_len: usize = 0,
};

/// POSTs the WAV at `wav_abs_path` to Deepgram and appends the response body
/// to `out.json`. On error.RequestFailed the tail of curl's stderr is copied
/// into `out.err_tail` for the caller's one-line message. The key travels
/// only inside the child's Authorization header; resolving it is the
/// caller's job.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, wav_abs_path: []const u8, api_key: []const u8, language: []const u8, out: *TranscribeOutput) TranscribeError!void {
    const url_buf = gpa.alloc(u8, listenUrlLen(language.len)) catch return error.OutOfMemory;
    defer gpa.free(url_buf);
    const url = buildListenUrl(url_buf, language);

    const auth_header = std.fmt.allocPrint(gpa, "Authorization: Token {s}", .{api_key}) catch return error.OutOfMemory;
    defer gpa.free(auth_header);

    const data_arg = std.fmt.allocPrint(gpa, "@{s}", .{wav_abs_path}) catch return error.OutOfMemory;
    defer gpa.free(data_arg);

    const argv = [_][]const u8{
        curl_path,
        "-fsS",
        "-X",
        "POST",
        auth_header,
        "Content-Type: audio/wav",
        "--data-binary",
        data_arg,
        url,
    };

    out.err_tail_len = 0;

    // run() is playback's spawn idiom plus concurrent pipe draining, so a
    // large response body cannot deadlock on a full pipe while we read.
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Limits are unlimited and no timeout is set, so every remaining
        // error means curl itself could not be launched or its streams broke.
        else => return error.CurlSpawnFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        // -fS sends the failing HTTP status detail to stderr; keep its tail.
        copyErrTail(out, result.stderr);
        return error.RequestFailed;
    }

    out.json.appendSlice(gpa, result.stdout) catch return error.OutOfMemory;
}

/// Last err_tail.len bytes, so the CLI quotes the most recent diagnostic.
fn copyErrTail(out: *TranscribeOutput, stderr_bytes: []const u8) void {
    const n = @min(stderr_bytes.len, out.err_tail.len);
    @memcpy(out.err_tail[0..n], stderr_bytes[stderr_bytes.len - n ..]);
    out.err_tail_len = n;
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |ch| {
        buf[n.*] = ch;
        n.* += 1;
    }
}

test "listen url keeps the fixed parameter order with the default language" {
    var buf: [listenUrlLen("pt-BR".len)]u8 = undefined;
    const url = buildListenUrl(&buf, "pt-BR");
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&language=pt-BR&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true",
        url,
    );
}

test "listen url splices custom languages verbatim without reordering" {
    var buf: [listenUrlLen("en-US".len)]u8 = undefined;
    const url = buildListenUrl(&buf, "en-US");
    try std.testing.expectEqual(listenUrlLen("en-US".len), url.len);
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&language=en-US&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true",
        url,
    );
}

// Shaped like a real nova-3 response: metadata envelope, per-word details,
// confidence — none of which the parser consumes.
const fixture_response =
    \\{
    \\  "metadata": {
    \\    "transaction_key": "deprecated",
    \\    "request_id": "63aa2ff4-1c9e-4d2e-b5f0-1a2b3c4d5e6f",
    \\    "sha256": "abc123",
    \\    "created": "2026-08-25T17:30:05.123Z",
    \\    "duration": 5.03,
    \\    "channels": 1,
    \\    "models": { "language": "pt-BR" }
    \\  },
    \\  "results": {
    \\    "utterances": [
    \\      {
    \\        "start": 0.0,
    \\        "end": 2.1,
    \\        "confidence": 0.9876543,
    \\        "transcript": "Bom dia.",
    \\        "words": [
    \\          { "word": "Bom", "start": 0.0, "end": 0.4, "confidence": 0.99, "speaker": 0 },
    \\          { "word": "dia.", "start": 0.5, "end": 2.1, "confidence": 0.98, "speaker": 0 }
    \\        ],
    \\        "speaker": 0
    \\      },
    \\      {
    \\        "start": 2.48,
    \\        "end": 5.03,
    \\        "confidence": 0.96,
    \\        "transcript": "Tudo bem?",
    \\        "words": [],
    \\        "speaker": 1
    \\      }
    \\    ]
    \\  }
    \\}
;

test "parse extracts ordered utterances from a deepgram-shaped response" {
    const utts = try parseResponse(std.testing.allocator, fixture_response);
    defer freeUtterances(std.testing.allocator, utts);

    try std.testing.expectEqual(@as(usize, 2), utts.len);
    try std.testing.expectEqual(@as(f64, 0.0), utts[0].start_sec);
    try std.testing.expectEqual(@as(f64, 2.1), utts[0].end_sec);
    try std.testing.expectEqual(@as(u32, 0), utts[0].speaker);
    try std.testing.expectEqualStrings("Bom dia.", utts[0].text);
    try std.testing.expectEqual(@as(f64, 2.48), utts[1].start_sec);
    try std.testing.expectEqual(@as(f64, 5.03), utts[1].end_sec);
    try std.testing.expectEqual(@as(u32, 1), utts[1].speaker);
    try std.testing.expectEqualStrings("Tudo bem?", utts[1].text);
}

test "parse rejects malformed json distinctly from silence" {
    try std.testing.expectError(error.BadResponse, parseResponse(std.testing.allocator, "{not json"));
    try std.testing.expectError(error.BadResponse, parseResponse(std.testing.allocator, ""));
}

test "missing, absent, and empty utterance lists all mean no speech" {
    try std.testing.expectError(error.NoSpeech, parseResponse(std.testing.allocator, "{}"));
    try std.testing.expectError(error.NoSpeech, parseResponse(std.testing.allocator, "{\"results\":{}}"));
    try std.testing.expectError(error.NoSpeech, parseResponse(std.testing.allocator, "{\"results\":{\"utterances\":[]}}"));
}
