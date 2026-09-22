const std = @import("std");
const wav = @import("wav.zig");

/// System curl: the pinned absolute path on POSIX, the PATH one on Windows
/// (System32 ships curl.exe and spawn resolves bare names from PATH).
const curl_path = if (@import("builtin").os.tag == .windows) "curl" else "/usr/bin/curl";

const listen_base = @import("build_info").listen_base;
const listen_query_before_language = "model=nova-3&";
const listen_query_after_language = "&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true";

/// Wall-clock bound for the whole curl request, in seconds. `update.zig`
/// bounds its downloads the same way; a stalled peer must not wedge transcribe.
pub const request_max_time_secs: u32 = 300;

/// Response-body cap, mirroring `llm.zig`'s `max_output_bytes`: an endpoint
/// that returns more than this fails the request instead of exhausting memory.
pub const max_response_bytes: usize = 8 * 1024 * 1024;

fn isUrlUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// Length of `language` once percent-encoded as the query value.
fn encodedLanguageLen(language: []const u8) usize {
    var n: usize = 0;
    for (language) |ch| n += if (isUrlUnreserved(ch)) @as(usize, 1) else 3;
    return n;
}

fn appendEncodedLanguage(buf: []u8, n: *usize, language: []const u8) void {
    const hex = "0123456789ABCDEF";
    for (language) |ch| {
        if (isUrlUnreserved(ch)) {
            buf[n.*] = ch;
            n.* += 1;
        } else {
            buf[n.*] = '%';
            buf[n.* + 1] = hex[ch >> 4];
            buf[n.* + 2] = hex[ch & 0x0f];
            n.* += 3;
        }
    }
}

/// Bytes `buildListenUrl` needs for an explicit language code or "auto".
pub fn listenUrlLen(language: []const u8) usize {
    const lang_len = if (std.mem.eql(u8, language, "auto")) "detect_language=true".len else "language=".len + encodedLanguageLen(language);
    return listen_base.len + listen_query_before_language.len + lang_len + listen_query_after_language.len;
}

/// Writes the Deepgram listen URL for `language` into `buf` (size it with
/// listenUrlLen) and returns the filled slice. Parameter order is part of the
/// request contract, not cosmetic. The language is percent-encoded instead of
/// regex-validated so a reserved byte cannot inject another query parameter
/// without rejecting Deepgram's growing list of language codes.
pub fn buildListenUrl(buf: []u8, language: []const u8) []const u8 {
    std.debug.assert(buf.len >= listenUrlLen(language));
    var n: usize = 0;
    appendStr(buf, &n, listen_base);
    appendStr(buf, &n, listen_query_before_language);
    if (std.mem.eql(u8, language, "auto")) {
        appendStr(buf, &n, "detect_language=true");
    } else {
        appendStr(buf, &n, "language=");
        appendEncodedLanguage(buf, &n, language);
    }
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
    channels: ?[]const struct { detected_language: ?[]const u8 = null } = null,
};

const ApiResponse = struct {
    results: ?ApiResults = null,
};

/// Owned language code for the transcript metadata, never the selector "auto".
pub fn responseLanguage(gpa: std.mem.Allocator, json_bytes: []const u8, requested: []const u8) ParseError![]u8 {
    if (!std.mem.eql(u8, requested, "auto")) return gpa.dupe(u8, requested);
    const parsed = std.json.parseFromSlice(ApiResponse, gpa, json_bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    defer parsed.deinit();
    const results = parsed.value.results orelse return error.BadResponse;
    const channels = results.channels orelse return error.BadResponse;
    if (channels.len != 1) return error.BadResponse;
    const language = channels[0].detected_language orelse return error.BadResponse;
    if (language.len == 0) return error.BadResponse;
    return gpa.dupe(u8, language);
}

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

/// Deepgram content type for a recording: M4A files are MPEG-4 audio,
/// legacy WAV files are sent as PCM RIFF.
pub fn contentTypeFor(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".m4a")) return "audio/mp4";
    return "audio/wav";
}

/// Builds curl's argv for one Deepgram request. `auth_arg` is the literal
/// `@<path>` pointing at the 0600 header file, so the API key never becomes an
/// argv element (FINDING-SYNTH-03); `--max-time` bounds the request
/// (FINDING-SYNTH-07). Slices borrowed from the caller must outlive the run.
fn buildRequestArgv(
    auth_arg: []const u8,
    content_type_header: []const u8,
    data_arg: []const u8,
    url: []const u8,
) [13][]const u8 {
    return .{
        curl_path,
        "-fsS",
        "-X",
        "POST",
        "--max-time",
        std.fmt.comptimePrint("{d}", .{request_max_time_secs}),
        "-H",
        auth_arg,
        "-H",
        content_type_header,
        "--data-binary",
        data_arg,
        url,
    };
}

