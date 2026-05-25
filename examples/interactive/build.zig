const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pkg_prefix =
        b.option([]const u8, "NNG_PREFIX", "pkg prefix path")
        orelse b.graph.environ_map.get("NNG_PREFIX").?
    ;

    const dep_nnng = b.dependency("nnng", .{
        .NNG_PREFIX = pkg_prefix,
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "interactive-shell",
        .root_module = b.addModule("shell", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nnng", .module = dep_nnng.module("nnng") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_cmd_step = b.step("run", "Launch shell");
    run_cmd_step.dependOn(&run_cmd.step);
}
