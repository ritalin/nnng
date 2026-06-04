const std = @import("std");
const root = @import("../root.zig");
const pipe_impl = @import("../socket/pipe_impls.zig");
const poller_impl = @import("./poller_impls.zig");

const Context = root.Context;
const Pipe = root.Pipe;
const PipeLock = root.PipeLock;
const PipeSender = root.PipeSender;
const TryPipeReceiver = root.TryPipeReceiver;
const Message = root.Message;
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;

/// Attaches a Pipe to a synchronous Poller.
///
/// ## Behavior
/// The Poller drives all execution for the attached Pipe in a single loop.
///
/// Message delivery is strictly serialized.
///
/// ## Concurrency model
/// Single execution flow.
///
/// Only the Poller interacts with the Pipe during execution.
///
/// ## External interaction
/// External `drain()` calls are allowed but not coordinated with Poller execution.
///
/// Concurrent execution may result in undefined behavior if both paths
/// attempt to receive messages simultaneously.
///
/// ## Semantics
/// This mode assumes Poller is the primary execution driver.
/// 
pub fn ReceivePoller(comptime buffer_size: comptime_int) type {
    return struct {
        context: Context,
        poller_pipes: std.AutoHashMap(u64, poller_impl.PollerPipe),
        skip_set: std.AutoHashMap(u64, void),
        ready_set: std.AutoHashMap(u64, void),
        in_fight_set: std.AutoHashMap(u64, void),
        tasks: *PollerTaskImpl,

        const Poller = @This();

        pub fn create(context: Context) !Poller {
            return .{
                .context = context,
                .poller_pipes = .init(context.allocator),
                .skip_set = .init(context.allocator),
                .ready_set = .init(context.allocator),
                .in_fight_set = .init(context.allocator),
                .tasks = try PollerTaskImpl.init(context),
            };
        }

        /// Shutdown cleanup.
        ///
        /// Any pending or in-flight messages are intentionally discarded.
        /// This is a defined part of the lifecycle model, not a resource leak.
        ///
        /// Rationale:
        /// - Poller is the sole FSM writer
        /// - main thread owns final lifecycle termination
        /// - after stop, no further message processing is valid
        /// 
        pub fn deinit(self: *Poller) void {
            self.terminate();
            self.poller_pipes.deinit();
            self.skip_set.deinit();
            self.ready_set.deinit();
            self.in_fight_set.deinit();
            self.tasks.deinit(self.context.allocator);
        }

        /// Runs the event loop.
        ///
        /// This function is not reentrant.
        /// It must not be called concurrently on the same Poller instance.
        ///
        /// Behavior is undefined if re-entered.
        ///
        pub fn poll(self: *Poller, callback: WakeupCallback) !usize {
            var ready_iter = self.ready_set.keyIterator();

            var i: usize = 0;
            while (ready_iter.next()) |id| {
                if (self.in_fight_set.contains(id.*)) continue;
                if (self.skip_set.contains(id.*)) continue;

                if (self.poller_pipes.get(id.*)) |pipe| {
                    const channel = try self.context.allocator.create(ReadyChannel);

                    try self.in_fight_set.put(id.*, {});
                    try self.tasks.attach(id.*, pipe, channel);
                    i += 1;
                }
            }
            self.ready_set.clearRetainingCapacity();

            std.debug.assert(self.ready_set.count() == 0);

            var wakeups: [buffer_size]PollWakeupResult = undefined;
            const count = try self.tasks.poll(&wakeups);
            defer dropReadyChannels(self.context.allocator, wakeups[0..count]);

            var results: [buffer_size]PollEvent = undefined;

            for (0..count) |w| {
                switch (wakeups[w].event) {
                    .ready => |event| results[w] = .{ .ready = event.channel },
                    .failed => |event| results[w] = .{ .failed = .{ .id = event.channel.id, .err = event.err } },
                }
            }

            // reactivate
            for (0..count) |w| {
                const poller_id, const channel = switch (wakeups[w].event) {
                    .ready => |event| .{ event.poller_id, event.channel },
                    .failed => |event| .{ event.poller_id, event.channel },
                };
                
                // reset in-fight set (ready channel only)
                _ = self.in_fight_set.remove(poller_id);

                // ready pipe
                if (channel.features.receive_first) {
                    try self.ready_set.put(poller_id, {});
                }
            }

            // reset skip-set
            var skip_iter = self.skip_set.keyIterator();
            while(skip_iter.next()) |id| {
                try self.ready_set.put(id.*, {});
            }
            try callback(self, results[0..count]);

            return count;
        }

        pub fn cancel(self: *Poller, id: u64) void {
            if (self.poller_pipes.get(id)) |pipe| {
                std.log.scoped(.nnng).debug("Poller:cancel/id: {}", .{id});
                pipe.cancel();
            }
        }

        pub fn terminate(self: *Poller) void {
            var iter = self.in_fight_set.keyIterator();
            while (iter.next()) |id| {
                self.cancel(id.*);
            }

            if (self.in_fight_set.count() > 0) await: {
                var wakeups: [buffer_size]PollWakeupResult = undefined;
                const count = 
                    self.tasks.select.awaitMany(&wakeups, self.in_fight_set.count()) 
                    catch break:await
                ;

                dropReadyChannels(self.context.allocator, wakeups[0..count]);
            }
        }

        fn attachInternal(self: *Poller, id: u64, channel: poller_impl.PollerPipe) !void {
            if (self.ready_set.contains(id) or self.in_fight_set.contains(id)) {
                std.log.scoped(.nnng).warn("Poller:already attached/id: {}", .{id});
                return;
            }

            std.log.scoped(.nnng).debug("Poller:attach/id: {}", .{id});

            try self.poller_pipes.put(id, channel);

            if (channel.features.receive_first) {
                try self.ready_set.put(id, {});
            }
        }

        /// Attaches a socket-backed Pipe to the Poller in synchronous mode.
        ///
        /// ## Execution model
        /// Execution is driven sequentially by the Poller for a single socket stream.
        ///
        /// ## External interaction
        /// External Receiver usage is allowed but not coordinated with Poller execution.
        ///
        /// Concurrent receive operations are not synchronized and may result in
        /// undefined ordering.
        /// 
        pub const Sync = struct {
            pub fn attach(poller: *Poller, pipe: *Pipe.Sync) !void {
                var iter = pipe.iter();
                while (iter.next()) |p| {
                    const channel: poller_impl.PollerPipe = .{
                        .owner = p,
                        .vtable = .{
                            .on_pipe_id = poller_impl.PollerPipeImpl.Sync.pipeId,
                            .on_wait_complete = poller_impl.PollerPipeImpl.Sync.waitComplete,
                            .on_cancel = poller_impl.PollerPipeImpl.Sync.cancelSession,
                        },
                        .features = p.features,
                    };

                    try poller.attachInternal(p.id, channel);
                }
            }
        };

        /// Attaches a context-backed Pipe to the Poller in parallel mode.
        ///
        /// ## Execution model
        /// Execution is driven concurrently across multiple contexts.
        ///
        /// ## External interaction
        /// External Receiver usage is allowed but not synchronized with Poller execution.
        ///
        /// Concurrent receive operations are not synchronized and ordering is undefined.
        /// 
        pub const Parallel = struct {
            pub fn attach(poller: *Poller, pipe: *Pipe.Parallel) !void {
                var iter = pipe.iter();
                while (iter.next()) |p| {
                    const channel: poller_impl.PollerPipe = .{
                        .owner = p,
                        .vtable = .{
                            .on_pipe_id = poller_impl.PollerPipeImpl.Parallel.pipeId,
                            .on_wait_complete = poller_impl.PollerPipeImpl.Parallel.waitComplete,
                            .on_cancel = poller_impl.PollerPipeImpl.Parallel.cancelSession,
                        },
                        .features = p.features,
                    };

                    try poller.attachInternal(p.id, channel);
                }
            }
        };

        pub const WakeupCallback = *const fn (poller: *Poller, channels: []const PollEvent) anyerror!void;

        //
        // Internal implementations
        //

        const PollerTaskImpl = struct {
           select: std.Io.Select(PollWakeupResult),
           select_buffer: [buffer_size]PollWakeupResult = undefined,

           fn init(context: Context) !*PollerTaskImpl {
               var self = try context.allocator.create(PollerTaskImpl);
               self.* = .{
                   .select = std.Io.Select(PollWakeupResult).init(context.io, &self.select_buffer),
               };

               return self;
           }

           fn deinit(self: *PollerTaskImpl, allocator: std.mem.Allocator) void {
               allocator.destroy(self);
           }

           fn attach(self: *PollerTaskImpl, id: u64, pipe: poller_impl.PollerPipe, channel: *ReadyChannel) !void {
                try self.select.concurrent(.event, doReceive, .{ id, pipe, channel });
           }

           fn poll(self: *PollerTaskImpl, wakeups: []PollWakeupResult) !usize {
               return self.select.awaitMany(wakeups, 1);
           }
        };
    };
}

