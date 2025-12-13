const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch libvaxis dependency
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vigil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            },
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run vigil");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    // Test each module that has tests
    const test_modules = [_][]const u8{
        "src/types.zig",
        "src/parse.zig",
        "src/input.zig",
        "src/render.zig",
        "src/watch.zig",
        "src/app.zig",
    };

    for (test_modules) |test_file| {
        const module_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                },
            }),
        });

        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
}
