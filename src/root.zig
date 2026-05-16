const std = @import("std");
const errors = @import("./error_handlers.zig");
const c = @import("c");

pub const Context = @import("./Context.zig");
pub const Socket = @import("./socket/Socket.zig");
pub const Transport = @import("./socket/Transport.zig");
pub const Pipe = @import("./socket/Pipe.zig");
pub const Message = @import("./message/Message.zig");

pub const PipeSender = @import("./message/Sender.zig");
pub const PipeReceiver = @import("./message/Receiver.zig");

pub const Req = @import("./protocols/Req.zig");
pub const Rep = @import("./protocols/Rep.zig");
pub const Push = @import("./protocols/Push.zig");
pub const Pull = @import("./protocols/Pull.zig");
pub const Pub = @import("./protocols/Pub.zig");
pub const Sub = @import("./protocols/Sub.zig");
pub const Pair = @import("./protocols/Pair.zig");

// extras
pub const ReceivePoller = @import("./extra/poller.zig").ReceivePoller;

pub const InitializeError = error { AlreadyInited };
pub const FeatureError = error { NotSupported };
pub const OpenError = std.mem.Allocator.Error || FeatureError;
pub const CloseError = error { AlreadyClosed };
pub const ConnectionError = error { NotOpened, Refused };
pub const TransportUrlError = error { InvalidUrl };
pub const NewTransportError = TransportUrlError || CloseError || std.mem.Allocator.Error;
pub const InvalidError = error { InvalidValue, InvalidState };

pub const StartTransportError = (
    TransportUrlError || CloseError || ConnectionError || InvalidError ||
    std.mem.Allocator.Error || error { ProtocolError, AlreadyStarted, FailureAuth, Unreachable, AddressInUse }
);

pub const MessageAllocError = std.mem.Allocator.Error;

pub const SendError = (
    error { WouldBlock, TooLargeSize, Timeout, Canceled } ||
    FeatureError || CloseError || InvalidError || std.mem.Allocator.Error
);

pub const ReceiveError = (
    error { WouldBlock, NotSupported, Timeout, Canceled, OperationConflict } ||
    CloseError || InvalidError || std.mem.Allocator.Error
);

pub const OpenAioPipeError = FeatureError || std.mem.Allocator.Error;

pub const OptionError = (
    error {
        // Incorrect type for option.
        BadType,
        // The option opt is write-only.
        WriteOnly
    }) ||
    CloseError || InvalidError || FeatureError || std.mem.Allocator.Error
;

test "all_tests" {
    std.testing.refAllDecls(@This());
}
