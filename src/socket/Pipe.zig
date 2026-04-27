const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = @import("./Socket.zig");
const Sender = @import("../message/Sender.zig");
const Message = @import("../message/Message.zig");
const Receiver = @import("../message/Receiver.zig");
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;

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
                .on_submit = SenderImpl.submit_message,
            };
        }

        pub fn receiver(self: *@This()) Receiver {
            return .{
                .owner = self,
                .on_drain = ReceiverImpl.drain_message,
            };
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
        fn submit_message(sender: *const Sender, msg: Message, options: Receiver.Options) SendError!void {
            const pipe: *Sync.Item = @ptrCast(@alignCast(sender.owner));

            const flags = std.enums.EnumSet(Receiver.Option).init(options);
            std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            const err = c.nng_sendmsg(pipe.socket.raw_socket, msg.raw_msg, flags.bits.mask);
            if (err != 0) {
                return errors.send_error(err);
            }
        }
    };

    const ReceiverImpl = struct {
        fn drain_message(receiver: *const Receiver, options: Receiver.Options) ReceiveError!Message {
            const pipe: *Sync.Item = @ptrCast(@alignCast(receiver.owner));

            const flags = std.enums.EnumSet(Receiver.Option).init(options);

            var raw_msg: ?*c.nng_msg = null;
            const err = c.nng_recvmsg(pipe.socket.raw_socket, &raw_msg, flags.bits.mask);
            if (err != 0) {
                return errors.receive_error(err);
            }

            const msg = Message.from_raw(raw_msg.?);
            std.log.debug("Start receiving/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            return msg;
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
