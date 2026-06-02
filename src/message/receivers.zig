//! Message receiver interface.

const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;
const ReceiveError = root.ReceiveError;
const message_impl = @import("./message_impl.zig");

owner: *const anyopaque,
slot: *message_impl.AioSlot,
on_drain: *const fn (receiver: *const Receiver, options: Options) ReceiveError!Message,

const Self = @This();
const Receiver = Self;

/// Receives a message.
///
/// This is a single-consumer operation.
/// drain() must not be called concurrently or recursively.
///
/// External synchronization does not make multiple calls safe.
/// The function assumes single-consumer semantics.
///
pub fn drain(self: *const Self, options: Options) ReceiveError!Message {
    return (self.on_drain)(self, options);
}

pub const Option = enum {
    /// If true, the operation does not block.
    nonblocking
};

/// Options for receive operations.
pub const Options = struct {
    flags: Flags = .{},
    timeout: ?std.Io.Duration = null,

    /// Flag set for receive operations.
    pub const Flags = std.enums.EnumFieldStruct(Option, bool, false);
};