fn doReceive(id: u64, pipe: poller_impl.PollerPipe, channel: *ReadyChannel) std.meta.fieldInfo(PollWakeupResult, .event).type {
    pipe.wait(channel)
    catch |err| return .{
        .failed = .{ .poller_id = id, .channel = channel, .err = err },
    };

    return .{
        .ready = .{ .poller_id = id, .channel = channel },
    };
}

fn dropReadyChannels(allocator: std.mem.Allocator, results: []PollWakeupResult) void {
    for (results) |*result| {
        switch (result.event) {
            .failed => |event| allocator.destroy(event.channel),
            .ready => |event| allocator.destroy(event.channel),
        }
    }
}

const PollWakeupResult = union {
    event: union(enum) { 
        ready: struct { poller_id: u64, channel: *ReadyChannel }, 
        failed: struct { poller_id: u64, channel: *ReadyChannel, err: ReceiveError } },
};

pub const PollEvent = union(enum) {
    ready: *ReadyChannel,
    failed: struct {
        id: u64,
        err: ReceiveError,
    },
};

pub const Timeout = union {
    unlimited: void,
    msec: u64,
};

/// ReadyChannel is a logical entry point for creating Sender/Receiver
/// interfaces bound to an execution context.
///
/// ## Options behavior
/// Options passed through Sender/Receiver construction are accepted
/// for API compatibility but do not affect behavior in this mode.
///
/// The execution behavior is fixed by the underlying Poller configuration.
/// 
pub const ReadyChannel = struct {
    id: u64,
    impl: poller_impl.PollerPipeImpl,
    vtable: struct {
        on_submit: *const fn (sender: *const PipeSender, msg: Message, options: PipeSender.Options) SendError!void,
        on_try_drain: *const fn (receiver: *const TryPipeReceiver, options: TryPipeReceiver.Options) ReceiveError!?Message,
        on_lock_pipe: *const fn (sender: *const PipeSender) PipeLock,
    },
    features: Pipe.Features,

    pub fn sender(self: *const ReadyChannel) PipeSender {
        switch (self.impl) {
            .sync => |*impl| {
                return .{
                    .owner = impl,
                    .vtable = .{
                        .on_submit =  self.vtable.on_submit,
                        .on_lock_pipe = self.vtable.on_lock_pipe,
                    },
                };
            },
            .parallel => |*impl| {
                return .{
                    .owner = impl,
                    .vtable = .{
                        .on_submit =  self.vtable.on_submit,
                        .on_lock_pipe = self.vtable.on_lock_pipe,
                    },
                };
            },
        }
    }

    pub fn receiver(self: *const ReadyChannel) TryPipeReceiver {
        switch (self.impl) {
            .sync => |*impl| {
                return .{
                    .owner = impl,
                    .slot = &impl.pipe.aio_slot,
                    .on_try_drain = self.vtable.on_try_drain,
                };
            },
            .parallel => |*impl| {
                return .{
                    .owner = impl,
                    .slot = &impl.pipe.aio_slot,
                    .on_try_drain = self.vtable.on_try_drain,
                };
            },
        }
    }
};

