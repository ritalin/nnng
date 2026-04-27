const std = @import("std");
const root = @import("../root.zig");

const Socket = root.Socket;
const Message = root.Message;
const SendError = root.SendError;

owner: *anyopaque,
on_submit: *const fn (owner: *anyopaque, msg: Message, options: Options) SendError!void,

const Self = @This();
const Sender = Self;
const Option = enum { nonblocking };

pub const Options = std.enums.EnumFieldStruct(Option, bool, false);

pub fn default() Self {

}

pub fn submit_message(self: Self, msg: Message, options: Options) SendError!void {
    return (self.on_submit)(self.owner, msg, options);
}
