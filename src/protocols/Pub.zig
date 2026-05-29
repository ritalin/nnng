const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Pub = @This();

const Context = root.Context;
const Socket = root.Socket;
const OpenError = root.OpenError;
const Transport = root.Transport;
const Pipe = root.Pipe;

const comptime_feature: Socket.ComptimeFeature = .{
    .protocol_name = @typeName(@This()),
    .forbid_parallel = true,
};

/// Creates a PUB protocol socket instance.
/// This is the primary way to construct the type.
pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Pub.Protocol, comptime_feature) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_pub0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    const socket = Socket.init(ctx, raw_socket);
    const features: Pipe.Features = .{
        .send_first = true,
    };

    return Socket.SyncBuilder(Pub.Protocol, comptime_feature).init(socket, features);
}

/// PUB protocol type.
/// Transport: connection role (Listener or Dialer).
/// Pipe: message handling model (Sync or Parallel).
pub fn Protocol(comptime TTransport: type, comptime TPipe: type) type {
    return struct {
        /// Transport role.
        transport: TTransport,
        /// Pipe model.
        pipe: TPipe,

        const Self = @This();

        /// Initializes the instance.
        /// Intended for internal use; prefer open().
        pub fn init(transport: TTransport, pipe: TPipe) Self {
            return .{
                .transport = transport,
                .pipe = pipe,
            };
        }

        /// Releases all associated resources.
        pub fn close(self: *Self) void {
            self.pipe.deinit();
            self.transport.deinit();
            self.transport.socket.close();
        }
    };
}