/// Caps and bounds the run the way `llm.zig` bounds harness output: an
/// oversized body fails instead of being buffered, and the wall clock kills a
/// stalled peer even if curl's own `--max-time` is bypassed.
fn requestRunOptions(argv: []const []const u8) std.process.RunOptions {
    return .{
        .argv = argv,
        .stdout_limit = .limited(max_response_bytes),
        .stderr_limit = .limited(max_response_bytes),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(request_max_time_secs),
            .clock = .real,
        } },
    };
}

/// Writes `Authorization: Token <key>` to a fresh 0600 file beside the
/// recording and returns its path in `path_buf`. The caller deletes it; the
/// key stays here and in the child's `-H @file` argument, never on argv. The
/// exclusive create refuses a pre-planted symlink and the mode matches
/// storeKey's exact 0600.
fn writeAuthHeader(io: std.Io, wav_abs_path: []const u8, key: []const u8, path_buf: []u8) ?[]const u8 {
    const dir = std.fs.path.dirname(wav_abs_path) orelse ".";
    var rand_bytes: [12]u8 = undefined;
    io.random(&rand_bytes);
    var rand_b64: [std.base64.url_safe.Encoder.calcSize(rand_bytes.len)]u8 = undefined;
    const suffix = std.base64.url_safe.Encoder.encode(&rand_b64, &rand_bytes);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, ".rec-auth-{s}.tmp", .{suffix}) catch return null;
    const path = std.fmt.bufPrint(path_buf, "{f}", .{std.fs.path.fmtJoin(&.{ dir, name })}) catch return null;

    const secret_mode: std.Io.File.Permissions = @enumFromInt(0o600);
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = secret_mode }) catch return null;
    var write_ok = true;
    file.writeStreamingAll(io, "Authorization: Token ") catch {
        write_ok = false;
    };
    if (write_ok) file.writeStreamingAll(io, key) catch {
        write_ok = false;
    };
    if (write_ok) file.writeStreamingAll(io, "\n") catch {
        write_ok = false;
    };
    file.close(io);
    if (!write_ok) {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return null;
    }
    return path;
}

/// POSTs the recording at `wav_abs_path` to Deepgram and appends the response
/// body to `out.json`. On error.RequestFailed the tail of curl's stderr is
/// copied into `out.err_tail` for the caller's one-line message. The key
/// travels only inside the 0600 header file curl reads via `-H @file`;
/// resolving it is the caller's job.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, wav_abs_path: []const u8, api_key: []const u8, language: []const u8, out: *TranscribeOutput) TranscribeError!void {
    out.err_tail_len = 0;

    const url_buf = gpa.alloc(u8, listenUrlLen(language)) catch return error.OutOfMemory;
    defer gpa.free(url_buf);
    const url = buildListenUrl(url_buf, language);

    // Keep the key off argv (and /proc/<pid>/cmdline) by handing curl a 0600
    // header file, deleted on every return path below.
    var header_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const header_path = writeAuthHeader(io, wav_abs_path, api_key, &header_path_buf) orelse return error.CurlSpawnFailed;
    defer std.Io.Dir.cwd().deleteFile(io, header_path) catch {};

    const auth_arg = std.fmt.allocPrint(gpa, "@{s}", .{header_path}) catch return error.OutOfMemory;
    defer gpa.free(auth_arg);

    const data_arg = std.fmt.allocPrint(gpa, "@{s}", .{wav_abs_path}) catch return error.OutOfMemory;
    defer gpa.free(data_arg);

    var content_type_buf: [32]u8 = undefined;
    const content_type_header = std.fmt.bufPrint(&content_type_buf, "Content-Type: {s}", .{contentTypeFor(wav_abs_path)}) catch unreachable;

    const argv = buildRequestArgv(auth_arg, content_type_header, data_arg, url);

    // run() is playback's spawn idiom plus concurrent pipe draining, so a
    // large response body cannot deadlock on a full pipe while we read.
    const result = std.process.run(gpa, io, requestRunOptions(&argv)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // An oversized body or an expired wall clock is a failed request;
        // every other error means curl itself could not be launched.
        error.StreamTooLong, error.Timeout => return error.RequestFailed,
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

test "listen url keeps the fixed parameter order with explicit Portuguese" {
    var buf: [listenUrlLen("pt-BR")]u8 = undefined;
    const url = buildListenUrl(&buf, "pt-BR");
    try std.testing.expectEqual(listenUrlLen("pt-BR"), url.len);
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&language=pt-BR&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true",
        url,
    );
}

