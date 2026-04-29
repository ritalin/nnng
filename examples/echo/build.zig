const std = @import("std");

pub fn build(b: *std.Build) void {
    const pkg_prefix = b.option([]const u8, "PKG_PREFIX", "Native dependency root path") orelse @panic("Need to specify pkg prefix path");

    const dep_blocking_server = b.dependency("blocking_server", .{ .PKG_PREFIX = pkg_prefix });

    const exe_blocking_server = dep_blocking_server.artifact("echo-server-blocking");

    b.installArtifact(exe_blocking_server);
}
