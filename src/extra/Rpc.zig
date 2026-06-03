///! Helper for request/reply style transactions over NNG pipes.
///!
///! Rpc owns a Message used for both request and response payloads.
///! Message ownership is temporarily transferred while a transaction
///! is in flight.

const std = @import("std");
const root = @import("../root.zig");

const Message = root.Message;
const SendError = root.SendError;
const ReceiveError = root.ReceiveError;

msg: ?Message,
options: Options = .{},

const Self = @This();

pub fn create() !Self {
    return .{
        .msg = try Message.create(),
    };
}

pub fn withCapacity(size: usize) !Self {
    return .{
        .msg = try Message.withCapacity(size),
    };
}

pub fn deinit(self: *Self) void {
    if (self.msg) |*msg| {
        msg.deinit();
    }
}

/// The returned Future borrows `self`, `sender`, and `receiver`.
/// The Future must be awaited before destroying any borrowed value.
///
pub fn submit(self: *Self, io: std.Io, sender: root.PipeSender, receiver: root.PipeReceiver) std.Io.Future(Self.Error!void) {
    const msg = self.msg.?;
    self.msg = null;
    return io.async(Self.submitInternal, .{ self, sender, receiver, msg });
}

fn submitInternal(self: *Self, sender: root.PipeSender, receiver: root.PipeReceiver, msg: Message) Self.Error!void {
    try sender.submit(msg, .{});
    self.msg = try receiver.drain(.{ .timeout = self.options.timeout });
}

pub const Options = struct {
    // drain timeout
    timeout: ?std.Io.Duration = null,
};

pub const Error = root.SendError || root.ReceiveError || std.Io.ConcurrentError;

test "rpc test" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const test_support = @import("../supports/test.zig");

    const Context = root.Context;
    const Req = root.Req;
    const Rep = root.Rep;
    const Transport = root.Transport;
    const Pipe = root.Pipe;
    const Rpc = Self;

    const RunRpcError = union(enum) {
        ok: void,
        write_failed: std.Io.Writer.Error,
        rpc_failed: Self.Error,
        rep_send_failed: root.SendError,
        rep_receive_failed: root.ReceiveError,
    };

    fn runRpc(io: std.Io, rpc: *Rpc, req: *Req.Protocol(Transport.Dialer, Pipe.Sync), rep: *Rep.Protocol(Transport.Listener, Pipe.Sync), reply: []const u8) !void {
        var g: std.Io.Group = .init;

        try g.concurrent(io, testSendFromRpc, .{ rpc, io, req.pipe.item.sender(), req.pipe.item.receiver() });
        try g.concurrent(io, testReplyToRpc, .{ rep.pipe.item.sender(), rep.pipe.item.receiver(), reply });
        try g.await(io);
    }

    fn testSendFromRpc(rpc: *Rpc, io: std.Io, sender: root.PipeSender, receiver: root.PipeReceiver) void {
        const result: RunRpcError = submit: {
            var f = rpc.submit(io, sender, receiver);
            f.await(io) catch |err| break:submit .{ .rpc_failed = err };
            break:submit .ok;
        };

        // assertion
        _ = result.ok;
    }

    fn testReplyToRpc(sender: root.PipeSender, receiver: root.PipeReceiver, reply: []const u8) void {
        const result: RunRpcError = reply: {
            var msg = receiver.drain(.{}) catch |err| break:reply .{ .rep_receive_failed = err };

            msg.writer.advance(msg.len());
            msg.writer.writeAll(reply) catch |err| break:reply .{ .write_failed = err };
            msg.writer.flush() catch |err| break:reply .{ .write_failed = err };

            sender.submit(msg, .{}) catch |err| break:reply .{ .rep_send_failed = err };
            break:reply .ok;
        };

        // assertion
        _ = result.ok;
    }

    test "submit rpc with unlimited timeout" {
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

        var rpc = try Rpc.create();
        defer rpc.deinit();

        if (rpc.msg) |*msg| {
            try msg.writer.writeAll("Hello");
            try msg.writer.flush();
        }

        try runRpc(std.testing.io, &rpc, &req_socket, &rep_socket, "World");

        try std.testing.expect(rpc.msg != null);
        try std.testing.expectEqualStrings("HelloWorld", rpc.msg.?.bytes());
    }

    test "submit rpc with timeout" {
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

        var rpc = try Rpc.create();
        defer rpc.deinit();

        rpc.options.timeout = std.Io.Duration.fromMilliseconds(10);

        if (rpc.msg) |*msg| {
            try msg.writer.writeAll("Hello");
            try msg.writer.flush();
        }

        var f = rpc.submit(std.testing.io, req_socket.pipe.item.sender(), req_socket.pipe.item.receiver());
        const result = f.await(std.testing.io);
        try std.testing.expectError(error.Timeout, result);
    }
};
