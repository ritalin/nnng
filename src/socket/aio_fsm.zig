const std = @import("std");
const c = @import("c");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");

const AioPipeError = root.AioPipeError;
const PipeLock = root.PipeLock;

const AioState = enum(u8) {
    idle,
    waiting,
    completed,
    timeout,
    canceled,
    stopped,
};

pub const StateMachine = extern struct {
    raw_aio: *c.nng_aio,
    mutex: *c.nng_mtx,
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

        var mutex: ?*c.nng_mtx = null;
        const err = c.nng_mtx_alloc(&mutex);
        if (err != 0) {
            return errors.aio_pipe_error(@intCast(err));
        }

        const inner = try allocator.create(StateMachine.Inner);
        inner.* = StateMachine.Inner.init(io);

        self.* = .{
            .raw_aio = raw_aio.?,
            .mutex = mutex.?,
            .inner = inner,
        };

        return self;
    }

    pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
        c.nng_mtx_free(self.mutex);
        _ = c.nng_aio_free(self.raw_aio);
        allocator.destroy(self.inner);
        allocator.destroy(self);
    }

    pub fn wait(self: *StateMachine) AioPipeError!void {
        while (self.currentState() == .waiting) {
            if (self.currentState() == .completed) return;
            if (self.currentState() == .stopped) return error.Canceled;
            try self.inner.barrier.wait(self.inner.io);
        }
    }

    pub fn transitIdle(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .idle, .release);

        self.inner.barrier.reset();
    }

    pub fn transitWaiting(self: *StateMachine) AioPipeError!void {
        if (self.currentState() != .idle) {
            return error.Canceled;
        }
        @atomicStore(AioState, &self.inner.state, .waiting, .release);
    }

    pub fn transitComplete(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .completed, .release);

        self.inner.barrier.set(self.inner.io);
    }

    pub fn transitTimeout(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .timeout, .release);

        self.inner.barrier.set(self.inner.io);
    }

    pub fn transitCancel(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .canceled, .release);

        self.inner.barrier.set(self.inner.io);
    }

    pub fn transitStopped(self: *StateMachine) void {
        @atomicStore(AioState, &self.inner.state, .stopped, .release);

        c.nng_aio_stop(self.raw_aio);

        self.inner.barrier.set(self.inner.io);
    }

    pub fn currentState(self: *StateMachine) AioState {
        return @atomicLoad(AioState, &self.inner.state, .acquire);
    }

    pub fn lock(self: *StateMachine) PipeLock {
        c.nng_mtx_lock(self.mutex);
        return .{ .mutex = self.mutex };
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
            .idle, .completed, .stopped, .timeout, .canceled => {},
            .waiting => {
                const err = c.nng_aio_result(fsm.raw_aio);
                if (err == c.NNG_ETIMEDOUT) {
                    fsm.transitTimeout();
                }
                else if (err == c.NNG_ECANCELED) {
                    fsm.transitCancel();
                }
                else if ((err == 0) and (c.nng_aio_get_msg(fsm.raw_aio) != null)) {
                    fsm.transitComplete();
                }
            },
        }
    }
}