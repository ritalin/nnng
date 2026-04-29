const std = @import("std");
const folders = @import("known_folders");

pub fn make_ipc_url(init: std.process.Init, socket_name: []const u8) ![]const u8 {
    const cache_dir = try folders.open(init.io, init.gpa, init.environ_map, folders.KnownFolder.cache, .{}) orelse @panic("Socket dir is not found");
    defer cache_dir.close(init.io);

    const dir = try cache_dir.createDirPathOpen(init.io, "nng", .{});
    defer dir.close(init.io);
    const dir_path = try dir.realPathFileAlloc(init.io, ".", init.gpa);
    defer init.gpa.free(dir_path);

    return std.fmt.allocPrint(init.gpa, "ipc://{s}/{s}.sock", .{ dir_path, socket_name });
}
