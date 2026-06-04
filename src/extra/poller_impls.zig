const std = @import("std");
const root = @import("../root.zig");
const pipe_impl = @import("../socket/pipe_impls.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Sender = @import("../message/Sender.zig");
const TryPipeReceiver = root.TryPipeReceiver;
const ReadyChannel = @import("./poller.zig").ReadyChannel;

const Pipe = root.Pipe;
const PipeLock = root.PipeLock;
const Message = root.Message;
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;
const AioPipeError = root.AioPipeError;

pub const PollerPipe = struct {
    owner: *anyopaque,
    vtable: struct {
        on_pipe_id: *const fn (owner: *anyopaque) u64,
        on_wait_complete: *const fn (owner: *anyopaque, channel: *ReadyChannel) ReceiveError!void,
        on_cancel: *const fn (owner: *const anyopaque) void,
    },
    features: Pipe.Features,

    const Self = @This();

    pub fn id(self: *const Self) u64 {
        return (self.vtable.on_pipe_id)(self.owner);
    }

    pub fn wait(self: *const Self, channel: *ReadyChannel) ReceiveError!void {
        return (self.vtable.on_wait_complete)(self.owner, channel);
    }

    pub fn cancel(self: Self) void {
        (self.vtable.on_cancel)(self.owner);
    }
};

pub const PollerPipeImpl = union(enum) {
    sync: PollerPipeImpl.Sync,
    parallel: PollerPipeImpl.Parallel,

    pub const Sync = struct {
        pipe: *Pipe.Sync.Item,

        const Self = @This();

        pub fn pipeId(ptr: *anyopaque) u64 {
            const pipe: *Pipe.Sync.Item = @ptrCast(@alignCast(ptr));

            return pipe.id;
        }

        pub fn waitComplete(ptr: *anyopaque, channel: *ReadyChannel) ReceiveError!void {
            const pipe: *Pipe.Sync.Item = @ptrCast(@alignCast(ptr));

            if (pipe.fsm.currentState() == .completed) {
                // For no `drain` call
                pipe.fsm.transitIdle();
            }
            if (pipe.fsm.currentState() != .waiting) {
                try pipe.fsm.transitWaiting();
                c.nng_recv_aio(pipe.socket.raw_socket, pipe.aio_slot.raw_aio);
            }
            try pipe.fsm.wait();

            std.log.scoped(.nnng).debug("Poller-awake:Sync/id: {}", .{ pipe.id });

            const err = c.nng_aio_result(pipe.aio_slot.raw_aio);
            if (err != 0) {
                return errors.receive_error(@intCast(err));
            }

            const self: Self = .{
                .pipe = pipe,
            };

            channel.* = .{
                .id = pipe.id,
                .impl = .{ .sync = self },
                .vtable = .{
                    .on_submit = Self.submitMessage,
                    .on_try_drain = Self.tryDrainMessage,
                    .on_lock_pipe = Self.lockSendPipe,
                },
                .features = pipe.features,
            };
        }

        pub fn cancelSession(ptr: *const anyopaque) void {
            const pipe: *const Pipe.Sync.Item = @ptrCast(@alignCast(ptr));
            c.nng_aio_stop(pipe.aio_slot.raw_aio);
        }

        pub fn submitMessage(sender0: *const Sender, msg: Message, options: Sender.Options) SendError!void {
            const self: *const Self = @ptrCast(@alignCast(sender0.owner));

            const sender: Sender = .{
                .owner = self.pipe,
                .vtable = .{
                    .on_submit = sender0.vtable.on_submit,
                    .on_lock_pipe = sender0.vtable.on_lock_pipe,
                },
            };

            return pipe_impl.SyncSenderImpl.submit_message(&sender, msg, options);
        }

        pub fn tryDrainMessage(receiver: *const TryPipeReceiver, options: TryPipeReceiver.Options) ReceiveError!?Message {
            _ = options;

            const self: *const Self = @ptrCast(@alignCast(receiver.owner));
            if (self.pipe.fsm.currentState() == .idle) {
                return null;
            }

            std.log.scoped(.nnng).debug("Poller-received:Sync/id: {}", .{ self.pipe.id });

            const raw_msg: ?*c.nng_msg = msg: switch (self.pipe.fsm.currentState()) {
                .completed => c.nng_aio_get_msg(self.pipe.aio_slot.raw_aio),
                .has_more => {
                    var raw_msg: ?*c.nng_msg = null;
                    const err = c.nng_recvmsg(self.pipe.socket.raw_socket, &raw_msg, c.NNG_FLAG_NONBLOCK);
                    if (err == 0) break:msg raw_msg
                    else if (err == c.NNG_EAGAIN) {
                        break:msg null;
                    }
                    else {
                        defer self.pipe.fsm.transitIdle();
                        return errors.receive_error(@intCast(err));
                    }
                },
                else => break:msg null,
            };

            if (raw_msg == null) {
                defer self.pipe.fsm.transitIdle();
                return null;
            }

            if (!self.pipe.features.replyable) {
                try self.pipe.fsm.transitIteration();
            }

            return Message.fromRaw(raw_msg.?);
        }

        pub fn lockSendPipe(receiver: *const Sender) PipeLock {
            const self: *const Self = @ptrCast(@alignCast(receiver.owner));

            return self.pipe.fsm.lock();
        }
    };

    pub const Parallel = struct {
        pipe: *Pipe.Parallel.Item,

        const Self = @This();

        pub fn pipeId(ptr: *anyopaque) u64 {
            const pipe: *Pipe.Parallel.Item = @ptrCast(@alignCast(ptr));

            return pipe.id;
        }

        pub fn waitComplete(ptr: *anyopaque, channel: *ReadyChannel) ReceiveError!void {
            const pipe: *Pipe.Parallel.Item = @ptrCast(@alignCast(ptr));

            if (pipe.fsm.currentState() == .completed) {
                // For no `drain` call
                pipe.fsm.transitIdle();
            }
            if (pipe.fsm.currentState() != .waiting) {
                try pipe.fsm.transitWaiting();
                c.nng_ctx_recv(pipe.raw_ctx, pipe.aio_slot.raw_aio);
            }
            try pipe.fsm.wait();

            std.log.scoped(.nnng).debug("Poller-awake:Parallel/id: {}", .{ pipe.id });

            const err = c.nng_aio_result(pipe.aio_slot.raw_aio);
            if (err != 0) {
                return errors.receive_error(@intCast(err));
            }

            const self: Self = .{
                .pipe = pipe,
            };

            channel.* = .{
                .id = pipe.id,
                .impl = .{ .parallel = self },
                .vtable = .{
                    .on_submit = Self.submitMessage,
                    .on_try_drain = Self.tryDrainMessage,
                    .on_lock_pipe = Self.lockSenderPipe,
                },
                .features = pipe.features,
            };
        }

        pub fn cancelSession(ptr: *const anyopaque) void {
            const pipe: *const Pipe.Parallel.Item = @ptrCast(@alignCast(ptr));
            pipe.fsm.transitStopped();
        }

        pub fn submitMessage(sender0: *const Sender, msg: Message, options: Sender.Options) SendError!void {
            const self: *const Self = @ptrCast(@alignCast(sender0.owner));

            const sender: Sender = .{
                .owner = self.pipe,
                .vtable = .{
                    .on_submit = sender0.vtable.on_submit,
                    .on_lock_pipe = sender0.vtable.on_lock_pipe,
                },
            };

            return pipe_impl.ParallelSenderImpl.submit_message(&sender, msg, options);
        }

        pub fn tryDrainMessage(receiver: *const TryPipeReceiver, options: TryPipeReceiver.Options) ReceiveError!?Message {
            _ = options;

            const self: *const Self = @ptrCast(@alignCast(receiver.owner));
            if (self.pipe.fsm.currentState() == .idle) {
                return null;
            }

            std.log.scoped(.nnng).debug("Poller-received:Parallel/id: {}", .{ self.pipe.id });

            const raw_msg = c.nng_aio_get_msg(self.pipe.aio_slot.raw_aio);
            if (raw_msg == null) {
                return null;
            }
            defer self.pipe.fsm.transitIdle();
            
            return Message.fromRaw(raw_msg.?);
        }

        pub fn lockSenderPipe(receiver: *const Sender) PipeLock {
            const self: *const Self = @ptrCast(@alignCast(receiver.owner));
            return self.pipe.fsm.lock();
        }
    };
};
