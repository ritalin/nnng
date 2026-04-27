const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;
const SendError = root.SendError;

socket: Socket,

const Self = @This();
const Option = enum { nonblocking };

pub const Options = std.enums.EnumFieldStruct(Option, bool, false);

pub fn submit_message(self: Self, msg: Message, options: Options) SendError!void {
    const flags = std.enums.EnumSet(Option).init(options);
    std.log.debug("Start sending/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

    const err = c.nng_sendmsg(self.socket.raw_socket, msg.raw_msg, flags.bits.mask);
    if (err != 0) {
        return errors.send_error(err);
    }
}
