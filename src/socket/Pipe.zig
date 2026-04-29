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
const OpenAioPipeError = root.OpenAioPipeError;

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

        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .on_submit = SenderImpl.submit_message,
            };
        }

        pub fn receiver(self: *const @This()) Receiver {
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

            defer self.index += 1;
            return self.item;
        }
    };

    const SenderImpl = struct {
        fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) SendError!void {
            const pipe: *const Sync.Item = @ptrCast(@alignCast(sender.owner));

            const flags = std.enums.EnumSet(Sender.Option).init(options);
            std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            const err = c.nng_sendmsg(pipe.socket.raw_socket, msg.raw_msg, flags.bits.mask);
            if (err != 0) {
                return errors.send_error(err);
            }
        }
    };

    const ReceiverImpl = struct {
        fn drain_message(receiver: *const Receiver, options: Receiver.Options) ReceiveError!Message {
            const pipe: *const Sync.Item = @ptrCast(@alignCast(receiver.owner));

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
    items: []Item,

    const Self = @This();

    pub fn create(socket: Socket, count: usize) !Self {
        const items = try socket.context.allocator.alloc(Item, count);
        for (items) |*item| {
            item.* = try Item.create(socket);
        }

        return .{
            .socket = socket,
            .items = items,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.items) |*item| {
            item.deinit();
        }
        self.socket.context.allocator.free(self.items);
    }

    pub fn iter(self: Self) PipeIter {
        return .{
            .items = self.items,
        };
    }

    pub const PipeIter = struct {
        index: usize = 0,
        items: []Item,

        pub fn next(self: *@This()) ?Item {
            if (self.index >= self.items.len) return null;

            defer self.index += 1;
            return self.items[self.index];
        }
    };

    const Item = struct {
        raw_ctx: c.nng_ctx,
        raw_aio: *c.nng_aio,

        const State = enum { send, receive };

        pub fn create(socket: Socket) OpenAioPipeError!@This() {
            const raw_ctx = open: {
                var raw_ctx: c.nng_ctx = undefined;
                const err = c.nng_ctx_open(&raw_ctx, socket.raw_socket);
                if (err != 0) {
                    return errors.open_aio_pipe_error(err);
                }
                break:open raw_ctx;
            };

            const raw_aio = open: {
                var raw_aio: ?*c.nng_aio = null;
                const err = c.nng_aio_alloc(&raw_aio, null, null);
                if (err != 0) {
                    defer _ = c.nng_ctx_close(raw_ctx);
                    return errors.open_aio_pipe_error(@intCast(err));
                }
                break:open raw_aio;
            };

            return .{
                .raw_ctx = raw_ctx,
                .raw_aio = raw_aio.?,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = c.nng_aio_free(self.raw_aio);
            _ = c.nng_ctx_close(self.raw_ctx);
            self.* = undefined;
        }

        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .on_submit = SenderImpl.submit_message,
            };
        }

        pub fn receiver(self: *const @This()) Receiver {
            return .{
                .owner = self,
                .on_drain = ReceiverImpl.drain_message,
            };
        }
    };

    const SenderImpl = struct {
        fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) SendError!void {
            const pipe: *const Parallel.Item = @ptrCast(@alignCast(sender.owner));

            std.log.debug("Start sending parallel/flags(discard): {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            c.nng_aio_set_msg(pipe.raw_aio, msg.raw_msg);
            c.nng_ctx_send(pipe.raw_ctx, pipe.raw_aio);

            c.nng_aio_wait(pipe.raw_aio);
            const err = c.nng_aio_result(pipe.raw_aio);
            if (err != 0) {
                return errors.send_error(@intCast(err));
            }
        }
    };

    const ReceiverImpl = struct {
        fn drain_message(receiver: *const Receiver, options: Receiver.Options) ReceiveError!Message {
            const pipe: *const Parallel.Item = @ptrCast(@alignCast(receiver.owner));

            c.nng_ctx_recv(pipe.raw_ctx, pipe.raw_aio);

            c.nng_aio_wait(pipe.raw_aio);
            const err = c.nng_aio_result(pipe.raw_aio);
            if (err != 0) {
                return errors.receive_error(@intCast(err));
            }

            const raw_msg: ?*c.nng_msg = c.nng_aio_get_msg(pipe.raw_aio);
            const msg = Message.from_raw(raw_msg.?);
            std.log.debug("Start receiving/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

            return msg;
        }
    };
};
