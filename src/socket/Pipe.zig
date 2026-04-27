const std = @import("std");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = @import("./Socket.zig");
const Sender = @import("../message/Sender.zig");
const Message = @import("../message/Message.zig");
const Receiver = @import("../message/Receiver.zig");
const SendError = @import("../root.zig").SendError;

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

        pub fn sender(self: *@This()) Sender {
            return .{
                .owner = self,
                .on_submit = SenderImpl.submit_message };
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

    const SenderImpl = struct {
        fn submit_message(owner: *anyopaque, msg: Message, options: Receiver.Options) SendError!void {
            const pipe: *Sync.Item = @ptrCast(@alignCast(owner));

            const flags = std.enums.EnumSet(Receiver.Option).init(options);
            std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            const err = c.nng_sendmsg(pipe.socket.raw_socket, msg.raw_msg, flags.bits.mask);
            if (err != 0) {
                return errors.send_error(err);
            }
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
