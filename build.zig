const std = @import("std");
const builtin = @import("builtin");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe
    });

    // Exposing as a dependency for other projects
    const pkg = b.addModule("stencil", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize
    });
    _ = pkg;

    // Making executable for this project
    const exe = b.addExecutable(.{
        .name = "stencil",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}