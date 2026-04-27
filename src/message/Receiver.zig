const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;

owner: *anyopaque,
on_drain: *const fn (receiver: *Receiver, callback: DrainCallback, options: Options) anyerror!void,

const Self = @This();
const Receiver = Self;

pub fn drain(self: *Self, callback: DrainCallback, options: Options) anyerror!void {
    return (self.on_drain)(self, callback, options);
}

pub const Option = enum { nonblocking };
pub const Options = std.enums.EnumFieldStruct(Option, bool, false);
pub const DrainCallback = *const fn (receiver: *Receiver, msg: Message) anyerror!void;
