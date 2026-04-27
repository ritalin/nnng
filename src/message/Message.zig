const std = @import("std");
const root = @import("../root.zig");
const c = @import("c");

raw_msg: *c.nng_msg,
writer: std.Io.Writer,

const vtbl: std.Io.Writer.VTable = .{
    .drain = Impl.drainInternal,
    .sendFile = std.Io.Writer.unimplementedSendFile,
    .flush = Impl.flushInternal,
    .rebase = Impl.unimplementedRebase,
};

const Self = @This();
const ALIGNED_BUF_SIZE: usize = 1024;

pub fn create() !Self {
    return Self.with_capacity(ALIGNED_BUF_SIZE);
}

pub fn with_capacity(cap: usize) root.MessageAllocError!Self {
    var raw_msg: ?*c.nng_msg = null;
    const err = c.nng_msg_alloc(&raw_msg, cap);
    if (err != 0) {
        return error.OutOfMemory;
    }

    const p: [*c]u8 = @ptrCast(c.nng_msg_body(raw_msg));
    const buffer = p[0..cap];

    return .{
        .raw_msg = raw_msg.?,
        .writer = .{
            .vtable = &vtbl,
            .buffer = buffer,
            .end = 0,
        },
    };
}

pub fn from_raw(raw_msg: *c.nng_msg) Self {
    const p: [*c]u8 = @ptrCast(c.nng_msg_body(raw_msg));
    const end = c.nng_msg_len(raw_msg);
    const buffer = p[0..end];

    return .{
        .raw_msg = raw_msg,
        .writer = .{
            .vtable = &vtbl,
            .buffer = buffer,
            .end = end,
        },
    };
}

pub fn deinit(self: *Self) void {
    c.nng_msg_free(self.raw_msg);
    self.* = undefined;
}

pub fn len(self: Self) usize {
    return c.nng_msg_len(self.raw_msg);
}

pub fn bytes(self: Self) []const u8 {
    const p: [*c]u8 = @ptrCast(c.nng_msg_body(self.raw_msg));

    return p[0..self.len()];
}

const Impl = struct {
    fn drainInternal(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Self = @fieldParentPtr("writer", w);

        const cap = c.nng_msg_capacity(self.raw_msg);
        var req_size: usize = 0;
        for (0..splat) |i| { req_size += data[i].len; }
        const new_size = std.mem.alignForward(usize, (cap + req_size) * 2, ALIGNED_BUF_SIZE);

        if (c.nng_msg_realloc(self.raw_msg, new_size) != 0) {
            return error.WriteFailed;
        }

        const p: [*c]u8 = @ptrCast(c.nng_msg_body(self.raw_msg));
        w.buffer = p[0..new_size];

        for (0..splat) |i| {
            const src_len = data[i].len;
            @memcpy(w.buffer[w.end..][0..src_len], data[i]);
            w.end += src_len;
        }

        return req_size;
    }

    fn flushInternal(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Self = @fieldParentPtr("writer", w);

        std.log.debug("Flush msg/len: {}, end: {}", .{ self.len(), w.end });

        const err = c.nng_msg_realloc(self.raw_msg, w.end);
        if (err != 0) {
            return error.WriteFailed;
        }
    }

    fn unimplementedRebase(w: *std.Io.Writer, preserve: usize, cap: usize) std.Io.Writer.Error!void {
        _ = w;
        _ = preserve;
        _ = cap;
        return error.WriteFailed;
    }
};

test "create message (default size)" {
    var msg = try Self.create();
    defer msg.deinit();
    try std.testing.expectEqual(ALIGNED_BUF_SIZE, msg.len());
}

test "create message (specified size)" {
    var msg = try Self.with_capacity(1);
    defer msg.deinit();
    try std.testing.expectEqual(1, msg.len());
}

test "write message payload" {
    var msg = try Self.create();
    defer msg.deinit();

    try msg.writer.print("{s} {s}", .{"Hello", "World"});
    try msg.writer.flush();

    try std.testing.expectEqualSlices(u8, "Hello World", msg.writer.buffered());
    try std.testing.expectEqual("Hello World".len, msg.len());
}

test "write message payload with extend capacity" {
    const INITIAL_SIZE = 8;
    var msg = try Self.with_capacity(INITIAL_SIZE);
    defer msg.deinit();

    const s = "Hello";
    try msg.writer.writeAll(s);
    try std.testing.expectEqual(8, msg.len());

    try msg.writer.writeAll(s);
    try std.testing.expectEqual(ALIGNED_BUF_SIZE , msg.len());

    try msg.writer.writeAll(s);
    try std.testing.expectEqual(ALIGNED_BUF_SIZE , msg.len());

    try msg.writer.writeAll(s ** 897);
    try std.testing.expectEqual(ALIGNED_BUF_SIZE * 11, msg.len()); // align{ (1024 + 5 x 897) x 2, 1024 }

    try msg.writer.flush();
    try std.testing.expectEqual(s.len * 900, msg.len());
}
