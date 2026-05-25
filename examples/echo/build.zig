const std = @import("std");

pub fn build(b: *std.Build) void {
    const pkg_prefix =
        b.option([]const u8, "NNG_PREFIX", "pkg prefix path")
        orelse b.graph.environ_map.get("NNG_PREFIX").?
    ;

    const dep_blocking_server = b.dependency("blocking_server", .{ .NNG_PREFIX = pkg_prefix });
    const dep_pollable_server = b.dependency("pollable_server", .{ .NNG_PREFIX = pkg_prefix });
    const dep_echo_oneshot = b.dependency("echo_oneshot", .{ .NNG_PREFIX = pkg_prefix });

    const exe_blocking_server = dep_blocking_server.artifact("echo-server-blocking");
    b.installArtifact(exe_blocking_server);

    const exe_pollable_server = dep_pollable_server.artifact("echo-server-pollable");
    b.installArtifact(exe_pollable_server);

    const exe_echo_oneshot = dep_echo_oneshot.artifact("echo-oneshop");
    b.installArtifact(exe_echo_oneshot);
}
