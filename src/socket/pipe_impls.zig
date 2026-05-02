const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Message = root.Message;
const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");

pub const SyncSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(sender.owner));

        const flags = std.enums.EnumSet(Sender.Option).init(options);
        std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

        const err = c.nng_sendmsg(pipe.socket.raw_socket, msg.raw_msg, flags.bits.mask);
        if (err != 0) {
            return errors.send_error(err);
        }
    }
};

pub const SyncReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(receiver.owner));

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

pub const ParallelSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(sender.owner));

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

pub const ParallelReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(receiver.owner));

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
