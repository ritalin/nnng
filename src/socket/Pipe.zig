const std = @import("std");

const Socket = @import("./Socket.zig");

pub const Sync = struct {
    socket: Socket,

    const Self = @This();

    pub fn create(socket: Socket) Self {
        return .{
            .socket = socket,
        };
    }

    pub fn deinit(_: *Self) void {}
};

pub const Parallel = struct {
    socket: Socket,
    pipes: std.ArrayListUnmanaged(AioInner),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, socket: Socket, count: usize) !Self {
        const pipes = try std.ArrayListUnmanaged(AioInner).initCapacity(allocator, count);

        return .{
            .socket = socket,
            .pipes = pipes,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pipes) |_| {}
        self.pipes.deinit(self.socket.context.allocator);
    }
};

const AioInner = struct {

};
