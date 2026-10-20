const std = @import("std");

const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig locates Apple frameworks through the macOS SDK, but only probes it
    // for the native target — an x86_64-macos build on an arm64 host finds no
    // framework search paths at all. Hand every macOS target the sysroot.
    var sdk_path: ?[]const u8 = null;
    if (target.result.os.tag == .macos) {
        if (std.zig.system.darwin.getSdk(b.graph.arena, b.graph.io, &target.result)) |sdk| {
            b.sysroot = sdk;
            sdk_path = sdk;
        }
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe_mod.addCSourceFile(.{
        .file = b.path("src/miniaudio.c"),
        .flags = &.{},
    });
    exe_mod.addIncludePath(b.path("vendor"));

    // libopus decodes AIREC `.ops` recordings for `rec import` (see
    // docs/adr/0021); built from source by zig for every target.
    const opus = b.dependency("opus", .{ .target = target, .optimize = optimize });
    exe_mod.linkLibrary(staticArtifact(opus, "opus"));

    // Deterministic E2E recordings without opening a physical microphone.
    if (b.option(bool, "silent-input", "Use miniaudio's null backend for E2E tests") orelse false) {
        exe_mod.addCMacro("MA_ENABLE_ONLY_SPECIFIC_BACKENDS", "1");
        exe_mod.addCMacro("MA_ENABLE_NULL", "1");
    }

    // The single version source: build.zig.zon, embedded as `build_info`
    // so `rec about` shows it and auto-update compares it against releases.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);
    build_info.addOption([]const u8, "listen_base", b.option([]const u8, "test-listen-base", "Local transcription server URL for E2E tests") orelse "https://api.deepgram.com/v1/listen?");
    build_info.addOption(bool, "fake_airec", b.option(bool, "fake-airec", "Serve AIREC sync from a directory instead of Bluetooth (E2E tests)") orelse false);
    exe_mod.addOptions("build_info", build_info);

    // CoreAudio's frameworks exist (and are needed) only on macOS; the M4A
    // encoder is compiled out elsewhere (see src/recording.zig). miniaudio's
    // backends self-load at runtime (ALSA/WASAPI via dlopen), so the other
    // systems only need their base system libraries.
    if (target.result.os.tag == .macos) {
        if (sdk_path) |sdk| {
            // The sysroot alone leaves the framework search list empty on a
            // non-native target; name the SDK's framework directory too.
            exe_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
        exe_mod.linkFramework("CoreFoundation", .{});
        exe_mod.linkFramework("CoreAudio", .{});
        exe_mod.linkFramework("AudioToolbox", .{});
        // Bluetooth device sync drives CoreBluetooth through the Objective-C
        // runtime (src/objc.zig, docs/adr/0022).
        exe_mod.linkFramework("Foundation", .{});
        exe_mod.linkFramework("CoreBluetooth", .{});
        // libobjc.tbd sits in the SDK's usr/lib; the sysroot prefixes this path.
        exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        exe_mod.linkSystemLibrary("objc", .{});
    } else if (target.result.os.tag == .linux) {
        exe_mod.linkSystemLibrary("m", .{});
        exe_mod.linkSystemLibrary("pthread", .{});
        exe_mod.linkSystemLibrary("dl", .{});
    } else if (target.result.os.tag == .windows) {
        exe_mod.linkSystemLibrary("ole32", .{});
    }

    const exe = b.addExecutable(.{
        .name = "rec",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run rec");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// The static library `name` a dependency installs. `Dependency.artifact`
/// panics when a package installs a static and a shared library under one
/// name, as the opus package does; rec ships one self-contained binary.
fn staticArtifact(dep: *std.Build.Dependency, name: []const u8) *std.Build.Step.Compile {
    for (dep.builder.install_tls.step.dependencies.items) |step| {
        const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
        const lib = install.artifact;
        if (std.mem.eql(u8, lib.name, name) and lib.linkage == .static) return lib;
    }
    std.debug.panic("dependency installs no static library '{s}'", .{name});
}
