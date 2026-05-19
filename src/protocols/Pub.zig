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

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open SUB

        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // Open PUB

        var pub_socket: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();
    }

    test "PUB socket features for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open SUB socket

        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // Open PUB socket

        var socket: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

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

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // PUB socket
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var sub_pipe = iter: {
            var iter = sub_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        var msg = try Message.create();
        defer msg.deinit();

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

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };

        var view = sub_socket.subscriptionView();
        try view.enableWildcard();

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // PUB socket#1
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // PUB socket#2
        var pub_socket2: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket2.transport.start(.{});
        defer pub_socket2.close();

        // get pipe
        const pub_pipe1 = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const pub_pipe2 = iter: {
            var iter = pub_socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const sub_pipe = iter: {
            var iter = sub_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe1.sender().submit(msg, .{});
            break:send_PUB_1;
        }

        recv_sub: {
            var msg = try sub_pipe.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("greeting|Hello", v);
            break:recv_sub;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe2.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_sub: {
            var msg = try sub_pipe.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub;
        }
    }

    test "Apply sbscription filter" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open SUB socket
        var sub_protocol: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        var view = sub_protocol.subscriptionView();
        try view.subscribe("hobby");
        try sub_protocol.transport.start(.{});
        defer sub_protocol.close();

        // open PUB socket#1
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // open PUB socket#2
        var pub_socket2: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket2.transport.start(.{});
        defer pub_socket2.close();

        // get pipe
        const pub_pipe1 = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const pub_pipe2 = iter: {
            var iter = pub_socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const sub_pipe = iter: {
            var iter = sub_protocol.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe1.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_sub: {
            const msg = sub_pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe2.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_sub: {
            var msg = try sub_pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub;
        }
    }

    test "wildcard dominance" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };

        var view = sub_socket.subscriptionView();
        try view.enableWildcard();
        try view.subscribe("greeting");

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // PUB socket
        var pub_socket: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket.transport.start(.{});
        defer pub_socket.close();

        // get pipe
        const pub_pipe = iter: {
            var iter = pub_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const sub_pipe = iter: {
            var iter = sub_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_sub: {
            var msg = try sub_pipe.receiver().drain(.{});
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub;
        }
    }

    test "unsubscribe sanity" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        var view = sub_socket.subscriptionView();
        try view.subscribe("greeting");
        try view.unsubscribe("greeting");
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // PUB socket
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var sub_pipe = iter: {
            var iter = sub_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        var msg = try Message.create();
        defer msg.deinit();

        // PUB (send)
        const v0 = "greeting|Hello";
        try msg.writer.writeAll(v0);
        try msg.writer.flush(); // Need to sync written length
        try pub_pipe.sender().submit(msg, .{});

        // SUB (recv)
        const recv_msg = sub_pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMicroseconds(10)});
        try std.testing.expectError(error.Timeout, recv_msg);
    }

    test "Wildcard for prallel pipe lane" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(2).as_listener(url);
        };

        var view = sub_socket.subscriptionView().lane_at(1);
        try view.enableWildcard();

        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        // PUB socket#1
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // PUB socket#2
        var pub_socket2: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket2.transport.start(.{});
        defer pub_socket2.close();

        // get pipe
        var pub_pipe1 = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var pub_pipe2 = iter: {
            var iter = pub_socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var sub_pipe1 = iter: {
            break:iter sub_socket.pipe.items[0];
        };
        var sub_pipe2 = iter: {
            break:iter sub_socket.pipe.items[1];
        };

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe1.sender().submit(msg, .{});
            break:send_PUB_1;
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

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe2.sender().submit(msg, .{});
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
    }

    test "Apply subscription filter for prallel pipe lane" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open SUB socket
        var sub_protocol: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        var view = sub_protocol.subscriptionView().lane_at(1);
        try view.subscribe("hobby");
        try sub_protocol.transport.start(.{});
        defer sub_protocol.close();

        // open PUB socket#1
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        // open PUB socket#2
        var pub_socket2: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket2.transport.start(.{});
        defer pub_socket2.close();

        // get pipe
        const pub_pipe1 = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        const pub_pipe2 = iter: {
            var iter = pub_socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var sub_pipe1 = iter: {
            break:iter sub_protocol.pipe.items[0];
        };
        var sub_pipe2 = iter: {
            break:iter sub_protocol.pipe.items[1];
        };

        send_PUB_1: {
            var msg = try Message.create();
            const v0 = "greeting|Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe1.sender().submit(msg, .{});
            break:send_PUB_1;
        }
        recv_sub_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_1;
        }
        recv_sub_2: {
            const msg = sub_pipe2.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_2;
        }

        send_PUB_2: {
            var msg = try Message.create();
            const v0 = "hobby|Soccor";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pub_pipe2.sender().submit(msg, .{});
            break:send_PUB_2;
        }
        recv_sub_1: {
            const msg = sub_pipe1.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_1;
        }
        recv_sub_2: {
            var msg = try sub_pipe2.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            defer msg.deinit();
            const v = msg.bytes();
            try std.testing.expectEqualStrings("hobby|Soccor", v);
            break:recv_sub_2;
        }
    }

    test "Unsubscription sanity for prallel pipe lane" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // SUB socket
        var sub_socket: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        var view = sub_socket.subscriptionView();
        try view.subscribe("greeting");
        try view.unsubscribe("greeting");
        try sub_socket.transport.start(.{});
        defer sub_socket.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // PUB socket
        var pub_socket1: Pub.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pub.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try pub_socket1.transport.start(.{});
        defer pub_socket1.close();

        try test_support.waitPipeReady(std.testing.io, sub_socket.transport.socket);

        // get pipe
        var pub_pipe = iter: {
            var iter = pub_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var sub_pipe1 = iter: {
            break:iter sub_socket.pipe.items[0];
        };
        var sub_pipe2 = iter: {
            break:iter sub_socket.pipe.items[1];
        };

        send_PUB: {
            var msg = try Message.create();
            defer msg.deinit();

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
            const msg = sub_pipe2.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:recv_sub_2;
        }
    }
};
