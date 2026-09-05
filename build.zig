const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // CoreAudio's frameworks exist (and are needed) only on macOS; the M4A
    // encoder is compiled out elsewhere (see src/recording.zig). miniaudio's
    // backends self-load at runtime (ALSA/WASAPI via dlopen), so the other
    // systems only need their base system libraries.
    if (target.result.os.tag == .macos) {
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
