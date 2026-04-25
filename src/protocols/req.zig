const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Context = root.Context;
const Socket = root.Socket;
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

pub fn Req(comptime Transport: type, comptime Pipe: type) type {
    return struct {
        transport: Transport,
        pipe: Pipe,

        const Self = @This();

        pub fn init(transport: Transport, pipe: Pipe) Self {
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

    test "new REQ socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try root.testing.make_ipc_sock(tmp.dir, "req_rep.sock");
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
        const url = try root.testing.make_ipc_sock(tmp.dir, "req_rep.sock");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket = socket: {
            var b = try try rep.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start();
        defer socket.close();
    }
};
