const std = @import("std");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = @import("../root.zig").Socket;
const OpenError = @import("../root.zig").OpenError;

pub fn make_ipc_sock(dir: std.Io.Dir, file_name: []const u8) anyerror![]const u8 {
    const sock_path = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(sock_path);

    return std.fmt.allocPrint(std.testing.allocator, "ipc://{s}/{s}", .{ sock_path, file_name });
}

pub fn cleanup() void {
    // std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
}

const ReadyWait = struct {
    ev: std.Io.Event,
    io: std.Io,

    pub fn init(io: std.Io) ReadyWait {
        return .{
            .ev = .unset,
            .io = io
        };
    }

    pub fn wait(self: *ReadyWait) void {
        const d = std.Io.Duration.fromMilliseconds(10);
        self.ev.waitTimeout(self.io, .{ .duration = .{ .raw = d, .clock = .awake } }) catch {};
    }

    pub fn awake(self: *ReadyWait) void {
        self.ev.set(self.io);
    }
};

pub fn waitPipeReady(io: std.Io, socket: Socket) OpenError!void {
    var waiter = ReadyWait.init(io);
    const err = c.nng_pipe_notify(socket.raw_socket, c.NNG_PIPE_EV_ADD_POST, callbackPipeUpNotification, &waiter);
    if (err != 0) {
        return errors.open_error(err);
    }
    defer _ = c.nng_pipe_notify(socket.raw_socket, c.NNG_PIPE_EV_ADD_POST, null, null);

    waiter.wait();
}

fn callbackPipeUpNotification(_: c.nng_pipe, _: c.nng_pipe_ev, arg: ?*anyopaque) callconv(.c) void {
    var waiter: *ReadyWait = @ptrCast(@alignCast(arg));
    waiter.awake();
}

test "test/supports" {
    // std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const Context = @import("../root.zig").Context;

    test "wait pipe ready" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);
        const url0 = try std.testing.allocator.dupeSentinel(u8, url, 0);
        defer std.testing.allocator.free(url0);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        var raw_socket: c.nng_socket = undefined;
        _ = c.nng_rep0_open(&raw_socket);
        const socket = Socket.init(ctx, raw_socket);
        defer socket.close();

        _ = c.nng_listen(socket.raw_socket, url0, null, c.NNG_FLAG_NONBLOCK);

        try waitPipeReady(std.testing.io, socket);
    }

    test "wait pipe ready after blocking" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);
        const url0 = try std.testing.allocator.dupeSentinel(u8, url, 0);
        defer std.testing.allocator.free(url0);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        var raw_socket: c.nng_socket = undefined;
        _ = c.nng_rep0_open(&raw_socket);
        const socket = Socket.init(ctx, raw_socket);
        defer socket.close();

        _ = c.nng_listen(socket.raw_socket, url0, null, 0);

        try waitPipeReady(std.testing.io, socket);
    }
};