test "PUB tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const Sub = @import("./Sub.zig");
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new PUB socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PUB

        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // Open SUB

        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();
    }

    test "PUB socket features for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PUB socket

        var socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        // Open SUB socket

        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        var iter = socket.pipe.iter();
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqualDeep(Pipe.Features{ .send_first = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe == null);
            break:pipe;
        }
    }

    test "No sbscription" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket1: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // try test_support.waitPipeReady(std.testing.io, pub_socket.transport.socket);
        // try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = pub_socket1.pipe.item;
        var sub_pipe = sub_socket.pipe.item;

        var msg = try Message.create();

        // PUB (send)
        const v0 = "greeting|Hello";
        try msg.writer.writeAll(v0);
        try msg.writer.flush(); // Need to sync written length
        try pub_pipe.sender().submit(msg, .{});

        // SUB (recv)
        const recv_msg = sub_pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMicroseconds(10)});
        try std.testing.expectError(error.Timeout, recv_msg);
    }

    test "Wildcard sbscription" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // SUB socket#1
        var sub_socket_1: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket_1.subscriptionView();
            try view.enableWildcard();
            break:subscribe;
        }

        try sub_socket_1.transport.start(.{});
        defer sub_socket_1.close();

        // SUB socket#2
        var sub_socket_2: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket_2.subscriptionView();
            try view.enableWildcard();
            break:subscribe;
        }

        try sub_socket_2.transport.start(.{});
        defer sub_socket_2.close();

        // get pipe
        const pub_pipe = pub_socket.pipe.item;
        const sub_pipe1 = sub_socket_1.pipe.item;
        const sub_pipe2 = sub_socket_2.pipe.item;

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_SUB_1: {
            var msg = try sub_pipe1.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_SUB_1;
        }
        recv_SUB_2: {
            var msg = try sub_pipe2.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_SUB_2;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_SUB_1: {
            var msg = try sub_pipe1.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_SUB_1;
        }
        recv_SUB_2: {
            var msg = try sub_pipe2.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_SUB_2;
        }
    }

    test "Apply sbscription filter" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // open PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // Open SUB socket#1
        var sub_socket1: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket1.subscriptionView();
            try view.subscribe("hobby");
            break:subscribe;
        }
        try sub_socket1.transport.start(.{});
        defer sub_socket1.close();

        // open SUB socket#2
        var sub_socket2: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket2.subscriptionView();
            try view.subscribe("greeting");
            break:subscribe;
        }
        try sub_socket2.transport.start(.{});
        defer sub_socket2.close();

        // get pipe
        const pub_pipe = pub_socket.pipe.item;
        const sub_pipe1 = sub_socket1.pipe.item;
        const sub_pipe2 = sub_socket2.pipe.item;

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_SUB_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_SUB_1;
        }
        recv_SUB_2: {
            var msg = try sub_pipe2.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_SUB_2;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_SUB_1: {
            var msg = try sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_SUB_1;
        }
        recv_SUB_2: {
            const msg = sub_pipe2.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_SUB_2;
        }
    }

    test "wildcard dominance" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket.subscriptionView();
            try view.enableWildcard();
            try view.subscribe("greeting");
            break:subscribe;
        }

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        const pub_pipe = pub_socket.pipe.item;
        const sub_pipe = sub_socket.pipe.item;

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_SUB: {
            var msg = try sub_pipe.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_SUB;
        }
        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_SUB: {
            var msg = try sub_pipe.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_SUB;
        }
    }

    test "unsubscribe sanity" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        try test_support.waitPipeReady(std.testing.io, pub_socket.transport.socket);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        subscribe: {
            var view = sub_socket.subscriptionView();
            try view.subscribe("greeting");
            try view.unsubscribe("greeting");
            break:subscribe;
        }
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = pub_socket.pipe.item;
        var sub_pipe = sub_socket.pipe.item;

        var msg = try Message.create();

        send_PUB: {
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB;
        }
        recv_SUB: {
            const recv_msg = sub_pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMicroseconds(10)});
            try std.testing.expectError(error.Timeout, recv_msg);
            break:recv_SUB;
        }
    }

    test "Apply subscription filter for prallel pipe lane" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // SUB socket#1
        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_dialer(url);
        };
        subscribe_1: {
            // noop
            break:subscribe_1;
        }
        subscribe_2: {
            var view = sub_socket.subscriptionView().lane_at(1);
            try view.enableWildcard();
            break:subscribe_2;
        }
        subscribe_3: {
            var view = sub_socket.subscriptionView().lane_at(2);
            try view.subscribe("hobby");
            break:subscribe_3;
        }

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = pub_socket.pipe.item;
        var sub_pipe1 = sub_socket.pipe.items[0];
        var sub_pipe2 = sub_socket.pipe.items[1];
        var sub_pipe3 = sub_socket.pipe.items[2];

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_SUB_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_SUB_1;
        }
        recv_SUB_2: {
            var msg = try sub_pipe2.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_SUB_2;
        }
        recv_SUB_3: {
            const msg = sub_pipe3.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_SUB_3;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_sub_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_1;
        }
        recv_sub_2: {
            var msg = try sub_pipe2.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub_2;
        }
        recv_sub_3: {
            var msg = try sub_pipe3.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub_3;
        }
    }

    test "Unsubscription sanity for prallel pipe lane" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);
        defer test_support.cleanup();

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        try test_support.waitPipeReady(std.testing.io, pub_socket.transport.socket);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Dialer, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_dialer(url);
        };
        subscribe_1: {
            var view = sub_socket.subscriptionView().lane_at(0);
            try view.subscribe("greeting");
            try view.unsubscribe("greeting");
            break:subscribe_1;
        }
        subscribe_2: {
            var view = sub_socket.subscriptionView().lane_at(1);
            try view.subscribe("greeting");
            break:subscribe_2;
        }
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = pub_socket.pipe.item;
        var sub_pipe1 = sub_socket.pipe.items[0];
        var sub_pipe2 = sub_socket.pipe.items[1];

        send_PUB: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB;
        }

        recv_sub_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_1;
        }
        recv_sub_2: {
            var msg = try sub_pipe2.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_sub_2;
        }
    }
};
