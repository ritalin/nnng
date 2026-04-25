const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Context = @import("../Context.zig");

const Transport = @import("./Transport.zig");
const Pipe = @import("./Pipe.zig");

context: Context,
raw_socket: c.nng_socket,

const Socket = @This();

pub fn init(context: Context, raw_socket: c.nng_socket) Socket {
    return .{
        .context = context,
        .raw_socket = raw_socket,
    };
}

pub fn close(self: Socket) void {
    const err = c.nng_socket_close(self.raw_socket);
    if (err != 0) {
        std.log.warn("Socket: already closed", .{});
    }
}

pub fn SyncBuilder(comptime Protocol: *const fn (comptime type, comptime type) type) type {
    return struct {
        socket: Socket,

        const Builder = @This();

        pub fn init(socket: Socket) Builder {
            return .{
                .socket = socket,
            };
        }

        pub fn parallel(self: Builder, count: usize) ParallelBuilder(Protocol) {
            return .{
                .socket = self.socket,
                .count = count,
            };
        }

        pub fn as_listener(self: *Builder, url: []const u8) anyerror!Protocol(Transport.Listener, Pipe.Sync) {
            defer self.* = undefined;
            const listener = try Transport.Listener.create(self.socket, url);
            const pipes = Pipe.Sync.create(self.socket);

            return Protocol(Transport.Listener, Pipe.Sync).init(listener, pipes);
        }

        pub fn as_dialer(self: *Builder, url: []const u8) anyerror!Protocol(Transport.Dialer, Pipe.Sync) {
            defer self.* = undefined;
            const dialer = try Transport.Dialer.create(self.socket, url);
            const pipes = Pipe.Sync.create(self.socket);

            return Protocol(Transport.Dialer, Pipe.Sync).init(dialer, pipes);
        }
    };
}

pub fn ParallelBuilder(comptime Protocol: type) type {
    return struct {
        socket: Socket,
        count: usize,

        const Builder = @This();

        pub fn as_listener(self: *Builder, url: []const u8) anyerror!Protocol(Transport.Listener, Pipe.Parallel) {
            defer self.* = undefined;
            const listener = try Transport.Listener.create(self.socket, url);
            const pipes = try Pipe.Parallel.create(self.socket.context.allocator, self.socket, self.count);

            return Protocol(Transport.Listener, Pipe.Parallel).init(listener, pipes);
        }

        pub fn as_dialer(self: *Builder, url: []const u8) anyerror!Protocol(Transport.Dialer, Pipe.Parallel) {
            defer self.* = undefined;
            const dialer = try Transport.Dialer.create(self.socket, self.socket, url);
            const pipes = try Pipe.Parallel.create(self.socket.context.allocator, self.count);

            return Protocol(Transport.Dialer, Pipe.Parallel).init(dialer, pipes);
        }
    };
}
