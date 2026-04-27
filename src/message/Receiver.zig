const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Socket = root.Socket;
const Message = root.Message;

socket: Socket,

const Self = @This();
const Receiver = Self;
const Option = enum { nonblocking };

pub const Options = std.enums.EnumFieldStruct(Option, bool, false);

pub fn drain(self: *Self, callback: *const fn (receiver: *Receiver, msg: Message) anyerror!void, options: Options) anyerror!void {
    const flags = std.enums.EnumSet(Option).init(options);

    var raw_msg: ?*c.nng_msg = null;
    const err = c.nng_recvmsg(self.socket.raw_socket, &raw_msg, flags.bits.mask);
    if (err != 0) {
        return errors.receive_error(err);
    }

    const msg = Message.from_raw(raw_msg.?);
    std.log.debug("Start receiving/flags: {}, len(edit): {}, len(commit): {}", .{options, msg.writer.end, msg.len()});

    return callback(self, msg);
}
