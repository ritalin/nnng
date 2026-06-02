const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Message = root.Message;
const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");
const PipeLock = root.PipeLock;

pub const PipeIdCounter = struct {
    var current_id: u64 = 1;

    pub fn next() u64 {
        return @atomicRmw(u64, &PipeIdCounter.current_id, .Add, 1, .monotonic);
    }
};

pub const SyncSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(sender.owner));

        // std.log.scoped(.nnng).debug("Start sending:Sync/id: {}, socket: {}, flags: {}, len(edit): {}, len(commit): {}", .{pipe.id, pipe.socket.raw_socket, options, msg.writer.end, msg.len()});
        std.debug.print("Start sending:Sync/id: {}, socket: {}, flags: {}, len(edit): {}, len(commit): {}, busy: {}\n", .{pipe.id, pipe.socket.raw_socket, options, msg.writer.end, msg.len(), c.nng_aio_busy(pipe.aio_slot.raw_aio)});

        c.nng_aio_set_msg(pipe.aio_slot.raw_aio, msg.raw_msg);
        c.nng_send_aio(pipe.socket.raw_socket, pipe.aio_slot.raw_aio);

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.aio_slot.raw_aio);
        }

        const err = c.nng_aio_result( pipe.aio_slot.raw_aio);
        if (err != 0) {
            return errors.send_error(err);
        }
    }

    pub fn lock_pipe(sender: *const Sender) PipeLock {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(sender.owner));
        return pipe.fsm.lock();
    }
};

pub const SyncReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Sync.Item = @ptrCast(@alignCast(receiver.owner));

        try receiver.slot.storeReceiveOpion(options);

        std.log.scoped(.nnng).debug("Start receiving:Sync/id: {}, socket: {}, id: {}, flags: {}", .{pipe.id, pipe.socket.raw_socket, pipe.id, options});

        if (options.flags.nonblocking) {
            c.nng_recv_aio(pipe.socket.raw_socket, pipe.aio_slot.raw_aio);
        }
        else {
            try pipe.fsm.transitWaiting();
            c.nng_recv_aio(pipe.socket.raw_socket, pipe.aio_slot.raw_aio);
            try pipe.fsm.wait();
        }

        const err = c.nng_aio_result(pipe.aio_slot.raw_aio);
        if (err != 0) {
            defer if (err != c.NNG_EAGAIN) { 
                receiver.slot.reset(); 
                pipe.fsm.transitIdle();
            };
            return errors.receive_error(err);
        }

        const raw_msg = c.nng_aio_get_msg(pipe.aio_slot.raw_aio);
        if (raw_msg == null) {
            // Result is not available yet
            return error.WouldBlock;
        }

        defer receiver.slot.reset();
        defer pipe.fsm.transitIdle();

        const msg = Message.fromRaw(raw_msg.?);
        std.log.scoped(.nnng).debug("Received:Sync/id: {}, len(edit): {}, len(commit): {}", .{pipe.id, msg.writer.end, msg.len()});

        return msg;
    }
};

pub const ParallelSenderImpl = struct {
    pub fn submit_message(sender: *const Sender, msg: Message, options: Sender.Options) root.SendError!void {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(sender.owner));

        std.log.scoped(.nnng).debug("Start sending:Parallel/id: {}, flags(discard): {}, len(edit): {}, len(commit): {}", .{pipe.id, options, msg.writer.end, msg.len()});

        c.nng_aio_set_msg(pipe.aio_slot.raw_aio, msg.raw_msg);
        c.nng_ctx_send(pipe.raw_ctx, pipe.aio_slot.raw_aio);

        if (!options.flags.nonblocking) {
            c.nng_aio_wait(pipe.aio_slot.raw_aio);
        }
        const err = c.nng_aio_result(pipe.aio_slot.raw_aio);
        if (err != 0) {
            return errors.send_error(@intCast(err));
        }
    }

    pub fn lock_pipe(sender: *const Sender) PipeLock {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(sender.owner));
        return pipe.fsm.lock();
    }
};

pub const ParallelReceiverImpl = struct {
    pub fn drain_message(receiver: *const Receiver, options: Receiver.Options) root.ReceiveError!Message {
        const pipe: *const root.Pipe.Parallel.Item = @ptrCast(@alignCast(receiver.owner));

        try receiver.slot.storeReceiveOpion(options);

        std.log.scoped(.nnng).debug("Start receiving:Parallel/id: {}, flags: {}", .{pipe.id, options});

        c.nng_ctx_recv(pipe.raw_ctx, receiver.slot.raw_aio);
        
        if (!options.flags.nonblocking) {
            c.nng_aio_wait(receiver.slot.raw_aio);
        }

        const err = c.nng_aio_result(receiver.slot.raw_aio);
        if (err != 0) {
            defer if (err != c.NNG_EAGAIN) { receiver.slot.reset(); };
            return errors.receive_error(@intCast(err));
        }

        const raw_msg: ?*c.nng_msg = c.nng_aio_get_msg(receiver.slot.raw_aio);
        if (raw_msg == null) {
            // Result is not available yet
            return error.WouldBlock;
        }

        defer receiver.slot.reset();

        const msg = Message.fromRaw(raw_msg.?);
        std.log.scoped(.nnng).debug("Received:Parallel/id: {}, len(edit): {}, len(commit): {}", .{pipe.id, msg.writer.end, msg.len()});

        return msg;
    }
};
