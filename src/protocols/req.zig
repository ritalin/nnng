const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Context = root.Context;
const Socket = root.Socket;
const Transport = root.Transport;
const Pipe = root.Pipe;
const OpenError = root.OpenError;
const CloseError = root.CloseError;

pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Req) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_req0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    return Socket.SyncBuilder(Req).init(Socket.init(ctx, raw_socket));
}

pub fn Req(comptime TTransport: type, comptime TPipe: type) type {
    return struct {
        transport: TTransport,
        pipe: TPipe,

        const Self = @This();

        pub fn init(transport: TTransport, pipe: TPipe) Self {
            return .{
                .transport = transport,
                .pipe = pipe,
            };
        }

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
    const rep = @import("./rep.zig");
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new REQ socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket = socket: {
            var b = try open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket.transport.start();
        defer socket.close();
    }

    test "new REP socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket = socket: {
            var b = try try rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start();
        defer socket.close();
    }

    test "REQ/REP communication" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: rep.Rep(Transport.Listener, Pipe.Sync) = socket: {
            var b = try try rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try rep_socket.transport.start();
        defer rep_socket.close();

        // Open REQ socket
        var req_socket: Req(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket.transport.start();
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
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open REP socket
        var rep_socket: rep.Rep(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try try rep.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try rep_socket.transport.start();
        defer rep_socket.close();

        // Open REQ#1 socket
        var req_socket1: Req(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try open(ctx);
            break:socket try b.as_dialer(url);
        };
        try req_socket1.transport.start();
        defer req_socket1.close();

        // Open REQ#2 socket
        var req_socket2: Req(Transport.Dialer, Pipe.Parallel) = socket: {
            var b = try open(ctx);
            break:socket try b.parallel(2).as_dialer(url);
        };
        try req_socket2.transport.start();
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
};
