const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Req = @This();

const Context = root.Context;
const Socket = root.Socket;
const Transport = root.Transport;
const Pipe = root.Pipe;
const OpenError = root.OpenError;
const CloseError = root.CloseError;

const comptime_feature: Socket.ComptimeFeature = .{
    .protocol_name = @typeName(@This()),
};

/// Creates a REQ protocol socket instance.
/// This is the primary way to construct the type.
pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Req.Protocol, comptime_feature) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_req0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    const socket = Socket.init(ctx, raw_socket);
    const features: Pipe.Features = .{
        .send_first = true,
        .last_msg_owner = true,
    };

    return Socket.SyncBuilder(Req.Protocol, comptime_feature).init(socket, features);
}

/// REQ protocol type.
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

test "REQ tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const Rep = @import("./Rep.zig");
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new REQ socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var socket = socket: {
            var b = try Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket.transport.start(.{});
        defer socket.close();
    }

    test "REQ socket features for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var socket = socket: {
            var b = try Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var iter = socket.pipe.iter();
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqual(Pipe.Features{.send_first = true, .last_msg_owner = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe == null);
            break:pipe;
        }
    }

    test "REQ socket features for parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var socket = socket: {
            var b = try Req.open(ctx);
            break:socket try b.parallel(2).as_dialer(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var iter = socket.pipe.iter();
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqual(Pipe.Features{.send_first = true, .last_msg_owner = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqual(Pipe.Features{.send_first = true, .last_msg_owner = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe == null);
            break:pipe;
        }
    }

    test "REQ/REP communication" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket: Req.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket.transport.start(.{});
        defer req_socket.close();

        // get pipe
        var req_pipe = iter: {
            var iter = req_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var rep_pipe = iter: {
            var iter = rep_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        var msg = try Message.create();
        defer msg.deinit();

        //
        // One-way path
        //

        // REQ (send)
        const v0 = "Hello";
        try msg.writer.writeAll(v0);
        try msg.writer.flush(); // Need to sync written length
        try req_pipe.sender().submit(msg, .{});

        // REP (recv)
        msg = try rep_pipe.receiver().drain(.{});

        const v1 = try std.testing.allocator.dupe(u8, msg.bytes()); // Prevent in-place overwrite of the source buffer during write.
        defer std.testing.allocator.free(v1);
        try std.testing.expectEqualStrings(v0, v1);

        //
        // Return path
        //

        // REP (send)
        msg.writer.end = 0;
        try msg.writer.print("{s}{s}", .{ v1, v1 });
        try msg.writer.flush();
        try rep_pipe.sender().submit(msg, .{});

        // REQ (recv)
        msg = try req_pipe.receiver().drain(.{});
        const v2 = msg.bytes();
        try std.testing.expectEqualStrings("HelloHello", v2);
    }

    test "REQ/REP parallel communication" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ#1 socket
        var req_socket1: Req.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start(.{});
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2: Req.Protocol(Transport.Dialer, Pipe.Parallel) = socket: {
            var b = try Req.open(ctx);
            break:socket try b.parallel(2).as_dialer(url);
        };
        try req_socket2.transport.start(.{});
        defer req_socket2.close();

        var msgs: [3]Message = .{ try Message.create(), try Message.create(), try Message.create() };
        defer {
            for (&msgs) |*msg| msg.deinit();
        }

        // get REQ pipes
        var req_pipe0 = iter: {
            var iter = req_socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var req_pipe1, var req_pipe2 = iter: {
            var iter = req_socket2.pipe.iter();
            break:iter .{
                iter.next() orelse unreachable,
                iter.next() orelse unreachable,
            };
        };

        //
        // One-way path
        //

        const v0 = &.{ "Fizz", "Buzz", "FizzBuzz" };

        send_REQ_0: {
            try msgs[0].writer.writeAll(v0[0]);
            try msgs[0].writer.flush(); // Need to sync written length
            try req_pipe0.sender().submit(msgs[0], .{});
            break:send_REQ_0;
        }
        send_REQ_1: {
            try msgs[1].writer.writeAll(v0[1]);
            try msgs[1].writer.flush(); // Need to sync written length
            try req_pipe1.sender().submit(msgs[1], .{});
            break:send_REQ_1;
        }
        send_REQ_2: {
            try msgs[2].writer.writeAll(v0[2]);
            try msgs[2].writer.flush(); // Need to sync written length
            try req_pipe2.sender().submit(msgs[2], .{});
            break:send_REQ_2;
        }

        replying: {
            var iter = rep_socket.pipe.iter();
            while (iter.next()) |p| {
                var msg = try p.receiver().drain(.{});
                const v1 = try std.testing.allocator.dupe(u8, msg.bytes());
                defer std.testing.allocator.free(v1);

                msg.writer.end = 0;
                try msg.writer.print("Fizz{s}", .{v1});
                try msg.writer.flush();
                try p.sender().submit(msg, .{});
            }
            break:replying;
        }

        //
        // Return path
        //

        receive_REQ_0: {
            const msg = try req_pipe0.receiver().drain(.{});
            const v2 = msg.bytes();
            try std.testing.expectEqualSlices(u8, "FizzFizz", v2);
            break:receive_REQ_0;
        }
        receive_REQ_1: {
            const msg = try req_pipe1.receiver().drain(.{});
            const v2 = msg.bytes();
            try std.testing.expectEqualSlices(u8, "FizzBuzz", v2);
            break:receive_REQ_1;
        }
        receive_REQ_2: {
            const msg = try req_pipe2.receiver().drain(.{});
            const v2 = msg.bytes();
            try std.testing.expectEqualSlices(u8, "FizzFizzBuzz", v2);
            break:receive_REQ_2;
        }
    }

    test "REP receive timeout for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        var pipe = rep_socket.pipe.item;
        timeout: {
            const msg = pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:timeout;
        }
        timeout: {
            const msg = pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(20), .flags = .{ .nonblocking = true } });
            try std.testing.expectError(error.WouldBlock, msg);
            break:timeout;
        }
    }

    test "REP receive timeout for parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        var pipe = rep_socket.pipe.items[1];
        timeout: {
            const msg = pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, msg);
            break:timeout;
        }
        timeout: {
            const msg = pipe.receiver().drain(.{ .timeout = std.Io.Duration.fromMilliseconds(20), .flags = .{ .nonblocking = true } });
            try std.testing.expectError(error.WouldBlock, msg);
            break:timeout;
        }
    }

    test "cancel comminication for sync" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: Rep.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start(.{});
        defer rep_socket.close();

        // Open REQ socket
        var req_socket: Req.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Req.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket.transport.start(.{});
        defer req_socket.close();

        // get pipe
        var req_pipe = iter: {
            var iter = req_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var rep_pipe = iter: {
            var iter = rep_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        var msg = try Message.create();
        defer msg.deinit();

        send_req: {
            try msg.writer.writeAll("Hello");
            try msg.writer.flush();
            try req_pipe.sender().submit(msg, .{});
            break:send_req;
        }
        reply_rep: {
            msg = try rep_pipe.receiver().drain(.{});
            msg.writer.end = 0;
            try msg.writer.writeAll("World");
            try msg.writer.flush();
            try rep_pipe.sender().submit(msg, .{});
            break:reply_rep;
        }
        cancel_rec: {
            try req_pipe.cancel(.{});
            break:cancel_rec;
        }
    }
};
