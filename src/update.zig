//! Self-update from GitHub Releases: the running binary compares its
//! embedded version (`build.zig.zon`, bumped by release-please) against the
//! latest published release, downloads the asset built for this platform —
//! the same artifact contract the installers follow — and replaces itself.
//! `rec update` does this verbosely; a silent, once-a-day check runs before
//! other commands and stays mute whenever anything goes wrong.

const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

const llm = @import("llm.zig");

/// System curl, same contract as src/transcribe.zig.
const curl_path = if (builtin.os.tag == .windows) "curl" else "/usr/bin/curl";

const release_api = "https://api.github.com/repos/feliperun/rec/releases/latest";

/// Minimum seconds between silent startup checks; `rec update` ignores it.
/// The attempt timestamp is written even when the check fails, so an
/// offline machine never pays a network stall on every command.
pub const check_interval_s: i64 = 24 * 60 * 60;

const download_timeout_s = 300;

/// The newest published release, as far as this run can see.
pub const Release = struct {
    /// "1.8.0" — the tag minus a leading 'v'.
    version: []u8,
    /// browser_download_url of this platform's asset.
    url: []u8,
    /// browser_download_url of the `<artifact>.sha256` sibling asset the
    /// release workflow publishes. Required: a release without it is not
    /// offered as an update, so an unverifiable binary is never installed.
    checksum_url: []u8,

    pub fn deinit(release: *Release, gpa: std.mem.Allocator) void {
        gpa.free(release.version);
        gpa.free(release.url);
        gpa.free(release.checksum_url);
        release.* = undefined;
    }
};

/// `rec update`: check, download, replace. Prints what happened; the process
/// keeps running the old image — the new one wins on the next invocation.
pub fn run(io: std.Io, gpa: std.mem.Allocator) u8 {
    print(io, "Procurando atualização...\n");
    var version_buf: [32]u8 = undefined;
    switch (checkAndApply(io, gpa, &version_buf, true)) {
        .updated => |version| {
            print(io, "Atualizado para ");
            print(io, version);
            print(io, " — vale na próxima execução.\n");
            return 0;
        },
        .up_to_date => {
            print(io, "Você já está na versão mais recente (");
            print(io, build_info.version);
            print(io, ").\n");
            return 0;
        },
        .no_release => {
            print(io, "Nenhum lançamento disponível para esta plataforma.\n");
            return 1;
        },
        .check_failed => {
            print(io, "Não consegui verificar atualizações (sem rede?).\n");
            return 1;
        },
        .apply_failed => {
            print(io, "Baixei a nova versão mas não consegui instalá-la.\n");
            print(io, "Reinstale com o script de instalação do README.\n");
            return 1;
        },
    }
}

/// The silent startup check: at most once per check_interval_s, never while
/// recording or inside `rec update` itself, mute on any failure and on any
/// notice other than a successful self-replacement.
pub fn autoCheck(io: std.Io, gpa: std.mem.Allocator, config_dir: []const u8) void {
    var state_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const state_path = statePath(&state_buf, config_dir) orelse return;
    if (recentlyChecked(io, gpa, state_path)) return;
    writeCheckedAt(io, gpa, state_path);

    var version_buf: [32]u8 = undefined;
    switch (checkAndApply(io, gpa, &version_buf, false)) {
        .updated => |version| {
            print(io, "rec: atualizado para ");
            print(io, version);
            print(io, " — vale na próxima execução.\n");
        },
        else => {},
    }
}

const Outcome = union(enum) {
    /// The binary on disk was replaced; payload is the new version string,
    /// copied into the caller's buffer (the release's own memory is freed
    /// before the caller prints).
    updated: []const u8,
    up_to_date,
    /// Latest release exists but carries no asset for this platform.
    no_release,
    /// GitHub could not be reached or answered unusable JSON.
    check_failed,
    /// Downloaded fine but the on-disk replacement failed.
    apply_failed,
};

