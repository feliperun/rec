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

    // The single version source: build.zig.zon, embedded as `build_info`
    // so `rec about` shows it and auto-update compares it against releases.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", zon.version);
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
