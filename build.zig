const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pkg_sysroot = b.option([]const u8, "PKG_SYSROOT", "Native dependency root path");

    const c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(b.pathResolve(&.{ pkg_sysroot.?, "include/nng/nng.h" })),
        .link_libc = true,
    });

    const mod = b.addLibrary(.{
        .name = "nnng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c.createModule() },
            },
        }),
    });
    mod.root_module.addLibraryPath(b.path(b.pathResolve(&.{ pkg_sysroot.?, "lib" })));
    mod.root_module.linkSystemLibrary("nng", .{});

    b.installArtifact(mod);

    const mod_tests = b.addTest(.{
        .root_module = mod.root_module,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

}
