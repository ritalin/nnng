const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Context = @import("../Context.zig");

const Transport = @import("./Transport.zig");
const Pipe = @import("./Pipe.zig");
const OptionError = root.OptionError;
const findGetOptionInfo = @import("./socket_options.zig").findGetOptionInfo;
const findSetOptionInfo = @import("./socket_options.zig").findSetOptionInfo;

context: Context,
raw_socket: c.nng_socket,

const Socket = @This();

pub const Option = @import("./socket_options.zig").Option;

pub fn init(context: Context, raw_socket: c.nng_socket) Socket {
    return .{
        .context = context,
        .raw_socket = raw_socket,
    };
}

pub fn close(self: Socket) void {
    const err = c.nng_socket_close(self.raw_socket);
    if (err != 0) {
        std.log.scoped(.nnng).warn("Socket: already closed", .{});
    }
}

pub fn setOptions(self: Socket, option_values: Option.Values.Set) OptionError!void {
    inline for (comptime std.meta.tags(std.meta.FieldEnum(Option.Values.Set))) |name| {
        if (comptime findSetOptionInfo(name)) |info| {
            if (@field(option_values, @tagName(name))) |v| {
                const err = set_opt: {
                    if (info.type == c.nng_duration) {
                        break:set_opt c.nng_socket_set_ms(self.raw_socket, info.raw_name, v);
                    }
                    else {
                        unreachable;
                    }
                };
                if (err != 0) {
                    return errors.option_error(err);
                }
            }
        }
    }
}

pub fn options(self: Socket, comptime names: []const std.meta.FieldEnum(Option.Values.Get)) OptionError!Option.Values.Get {
    var result: Option.Values.Get = .{};

    inline for (names) |name| {
        if (comptime findGetOptionInfo(name)) |info| {
            const err = get_opt: {
                if (info.type == c.nng_duration) {
                    var tmp: c.nng_duration = undefined;
                    const err = c.nng_socket_get_ms(self.raw_socket, info.raw_name, &tmp);
                    @field(result, @tagName(name)) = tmp;
                    break:get_opt err;
                }
                else if (info.type == c_int) {
                    var tmp: c_int = undefined;
                    const err = c.nng_socket_get_int(self.raw_socket, info.raw_name, &tmp);
                    @field(result, @tagName(name)) = tmp;
                    break:get_opt err;
                }
                else if (info.type == u64) {
                    var tmp: u64 = undefined;
                    const err = c.nng_socket_get_uint64(self.raw_socket, info.raw_name, &tmp);
                    @field(result, @tagName(name)) = tmp;
                    break:get_opt err;
                }
                else {
                    unreachable;
                }
            };
            if (err != 0) {
                return errors.option_error(err);
            }
        }
    }

    return result;
}

pub const ComptimeFeature = struct {
    protocol_name: []const u8,
    forbid_parallel: bool = false,
};

/// Builder for protocol instances using Pipe.Sync.
///
/// Created via open(). Configure as needed, then finalize with
/// as_listener() or as_dialer().
///
/// Call parallel() to switch to Pipe.Parallel.
pub fn SyncBuilder(comptime Protocol: *const fn (comptime type, comptime type) type, comptime comptime_feature: ComptimeFeature) type {
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
            if (comptime comptime_feature.forbid_parallel) {
                @compileError(std.fmt.comptimePrint("{s} is not supported a parallel pipe", .{ comptime_feature.protocol_name }));
            }

            return .{
                .socket = self.socket,
                .count = count,
                .features = self.features,
            };
        }

        /// Build as a listener.
        pub fn as_listener(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Listener, Pipe.Sync) {
            const listener = try Transport.Listener.create(self.socket, url);
            const pipes = try Pipe.Sync.create(self.socket, self.features);

            return Protocol(Transport.Listener, Pipe.Sync).init(listener, pipes);
        }

        /// Build as a dialer.
        pub fn as_dialer(self: *const Builder, url: []const u8) anyerror!Protocol(Transport.Dialer, Pipe.Sync) {
            const dialer = try Transport.Dialer.create(self.socket, url);
            const pipes = try Pipe.Sync.create(self.socket, self.features);

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

test "test/socket" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const test_support = @import("../supports/test.zig");

   test "set socket options" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);
        const url0 = try std.testing.allocator.dupeSentinel(u8, url, 0);
        defer std.testing.allocator.free(url0);

        const ctx = Context.init(std.testing.io, std.testing.allocator);

        var raw_socket: c.nng_socket = undefined;
        _ = c.nng_rep0_open(&raw_socket);
        const socket = Socket.init(ctx, raw_socket);
        defer socket.close();

        try socket.setOptions(.{ .recv_timeout_ms = 1234 });
        const values = try socket.options(&.{ .recv_timeout_ms, .send_timeout_ms });
        try std.testing.expectEqualDeep(Socket.Option.Values.Get{ .recv_timeout_ms = 1234, .send_timeout_ms = c.NNG_DURATION_INFINITE }, values);
   }

   test "get read-only socket options" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "req_rep");
        defer std.testing.allocator.free(url);
        const url0 = try std.testing.allocator.dupeSentinel(u8, url, 0);
        defer std.testing.allocator.free(url0);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var raw_socket: c.nng_socket = undefined;
        _ = c.nng_rep0_open(&raw_socket);
        const socket = Socket.init(ctx, raw_socket);
        defer socket.close();

       _ = try socket.options(&.{ .recv_fd, .send_fd });
   }
};
