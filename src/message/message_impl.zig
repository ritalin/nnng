const std = @import("std");
const c = @import("c");

const ReceiveOptions = @import("./Receiver.zig").Options;

pub const AioSlot = struct {
    raw_aio: *c.nng_aio,
    generation: u64 = 0,
    state: ?State = null,

    pub fn reset(self: *AioSlot) void {
        c.nng_aio_set_timeout(self.raw_aio, c.NNG_DURATION_DEFAULT);
        self.state = null;
    }

    pub fn storeReceiveOpion(self: *AioSlot, options: ReceiveOptions) ValidateError!void {
        if (try validateReceiveOption(self, options)) |new_state| {
            if (new_state.timeout) |timeout| {
                c.nng_aio_set_timeout(self.raw_aio, @intCast(timeout.toMilliseconds()));
            }
            self.state = new_state;
        }
    }

    pub const State = struct {
        timeout: ?std.Io.Duration = null,
        nonblocking: ?bool = false,
    };

    pub const ValidateError = error {
        OperationConflict,
    };
};

fn validateReceiveOption(slot: *const AioSlot, options: ReceiveOptions) AioSlot.ValidateError!?AioSlot.State {
    const new_state: AioSlot.State = .{
        .timeout = options.timeout,
        .nonblocking = options.flags.nonblocking
    };
    if (slot.state != null) {
        if (!std.meta.eql(slot.state.?, new_state)) {
            return error.OperationConflict;
        }
        return null;
    }

    return new_state;
}
