const std = @import("std");
const root = @import("../root.zig");
const pipe_impl = @import("../socket/pipe_impls.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");
const ReadyChannel = @import("./ReceivePoller.zig").ReadyChannel;

const Pipe = root.Pipe;
const Message = root.Message;
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;

pub const PollerPipe = struct {
    owner: *const anyopaque,
    vtable: struct {
        on_wait_complete: *const fn (owner: *const anyopaque, channel: *ReadyChannel) ReceiveError!void,
        on_cancel: *const fn (owner: *const anyopaque) void,
    },
    features: Pipe.Features,

    const Self = @This();

    pub fn wait(self: Self, channel: *ReadyChannel) ReceiveError!void {
        return (self.vtable.on_wait_complete)(self.owner, channel);
    }

    pub fn cancel(self: Self) void {
        (self.vtable.on_cancel)(self.owner);
    }
};

pub const PollerPipeImpl = union(enum) {
    parallel: PollerPipeImpl.Parallel,

    pub const Parallel = struct {
        pipe: *const Pipe.Parallel.Item,

        const Self = @This();

        pub fn wait_complete(ptr: *const anyopaque, channel: *ReadyChannel) ReceiveError!void {
            const pipe: *const Pipe.Parallel.Item = @ptrCast(@alignCast(ptr));

            c.nng_ctx_recv(pipe.raw_ctx, pipe.raw_aio);
            c.nng_aio_wait(pipe.raw_aio);

            const err = c.nng_aio_result(pipe.raw_aio);
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
                    .on_submit = Self.submit_message,
                    .on_drain = Self.drain_message,
                },
                .features = pipe.features,
            };
        }

        pub fn cancel_session(ptr: *const anyopaque) void {
            const pipe: *const Pipe.Parallel.Item = @ptrCast(@alignCast(ptr));
            pipe.cancel();
        }

        pub fn submit_message(sender0: *const Sender, msg: Message, options: Sender.Options) SendError!void {
            const self: *const Self = @ptrCast(@alignCast(sender0.owner));

            const sender: Sender = .{
                .owner = self.pipe,
                .on_submit = sender0.on_submit,
            };

            return pipe_impl.ParallelSenderImpl.submit_message(&sender, msg, options);
        }

        pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) ReceiveError!Message {
            _ = options;

            const self: *const Self = @ptrCast(@alignCast(receiver.owner));

            const err = c.nng_aio_result(self.pipe.raw_aio);
            if (err != 0) {
                return errors.receive_error(@intCast(err));
            }

            const raw_msg: ?*c.nng_msg = c.nng_aio_get_msg(self.pipe.raw_aio);
            return Message.from_raw(raw_msg.?);
        }
    };
};
