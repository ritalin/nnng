const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = @import("./Socket.zig");

pub const Listener = struct {
    socket: Socket,
    raw_listener: c.nng_listener,
    url: [:0]const u8,

    const Self = @This();

    pub fn create(socket: Socket, url: []const u8) root.NewTransportError!Self {
        const urlz = try socket.context.allocator.dupeSentinel(u8, url, 0);

        var raw_listener: c.nng_listener = undefined;
        const err = c.nng_listener_create(&raw_listener, socket.raw_socket, urlz);
        if (err != 0) {
            return errors.new_transport_error(err);
        }

        return .{
            .socket = socket,
            .raw_listener = raw_listener,
            .url = urlz,
        };
    }

    pub fn deinit(self: Self) void {
        const err = c.nng_listener_close(self.raw_listener);
        if (err != 0) {
            std.log.warn("Listener is already closed", .{});
        }
        self.socket.context.allocator.free(self.url);
    }

    pub fn start(self: Self) root.StartTransportError!void {
        const err = c.nng_listener_start(self.raw_listener, c.NNG_FLAG_NONBLOCK);
        if (err != 0) {
            return errors.start_transport_error(err);
        }
    }
};

pub const Dialer = struct {
    socket: Socket,
    raw_dialer: c.nng_dialer,
    url: [:0]const u8,

    const Self = @This();

    pub fn create(socket: Socket, url: []const u8) anyerror!Self {
        const urlz = try socket.context.allocator.dupeSentinel(u8, url, 0);

        var raw_dialer: c.nng_dialer = undefined;
        const err = c.nng_dialer_create(&raw_dialer, socket.raw_socket, urlz);
        if (err != 0) {
            return errors.new_transport_error(err);
        }

        return .{
            .socket = socket,
            .raw_dialer = raw_dialer,
            .url = urlz,
        };
    }

    pub fn deinit(self: *Self) void {
        const err = c.nng_dialer_close(self.raw_dialer);
        if (err != 0) {
            std.log.warn("Dialer is already closed", .{});
        }
        self.socket.context.allocator.free(self.url);
    }

    pub fn start(self: Self) root.StartTransportError!void {
        const err = c.nng_dialer_start(self.raw_dialer, c.NNG_FLAG_NONBLOCK);
        if (err != 0) {
            return errors.start_transport_error(err);
        }
    }
};
