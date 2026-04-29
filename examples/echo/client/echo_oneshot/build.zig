const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pkg_prefix = b.option([]const u8, "PKG_PREFIX", "Native dependency root path") orelse @panic("Need to specify pkg prefix path");

    const dep_nnng = b.dependency("nnng", .{
        .PKG_PREFIX = pkg_prefix,
        .target = target,
        .optimize = optimize,
    });
    const dep_supports = b.dependency("echo_support", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "echo-oneshop",
        .root_module = b.addModule("echo_oneshop",.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nnng", .module = dep_nnng.artifact("nnng").root_module },
                .{ .name = "clap", .module = dep_clap.module("clap") },
                .{ .name = "echo_support", .module = dep_supports.module("echo_support") }
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_cmd_step = b.step("run", "Run echo oneshot");
    run_cmd_step.dependOn(&run_cmd.step);
}
