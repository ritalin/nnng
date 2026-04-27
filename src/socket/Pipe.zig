const std = @import("std");

const Socket = @import("./Socket.zig");
const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");

pub const Sync = struct {
    socket: Socket,

    const Self = @This();

    pub fn create(socket: Socket) Self {
        return .{
            .socket = socket,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn iter(self: Self) PipeIter {
        return .{
            .item = .{ .socket = self.socket },
        };
    }

    pub const Item = struct {
        socket: Socket,

        pub fn sender(self: @This()) Sender {
            return .{ .socket = self.socket };
        }

        pub fn receiver(self: @This()) Receiver {
            return .{ .socket = self.socket };
        }
    };

    pub const PipeIter = struct {
        index: usize = 0,
        item: Item,

        pub fn next(self: *@This()) ?Item {
            if (self.index > 0) return null;

            self.index += 1;
            return self.item;
        }
    };
};

pub const Parallel = struct {
    socket: Socket,
    items: std.ArrayListUnmanaged(AioInner),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, socket: Socket, count: usize) !Self {
        const items = try std.ArrayListUnmanaged(AioInner).initCapacity(allocator, count);

        return .{
            .socket = socket,
            .items = items,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pipes) |_| {}
        self.pipes.deinit(self.socket.context.allocator);
    }
};

const AioInner = struct {

};