fn checkAndApply(io: std.Io, gpa: std.mem.Allocator, version_out: []u8, verbose: bool) Outcome {
    var asset_buf: [64]u8 = undefined;
    const asset = assetName(&asset_buf) orelse return .no_release;

    const release = latestRelease(io, gpa, asset) orelse return .check_failed;
    var r = release;
    defer r.deinit(gpa);

    switch (compareVersions(build_info.version, r.version) orelse .eq) {
        // Never downgrade: a local build newer than the latest release
        // (e.g. cut from main) counts as up to date.
        .eq, .gt => return .up_to_date,
        .lt => {},
    }

    if (!apply(io, gpa, r.url, r.checksum_url, asset, verbose)) return .apply_failed;
    const version = version_out[0..@min(version_out.len, r.version.len)];
    @memcpy(version, r.version[0..version.len]);
    return .{ .updated = version };
}

// --- pure helpers (tested) ---------------------------------------------------

/// Orders the running version against a release tag ("v1.8.0"); null when
/// either side is not a plain three-part semver — an unparseable tag must
/// never trigger (or block) an update.
pub fn compareVersions(local: []const u8, tag: []const u8) ?std.math.Order {
    const remote = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
    const l = std.SemanticVersion.parse(local) catch return null;
    const r = std.SemanticVersion.parse(remote) catch return null;
    return l.order(r);
}

/// The release asset that runs on this platform — the exact names the
/// installers and release workflow publish.
pub fn assetName(buf: []u8) ?[]const u8 {
    const platform: []const u8 = switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-intel",
            else => return null,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x64",
            else => return null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x64",
            else => return null,
        },
        else => return null,
    };
    const suffix: []const u8 = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.bufPrint(buf, "rec-{s}{s}", .{ platform, suffix }) catch null;
}

/// The only download prefix the updater trusts: the release assets this
/// project itself publishes. The release JSON is unauthenticated input, so a
/// rogue response must not be able to redirect the updater to another host or
/// scheme.
const trusted_download_prefix = "https://github.com/feliperun/rec/releases/download/";

pub fn isTrustedDownloadUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, trusted_download_prefix);
}

/// Parses the `sha256sum` text the release workflow publishes as
/// `<artifact>.sha256`: exactly `<64 lowercase hex><two spaces><artifact>`,
/// with an optional trailing newline. Returns false on any other shape.
pub fn parseChecksumText(text: []const u8, artifact: []const u8, out: *[32]u8) bool {
    const line = std.mem.trimEnd(u8, text, "\n");
    if (line.len != 64 + 2 + artifact.len) return false;
    const hex = line[0..64];
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and !std.ascii.isLower(c)) return false;
    }
    if (!std.mem.eql(u8, line[64..66], "  ")) return false;
    if (!std.mem.eql(u8, line[66..], artifact)) return false;
    _ = std.fmt.hexToBytes(out, hex) catch return false;
    return true;
}

/// True when `text` is a valid checksum asset for `artifact` whose digest
/// matches the SHA-256 of `data`. Any parse failure counts as a mismatch.
pub fn checksumMatches(text: []const u8, artifact: []const u8, data: []const u8) bool {
    var expected: [32]u8 = undefined;
    if (!parseChecksumText(text, artifact, &expected)) return false;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &actual, .{});
    return std.mem.eql(u8, &expected, &actual);
}

/// Exclusive creation flags for the update temp file: the file must not
/// already exist, so a planted symlink (or a stale leftover) at the
/// predictable path makes the update fail loudly instead of being followed
/// or clobbered.
pub fn tempCreateOptions() std.Io.Dir.CreateFileOptions {
    return .{ .exclusive = true, .truncate = false };
}

