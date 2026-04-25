const root = @import("./root.zig");
const c = @import("c");

pub fn open_error(err: i32) root.OpenError {
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    if (err == c.NNG_ENOTSUP) {
        return error.NotSupported;
    }
    unreachable;
}

pub fn close_error(err: i32) root.CloseError {
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    unreachable;
}

pub fn new_transport_error(err: i32) root.NewTransportError {
    if (err == c.NNG_EADDRINVAL) {
        return error.InvalidUrl;
    }
    if (err == c.NNG_ECLOSED) {
        return error.AlreadyClosed;
    }
    if (err == c.NNG_ENOMEM) {
        return error.OutOfMemory;
    }
    unreachable;
}

pub fn start_transport_error(err: i32) root.StartTransportError {
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
    unreachable;
}
