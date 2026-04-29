const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Context = root.Context;
const Socket = root.Socket;
const OpenError = root.OpenError;

pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Rep) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_rep0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    return Socket.SyncBuilder(Rep).init(Socket.init(ctx, raw_socket));
}

pub fn Rep(comptime Transport: type, comptime Pipe: type) type {
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
