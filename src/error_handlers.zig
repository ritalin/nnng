const std = @import("std");
const root = @import("./root.zig");
const c = @import("c");

pub fn open_error(err: c_int) root.OpenError {
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_ENOTSUP) {
        return error.NotSupported;
    }
    std.log.err("open_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn close_error(err: c_int) root.CloseError {
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    std.log.err("close_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn new_transport_error(err: c_int) root.NewTransportError {
    if (err == c.NNG_EADDRINVAL) {
        return error.InvalidUrl;
    }
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    std.log.err("new_transport_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn start_transport_error(err: c_int) root.StartTransportError {
    if (err == c.NNG_EADDRINVAL) {
        return error.InvalidUrl;
    }
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    if (err == c.NNG_ECONNREFUSED) {
        return error.NotOpened;
    }
    if (err == c.NNG_ECONNRESET) {
        return error.Refused;
    }
    if (err == c.NNG_EINVAL) {
        return error.InvalidValue;
    }
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_EPEERAUTH) {
        return error.FailureAuth;
    }
    if (err == c.NNG_EPROTO) {
        return error.ProtocolError;
    }
    if (err == c.NNG_ESTATE) {
        return error.AlreadyStarted;
    }
    if (err == c.NNG_EUNREACHABLE) {
        return error.Unreachable;
    }
    if (err == c.NNG_EADDRINUSE) {
        return error.AddressInUse;
    }
    std.log.err("start_transport_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn open_aio_pipe_error(err: c_int) root.OpenAioPipeError {
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_ENOTSUP) {
        return error.NotSupported;
    }
    std.log.err("open_aio_pipe_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn send_error(err: c_int) root.SendError {
    if (err == c.NNG_EAGAIN) {
        return error.WouldBlock;
    }
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    if (err == c.NNG_EINVAL) {
        return error.InvalidValue;
    }
    if (err == c.NNG_EMSGSIZE) {
        return error.TooLargeSize;
    }
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_ENOTSUP) {
        return error.NotSupported;
    }
    if (err == c.NNG_ESTATE) {
        return error.InvalidState;
    }
    if (err == c.NNG_ETIMEDOUT) {
        return error.Timeout;
    }
    if (err == c.NNG_ECANCELED) {
        return error.Canceled;
    }

    std.log.err("send_error/unhandled code: {}", .{err});
    unreachable;
}

pub fn receive_error(err: c_int) root.ReceiveError {
    if (err == c.NNG_EAGAIN) {
        return error.WouldBlock;
    }
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    if (err == c.NNG_EINVAL) {
        return error.InvalidValue;
    }
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_ENOTSUP) {
        return error.NotSupported;
    }
    if (err == c.NNG_ESTATE) {
        return error.InvalidState;
    }
    if (err == c.NNG_ETIMEDOUT) {
        return error.Timeout;
    }
    if (err == c.NNG_ECANCELED) {
        return error.Canceled;
    }

    std.log.err("receive_error/unhandled code: {}", .{err});
    unreachable;
}