test "automatic language detection never sends a forced language" {
    var buf: [listenUrlLen("auto")]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&detect_language=true&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true",
        buildListenUrl(&buf, "auto"),
    );
}

test "transcript language is the detected code or explicit selection" {
    const gpa = std.testing.allocator;
    const json = "{\"results\":{\"channels\":[{\"detected_language\":\"en\"}]}}";
    const detected = try responseLanguage(gpa, json, "auto");
    defer gpa.free(detected);
    try std.testing.expectEqualStrings("en", detected);
    const explicit = try responseLanguage(gpa, "{}", "pt-BR");
    defer gpa.free(explicit);
    try std.testing.expectEqualStrings("pt-BR", explicit);
    try std.testing.expectError(error.BadResponse, responseLanguage(gpa, "{}", "auto"));
    try std.testing.expectError(error.BadResponse, responseLanguage(gpa, "{\"results\":{\"channels\":[]}}", "auto"));
    try std.testing.expectError(error.BadResponse, responseLanguage(gpa, "{\"results\":{\"channels\":[{}]}}", "auto"));
}

test "listen url keeps the fixed parameter order with explicit English" {
    var buf: [listenUrlLen("en-US")]u8 = undefined;
    const url = buildListenUrl(&buf, "en-US");
    try std.testing.expectEqual(listenUrlLen("en-US"), url.len);
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&language=en-US&smart_format=true&punctuate=true&utterances=true&diarize_model=latest&mip_opt_out=true",
        url,
    );
}

test "transcribe listen url rejects an injected language" {
    const injected = "en&callback=http://attacker.example/hook";
    var buf: [listenUrlLen(injected)]u8 = undefined;
    const url = buildListenUrl(&buf, injected);
    try std.testing.expect(std.mem.indexOf(u8, url, "&callback=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "language=en%26callback%3Dhttp%3A%2F%2Fattacker.example%2Fhook") != null);
    // The fixed suffix still trails exactly once: no injected parameter.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, url, "&smart_format=true"));
}

test "transcribe listen url bounds the language parameter" {
    const language = "a b&c=d#e/f";
    var buf: [listenUrlLen(language)]u8 = undefined;
    const url = buildListenUrl(&buf, language);
    try std.testing.expectEqual(listenUrlLen(language), url.len);
    // Every reserved byte is escaped, so the value stays a single query
    // parameter and cannot spill into the fixed parameters after it.
    const start = (std.mem.indexOf(u8, url, "language=") orelse return error.TestUnexpectedResult) + "language=".len;
    const suffix = std.mem.indexOf(u8, url[start..], "&smart_format=true") orelse return error.TestUnexpectedResult;
    const value = url[start .. start + suffix];
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, value, "&"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, value, "="));
}

test "transcribe authorization never reaches argv" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = std.mem.sliceTo(wav.testPath(&dir_buf, ".auth"), 0);
    defer std.Io.Dir.cwd().deleteDir(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    var rec_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rec_path = std.fmt.bufPrint(&rec_buf, "{s}/sample.wav", .{dir}) catch return error.TestUnexpectedResult;
    var rec = std.Io.Dir.cwd().createFile(io, rec_path, .{}) catch return error.TestUnexpectedResult;
    rec.close(io);

    const api_key = "sk-deepgram-secret-for-test";
    var header_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const header_path = writeAuthHeader(io, rec_path, api_key, &header_path_buf) orelse return error.TestUnexpectedResult;
    defer std.Io.Dir.cwd().deleteFile(io, header_path) catch {};

    const auth_arg = std.fmt.allocPrint(gpa, "@{s}", .{header_path}) catch return error.OutOfMemory;
    defer gpa.free(auth_arg);

    var url_buf: [listenUrlLen("en-US")]u8 = undefined;
    const url = buildListenUrl(&url_buf, "en-US");
    const argv = buildRequestArgv(auth_arg, "Content-Type: audio/wav", "@sample.wav", url);

    for (argv) |element| {
        try std.testing.expect(std.mem.indexOf(u8, element, api_key) == null);
        try std.testing.expect(std.mem.indexOf(u8, element, "Authorization") == null);
    }

    // The key lives in the 0600 header file that curl reads via `-H @file`.
    const header_contents = try std.Io.Dir.cwd().readFileAlloc(io, header_path, gpa, .limited(256));
    defer gpa.free(header_contents);
    try std.testing.expect(std.mem.indexOf(u8, header_contents, api_key) != null);
}

