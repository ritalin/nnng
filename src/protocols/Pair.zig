const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Pair = @This();

const Context = root.Context;
const Socket = root.Socket;
const Transport = root.Transport;
const Pipe = root.Pipe;
const OpenError = root.OpenError;
const CloseError = root.CloseError;

const comptime_feature: Socket.ComptimeFeature = .{
    .protocol_name = @typeName(@This()),
    .forbid_parallel = true,
};

/// Creates a PAIR protocol socket instance.
/// This is the primary way to construct the type.
pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Pair.Protocol, comptime_feature) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_pair1_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    const socket = Socket.init(ctx, raw_socket);
    const features: Pipe.Features = .{
        .send_first = true,
        .receive_first = true,
        .last_msg_owner = true,
    };

    return Socket.SyncBuilder(Pair.Protocol, comptime_feature).init(socket, features);
}

/// PAIR protocol type.
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

test "PAIR tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const Sub = @import("./Sub.zig");
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new PAIR socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PAIR protocol
        var sub_socket: Pair.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pair.open(ctx);
            break:socket try b.as_listener(url);
        };
        try sub_socket.transport.start(.{});
        defer sub_socket.close();
    }

    test "PAIR socket features" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open SUB socket

        var socket: Pair.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pair.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var iter = socket.pipe.iter();
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqualDeep(Pipe.Features{ .send_first = true, .receive_first = true, .last_msg_owner = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe == null);
            break:pipe;
        }
    }

    test "PAIR_PAIR communication" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "p2p");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PAIR socket
        var socket1: Pair.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pair.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket1.transport.start(.{});
        defer socket1.close();

        // Open PAIR socket
        var socket2: Pair.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Pair.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket2.transport.start(.{});
        defer socket2.close();

        // get pipe
        var pipe1 = iter: {
            var iter = socket1.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var pipe2 = iter: {
            var iter = socket2.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        oneway_path: {
            var msg = try Message.create();

            const v0 = "Hello";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pipe1.sender().submit(msg, .{});

            msg = try pipe2.receiver().drain(.{});
            defer msg.deinit();

            try std.testing.expectEqualStrings(v0, msg.bytes());
            break:oneway_path;
        }
        return_path: {
            var msg = try Message.create();

            const v0 = "World";
            try msg.writer.writeAll(v0);
            try msg.writer.flush(); // Need to sync written length
            try pipe2.sender().submit(msg, .{});

            msg = try pipe1.receiver().drain(.{});
            defer msg.deinit();

            try std.testing.expectEqualStrings(v0, msg.bytes());
            break:return_path;
        }
    }
};
