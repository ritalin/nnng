//! Message receiver interfaces.

const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;
const ReceiveError = root.ReceiveError;
const message_impl = @import("./message_impl.zig");

pub const Receiver = struct {
    owner: *const anyopaque,
    slot: *message_impl.AioSlot,
    options: Options = .{},
    vtable: VTable,

    const Self = @This();

    pub fn withOpt(self: *const Self, options: Options) Self {
        return .{
            .owner = self.owner,
            .slot = self.slot,
            .options = options,
            .vtable = self.vtable,
        };
    }

    /// Receives a message.
    ///
    /// This is a single-consumer operation.
    /// drain() must not be called concurrently or recursively.
    ///
    /// External synchronization does not make multiple calls safe.
    /// The function assumes single-consumer semantics.
    ///
    pub fn drain(self: *const Self) ReceiveError!Message {
        return (self.vtable.on_drain)(self, self.options);
    }

    pub const Option = ReceiverOption;
    pub const Options = ReceiverOptions;

    const VTable = struct {
        on_drain: *const fn (receiver: *const Self, options: Options) ReceiveError!Message,
    };
};

pub const TryReceiver = struct {
    owner: *const anyopaque,
    slot: *message_impl.AioSlot,
    on_try_drain: *const fn (receiver: *const Self, options: Options) ReceiveError!?Message,

    const Self = @This();

    /// Attempts to receive a message.
    ///
    /// Unlike drain(), the absence of a message is reported as `null`
    /// rather than an error.
    ///
    /// Returns:
    /// - `Message` if one is available.
    /// - `null` if the receive queue is currently empty.
    ///
    /// This is a single-consumer operation.
    /// tryDrain() must not be called concurrently or recursively.
    ///
    /// External synchronization does not make multiple calls safe.
    /// The function assumes single-consumer semantics.
    ///
    pub fn tryDrain(self: *const Self, options: Options) ReceiveError!?Message {
        return (self.on_try_drain)(self, options);
    }

    pub const Option = ReceiverOption;
    pub const Options = ReceiverOptions;
};

const ReceiverOption = enum {
    /// If true, the operation does not block.
    nonblocking
};

/// Options for receive operations.
const ReceiverOptions = struct {
    flags: Flags = .{},
    timeout: ?std.Io.Duration = null,

    /// Flag set for receive operations.
    pub const Flags = std.enums.EnumFieldStruct(ReceiverOption, bool, false);
};
