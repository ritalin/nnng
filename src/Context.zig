const std = @import("std");
const root = @import("./root.zig");
const c = @import("c");

io: std.Io,
allocator: std.mem.Allocator,

const Self = @This() ;

pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
    _ = c.nng_init(null);

    return .{
        .io = io,
        .allocator = allocator,
    };
}
