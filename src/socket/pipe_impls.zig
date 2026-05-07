const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Message = root.Message;
const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");

pub const PipeIdCounter = struct {
    var current_id: u64 = 1;

    pub fn next() u64 {
        return @atomicRmw(u64, &PipeIdCounter.current_id, .Add, 1, .monotonic);
    }
};

pub const SyncSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(sender.owner));

        std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

        c.nng_aio_set_msg(pipe.raw_aio, msg.raw_msg);
        c.nng_send_aio(pipe.socket.raw_socket, pipe.raw_aio);

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.raw_aio);
        }

        const err = c.nng_aio_result( pipe.raw_aio);
        if (err != 0) {
            return errors.send_error(err);
        }
    }
};

pub const SyncReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(receiver.owner));

        std.log.debug("Start receiving:Sync/id: {}, flags: {}", .{pipe.id, options});

        c.nng_recv_aio(pipe.socket.raw_socket, pipe.raw_aio);

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.raw_aio);
        }

        const err = c.nng_aio_result(pipe.raw_aio);
        if (err != 0) {
            return errors.receive_error(err);
        }

        const raw_msg = c.nng_aio_get_msg(pipe.raw_aio);
        if (raw_msg == null) {
            // Result is not available yet
            return error.WouldBlock;
        }

        const msg = Message.fromRaw(raw_msg.?);
        std.log.debug("Received:Sync/id: {}, len(edit): {}, len(commit): {}", .{pipe.id, msg.writer.end, msg.len()});

        return msg;
    }
};

pub const ParallelSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(sender.owner));

        std.log.debug("Start sending:Parallel/flags(discard): {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

        c.nng_aio_set_msg(pipe.raw_aio, msg.raw_msg);
        c.nng_ctx_send(pipe.raw_ctx, pipe.raw_aio);

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.raw_aio);
        }
        const err = c.nng_aio_result(pipe.raw_aio);
        if (err != 0) {
            return errors.send_error(@intCast(err));
        }
    }
};

pub const ParallelReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(receiver.owner));

        c.nng_ctx_recv(pipe.raw_ctx, pipe.raw_aio);
        std.log.debug("Start receiving:Parallel/id: {}, flags: {}", .{pipe.id, options});

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.raw_aio);
        }

        const err = c.nng_aio_result(pipe.raw_aio);
        if (err != 0) {
            return errors.receive_error(@intCast(err));
        }

        const raw_msg: ?*c.nng_msg = c.nng_aio_get_msg(pipe.raw_aio);
        if (raw_msg == null) {
            // Result is not available yet
            return error.WouldBlock;
        }

        const msg = Message.fromRaw(raw_msg.?);
        std.log.debug("Received:Parallel/id: {}, len(edit): {}, len(commit): {}", .{pipe.id, msg.writer.end, msg.len()});

        return msg;
    }
};
