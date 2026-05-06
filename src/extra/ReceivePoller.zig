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

context: Context,
poller_pipes: std.AutoHashMap(u64, poller_impl.PollerPipe),
skip_set: std.AutoHashMap(u64, void),
ready_set: std.AutoHashMap(u64, void),
in_fight_set: std.AutoHashMap(u64, void),
tasks: std.Io.Select(WakeupResult),
select_buffer: []WakeupResult,

const Self = @This();
const Poller = Self;

pub fn create(context: Context, buffer_size: u16) !Self {
    const buffer = try context.allocator.alloc(WakeupResult, @intCast(buffer_size));

    return .{
        .context = context,
        .poller_pipes = .init(context.allocator),
        .skip_set = .init(context.allocator),
        .ready_set = .init(context.allocator),
        .in_fight_set = .init(context.allocator),
        .tasks = std.Io.Select(WakeupResult).init(context.io, buffer),
        .select_buffer = buffer,
    };
}

pub fn deinit(self: *Self) void {
    self.terminate();
    self.poller_pipes.deinit();
    self.skip_set.deinit();
    self.ready_set.deinit();
    self.in_fight_set.deinit();
    self.context.allocator.free(self.select_buffer);
}

/// Runs the event loop.
///
/// This function is not reentrant.
/// It must not be called concurrently on the same Poller instance.
///
/// Behavior is undefined if re-entered.
///
pub fn poll(self: *Self, callback: WakeupCallback) !usize {
    var ready_iter = self.ready_set.keyIterator();

    const channels = try self.context.allocator.alloc(ReadyChannel, self.ready_set.count());
    defer self.context.allocator.free(channels);

    var i: usize = 0;
    while (ready_iter.next()) |id| {
        if (self.in_fight_set.contains(id.*)) continue;
        if (self.skip_set.contains(id.*)) continue;

        if (self.poller_pipes.get(id.*)) |pipe| {
            try self.in_fight_set.put(id.*, {});
            self.tasks.async(.event, doReceive, .{ self, id.*, pipe, &channels[i] });
            i += 1;
        }
    }
    self.ready_set.clearRetainingCapacity();

    std.debug.assert(self.ready_set.count() == 0);

    const wakeups = try self.context.allocator.alloc(WakeupResult, self.poller_pipes.count());
    defer self.context.allocator.free(wakeups);

    const count = try self.tasks.awaitMany(wakeups, 1);

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

pub fn mark_ready() !void {
    unreachable;
}

pub fn mark_skip() !void {
    unreachable;
}

pub fn cancel(self: *Self, id: u64) void {
    if (self.poller_pipes.get(id)) |pipe| {
        std.log.debug("Poller:cancel/id: {}", .{id});
        pipe.cancel();
    }
}

pub fn terminate(self: *Self) void {
    var iter = self.in_fight_set.keyIterator();
    while (iter.next()) |id| {
        self.cancel(id.*);
    }
}

pub fn attach(poller: *Self, pipe: *Pipe.Parallel) !void {
    var iter = pipe.iter();
    while (iter.next()) |p| {
        const channel: poller_impl.PollerPipe = .{
            .owner = p,
            .vtable = .{
                .on_wait_complete = poller_impl.PollerPipeImpl.Parallel.wait_complete,
                .on_cancel = poller_impl.PollerPipeImpl.Parallel.cancel_session,
            },
            .features = p.features,
        };

        try poller.attachInternal(p.id, channel);
    }
}

fn attachInternal(self: *Self, id: u64, channel: poller_impl.PollerPipe) !void {
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

fn doReceive(poller: *Poller, id: u64, pipe: poller_impl.PollerPipe, channel: *ReadyChannel) PollEvent {
    _ = poller;

    pipe.wait(channel)
    catch |err| return .{
        .failed = .{ .id = id, .err = err },
    };

    return .{
        .ready = channel.*
    };
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
            .parallel => |*impl| {
                return .{
                    .owner = impl,
                    .on_drain = self.vtable.on_drain,
                };
            },
        }
    }
};

pub const PollEvent = union(enum) {
    ready: ReadyChannel,
    failed: struct {
        id: u64,
        err: ReceiveError,
    },
};

pub const WakeupResult = union {
    event: Poller.PollEvent,
};

pub const WakeupCallback = *const fn (poller: *Poller, channels: []const Poller.WakeupResult) anyerror!void;

test "Poller tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const test_support = @import("../supports/test.zig");

    test "new receive poller with receiving parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try Poller.create(ctx, 64);
        defer poller.deinit();

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start();
        defer rep_socket.close();

        try poller.attach(&rep_socket.pipe);
        try std.testing.expectEqual(3, poller.poller_pipes.count());
        try std.testing.expectEqual(3, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "new receive poller with parallel REQ pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);
        var poller = try Poller.create(ctx, 64);
        defer poller.deinit();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.req.open(ctx);
            break:socket try b.parallel(3).as_dialer(url);
        };
        try req_socket2.transport.start();
        defer req_socket2.close();

        try poller.attach(&req_socket2.pipe);
        try std.testing.expectEqual(3, poller.poller_pipes.count());
        try std.testing.expectEqual(0, poller.ready_set.count());
        try std.testing.expectEqual(0, poller.in_fight_set.count());
    }

    test "receive mesg from poller with parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = root.Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket = socket: {
            var b = try root.rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start();
        defer rep_socket.close();

        // Open REQ socket
        var req_socket1 = socket: {
            var b = try root.req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start();
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2 = socket: {
            var b = try root.req.open(ctx);
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
            try req_pipe1.sender().submit(msg, .{ .nonblocking = true });
            break:send_req;
        }

        send_req: {
            var msg = try Message.create();
            try msg.writer.writeAll("Bar");
            try msg.writer.flush();
            try req_pipe2.sender().submit(msg, .{ .nonblocking = true });
            break:send_req;
        }

        const PollCallback = struct {
            pub fn replyMsg(p: *Poller, results: []const Poller.WakeupResult) anyerror!void {
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
                                try channel.sender().submit(msg, .{ .nonblocking = true });
                            }
                        }
                    }
                    break:reply;
                }
            }
        };

        // Receive with Poller
        var poller = try Poller.create(ctx, 64);
        defer poller.deinit();

        try poller.attach(&rep_socket.pipe);

        var accept: usize = 0;
        while (accept < 2) {
            accept += try poller.poll(PollCallback.replyMsg);
        }

        receive_msg: {
            var msg = try req_pipe1.receiver().drain(.{ .nonblocking = false });
            defer msg.deinit();
            try std.testing.expectEqualStrings("FooBaz", msg.bytes());
            break:receive_msg;
        }
        receive_msg: {
            var msg = try req_pipe2.receiver().drain(.{ .nonblocking = false });
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
