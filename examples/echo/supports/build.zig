const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("echo_support", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "known_folders", .module = dep_known_folders.module("known-folders") }
        },
    });
}