test "Poller tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const test_support = @import("../supports/test.zig");
    const TestPoller = root.ReceivePoller(32);

    test "new receive poller with receiving sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        try TestPoller.Sync.attach(&poller, &rep_socket.pipe);
        try std.testing.expectEqual(1, poller.poller_pipes.count());
        try std.testing.expectEqual(1, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "new receive poller with receiving parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        try TestPoller.Parallel.attach(&poller, &rep_socket.pipe);
        try std.testing.expectEqual(3, poller.poller_pipes.count());
        try std.testing.expectEqual(3, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "new receive poller with sync REQ pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket.transport.start(.{});
        defer req_socket.close();

        try TestPoller.Sync.attach(&poller, &req_socket.pipe);
        try std.testing.expectEqual(1, poller.poller_pipes.count());
        try std.testing.expectEqual(0, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "new receive poller with parallel REQ pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.parallel(3).as_dialer(url);
        };
        try req_socket.transport.start(.{});
        defer req_socket.close();

        try TestPoller.Parallel.attach(&poller, &req_socket.pipe);
        try std.testing.expectEqual(3, poller.poller_pipes.count());
        try std.testing.expectEqual(0, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "receive mesg from poller with sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start(.{});
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket2.transport.start(.{});
        defer req_socket2.close();

        var req_pipe1 = iter: {
            var iter = req_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("Foo");
            try msg.writer.flush();
            try req_pipe1.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
            break:send_req;
        }

        // Receive with Poller
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        const PollCallback = struct {
            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(1, p.ready_set.count());
                try std.testing.expectEqual(0, p.in_fight_set.count());

                try std.testing.expectEqual(p.ready_set.count(), results.len);
                reply: {
                    for (results) |result| {
                        switch (result) {
                            .failed => |x| return x.err,
                            .ready => |channel| {
                                var msg = try channel.receiver().tryDrain(.{}) orelse unreachable;
                                msg.writer.advance(msg.len());
                                try msg.writer.writeAll("Baz");
                                try msg.writer.flush();
                                try channel.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
                            }
                        }
                    }
                    break:reply;
                }
            }
        };

        try TestPoller.Sync.attach(&poller, &rep_socket.pipe);
        _ = try poller.poll(PollCallback.replyMsg);

        receive_msg: {
            var msg = try req_pipe1.receiver().withOpt(.{ .flags = .{ .nonblocking = false }}).drain();
            defer msg.deinit();
            try std.testing.expectEqualStrings("FooBaz", msg.bytes());
            break:receive_msg;
        }
    }

    test "receive mesg from poller with parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start(.{});
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.parallel(1).as_dialer(url);
        };
        try req_socket2.transport.start(.{});
        defer req_socket2.close();

        // get send pipe
        var req_pipe1 = iter: {
            var iter = req_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var req_pipe2 = iter: {
            var iter = req_socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("Foo");
            try msg.writer.flush();
            try req_pipe1.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
            break:send_req;
        }

        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("Bar");
            try msg.writer.flush();
            try req_pipe2.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
            break:send_req;
        }

        const PollCallback = struct {
            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(3, p.ready_set.count() + p.in_fight_set.count());

                test_unique_id: {
                    var iter = p.ready_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.in_fight_set.contains(id.*));
                        break:test_unique_id;
                    }
                }
                test_unique_id: {
                    var iter = p.in_fight_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.ready_set.contains(id.*));
                        break:test_unique_id;
                    }
                }

                try std.testing.expectEqual(p.ready_set.count(), results.len);
                reply: {
                    for (results) |result| {
                        switch (result) {
                            .failed => |x| return x.err,
                            .ready => |channel| {
                                var msg = try channel.receiver().tryDrain(.{}) orelse unreachable;
                                msg.writer.advance(msg.len());
                                try msg.writer.writeAll("Baz");
                                try msg.writer.flush();
                                try channel.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
                            }
                        }
                    }
                    break:reply;
                }
            }
        };

        // Receive with Poller
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        try TestPoller.Parallel.attach(&poller, &rep_socket.pipe);

        var accept: usize = 0;
        while (accept < 2) {
            accept += try poller.poll(PollCallback.replyMsg);
        }

        receive_msg: {
            var msg = try req_pipe1.receiver().withOpt(.{ .flags = .{ .nonblocking = false }}).drain();
            defer msg.deinit();
            try std.testing.expectEqualStrings("FooBaz", msg.bytes());
            break:receive_msg;
        }
        receive_msg: {
            var msg = try req_pipe2.receiver().withOpt(.{ .flags = .{ .nonblocking = false }}).drain();
            defer msg.deinit();
            try std.testing.expectEqualStrings("BarBaz", msg.bytes());
            break:receive_msg;
        }
    }

    test "receive msg from poller with parallel pipe (over logical CPUs)" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        const cpus = try std.Thread.getCpuCount();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.parallel(cpus * 2).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start(.{});
        defer req_socket1.close();

        send_msg: {
            var msg = try Message.create();
            try msg.writer.writeAll("Hello World");
            try msg.writer.flush();
            try req_socket1.pipe.item.sender().submit(msg, .{});
            break:send_msg;
        }

        const PollCallback = struct {
            poller: TestPoller,
            tasks: usize,
            called: bool = false,

            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                const self: *@This() = @fieldParentPtr("poller", p);

                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(self.tasks, p.ready_set.count() + p.in_fight_set.count());

                try std.testing.expectEqual(1, results.len);
                try std.testing.expectEqual(.ready, std.meta.activeTag(results[0]));

                var msg = try results[0].ready.receiver().tryDrain(.{}) orelse unreachable;
                try std.testing.expectEqualStrings("Hello World", msg.bytes());

                msg.writer.advance(msg.len());
                try msg.writer.writeAll("!!");
                try msg.writer.flush();
                try results[0].ready.sender().submit(msg, .{});
                self.called = true;
            }
        };

        var cb: PollCallback = .{ .poller = try TestPoller.create(ctx), .tasks = cpus * 2 };
        defer cb.poller.deinit();

        try TestPoller.Parallel.attach(&cb.poller, &rep_socket.pipe);
        try std.testing.expectEqual(cpus * 2, cb.poller.poller_pipes.count());
        try std.testing.expectEqual(cpus * 2, cb.poller.ready_set.count());
        try std.testing.expectEqual(0, cb.poller.in_fight_set.count());

        const n = try cb.poller.poll(PollCallback.replyMsg);
        try std.testing.expectEqual(1, n);
        try std.testing.expectEqual(true, cb.called);

        var msg = try req_socket1.pipe.item.receiver().drain();
        defer msg.deinit();
        try std.testing.expectEqualStrings("Hello World!!", msg.bytes());
    }

    test "one to many communication about REQ/REP" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.Rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start(.{});
        defer req_socket1.close();

        // get send pipe
        var req_pipe1 = req_socket1.pipe.item;

        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("Foo");
            try msg.writer.flush();
            try req_pipe1.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
            break:send_req;
        }

        const PollCallback = struct {
            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(1, p.ready_set.count());
                try std.testing.expectEqual(2, p.in_fight_set.count());

                test_unique_id: {
                    var iter = p.ready_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.in_fight_set.contains(id.*));
                        break:test_unique_id;
                    }
                }
                test_unique_id: {
                    var iter = p.in_fight_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.ready_set.contains(id.*));
                        break:test_unique_id;
                    }
                }

                try std.testing.expectEqual(p.ready_set.count(), results.len);
                 reply: {
                    for (results) |result| {
                        switch (result) {
                            .failed => |x| return x.err,
                            .ready => |channel| {
                                var msg = try channel.receiver().tryDrain(.{}) orelse unreachable;
                                msg.writer.advance(msg.len());
                                try msg.writer.writeAll("Baz");
                                try msg.writer.flush();
                                try channel.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
                            }
                        }
                    }
                    break:reply;
                }
            }
        };

        // Receive with Poller
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        try TestPoller.Parallel.attach(&poller, &rep_socket.pipe);

        const accept= try poller.poll(PollCallback.replyMsg);
        try std.testing.expectEqual(1, accept);

        receive_msg: {
            var msg = try req_pipe1.receiver().withOpt(.{ .flags = .{ .nonblocking = false }}).drain();
            defer msg.deinit();
            try std.testing.expectEqualStrings("FooBaz", msg.bytes());
            break:receive_msg;
        }
    }

    test "receive batch msg from poller about PUSH/PULL" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open PULL socket
        var pull_socket = socket: {
            var b = try root.Pull.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pull_socket.transport.start(.{});
        defer pull_socket.close();

        // Open PUSH socket
        var push_socket = socket: {
            var b = try root.Push.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try push_socket.transport.start(.{.nonblocking = false});
        defer push_socket.close();

        // get send pipe
        var push_pipe = push_socket.pipe.item;

        const sender = push_pipe.sender();
        send: {
            const g = sender.lock();
            defer g.unlock();

            var msg = try Message.create();
            try msg.writer.writeAll("Foo");
            try msg.writer.flush();
            try sender.submit(msg, .{ .flags = .{.nonblocking = false }});
            break:send;
        }
        send: {
            const g = sender.lock();
            defer g.unlock();

            var msg = try Message.create();
            try msg.writer.writeAll("Bar");
            try msg.writer.flush();
            try sender.submit(msg, .{ .flags = .{.nonblocking = false }});
            break:send;
        }

        const PollCallback = struct {
            allocator: std.mem.Allocator,
            poller: TestPoller,
            receive_queue: std.Deque(Message),

            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                const self: *@This() = @alignCast(@fieldParentPtr("poller", p));
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(1, p.ready_set.count() + p.in_fight_set.count());

                test_unique_id: {
                    var iter = p.ready_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.in_fight_set.contains(id.*));
                        break:test_unique_id;
                    }
                }
                test_unique_id: {
                    var iter = p.in_fight_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.ready_set.contains(id.*));
                        break:test_unique_id;
                    }
                }                
                try std.testing.expectEqual(p.ready_set.count(), results.len);
                received: {
                    for (results) |result| {
                        try std.testing.expectEqual(.ready, std.meta.activeTag(result));
                        const receiver = result.ready.receiver();
                        while (try receiver.tryDrain(.{})) |msg| {
                            try self.receive_queue.pushBack(self.allocator, msg);
                        }
                    }
                    break:received;
                }
            }
        };

        var cb: PollCallback = .{
            .allocator = std.testing.allocator,
            .poller = try TestPoller.create(ctx),
            .receive_queue = .empty,
        };
        defer cb.poller.deinit();
        defer cb.receive_queue.deinit(std.testing.allocator);

        try TestPoller.Sync.attach(&cb.poller, &pull_socket.pipe);
        _ = try cb.poller.poll(PollCallback.replyMsg);

        try std.testing.expectEqual(2, cb.receive_queue.len);
        pop_msg: {
            var msg = cb.receive_queue.popFront() orelse unreachable;
            defer msg.deinit();
            try std.testing.expectEqualStrings("Foo", msg.bytes());
            break:pop_msg;
        }
        pop_msg: {
            var msg = cb.receive_queue.popFront() orelse unreachable;
            defer msg.deinit();
            try std.testing.expectEqualStrings("Bar", msg.bytes());
            break:pop_msg;
        }
    }

    test "one to many communication about PUB/SUB" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var sub_socket = socket: {
            var b = try root.Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        var view = sub_socket.subscriptionView();
        try view.subscribe("topic");

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // Open REQ socket
        var pub_socket1 = socket: {
            var b = try root.Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // get send pipe
        var pub_pipe1 = pub_socket1.pipe.item;

        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("topic|Foo");
            try msg.writer.flush();
            try pub_pipe1.sender().submit(msg, .{ .flags = .{.nonblocking = true }});
            break:send_req;
        }

        const PollCallback = struct {
            pub fn replyMsg(p: *TestPoller, results: []const PollEvent) anyerror!void {
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(3, p.ready_set.count() + p.in_fight_set.count());

                test_unique_id: {
                    var iter = p.ready_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.in_fight_set.contains(id.*));
                        break:test_unique_id;
                    }
                }
                test_unique_id: {
                    var iter = p.in_fight_set.keyIterator();
                    while (iter.next()) |id| {
                        try std.testing.expectEqual(false, p.ready_set.contains(id.*));
                        break:test_unique_id;
                    }
                }

                try std.testing.expectEqual(p.ready_set.count(), results.len);
                received: {
                    for (results) |result| {
                        try std.testing.expectEqual(.ready, std.meta.activeTag(result));

                        var msg = try result.ready.receiver().tryDrain(.{}) orelse unreachable;
                        defer msg.deinit();
                        try std.testing.expectEqualStrings("topic|Foo", msg.bytes());
                    }
                    break:received;
                }
            }
        };

        // Receive with Poller
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        try TestPoller.Parallel.attach(&poller, &sub_socket.pipe);

        var accept: usize = 0;
        while (accept < 3) {
            accept += try poller.poll(PollCallback.replyMsg);
        }
        try std.testing.expectEqual(3, accept);
    }

    test "cancel receive on poller" {

    }
};