/// Extracts the tag, this platform's download URL, and the matching
/// `<asset>.sha256` URL from a GitHub latest-release body. Null when the
/// shape is not what we publish, when the checksum sibling is absent, or when
/// either URL points anywhere but the project's own release assets.
pub fn extractRelease(gpa: std.mem.Allocator, body: []const u8, asset: []const u8) ?Release {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const tag = switch (parsed.value.object.get("tag_name") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (tag.len == 0) return null;

    const assets = switch (parsed.value.object.get("assets") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var checksum_name_buf: [128]u8 = undefined;
    const checksum_name = std.fmt.bufPrint(&checksum_name_buf, "{s}.sha256", .{asset}) catch return null;

    var artifact_url: ?[]const u8 = null;
    var checksum_url: ?[]const u8 = null;
    for (assets.items) |item| {
        if (item != .object) continue;
        const name = switch (item.object.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const slot = if (std.mem.eql(u8, name, asset))
            &artifact_url
        else if (std.mem.eql(u8, name, checksum_name))
            &checksum_url
        else
            continue;
        const link = switch (item.object.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!isTrustedDownloadUrl(link)) return null;
        slot.* = link;
    }

    const url = artifact_url orelse return null;
    const sum_url = checksum_url orelse return null;

    const version = gpa.dupe(u8, if (tag[0] == 'v') tag[1..] else tag) catch return null;
    const url_copy = gpa.dupe(u8, url) catch {
        gpa.free(version);
        return null;
    };
    const checksum_copy = gpa.dupe(u8, sum_url) catch {
        gpa.free(version);
        gpa.free(url_copy);
        return null;
    };
    return .{ .version = version, .url = url_copy, .checksum_url = checksum_copy };
}

// --- network -----------------------------------------------------------------

/// The latest release carrying an asset named `asset`; null on any network,
/// spawn, or shape failure.
fn latestRelease(io: std.Io, gpa: std.mem.Allocator, asset: []const u8) ?Release {
    const body = fetch(io, gpa, release_api, 15) orelse return null;
    defer gpa.free(body);
    return extractRelease(gpa, body, asset);
}

/// Runs curl and hands back stdout, owned by the caller; null on spawn or
/// non-zero exit (curl's -f turns HTTP failures into exit codes).
fn fetch(io: std.Io, gpa: std.mem.Allocator, url: []const u8, timeout_s: u32) ?[]u8 {
    var timeout_buf: [16]u8 = undefined;
    const timeout = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_s}) catch return null;
    const argv = [_][]const u8{ curl_path, "-fsSL", "--max-time", timeout, url };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch return null;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return null;
        },
        else => {
            gpa.free(result.stdout);
            return null;
        },
    }
    return result.stdout;
}

/// Downloads `url` beside the running executable, verifies the bytes against
/// the release's `<artifact>.sha256` sibling, and only then atomically
/// replaces the running image: a plain rename on POSIX, where the running
/// image keeps its inode; on Windows the running exe steps aside as `.old`
/// first (renaming a running image is allowed; deleting it is not) and a
/// stale `.old` from a previous update is removed before the dance. Any
/// verification failure deletes the temp file and leaves the executable
/// untouched.
fn apply(io: std.Io, gpa: std.mem.Allocator, url: []const u8, checksum_url: []const u8, artifact: []const u8, verbose: bool) bool {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch return false;
    const exe = exe_buf[0..exe_len];

    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.update.tmp", .{exe}) catch return false;

    var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe}) catch return false;

    if (builtin.os.tag == .windows) std.Io.Dir.cwd().deleteFile(io, old) catch {};

    // Create the temp file exclusively before curl touches it: a pre-existing
    // file or symlink (however it got there) fails the update loudly instead
    // of being followed or clobbered.
    var tmp_file = std.Io.Dir.cwd().createFile(io, tmp, tempCreateOptions()) catch {
        if (verbose) print(io, "Já existe um arquivo temporário de atualização; remova-o e tente de novo.\n");
        return false;
    };
    tmp_file.close(io);

    if (!downloadTo(io, gpa, url, tmp, verbose)) return fail(io, tmp);
    if (!verifyDownload(io, gpa, checksum_url, artifact, tmp, verbose)) return fail(io, tmp);

    if (builtin.os.tag != .windows) {
        // curl writes 0644 through the umask; the replacement must stay
        // executable. Windows has no exec bit.
        var file = std.Io.Dir.cwd().openFile(io, tmp, .{}) catch return fail(io, tmp);
        defer file.close(io);
        file.setPermissions(io, @enumFromInt(0o755)) catch {};
        std.Io.Dir.renameAbsolute(tmp, exe, io) catch return fail(io, tmp);
        return true;
    }

    // std's rename asks the kernel for POSIX rename semantics, which is
    // denied for a file with an active image section — the running
    // executable itself. MoveFileExW is the battle-tested way to run the
    // dance: the running exe steps aside, the download takes its place,
    // and a failed second step rolls the old image back.
    if (!moveFileEx(gpa, exe, old, false)) return fail(io, tmp);
    if (!moveFileEx(gpa, tmp, exe, true)) {
        _ = moveFileEx(gpa, old, exe, false);
        return fail(io, tmp);
    }
    std.Io.Dir.cwd().deleteFile(io, old) catch {};
    return true;
}

