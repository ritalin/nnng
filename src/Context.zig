//! Initializes the NNG library and makes it ready for use.
//! Should be created once at program startup.
//!
//! Note: not related to nng_ctx.

const std = @import("std");
const root = @import("./root.zig");
const c = @import("c");

io: std.Io,
allocator: std.mem.Allocator,

const Self = @This() ;

/// Initialize the context.
/// Expects `io` and `allocator` from the application entry point.
pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
    // _ = c.nng_init(null);

    return .{
        .io = io,
        .allocator = allocator,
    };
}