test "transcribe request argv bounds the wall clock" {
    const argv = buildRequestArgv("@h", "Content-Type: audio/wav", "@r", "https://api.deepgram.com");
    var found = false;
    for (argv, 0..) |element, i| {
        if (std.mem.eql(u8, element, "--max-time")) {
            found = true;
            try std.testing.expect(i + 1 < argv.len);
            try std.testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{request_max_time_secs}), argv[i + 1]);
        }
    }
    try std.testing.expect(found);
}

test "transcribe response body is capped" {
    const argv = buildRequestArgv("@h", "Content-Type: audio/wav", "@r", "https://api.deepgram.com");
    const options = requestRunOptions(&argv);
    try std.testing.expectEqual(@as(?usize, max_response_bytes), options.stdout_limit.toInt());
    try std.testing.expectEqual(@as(?usize, max_response_bytes), options.stderr_limit.toInt());
}

test "content type follows the recording format" {
    try std.testing.expectEqualStrings("audio/mp4", contentTypeFor("20260826-143000.m4a"));
    try std.testing.expectEqualStrings("audio/wav", contentTypeFor("20260826-143000.wav"));
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

// --- stored key -------------------------------------------------------------

// --- stored key -------------------------------------------------------------

/// The user's Deepgram key lives in its own file next to config.json:
/// `rec setup` writes it (0600 where the OS honors modes), and `rec
/// transcribe` reads it when the environment exports no DEEPGRAM_API_KEY.
pub fn keyFilePath(buf: []u8, config_dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/deepgram_key", .{config_dir}) catch null;
}

/// The stored key, whitespace-trimmed; freshly allocated, null when nothing
/// usable is stored.
pub fn loadStoredKey(io: std.Io, gpa: std.mem.Allocator, config_dir: []const u8) ?[]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = keyFilePath(&path_buf, config_dir) orelse return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(raw);
        return null;
    }
    const key = gpa.dupe(u8, trimmed) catch {
        gpa.free(raw);
        return null;
    };
    gpa.free(raw);
    return key;
}

/// Persists the key (overwriting any previous one) and creates the config
/// directory when missing. A trailing newline keeps `cat` output tidy; the
/// loader trims it back off.
pub fn storeKey(io: std.Io, gpa: std.mem.Allocator, config_dir: []const u8, key: []const u8) bool {
    _ = gpa;
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch {};

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = keyFilePath(&path_buf, config_dir) orelse return false;
    // 0600 on POSIX (the umask only subtracts, so the mode must be exact);
    // Windows has no modes and ignores this.
    const secret_mode: std.Io.File.Permissions = @enumFromInt(0o600);
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = secret_mode }) catch return false;
    defer file.close(io);
    file.writeStreamingAll(io, key) catch return false;
    file.writeStreamingAll(io, "\n") catch return false;
    return true;
}

test "stored key round-trips trimmed and absent means null" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const gpa = std.testing.allocator;

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = std.mem.sliceTo(wav.testPath(&dir_buf, ".cfg"), 0);
    defer std.Io.Dir.cwd().deleteDir(io, dir) catch {};

    // Nothing stored yet: loading answers null instead of erroring.
    try std.testing.expectEqual(@as(?[]u8, null), loadStoredKey(io, gpa, dir));

    // A key with trailing whitespace round-trips trimmed; an overwrite wins.
    try std.testing.expect(storeKey(io, gpa, dir, "sk-first\n"));
    {
        const key = (loadStoredKey(io, gpa, dir) orelse return error.TestUnexpectedResult);
        defer gpa.free(key);
        try std.testing.expectEqualStrings("sk-first", key);
    }
    try std.testing.expect(storeKey(io, gpa, dir, "sk-second"));
    {
        const key = (loadStoredKey(io, gpa, dir) orelse return error.TestUnexpectedResult);
        defer gpa.free(key);
        try std.testing.expectEqualStrings("sk-second", key);
    }
}

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
