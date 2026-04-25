const std = @import("std");
const errors = @import("./error_handlers.zig");
const c = @import("c");

pub const Context = @import("./Context.zig");
pub const Socket = @import("./socket/Socket.zig");
pub const req = @import("./protocols/req.zig");

pub const InitializeError = error { AlreadyInited };
pub const OpenError = (std.mem.Allocator.Error || error { NotSupported });
pub const CloseError = error { AlreadyClosed };
pub const ConnectionError = error { NotOpened, Refused };
pub const TransportUrlError = error { InvalidUrl };
pub const NewTransportError = TransportUrlError || CloseError || std.mem.Allocator.Error;
pub const InvalidError = error { InvalidValue };

pub const StartTransportError = (
    TransportUrlError || CloseError || ConnectionError || InvalidError ||
    std.mem.Allocator.Error || error { ProtocolError, AlreadyStarted, FailureAuth, Unreachable }
);






pub const testing = struct {
    pub fn make_ipc_sock(dir: std.Io.Dir, file_name: []const u8) anyerror![]const u8 {
        const sock_path = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(sock_path);

        return std.fmt.allocPrint(std.testing.allocator, "ipc://{s}/{s}", .{ sock_path, file_name });
    }
};

test "all_tests" {
    std.testing.refAllDecls(@This());
}
