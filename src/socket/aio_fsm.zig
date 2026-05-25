const std = @import("std");
const c = @import("c");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");

const AioPipeError = root.AioPipeError;

const AioState = enum(u8) {
    idle,
    wating,
    completed,
    stopped,
};

pub const StateMachine = extern struct {
    raw_aio: *c.nng_aio,
    inner: *StateMachine.Inner,

    pub fn create(io: std.Io, allocator: std.mem.Allocator) AioPipeError!*StateMachine {
        const self = try allocator.create(StateMachine);
        errdefer allocator.destroy(self);

        const raw_aio = open: {
            var raw_aio: ?*c.nng_aio = null;
            const err = c.nng_aio_alloc(&raw_aio, completionCallback, self);
            if (err != 0) {
                return errors.aio_pipe_error(@intCast(err));
            }
            break:open raw_aio;
        };

        const inner = try allocator.create(StateMachine.Inner);
        inner.* = StateMachine.Inner.init(io);

        self.* = .{
            .raw_aio = raw_aio.?,
            .inner = inner,
        };

        return self;
    }

    pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
        _ = c.nng_aio_free(self.raw_aio);
        allocator.destroy(self.inner);
        allocator.destroy(self);
    }

pub fn wait(self: *StateMachine) AioPipeError!void {
    std.debug.print("*** ENTER_WAIT/aio: {}, state={}\n", .{self.raw_aio, self.currentState()});

    while (self.currentState() == .wating) {
        if (self.currentState() == .completed) return;
        if (self.currentState() == .stopped) return error.Canceled;
        try self.inner.barrier.wait(self.inner.io);
    }

    std.debug.print("*** EXIT_WAIT/aio: {}, state={}\n", .{self.raw_aio, self.currentState()});
}

    pub fn transitIdle(self: *StateMachine) void {
        std.debug.print("*** IDLE_BEGIN/aio: {}, state={}\n", .{self.raw_aio, self.currentState()});
        @atomicStore(AioState, &self.inner.state, .idle, .release);
        std.debug.print("*** IDLE_AFTER_STATE\n", .{});

        self.inner.barrier.reset();
        std.debug.print("*** IDLE_AFTER_RESET/aio: {}\n", .{self.raw_aio});
    }

    pub fn transitWaiting(self: *StateMachine) AioPipeError!void {
        if (self.currentState() != .idle) {
            return error.Canceled;
        }
        @atomicStore(AioState, &self.inner.state, .wating, .release);
    }

    pub fn transitComplete(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .completed, .release);

        self.inner.barrier.set(self.inner.io);
    }

    pub fn transitStopped(self: *StateMachine) void {
        std.debug.print("*** STOP_BEGIN/aio: {}, state={}\n", .{self.raw_aio, self.currentState()});

        @atomicStore(AioState, &self.inner.state, .stopped, .release);
        std.debug.print("*** STOP_AFTER_STATE/aio: {}\n", .{self.raw_aio});

        c.nng_aio_stop(self.raw_aio);

        std.debug.print("*** STOP_AFTER_NNG/aio: {}, \n", .{self.raw_aio});

        self.inner.barrier.set(self.inner.io);

        std.debug.print("*** STOP_AFTER_SET/aio: {}\n", .{self.raw_aio});
    }

    pub fn currentState(self: *StateMachine) AioState {
        return @atomicLoad(AioState, &self.inner.state, .acquire);
    }

    const Inner = struct {
        io: std.Io,
        barrier: std.Io.Event,
        state: AioState,

        pub fn init(io: std.Io) Inner {
            return .{
                .io =io,
                .barrier = .unset,
                .state = .idle,
            };
        }
    };
};

fn completionCallback(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        var fsm: *StateMachine = @ptrCast(@alignCast(p));

        switch (fsm.currentState()) {
            .idle, .completed, .stopped => {},
            .wating => {
                if ((c.nng_aio_result(fsm.raw_aio) == 0) and (c.nng_aio_get_msg(fsm.raw_aio) != null)) {
                    fsm.transitComplete();
                }
            },
        }
    }
}