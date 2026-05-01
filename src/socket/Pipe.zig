//! Pipe implementations.
//!
//! - Pipe.Sync
//! - Pipe.Parallel

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

const Feature = enum {
    last_msg_owner,
};
pub const Features = std.enums.EnumFieldStruct(Feature, bool, false);

/// Synchronous message handling.
/// Processes messages in a single flow.
pub const Sync = struct {
    socket: Socket,
    features: Features,

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, features: Features) Self {
        return .{
            .socket = socket,
            .features = features,
        };
    }

    /// Internal. Called by protocol close().
    pub fn deinit(_: *Self) void {}

    /// Returns an iterator over the underlying pipes.
    /// This is the primary way to access pipe instances.
    pub fn iter(self: Self) PipeIter {
        return .{
            .item = .{
                .socket = self.socket,
                .features = self.features,
            },
        };
    }

    /// Pipe instance
    const Item = struct {
        socket: Socket,
        features: Features,

        /// Returns a sender for this pipe.
        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .on_submit = SenderImpl.submit_message,
            };
        }

        /// Returns a receiver for this pipe.
        pub fn receiver(self: *const @This()) Receiver {
            return .{
                .owner = self,
                .on_drain = ReceiverImpl.drain_message,
            };
        }
    };

    /// Iterates over pipe instances.
    pub const PipeIter = struct {
        index: usize = 0,
        item: Item,

        /// Returns the next pipe item, or null when exhausted.
        ///
        /// Yields a single item.
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

/// Parallel message handling.
/// Uses multiple contexts for concurrent processing.
pub const Parallel = struct {
    socket: Socket,
    items: []Item,

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, count: usize, features: Features) !Self {
        const items = try socket.context.allocator.alloc(Item, count);
        for (items) |*item| {
            item.* = try Item.create(socket, features);
        }

        return .{
            .socket = socket,
            .items = items,
        };
    }

    /// Internal. Called by protocol close().
    pub fn deinit(self: *Self) void {
        for (self.items) |*item| {
            item.deinit();
        }
        self.socket.context.allocator.free(self.items);
    }

    /// Returns an iterator over the underlying pipes.
    pub fn iter(self: Self) PipeIter {
        return .{
            .items = self.items,
        };
    }

    /// Iterates over pipe instances.
    pub const PipeIter = struct {
        index: usize = 0,
        items: []Item,

        /// Returns the next pipe item, or null when exhausted.
        ///
        /// Yields one item per configured parallel instance.
        pub fn next(self: *@This()) ?Item {
            if (self.index >= self.items.len) return null;

            defer self.index += 1;
            return self.items[self.index];
        }
    };

    /// Pipe instance
    const Item = struct {
        raw_ctx: c.nng_ctx,
        raw_aio: *c.nng_aio,
        features: Features,

        const State = enum { send, receive };

        pub fn create(socket: Socket, features: Features) OpenAioPipeError!@This() {
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
                .features = features,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = c.nng_aio_free(self.raw_aio);
            _ = c.nng_ctx_close(self.raw_ctx);
            self.* = undefined;
        }

        /// Returns a sender for this pipe.
        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .on_submit = SenderImpl.submit_message,
            };
        }

        /// Returns a receiver for this pipe.
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
