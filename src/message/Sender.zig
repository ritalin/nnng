//! Message sender interface.

const std = @import("std");
const root = @import("../root.zig");

const Socket = root.Socket;
const Message = root.Message;
const SendError = root.SendError;
const PipeLock = root.PipeLock;

/// Sends a Message to the underlying transport.
///
/// This operation is transport-level only.
/// It does not inspect or modify Message contents.
///
/// The Message must be fully prepared before submission.
/// Ownership is transferred at submit time.
///
/// A Sender may be shared across threads. Use lock() to serialize
/// submit operations when multiple threads access the same Sender.
///
/// submit() is atomic with respect to a single Message submission.
/// 

owner: *const anyopaque,
options: Options = .{},
vtable: VTable,

const Self = @This();
const Sender = Self;

pub fn withOpt(self: *const Self, options: Options) Self {
    return .{
        .owner = self.owner,
        .options = options,
        .vtable = self.vtable,
    };
}

/// Sends a message.
pub fn submit(self: *const Self, msg: Message) SendError!void {
    return (self.vtable.on_submit)(self, msg, self.options);
}

pub fn lock(self: *const Self) PipeLock {
    return (self.vtable.on_lock_pipe(self));
}

pub const Option = enum {
    /// If true, the operation does not block.
    nonblocking
};

/// Options for send operations.
pub const Options = struct {
    flags: Flags = .{},

    /// Flag set for send operations.
    pub const Flags = std.enums.EnumFieldStruct(Option, bool, false);
};

const VTable = struct {
    on_submit: *const fn (sender: *const Sender, msg: Message, options: Options) SendError!void,
    on_lock_pipe: *const fn (sender: *const Sender) PipeLock,
};
