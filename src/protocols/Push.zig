const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Push = @This();

const Context = root.Context;
const Socket = root.Socket;
const OpenError = root.OpenError;
const Transport = root.Transport;
const Pipe = root.Pipe;

const comptime_feature: Socket.ComptimeFeature = .{
    .protocol_name = @typeName(@This()),
    .forbid_parallel = true,
};

/// Creates a PUSH protocol socket instance.
/// This is the primary way to construct the type.
pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Push.Protocol, comptime_feature) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_push0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    const socket = Socket.init(ctx, raw_socket);
    const features: Pipe.Features = .{
        .send_first = true,
    };

    return Socket.SyncBuilder(Push.Protocol, comptime_feature).init(socket, features);
}

/// PUSH protocol type.
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

test "PUSH tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const Pull = @import("./Pull.zig");
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new PUSH socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PULL socket

        var pull_socket: Pull.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pull.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pull_socket.transport.start(.{});
        defer pull_socket.close();

        // Open PUSH socket

        var socket: Push.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Push.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try socket.transport.start(.{});
        defer socket.close();
    }

    test "PUSH socket features for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PULL socket

        var pull_socket: Pull.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pull.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pull_socket.transport.start(.{});
        defer pull_socket.close();

        // Open PUSH socket

        var socket: Push.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Push.open(ctx);
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

    test "PUSH/PULL communication" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "push_pull");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        // Open PULL socket
        var pull_socket: Pull.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Pull.open(ctx);
            break:socket try b.as_listener(url);
        };
        try pull_socket.transport.start(.{});
        defer pull_socket.close();

        // Open PUSH socket
        var push_socket: Push.Protocol(Transport.Dialer, Pipe.Sync) = socket: {
            var b = try Push.open(ctx);
            break:socket try b.as_dialer(url);
        };
        try push_socket.transport.start(.{});
        defer push_socket.close();

        // get pipe
        var push_pipe = iter: {
            var iter = push_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };
        var pull_pipe = iter: {
            var iter = pull_socket.pipe.iter();
            break:iter iter.next() orelse unreachable;
        };

        var msg = try Message.create();
        defer msg.deinit();

        // PUSH (send)
        const v0 = "Hello";
        try msg.writer.writeAll(v0);
        try msg.writer.flush(); // Need to sync written length
        try push_pipe.sender().submit(msg, .{});

        // REP (recv)
        msg = try pull_pipe.receiver().drain(.{});

        try std.testing.expectEqualStrings(v0, msg.bytes());
    }
};
