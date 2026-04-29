//! Message sender interface.

const std = @import("std");
const root = @import("../root.zig");

const Socket = root.Socket;
const Message = root.Message;
const SendError = root.SendError;

owner: *const anyopaque,
on_submit: *const fn (sender: *const Sender, msg: Message, options: Options) SendError!void,

const Self = @This();
const Sender = Self;

/// Sends a message.
pub fn submit(self: *const Self, msg: Message, options: Options) SendError!void {
    return (self.on_submit)(self, msg, options);
}

pub const Option = enum {
    /// If true, the operation does not block.
    nonblocking
};

/// Options for send operations.
pub const Options = std.enums.EnumFieldStruct(Option, bool, false);
