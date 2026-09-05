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

    pub fn deinit(release: *Release, gpa: std.mem.Allocator) void {
        gpa.free(release.version);
        gpa.free(release.url);
        release.* = undefined;
    }
};

/// `rec update`: check, download, replace. Prints what happened; the process
/// keeps running the old image — the new one wins on the next invocation.
pub fn run(io: std.Io, gpa: std.mem.Allocator) u8 {
    print(io, "Procurando atualização...\n");
    var version_buf: [32]u8 = undefined;
    switch (checkAndApply(io, gpa, &version_buf)) {
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
    switch (checkAndApply(io, gpa, &version_buf)) {
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

fn checkAndApply(io: std.Io, gpa: std.mem.Allocator, version_out: []u8) Outcome {
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

    if (!apply(io, gpa, r.url)) return .apply_failed;
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

/// Extracts the tag and this platform's download URL from a GitHub
/// latest-release body. Null when the shape is not what we publish.
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
    for (assets.items) |item| {
        if (item != .object) continue;
        const name = switch (item.object.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, asset)) continue;
        const url = switch (item.object.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const version = gpa.dupe(u8, if (tag[0] == 'v') tag[1..] else tag) catch return null;
        const url_copy = gpa.dupe(u8, url) catch {
            gpa.free(version);
            return null;
        };
        return .{ .version = version, .url = url_copy };
    }
    return null;
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

/// Downloads `url` beside the running executable and atomically replaces it:
/// a plain rename on POSIX, where the running image keeps its inode; on
/// Windows the running exe steps aside as `.old` first (renaming a running
/// image is allowed; deleting it is not) and a stale `.old` from a previous
/// update is removed before the dance.
fn apply(io: std.Io, gpa: std.mem.Allocator, url: []const u8) bool {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch return false;
    const exe = exe_buf[0..exe_len];

    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.update.tmp", .{exe}) catch return false;

    var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buf, "{s}.old", .{exe}) catch return false;

    // Leftovers of an interrupted previous update must not block this one.
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    if (builtin.os.tag == .windows) std.Io.Dir.cwd().deleteFile(io, old) catch {};

    if (!downloadTo(io, gpa, url, tmp)) return false;

    if (builtin.os.tag != .windows) {
        // curl writes 0644 through the umask; the replacement must stay
        // executable. Windows has no exec bit.
        var file = std.Io.Dir.cwd().openFile(io, tmp, .{}) catch return fail(io, tmp);
        defer file.close(io);
        file.setPermissions(io, @enumFromInt(0o755)) catch {};
        std.Io.Dir.renameAbsolute(tmp, exe, io) catch return fail(io, tmp);
        return true;
    }

    std.Io.Dir.renameAbsolute(exe, old, io) catch return fail(io, tmp);
    std.Io.Dir.renameAbsolute(tmp, exe, io) catch {
        // Put the old image back so `rec` keeps working.
        std.Io.Dir.renameAbsolute(old, exe, io) catch {};
        return fail(io, tmp);
    };
    std.Io.Dir.cwd().deleteFile(io, old) catch {};
    return true;
}

fn fail(io: std.Io, tmp: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    return false;
}

fn downloadTo(io: std.Io, gpa: std.mem.Allocator, url: []const u8, dest: []const u8) bool {
    var dest_arg_buf: [std.Io.Dir.max_path_bytes + 4]u8 = undefined;
    const dest_arg = std.fmt.bufPrint(&dest_arg_buf, "-o{s}", .{dest}) catch return false;
    var timeout_buf: [16]u8 = undefined;
    const timeout = std.fmt.bufPrint(&timeout_buf, "{d}", .{download_timeout_s}) catch return false;
    const argv = [_][]const u8{ curl_path, "-fsSL", "--max-time", timeout, dest_arg, url };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch return false;
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
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
    \\      "name": "rec-windows-x64.exe",
    \\      "browser_download_url": "https://github.com/feliperun/rec/releases/download/v1.8.0/rec-windows-x64.exe"
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
}
