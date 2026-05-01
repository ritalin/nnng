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

/// Builder for protocol instances using Pipe.Sync.
///
/// Created via open(). Configure as needed, then finalize with
/// as_listener() or as_dialer().
///
/// Call parallel() to switch to Pipe.Parallel.
pub fn SyncBuilder(comptime Protocol: *const fn (comptime type, comptime type) type) type {
    return struct {
        socket: Socket,
        features: Pipe.Features,

        const Builder = @This();

        /// Internal. Called by open().
        pub fn init(socket: Socket, features: Pipe.Features) Builder {
            return .{
                .socket = socket,
                .features = features,
            };
        }

        /// Switch to Pipe.Parallel builder.
        /// `count` specifies the number of parallel pipe instances.
        pub fn parallel(self: Builder, count: usize) ParallelBuilder(Protocol) {
            return .{
                .socket = self.socket,
                .count = count,
                .features = self.features,
            };
        }

        /// Build as a listener.
        pub fn as_listener(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Listener, Pipe.Sync) {
            const listener = try Transport.Listener.create(self.socket, url);
            const pipes = Pipe.Sync.create(self.socket, self.features);

            return Protocol(Transport.Listener, Pipe.Sync).init(listener, pipes);
        }

        /// Build as a dialer.
        pub fn as_dialer(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Dialer, Pipe.Sync) {
            const dialer = try Transport.Dialer.create(self.socket, url);
            const pipes = Pipe.Sync.create(self.socket, self.features);

            return Protocol(Transport.Dialer, Pipe.Sync).init(dialer, pipes);
        }
    };
}

/// Builder for protocol instances using Pipe.Parallel.
///
/// Created via SyncBuilder.parallel().
/// Finalize with as_listener() or as_dialer().
pub fn ParallelBuilder(comptime Protocol: *const fn (comptime type, comptime type) type) type {
    return struct {
        socket: Socket,
        count: usize,
        features: Pipe.Features,

        const Builder = @This();

        /// Build as a listener.
        pub fn as_listener(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Listener, Pipe.Parallel) {
            const listener = try Transport.Listener.create(self.socket, url);
            const pipes = try Pipe.Parallel.create(self.socket, self.count, self.features);

            return Protocol(Transport.Listener, Pipe.Parallel).init(listener, pipes);
        }

        /// Build as a dialer.
        pub fn as_dialer(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Dialer, Pipe.Parallel) {
            const dialer = try Transport.Dialer.create(self.socket, url);
            const pipes = try Pipe.Parallel.create(self.socket, self.count, self.features);

            return Protocol(Transport.Dialer, Pipe.Parallel).init(dialer, pipes);
        }
    };
}
