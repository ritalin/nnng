const std = @import("std");

pub fn make_ipc_sock(dir: std.Io.Dir, file_name: []const u8) anyerror![]const u8 {
    const sock_path = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(sock_path);

    return std.fmt.allocPrint(std.testing.allocator, "ipc://{s}/{s}", .{ sock_path, file_name });
}
