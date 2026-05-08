const std = @import("std");
const root = @import("../root.zig");
const pipe_impl = @import("../socket/pipe_impls.zig");
const poller_impl = @import("./poller_impls.zig");

const Context = root.Context;
const Pipe = root.Pipe;
const Sender = @import("../message/Sender.zig");
const Receiver = @import("../message/Receiver.zig");
const Message = root.Message;
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;

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

            const channels = try self.context.allocator.alloc(ReadyChannel, self.ready_set.count());
            defer self.context.allocator.free(channels);

            var i: usize = 0;
            while (ready_iter.next()) |id| {
                if (self.in_fight_set.contains(id.*)) continue;
                if (self.skip_set.contains(id.*)) continue;

                if (self.poller_pipes.get(id.*)) |pipe| {
                    try self.in_fight_set.put(id.*, {});
                    self.tasks.attach(id.*, pipe, &channels[i]);
                    i += 1;
                }
            }
            self.ready_set.clearRetainingCapacity();

            std.debug.assert(self.ready_set.count() == 0);

            var wakeups: [buffer_size]WakeupResult = undefined;
            const count = try self.tasks.poll(&wakeups);

            for (wakeups[0..count]) |result| {
                if (std.meta.activeTag(result.event) == .ready) {
                    // reset in-fight set (ready channel only)
                    _ = self.in_fight_set.remove(result.event.ready.id);

                    // ready pipe
                    if (result.event.ready.features.receive_first) {
                        try self.ready_set.put(result.event.ready.id, {});
                    }
                }
            }

            // reset skip-set
            var skip_iter = self.skip_set.keyIterator();
            while(skip_iter.next()) |id| {
                try self.ready_set.put(id.*, {});
            }

            try callback(self, wakeups[0..count]);

            return count;
        }

        pub fn cancel(self: *Poller, id: u64) void {
            if (self.poller_pipes.get(id)) |pipe| {
                std.log.debug("Poller:cancel/id: {}", .{id});
                pipe.cancel();
            }
        }

        pub fn terminate(self: *Poller) void {
            var iter = self.in_fight_set.keyIterator();
            while (iter.next()) |id| {
                self.cancel(id.*);
            }
        }

        fn attachInternal(self: *Poller, id: u64, channel: poller_impl.PollerPipe) !void {
            if (self.ready_set.contains(id) or self.in_fight_set.contains(id)) {
                std.log.warn("Poller:already attached/id: {}", .{id});
                return;
            }

            std.log.debug("Poller:attach/id: {}", .{id});

            try self.poller_pipes.put(id, channel);

            if (channel.features.receive_first) {
                try self.ready_set.put(id, {});
            }
        }

        pub const Sync = struct {
            pub fn attach(poller: *Poller, pipe: *Pipe.Sync) !void {
                var iter = pipe.iter();
                while (iter.next()) |p| {
                    const channel: poller_impl.PollerPipe = .{
                        .owner = p,
                        .vtable = .{
                            .on_wait_complete = poller_impl.PollerPipeImpl.Sync.waitComplete,
                            .on_cancel = poller_impl.PollerPipeImpl.Sync.cancelSession,
                        },
                        .features = p.features,
                    };

                    try poller.attachInternal(p.id, channel);
                }
            }
        };

        pub const Parallel = struct {
            pub fn attach(poller: *Poller, pipe: *Pipe.Parallel) !void {
                var iter = pipe.iter();
                while (iter.next()) |p| {
                    const channel: poller_impl.PollerPipe = .{
                        .owner = p,
                        .vtable = .{
                            .on_wait_complete = poller_impl.PollerPipeImpl.Parallel.waitComplete,
                            .on_cancel = poller_impl.PollerPipeImpl.Parallel.cancelSession,
                        },
                        .features = p.features,
                    };

                    try poller.attachInternal(p.id, channel);
                }
            }
        };

        pub const WakeupResult = union {
            event: PollEvent,
        };

        pub const WakeupCallback = *const fn (poller: *Poller, channels: []const Poller.WakeupResult) anyerror!void;

        //
        // Internal implementations
        //

       const PollerTaskImpl = struct {
           select: std.Io.Select(WakeupResult),
           select_buffer: [buffer_size]WakeupResult = undefined,

           fn init(context: Context) !*PollerTaskImpl {
               var self = try context.allocator.create(PollerTaskImpl);
               self.* = .{
                   .select = std.Io.Select(WakeupResult).init(context.io, &self.select_buffer),
               };

               return self;
           }

           fn deinit(self: *PollerTaskImpl, allocator: std.mem.Allocator) void {
               allocator.destroy(self);
           }

           fn attach(self: *PollerTaskImpl, id: u64, pipe: poller_impl.PollerPipe, channel: *ReadyChannel) void {
               self.select.async(.event, doReceive, .{ id, pipe, channel });
           }

           fn poll(self: *PollerTaskImpl, wakeups: []WakeupResult) !usize {
               return self.select.awaitMany(wakeups, 1);
           }
       };
    };
}

