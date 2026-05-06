//! Pipe implementations.
//!
//! - Pipe.Sync
//! - Pipe.Parallel

const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const impl = @import("./pipe_impls.zig");
const c = @import("c");

const Socket = @import("./Socket.zig");
const Sender = @import("../message/Sender.zig");
const Message = @import("../message/Message.zig");
const Receiver = @import("../message/Receiver.zig");
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;
const OpenAioPipeError = root.OpenAioPipeError;

const Feature = enum {
    send_first,
    receive_first,
    last_msg_owner,
};
pub const Features = std.enums.EnumFieldStruct(Feature, bool, false);

/// Synchronous message handling.
/// Processes messages in a single flow.
pub const Sync = struct {
    pipe: Item,
    features: Features,

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, features: Features) !Self {
        return .{
            .pipe = try Item.create(socket, features),
            .features = features,
        };
    }

    /// Internal. Called by protocol close().
    pub fn deinit(self: *Self) void {
        self.pipe.deinit();
    }

    /// Returns an iterator over the underlying pipes.
    /// This is the primary way to access pipe instances.
    pub fn iter(self: *Self) PipeIter {
        return .{
            .item = &self.pipe,
        };
    }

    /// Pipe instance
    pub const Item = struct {
        id: u64,
        socket: Socket,
        raw_aio: *c.nng_aio,
        features: Features,

        // Internal
        pub fn create(socket: Socket, features: Features) OpenAioPipeError!Item {
            var raw_aio: ?*c.nng_aio = null;
            const err = c.nng_aio_alloc(&raw_aio, null, null);
            if (err != 0) {
                return errors.open_aio_pipe_error(@intCast(err));
            }

            return .{
                .id = impl.PipeIdCounter.next(),
                .socket = socket,
                .raw_aio = raw_aio.?,
                .features = features,
            };
        }

        // Internal
        pub fn deinit(self: *@This()) void {
            c.nng_aio_free(self.raw_aio);
        }

        /// Returns a sender for this pipe.
        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .on_submit = impl.SyncSenderImpl.submit_message,
            };
        }

        /// Returns a receiver for this pipe.
        pub fn receiver(self: *const @This()) Receiver {
            return .{
                .owner = self,
                .on_drain = impl.SyncReceiverImpl.drain_message,
            };
        }

        // Cancel current session
        pub fn cancel(self: *const @This()) void {
            _ = self;
        }
    };

    /// Iterates over pipe instances.
    pub const PipeIter = struct {
        index: usize = 0,
        item: *Item,

        /// Returns the next pipe item, or null when exhausted.
        ///
        /// Yields a single item.
        pub fn next(self: *@This()) ?*const Item {
            if (self.index > 0) return null;

            defer self.index += 1;
            return self.item;
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
        pub fn next(self: *@This()) ?*const Item {
            if (self.index >= self.items.len) return null;

            defer self.index += 1;
            return &self.items[self.index];
        }
    };

    /// Pipe instance
    pub const Item = struct {
        id: u64,
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
                .id = impl.PipeIdCounter.next(),
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
                .on_submit = impl.ParallelSenderImpl.submit_message,
            };
        }

        /// Returns a receiver for this pipe.
        pub fn receiver(self: *const @This()) Receiver {
            return .{
                .owner = self,
                .on_drain = impl.ParallelReceiverImpl.drain_message,
            };
        }

        // Cancel current session
        pub fn cancel(self: *const @This()) void {
            c.nng_aio_cancel(self.raw_aio);
        }
    };
};
