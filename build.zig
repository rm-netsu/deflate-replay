const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("deflate_replay", .{
        .root_source_file = b.path("src/deflate_replay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "deflate-replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "deflate_replay",
                    .module = lib_mod,
                },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step(
        "run",
        "Run the deflate-replay CLI",
    );
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(
        .{ .root_module = lib_mod },
    );
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const exe_tests = b.addTest(
        .{ .root_module = exe.root_module },
    );
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
