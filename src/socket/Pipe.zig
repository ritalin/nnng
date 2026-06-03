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
const PipeReceiver = root.PipeReceiver;
const AioSlot = @import("../message/message_impl.zig").AioSlot;
const AioStateMachine = @import("./aio_fsm.zig").StateMachine;

const SendError = root.SendError;
const ReceiveError = root.ReceiveError;
const AioPipeError = root.AioPipeError;

const Feature = enum {
    send_first,
    receive_first,
    replyable,
    last_msg_owner,
};
pub const Features = std.enums.EnumFieldStruct(Feature, bool, false);

/// Synchronous message handling.
/// Processes messages in a single flow.
pub const Sync = struct {
    item: *Item,
    features: Features,

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, features: Features) !Self {
        return .{
            .item = try Item.create(socket, features),
            .features = features,
        };
    }

    /// Internal. Called by protocol close().
    pub fn deinit(self: *Self) void {
        self.item.deinit();
    }

    /// Returns an iterator over the underlying pipes.
    /// This is the primary way to access pipe instances.
    pub fn iter(self: *Self) PipeIter {
        return .{
            .item = self.item,
        };
    }

    /// Pipe instance
    pub const Item = struct {
        id: u64,
        socket: Socket,
        features: Features,
        aio_slot: AioSlot,
        fsm: *AioStateMachine,

        // Internal
        pub fn create(socket: Socket, features: Features) AioPipeError!*Item {
            const self = try socket.context.allocator.create(Item);
            errdefer socket.context.allocator.destroy(self);

            var raw_aio: ?*c.nng_aio = null;
            const err = c.nng_aio_alloc(&raw_aio, null, null);
            if (err != 0) {
                return errors.aio_pipe_error(@intCast(err));
            }

            const fsm = try AioStateMachine.create(socket.context.io, socket.context.allocator);

            self.* = .{
                .id = impl.PipeIdCounter.next(),
                .socket = socket,
                .features = features,
                .aio_slot = .{ .raw_aio = fsm.raw_aio },
                .fsm = fsm,
            };

            return self;
        }

        // Internal
        pub fn deinit(self: *@This()) void {
            c.nng_aio_stop(self.aio_slot.raw_aio);
            self.fsm.deinit(self.socket.context.allocator);
            self.socket.context.allocator.destroy(self);
        }

        /// Returns a sender for this pipe.
        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .vtable = .{
                    .on_submit = impl.SyncSenderImpl.submit_message,
                    .on_lock_pipe = impl.SyncSenderImpl.lock_pipe,
                },
            };
        }

        /// Returns a receiver for this pipe.
        pub fn receiver(self: *@This()) PipeReceiver {
            return .{
                .owner = self,
                .slot = &self.aio_slot,
                .on_drain = impl.SyncReceiverImpl.drain_message,
            };
        }

        // Cancel current session
        pub fn cancel(self: *const @This(), options: CancelOptions) AioPipeError!void {
            c.nng_aio_cancel(self.aio_slot.raw_aio);

            if (!options.nonblocking) {
                c.nng_aio_wait(self.aio_slot.raw_aio);
            }

            const err = c.nng_aio_result(self.aio_slot.raw_aio);
            if (err == 0) return;
            if (err == c.NNG_ECANCELED) return;

            return errors.aio_pipe_error(err);
        }
    };

    /// Iterates over pipe instances.
    pub const PipeIter = struct {
        index: usize = 0,
        item: *Item,

        /// Returns the next pipe item, or null when exhausted.
        ///
        /// Yields a single item.
        pub fn next(self: *@This()) ?*Item {
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
            item.deinit(self.socket.context.allocator);
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
        pub fn next(self: *@This()) ?*Item {
            if (self.index >= self.items.len) return null;

            defer self.index += 1;
            return &self.items[self.index];
        }
    };

    /// Pipe instance
    pub const Item = struct {
        id: u64,
        raw_ctx: c.nng_ctx,
        features: Features,
        aio_slot: AioSlot,
        fsm: *AioStateMachine,

        const State = enum { send, receive };

        pub fn create(socket: Socket, features: Features) AioPipeError!@This() {
            const raw_ctx = open: {
                var raw_ctx: c.nng_ctx = undefined;
                const err = c.nng_ctx_open(&raw_ctx, socket.raw_socket);
                if (err != 0) {
                    return errors.aio_pipe_error(err);
                }
                break:open raw_ctx;
            };

            const fsm = try AioStateMachine.create(socket.context.io, socket.context.allocator);

            return .{
                .id = impl.PipeIdCounter.next(),
                .raw_ctx = raw_ctx,
                .features = features,
                .aio_slot = .{ .raw_aio = fsm.raw_aio },
                .fsm = fsm,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.fsm.deinit(allocator);
            self.* = undefined;
        }

        /// Returns a sender for this pipe.
        pub fn sender(self: *const @This()) Sender {
            return .{
                .owner = self,
                .vtable = .{
                    .on_submit = impl.ParallelSenderImpl.submit_message,
                    .on_lock_pipe =     impl.ParallelSenderImpl.lock_pipe,
                },
            };
        }

        /// Returns a receiver for this pipe.
        pub fn receiver(self: *@This()) PipeReceiver {
            return .{
                .owner = self,
                .slot = &self.aio_slot,
                .on_drain = impl.ParallelReceiverImpl.drain_message,
            };
        }

        // Cancel current session
        pub fn cancel(self: *const @This(), options: CancelOptions) AioPipeError!void {
            c.nng_aio_cancel(self.aio_slot.raw_aio);

            if (!options.nonblocking) {
                c.nng_aio_wait(self.aio_slot.raw_aio);
            }

            const err = c.nng_aio_result(self.aio_slot.raw_aio);
            if (err == 0) return;
            if (err == c.NNG_ECANCELED) return;

            return errors.aio_pipe_error(err);
        }
    };
};

pub const Lock = struct {
    mutex: *c.nng_mtx,

    pub fn unlock(self: *const Lock) void {
        c.nng_mtx_unlock(self.mutex);
    }
};

pub const CancelOption = enum {
    /// If true, the operation does not block.
    nonblocking
};

/// Options for cancel operations.
pub const CancelOptions = std.enums.EnumFieldStruct(CancelOption, bool, false);