/// Fetches the release's `<artifact>.sha256` asset and compares its digest
/// with the SHA-256 of the freshly downloaded temp file. Missing asset,
/// fetch failure, unparseable digest, and mismatch are all hard failures.
fn verifyDownload(io: std.Io, gpa: std.mem.Allocator, checksum_url: []const u8, artifact: []const u8, tmp: []const u8, verbose: bool) bool {
    const text = fetch(io, gpa, checksum_url, 15) orelse {
        if (verbose) print(io, "Não consegui baixar a soma de verificação da versão.\n");
        return false;
    };
    defer gpa.free(text);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, tmp, gpa, .unlimited) catch {
        if (verbose) print(io, "Não consegui ler o arquivo baixado para verificar.\n");
        return false;
    };
    defer gpa.free(bytes);

    if (!checksumMatches(text, artifact, bytes)) {
        if (verbose) print(io, "A soma de verificação não confere; atualização abortada.\n");
        return false;
    }
    return true;
}

const movefile_replace_existing: std.os.windows.DWORD = 0x1;

pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: std.os.windows.LPCWSTR,
    lpNewFileName: std.os.windows.LPCWSTR,
    dwFlags: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn moveFileEx(gpa: std.mem.Allocator, from: []const u8, to: []const u8, replace: bool) bool {
    const from_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, from) catch return false;
    defer gpa.free(from_w);
    const to_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, to) catch return false;
    defer gpa.free(to_w);
    const flags: std.os.windows.DWORD = if (replace) movefile_replace_existing else 0;
    return MoveFileExW(from_w.ptr, to_w.ptr, flags) != .FALSE;
}

fn fail(io: std.Io, tmp: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    return false;
}

fn downloadTo(io: std.Io, gpa: std.mem.Allocator, url: []const u8, dest: []const u8, verbose: bool) bool {
    var dest_arg_buf: [std.Io.Dir.max_path_bytes + 4]u8 = undefined;
    const dest_arg = std.fmt.bufPrint(&dest_arg_buf, "-o{s}", .{dest}) catch return false;
    var timeout_buf: [16]u8 = undefined;
    const timeout = std.fmt.bufPrint(&timeout_buf, "{d}", .{download_timeout_s}) catch return false;
    const argv = [_][]const u8{ curl_path, "-fsSL", "--max-time", timeout, dest_arg, url };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch {
        if (verbose) print(io, "curl não pôde ser executado.\n");
        return false;
    };
    const code: ?u32 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    const ok = code != null and code.? == 0;
    if (!ok and verbose) {
        print(io, "curl ");
        if (code) |c| {
            var code_buf: [16]u8 = undefined;
            print(io, std.fmt.bufPrint(&code_buf, "saiu com código {d}", .{c}) catch "falhou");
        } else print(io, "terminou de forma anormal");
        print(io, ": ");
        // curl -s keeps stderr quiet except for the actual diagnostic.
        print(io, std.mem.trim(u8, result.stderr, " \t\r\n"));
        print(io, "\n");
    }
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return ok;
}

// --- check state -------------------------------------------------------------