fn doReceive(id: u64, pipe: poller_impl.PollerPipe, channel: *ReadyChannel) PollEvent {
    pipe.wait(channel)
    catch |err| return .{
        .failed = .{ .id = id, .err = err },
    };

    return .{
        .ready = channel.*
    };
}



pub const PollEvent = union(enum) {
    ready: ReadyChannel,
    failed: struct {
        id: u64,
        err: ReceiveError,
    },
};

pub fn mark_ready() !void {
    unreachable;
}

pub fn mark_skip() !void {
    unreachable;
}

pub const Timeout = union {
    unlimited: void,
    msec: u64,
};

pub const ReadyChannel = struct {
    id: u64,
    impl: poller_impl.PollerPipeImpl,
    vtable: struct {
        on_submit: *const fn (sender: *const Sender, msg: Message, options: Sender.Options) SendError!void,
        on_drain: *const fn (receiver: *const Receiver, options: Receiver.Options) ReceiveError!Message,
    },
    features: Pipe.Features,

    pub fn sender(self: *const ReadyChannel) Sender {
        switch (self.impl) {
            .sync => |*impl| {
                return .{
                    .owner = impl,
                    .on_submit = self.vtable.on_submit,
                };
            },
            .parallel => |*impl| {
                return .{
                    .owner = impl,
                    .on_submit = self.vtable.on_submit,
                };
            },
        }
    }

    pub fn receiver(self: *const ReadyChannel) Receiver {
        switch (self.impl) {
            .sync => |*impl| {
                return .{
                    .owner = impl,
                    .on_drain = self.vtable.on_drain,
                };
            },
            .parallel => |*impl| {
                return .{
                    .owner = impl,
                    .on_drain = self.vtable.on_drain,
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
        try rep_socket.transport.start();
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
        try rep_socket.transport.start();
        defer rep_socket.close();

        try TestPoller.Parallel.attach(&poller, &rep_socket.pipe);
        try std.testing.expectEqual(3, poller.poller_pipes.count());
        try std.testing.expectEqual(3, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "new receive poller with sync REQ pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try TestPoller.create(ctx);
        defer poller.deinit();

        // Open REQ#2 socket
        var req_socket = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket.transport.start();
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

        // Open REQ#2 socket
        var req_socket = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.parallel(3).as_dialer(url);
        };
        try req_socket.transport.start();
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
        try rep_socket.transport.start();
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start();
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket2.transport.start();
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
            pub fn replyMsg(p: *TestPoller, results: []const TestPoller.WakeupResult) anyerror!void {
                try std.testing.expectEqual(0, p.skip_set.count());
                try std.testing.expectEqual(1, p.ready_set.count());
                try std.testing.expectEqual(0, p.in_fight_set.count());

                try std.testing.expectEqual(p.ready_set.count(), results.len);
                reply: {
                    for (results) |result| {
                        const event = result.event;
                        switch (event) {
                            .failed => |x| return x.err,
                            .ready => |channel| {
                                var msg = try channel.receiver().drain(.{});
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
            var msg = try req_pipe1.receiver().drain(.{ .flags = .{ .nonblocking = false }});
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
        try rep_socket.transport.start();
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start();
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.Req.open(ctx);
            break:socket try b.parallel(1).as_dialer(url);
        };
        try req_socket2.transport.start();
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
            pub fn replyMsg(p: *TestPoller, results: []const TestPoller.WakeupResult) anyerror!void {
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
                        const event = result.event;
                        switch (event) {
                            .failed => |x| return x.err,
                            .ready => |channel| {
                                var msg = try channel.receiver().drain(.{});
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
            var msg = try req_pipe1.receiver().drain(.{ .flags = .{ .nonblocking = false }});
            defer msg.deinit();
            try std.testing.expectEqualStrings("FooBaz", msg.bytes());
            break:receive_msg;
        }
        receive_msg: {
            var msg = try req_pipe2.receiver().drain(.{ .flags = .{ .nonblocking = false }});
            defer msg.deinit();
            try std.testing.expectEqualStrings("BarBaz", msg.bytes());
            break:receive_msg;
        }
    }

    test "cance receive on poller" {

    }

    test "terminate poller" {

    }
};
