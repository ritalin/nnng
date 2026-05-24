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
    raw_listener: c.nng_listener,
    url: [:0]const u8,

    const Self = @This();

    /// Internal. Called by protocol open().
    pub fn create(socket: Socket, url: []const u8) root.NewTransportError!Self {
        const urlz = try socket.context.allocator.dupeSentinel(u8, url, 0);
        errdefer socket.context.allocator.free(urlz);

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

    /// Internal. Called by protocol close().
    pub fn deinit(self: Self) void {
        self.socket.context.allocator.free(self.url);
    }

    /// Starts listening for incoming connections.
    pub fn start(self: Self, options: Options) root.StartTransportError!void {
        const flags = optionsIntoMask(options);

        const err = c.nng_listener_start(self.raw_listener, flags);
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
        self.socket.context.allocator.free(self.url);
    }

    pub fn start(self: Self, options: Options) root.StartTransportError!void {
        const flags = optionsIntoMask(options);

        const err = c.nng_dialer_start(self.raw_dialer, flags);
        if (err != 0) {
            return errors.start_transport_error(err);
        }
    }
};