fn statePath(buf: []u8, config_dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/update_state", .{config_dir}) catch null;
}

/// True when the last check is younger than check_interval_s; anything
/// unreadable counts as "never checked".
fn recentlyChecked(io: std.Io, gpa: std.mem.Allocator, state_path: []const u8) bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, state_path, gpa, .limited(64)) catch return false;
    defer gpa.free(raw);
    const last = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return false;
    const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    return now_s - last < check_interval_s;
}

fn writeCheckedAt(io: std.Io, gpa: std.mem.Allocator, state_path: []const u8) void {
    const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    var line_buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d}\n", .{now_s}) catch return;
    var file = std.Io.Dir.cwd().createFile(io, state_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, line) catch {};
    _ = gpa;
}

fn print(io: std.Io, msg: []const u8) void {
    std.Io.File.writeStreamingAll(.stderr(), io, msg) catch {};
}

// --- tests -------------------------------------------------------------------

test "compareVersions orders local against a release tag" {
    const Order = std.math.Order;
    try std.testing.expectEqual(Order.lt, compareVersions("1.7.0", "v1.8.0").?);
    try std.testing.expectEqual(Order.eq, compareVersions("1.8.0", "v1.8.0").?);
    try std.testing.expectEqual(Order.gt, compareVersions("1.9.0", "v1.8.0").?);
    try std.testing.expectEqual(Order.lt, compareVersions("1.8.0", "v1.8.1").?);
    // A prerelease tag still parses and orders by the semver rules —
    // GitHub's /releases/latest never returns one, so this is a safety net.
    try std.testing.expectEqual(Order.lt, compareVersions("1.8.0", "v1.9.0-rc.1").?);
    // Garbage on either side never compares — no update either way.
    try std.testing.expect(compareVersions("dev", "v1.9.0") == null);
    try std.testing.expect(compareVersions("1.8.0", "not-a-tag") == null);
}

test "assetName matches the published artifact for the running platform" {
    var buf: [64]u8 = undefined;
    const name = assetName(&buf).?;
    const expected = switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "rec-macos-arm64" else "rec-macos-intel",
        .linux => if (builtin.cpu.arch == .aarch64) "rec-linux-arm64" else "rec-linux-x64",
        .windows => "rec-windows-x64.exe",
        else => unreachable,
    };
    try std.testing.expectEqualStrings(expected, name);
}

// Shaped like the real release body: the artifact plus its `.sha256` sibling
// for every supported platform, so the matched lookups work on every test
// runner.
const fixture_body =
    \\{
    \\  "url": "https://api.github.com/repos/feliperun/rec/releases/1",
    \\  "tag_name": "v1.8.0",
    \\  "name": "1.8.0",
    \\  "assets": [
    \\    {
    \\      "name": "rec-macos-arm64",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-macos-arm64"
    \\    },
    \\    {
    \\      "name": "rec-macos-arm64.sha256",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-macos-arm64.sha256"
    \\    },
    \\    {
    \\      "name": "rec-macos-intel",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-macos-intel"
    \\    },
    \\    {
    \\      "name": "rec-macos-intel.sha256",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-macos-intel.sha256"
    \\    },
    \\    {
    \\      "name": "rec-linux-x64",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-x64"
    \\    },
    \\    {
    \\      "name": "rec-linux-x64.sha256",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-x64.sha256"
    \\    },
    \\    {
    \\      "name": "rec-linux-arm64",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-arm64"
    \\    },
    \\    {
    \\      "name": "rec-linux-arm64.sha256",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-arm64.sha256"
    \\    },
    \\    {
    \\      "name": "rec-windows-x64.exe",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-windows-x64.exe"
    \\    },
    \\    {
    \\      "name": "rec-windows-x64.exe.sha256",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-windows-x64.exe.sha256"
    \\    }
    \\  ]
    \\}
;

