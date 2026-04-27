const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;
const ReceiveError = root.ReceiveError;

owner: *anyopaque,
on_drain: *const fn (receiver: *const Receiver, options: Options) ReceiveError!Message,

const Self = @This();
const Receiver = Self;

pub fn drain(self: *const Self, options: Options) ReceiveError!Message {
    return (self.on_drain)(self, options);
}

pub const Option = enum { nonblocking };
pub const Options = std.enums.EnumFieldStruct(Option, bool, false);
