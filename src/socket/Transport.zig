const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = @import("./Socket.zig");

const Option = enum(i32) { nonblocking };
// Connection options
pub const Options = std.enums.EnumFieldStruct(Option, bool, false);

fn optionsIntoMask(options: Options) c_int {
    var mask: c_int = 0;
    if (options.nonblocking) {
        mask += c.NNG_FLAG_NONBLOCK;
    }

    return mask;
}

pub const Listener = struct {
    socket: Socket,
    raw_listeners: std.ArrayListUnmanaged(c.nng_listener),

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, url: []const u8) root.TransportError!Self {
        var listeners: std.ArrayListUnmanaged(c.nng_listener) = .empty;
        try listeners.append(socket.context.allocator, try createRawListener(&socket, url));

        return .{
            .socket = socket,
            .raw_listeners = listeners,
        };
    }

    /// Internal. Called by protocol close().
    pub fn deinit(self: *Self) void {
        self.raw_listeners.deinit(self.socket.context.allocator);
    }

    /// Starts listening for incoming connections.
    pub fn start(self: *const Self, options: Options) root.StartTransportError!void {
        const flags = optionsIntoMask(options);

        for (self.raw_listeners.items) |listener| {
            const err = c.nng_listener_start(listener, flags);
            if (err != 0) {
                return errors.start_transport_error(err);
            }
        }
    }

    /// Adds another channel.
    pub fn addChannel(self: *Self, url: []const u8) root.TransportError!void {
        if (url.len > c.NNG_MAXADDRLEN - 1) {
            return error.TooLongUrl;
        }
        try self.raw_listeners.append(self.socket.context.allocator, try createRawListener(&self.socket, url));
    }
};

pub const Dialer = struct {
    socket: Socket,
    raw_dialers: std.ArrayListUnmanaged(c.nng_dialer),

    const Self = @This();

    pub fn create(socket: Socket, url: []const u8) root.TransportError!Self {
        if (url.len > c.NNG_MAXADDRLEN - 1) {
            return error.TooLongUrl;
        }

        var raw_dialers: std.ArrayListUnmanaged(c.nng_dialer) = .empty;
        try raw_dialers.append(socket.context.allocator, try createRawDialer(&socket, url));

        return .{
            .socket = socket,
            .raw_dialers = raw_dialers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.raw_dialers.deinit(self.socket.context.allocator);
    }

    pub fn start(self: *const Self, options: Options) root.StartTransportError!void {
        const flags = optionsIntoMask(options);

        for (self.raw_dialers.items) |raw_dialer| {
            const err = c.nng_dialer_start(raw_dialer, flags);
            if (err != 0) {
                return errors.start_transport_error(err);
            }
        }
    }

    /// Adds another channel.
    pub fn addChannel(self: *Self, url: []const u8) root.TransportError!void {
        if (url.len > c.NNG_MAXADDRLEN - 1) {
            return error.TooLongUrl;
        }
        try self.raw_dialers.append(self.socket.context.allocator, try createRawDialer(&self.socket, url));
    }
};

fn createRawListener(socket: *const Socket, url: []const u8) root.TransportError!c.nng_listener {
    const urlz = try socket.context.allocator.dupeSentinel(u8, url, 0);
    defer socket.context.allocator.free(urlz);

    var raw_listener: c.nng_listener = undefined;
    const err = c.nng_listener_create(&raw_listener, socket.raw_socket, urlz);
    if (err != 0) {
        return errors.new_transport_error(err);
    }
    
    return raw_listener;
}

fn createRawDialer(socket: *const Socket, url: []const u8) root.TransportError!c.nng_dialer {
    const urlz = try socket.context.allocator.dupeSentinel(u8, url, 0);
    defer socket.context.allocator.free(urlz);

    var raw_dialer: c.nng_dialer = undefined;
    const err = c.nng_dialer_create(&raw_dialer, socket.raw_socket, urlz);
    if (err != 0) {
        return errors.new_transport_error(err);
    }
    
    return raw_dialer;
}