test "extractRelease picks the platform asset and strips the tag's v" {
    var buf: [64]u8 = undefined;
    const asset = assetName(&buf).?;
    const gpa = std.testing.allocator;

    var release = extractRelease(gpa, fixture_body, asset) orelse return error.TestUnexpectedResult;
    defer release.deinit(gpa);
    try std.testing.expectEqualStrings("1.8.0", release.version);
    try std.testing.expect(std.mem.endsWith(u8, release.url, asset));
    try std.testing.expect(std.mem.endsWith(u8, release.checksum_url, ".sha256"));
}

test "extractRelease answers null for unusable bodies" {
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const asset = assetName(&buf).?;

    try std.testing.expect(extractRelease(gpa, "not json", asset) == null);
    try std.testing.expect(extractRelease(gpa, "{}", asset) == null);
    // A release without our asset (or without assets at all) is no release.
    try std.testing.expect(extractRelease(gpa, "{\"tag_name\":\"v1.8.0\",\"assets\":[]}", asset) == null);
    const wrong_platform =
        \\{"tag_name":"v1.8.0","assets":[{"name":"rec-other","browser_download_url":"https://x/y"}]}
    ;
    try std.testing.expect(extractRelease(gpa, wrong_platform, asset) == null);
    // An artifact without its checksum sibling is unverifiable: no update.
    const no_checksum =
        \\{"tag_name":"v1.8.0","assets":[{"name":"rec-linux-x64","browser_download_url":"https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-x64"}]}
    ;
    try std.testing.expect(extractRelease(gpa, no_checksum, asset) == null);
}

test "update checksum text parses and rejects a mismatch" {
    const data = "release artifact bytes";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{s}  rec-linux-x64\n", .{&hex}) catch return error.TestUnexpectedResult;

    var parsed: [32]u8 = undefined;
    try std.testing.expect(parseChecksumText(text, "rec-linux-x64", &parsed));
    try std.testing.expectEqualSlices(u8, &digest, &parsed);
    try std.testing.expect(checksumMatches(text, "rec-linux-x64", data));

    // A different payload, a different artifact name, malformed text, and
    // uppercase hex all fail closed instead of installing.
    try std.testing.expect(!checksumMatches(text, "rec-linux-x64", "tampered bytes"));
    try std.testing.expect(!checksumMatches(text, "rec-linux-arm64", data));
    try std.testing.expect(!checksumMatches("not a checksum", "rec-linux-x64", data));
    try std.testing.expect(!checksumMatches("", "rec-linux-x64", data));

    const upper_hex = std.fmt.bytesToHex(digest, .upper);
    var upper_buf: [128]u8 = undefined;
    const upper = std.fmt.bufPrint(&upper_buf, "{s}  rec-linux-x64\n", .{&upper_hex}) catch return error.TestUnexpectedResult;
    try std.testing.expect(!checksumMatches(upper, "rec-linux-x64", data));
}

test "update rejects an untrusted download url" {
    try std.testing.expect(isTrustedDownloadUrl("https://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-x64"));
    try std.testing.expect(!isTrustedDownloadUrl("http://github.com/feliperun/rec/releases/download/v1.8.0/rec-linux-x64"));
    try std.testing.expect(!isTrustedDownloadUrl("https://evil.example/rec-linux-x64"));
    try std.testing.expect(!isTrustedDownloadUrl("https://github.com/feliperun/rec/releases/download-evil/rec-linux-x64"));

    var name_buf: [64]u8 = undefined;
    const asset = assetName(&name_buf).?;
    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"tag_name":"v1.8.0","assets":[
        \\  {{"name":"{s}","browser_download_url":"https://evil.example/{s}"}},
        \\  {{"name":"{s}.sha256","browser_download_url":"https://github.com/feliperun/rec/releases/download/v1.8.0/{s}.sha256"}}
        \\]}}
    , .{ asset, asset, asset, asset }) catch return error.TestUnexpectedResult;
    try std.testing.expect(extractRelease(std.testing.allocator, body, asset) == null);
}

test "update temp path must be created exclusively" {
    const options = tempCreateOptions();
    try std.testing.expect(options.exclusive);
}
