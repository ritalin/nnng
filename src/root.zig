const std = @import("std");
const errors = @import("./error_handlers.zig");
const c = @import("c");

pub const Context = @import("./Context.zig");
pub const Socket = @import("./socket/Socket.zig");
pub const Transport = @import("./socket/Transport.zig");
pub const Pipe = @import("./socket/Pipe.zig");
pub const Message = @import("./message/Message.zig");

pub const req = @import("./protocols/req.zig");
pub const rep = @import("./protocols/rep.zig");

pub const InitializeError = error { AlreadyInited };
pub const FeatureError = error { NotSupported };
pub const OpenError = std.mem.Allocator.Error || FeatureError;
pub const CloseError = error { AlreadyClosed };
pub const ConnectionError = error { NotOpened, Refused };
pub const TransportUrlError = error { InvalidUrl };
pub const NewTransportError = TransportUrlError || CloseError || std.mem.Allocator.Error;
pub const InvalidError = error { InvalidValue };

pub const StartTransportError = (
    TransportUrlError || CloseError || ConnectionError || InvalidError ||
    std.mem.Allocator.Error || error { ProtocolError, AlreadyStarted, FailureAuth, Unreachable }
);

pub const MessageAllocError = std.mem.Allocator.Error;

pub const SendError = (
    error { Blocked, TooLargeSize, Unreachable, Timeout } ||
    FeatureError || CloseError || InvalidError || std.mem.Allocator.Error
);

pub const ReceiveError = (
    error { Blocked, NotSupported, Unreachable, Timeout } ||
    CloseError || InvalidError || std.mem.Allocator.Error
);

pub const OpenAioPipeError = FeatureError || std.mem.Allocator.Error;

test "all_tests" {
    std.testing.refAllDecls(@This());
}
