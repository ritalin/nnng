///! Parallel SUB subscriptions are designed for logical subscription
///! separation, not message distribution.
///!
///! Each subscription may maintain its own filter set while sharing
///! the same underlying connection resources.
///!
///! Note:
///! Subscriptions using the same filter are not load-balanced.
///! The same published message may be delivered to multiple subscriptions.

const std = @import("std");
const root = @import("../root.zig");
const errors = @import("../error_handlers.zig");
const c = @import("c");

const Sub = @This();

const Context = root.Context;
const Socket = root.Socket;
const OpenError = root.OpenError;
const Transport = root.Transport;
const Pipe = root.Pipe;

const comptime_feature: Socket.ComptimeFeature = .{
    .protocol_name = @typeName(@This()),
};

/// Creates a SUB protocol socket instance.
/// This is the primary way to construct the type.
pub fn open(ctx: Context) OpenError!Socket.SyncBuilder(Sub.Protocol, comptime_feature) {
    var raw_socket: c.nng_socket = undefined;
    const err = c.nng_sub0_open(&raw_socket);
    if (err != 0) {
        return errors.open_error(err);
    }

    const socket = Socket.init(ctx, raw_socket);
    const features: Pipe.Features = .{
        .receive_first = true,
        .last_msg_owner = true,
    };

    return Socket.SyncBuilder(Sub.Protocol, comptime_feature).init(socket, features);
}

/// SUB protocol type.
/// Transport: connection role (Listener or Dialer).
/// Pipe: message handling model (Sync or Parallel).
pub fn Protocol(comptime TTransport: type, comptime TPipe: type) type {
    return struct {
        /// Transport role.
        transport: TTransport,
        /// Pipe model.
        pipe: TPipe,
        /// Subscription interner
        interner: Interner,
        /// Subscription interned topic Ids
        topic_ids: std.MultiArrayList(FilterSet),

        const Self = @This();

        /// Initializes the instance.
        /// Intended for internal use; prefer open().
        pub fn init(transport: TTransport, pipe: TPipe) Self {
            return .{
                .transport = transport,
                .pipe = pipe,
                .interner = Interner.init(),
                .topic_ids = .empty,
            };
        }

        /// Releases all associated resources.
        pub fn close(self: *Self) void {
            self.topic_ids.deinit(self.transport.socket.context.allocator);
            self.interner.deinit(self.transport.socket.context.allocator);
            self.pipe.deinit();
            self.transport.deinit();
            self.transport.socket.close();
        }

        /// Manage topic subscription.
        pub fn subscriptionView(self: *Self)
            if (TPipe == Pipe.Sync) SyncSocketSubscriptionView(TTransport)
            else ParallelSocketSubscriptionView(TTransport)
        {
            return .{
                .protocol = self,
            };
        }
    };
}

test "SUB tests" {
    std.testing.refAllDecls(@This());
}

pub const tests = struct {
    const test_support = @import("../supports/test.zig");

    const Message = @import("../message/Message.zig");
    const Sender = @import("../message/Sender.zig");
    const Receiver = @import("../message/Receiver.zig");

    test "new SUB socket" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pub_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();
    }

    test "SUB socket features for sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pusb_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var iter = socket.pipe.iter();
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe != null);
            try std.testing.expectEqualDeep(Pipe.Features{ .receive_first = true, .last_msg_owner = true }, pipe.?.features);
            break:pipe;
        }
        pipe: {
            const pipe = iter.next();
            try std.testing.expect(pipe == null);
            break:pipe;
        }
    }
};

const Interner = struct {
    map: std.StringHashMapUnmanaged(u64),
    rev_map: std.AutoArrayHashMapUnmanaged(u64, []const u8),

    pub fn init() Interner {
        return .{
            .map = .empty,
            .rev_map = .empty,
        };
    }

    pub fn deinit(self: *Interner, allocator: std.mem.Allocator) void {
        self.rev_map.deinit(allocator);

        var keys = self.map.keyIterator();
        while (keys.next()) |key| {
            allocator.free(key.*);
        }
        self.map.deinit(allocator);
    }

    pub fn count(self: *Interner) usize {
        return self.map.count();
    }

    pub fn intern(self: *Interner, allocator: std.mem.Allocator, filter: []const u8) !u64 {
        const entry = try self.map.getOrPut(allocator, filter);
        if (!entry.found_existing) {
            const id = self.count();
            const key = try allocator.dupe(u8, filter);

            entry.key_ptr.* = key;
            entry.value_ptr.* = id;

            try self.rev_map.put(allocator, id, key);
        }

        return entry.value_ptr.*;
    }

    pub fn projection(self: *Interner, allocator: std.mem.Allocator, interns: []const bool, buf: *std.ArrayListUnmanaged([]const u8)) !void {
        for (interns, 0..) |accept, i| {
            if (accept) {
                if (self.rev_map.get(i)) |s| {
                    try buf.append(allocator, s);
                }
            }
        }
    }
};

const FilterSet = struct {
    pipe_index: usize,
    socket: u64,
    pipe: u64,
};

const FilterSetNeedle = struct {
    intern: u64,
    pipe_index: ?usize,
};

const FilterSetRevIterator = struct {
    slice: []const u64,
    needle: FilterSetNeedle,
    index: usize,

    pub fn init(slice: []const u64, needle: FilterSetNeedle) @This() {
        return .{
            .slice = slice,
            .needle = needle,
            .index = slice.len,
        };
    }

    pub fn next(self: *@This()) ?usize {
        while (self.index > 0) {
            self.index -= 1;
            if (self.slice[self.index] == self.needle.intern) {
                return self.index;
            }
        }

        return null;
    }
};

fn indexOfFilter(pipe_indices: []const usize, interns: []const u64, needle: FilterSetNeedle) ?usize {
    for (pipe_indices, interns, 0..) |pipe_index, intern, i| {
        if (intern != needle.intern) continue;
        if (needle.pipe_index) |index| {
            if (pipe_index != index) continue;
        }
        return i;
    }
    return null;
}

fn subscriptionIds(filters: std.MultiArrayList(FilterSet).Slice, comptime fields: []const @EnumLiteral(), ids: []bool) void {
    inline for (fields) |field| {
        for (filters.items(field)) |id| {
            if (id > 0) {
                ids[id] = true;
            }
        }
    }
}

pub const intern_test = struct {
    test "Intern symbol" {
        var interner = Interner.init();
        defer interner.deinit(std.testing.allocator);

        try std.testing.expectEqual(1, try interner.intern(std.testing.allocator, "abc"));
        try std.testing.expectEqual(2, try interner.intern(std.testing.allocator, "xyz"));
        try std.testing.expectEqual(3, try interner.intern(std.testing.allocator, ""));
        try std.testing.expectEqual(2, try interner.intern(std.testing.allocator, "xyz"));
    }

    test "Projection symbols for empty interns" {
        var interner = Interner.init();
        defer interner.deinit(std.testing.allocator);

        var subscriptions: std.ArrayListUnmanaged([]const u8) = .empty;
        defer subscriptions.deinit(std.testing.allocator);

        try interner.projection(std.testing.allocator, &.{false, false, false, false}, &subscriptions);
        try std.testing.expectEqual(0, subscriptions.items.len);
    }

    test "Projection symbols for unexisting interns" {
        var interner = Interner.init();
        defer interner.deinit(std.testing.allocator);

        _ = try interner.intern(std.testing.allocator, "abc");
        _ = try interner.intern(std.testing.allocator, "xyz");

        var subscriptions: std.ArrayListUnmanaged([]const u8) = .empty;
        defer subscriptions.deinit(std.testing.allocator);

        try interner.projection(std.testing.allocator, &.{ false, false, false, true }, &subscriptions);
        try std.testing.expectEqual(0, subscriptions.items.len);
    }

    test "Projection symbols" {
        var interner = Interner.init();
        defer interner.deinit(std.testing.allocator);

        var interns: [4]bool = .{ false, false, false, false, };
        interns[try interner.intern(std.testing.allocator, "abc")] = true;
        interns[try interner.intern(std.testing.allocator, "xyz")] = true;
        interns[try interner.intern(std.testing.allocator, "")] = true;
        interns[try interner.intern(std.testing.allocator, "xyz")] = true;

        var subscriptions: std.ArrayListUnmanaged([]const u8) = .empty;
        defer subscriptions.deinit(std.testing.allocator);

        try interner.projection(std.testing.allocator, &interns, &subscriptions);
        try std.testing.expectEqualDeep(&[_][]const u8{"abc", "xyz", ""}, subscriptions.items);
    }
};

pub fn SyncSocketSubscriptionView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Sync),

        const View = @This();

        pub fn enableWildcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWildcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);
            const interns: []const u64 = view.protocol.topic_ids.items(.socket);

            if (indexOfFilter(pipe_indices, interns, .{ .intern = intern, .pipe_index = null }) == null) {
                try view.protocol.topic_ids.append(allocator, .{ .pipe_index = 0, .socket = intern, .pipe = 0 });
                _ = c.nng_sub0_socket_subscribe(view.protocol.pipe.item.socket.raw_socket, topic.ptr, topic.len);
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);
            const interns: []const u64 = view.protocol.topic_ids.items(.socket);

            if (indexOfFilter(pipe_indices, interns, .{ .intern = intern, .pipe_index = null })) |index| {
                view.protocol.topic_ids.orderedRemove(index);
                _ = c.nng_sub0_socket_unsubscribe(view.protocol.pipe.item.socket.raw_socket, topic.ptr, topic.len);
            }
        }

        pub fn unsubscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.unsubscribe(topic);
            }
        }

        pub fn extractSubscriptions(view: *View, allocator: std.mem.Allocator, buf: *std.ArrayList([]const u8)) !void {
            const dedupe_ids = try allocator.alloc(bool, view.protocol.interner.count() + 1);
            defer allocator.free(dedupe_ids);

            subscriptionIds(view.protocol.topic_ids.slice(), &[_]@EnumLiteral(){ .socket }, dedupe_ids);
            try view.protocol.interner.projection(allocator, dedupe_ids, buf);
        }
    };
}

pub fn ParallelSocketSubscriptionView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Parallel),

        const View = @This();

        pub fn enableWildcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWildcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);
            const interns: []const u64 = view.protocol.topic_ids.items(.socket);

            if (indexOfFilter(pipe_indices, interns, .{ .intern = intern, .pipe_index = null }) == null) {
                for (view.protocol.pipe.items, 0..) |pipe, i| {
                    try view.protocol.topic_ids.append(allocator, .{ .pipe_index = i, .socket = intern, .pipe = 0 });
                    _ = c.nng_sub0_ctx_subscribe(pipe.raw_ctx, topic.ptr, topic.len);
                }
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const topic_interns: []const u64 = view.protocol.topic_ids.items(.socket);
            const pipe_interns: []const u64 = view.protocol.topic_ids.items(.pipe);
            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);

            var iter = FilterSetRevIterator.init(topic_interns, .{ .intern = intern, .pipe_index = null });

            while (iter.next()) |index| {
                view.protocol.topic_ids.orderedRemove(index);
            }

            for (0..view.protocol.pipe.items.len) |i| {
                if (indexOfFilter(pipe_indices, pipe_interns, .{ .intern = intern, .pipe_index = i }) == null) {
                    const pipe = view.protocol.pipe.items[i];
                    _ = c.nng_sub0_ctx_unsubscribe(pipe.raw_ctx, topic.ptr, topic.len);
                }
            }
        }

        pub fn unsubscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.unsubscribe(topic);
            }
        }

        pub fn extractScopeSubscriptions(view: *View, allocator: std.mem.Allocator, buf: *std.ArrayList([]const u8)) !void {
            const dedupe_ids = try allocator.alloc(bool, view.protocol.interner.count() + 1);
            defer allocator.free(dedupe_ids);

            subscriptionIds(view.protocol.topic_ids.slice(), &[_]@EnumLiteral(){ .socket }, dedupe_ids);
            try view.protocol.interner.projection(allocator, dedupe_ids, buf);
        }

        pub fn lane_at(view: View, index: usize) ParallelPipeSubscriptionView(TTransport) {
            std.debug.assert(index < view.protocol.pipe.items.len);

            return .{
                .protocol = view.protocol,
                .index = index,
            };
        }
    };
}

pub const global_subscription = struct {
    const test_support = @import("../supports/test.zig");

    test "Subscription wildcard for global sync pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pusb_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Sync) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var view = socket.subscriptionView();

        subscription: {
            try view.enableWildcard();
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribe("qwerty");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribeMany(&.{ "abc", "def" });
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribe("qwerty");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
            break:subscription;
        }
        unsubscribe: {
            try view.unsubscribe("abc");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "def" }, subscriptions.items);
            break:unsubscribe;
        }
        unsubscribe: {
            try view.disableWildcard();
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "def" }, subscriptions.items);
            break:unsubscribe;
        }
        unsubscribe: {
            try view.unsubscribeMany(&.{ "def", "qwerty",  });
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
            break:unsubscribe;
        }
    }

    test "Subscription for global parallel pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pusb_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var view = socket.subscriptionView();
        subscription: {
            try view.enableWildcard();
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribe("qwerty");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribeMany(&.{ "abc", "def" });
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
            break:subscription;
        }
        subscription: {
            try view.subscribe("qwerty");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
            break:subscription;
        }
        unsubscribe: {
            try view.unsubscribe("abc");
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "def" }, subscriptions.items);
            break:unsubscribe;
        }
        unsubscribe: {
            try view.disableWildcard();
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "def" }, subscriptions.items);
            break:unsubscribe;
        }
        unsubscribe: {
            try view.unsubscribeMany(&.{ "def", "qwerty",  });
            var subscriptions: std.ArrayList([]const u8) = .empty;
            defer subscriptions.deinit(std.testing.allocator);
            try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

            try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
            break:unsubscribe;
        }
    }
};

pub fn ParallelPipeSubscriptionView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Parallel),
        index: usize,

        const View = @This();

        pub fn enableWildcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWildcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);
            const interns: []const u64 = view.protocol.topic_ids.items(.pipe);

            if (indexOfFilter(pipe_indices, interns, .{ .intern = intern, .pipe_index = view.index }) == null) {
                try view.protocol.topic_ids.append(allocator, .{ .pipe_index = view.index, .socket = 0, .pipe = intern });
                _ = c.nng_sub0_ctx_subscribe(view.protocol.pipe.items[view.index].raw_ctx, topic.ptr, topic.len);
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const intern = try view.protocol.interner.intern(allocator, topic);

            const pipe_indices: []const usize = view.protocol.topic_ids.items(.pipe_index);
            const interns: []const u64 = view.protocol.topic_ids.items(.pipe);

            if (indexOfFilter(pipe_indices, interns, .{ .intern = intern, .pipe_index = view.index })) |index| {
                view.protocol.topic_ids.orderedRemove(index);
                _ = c.nng_sub0_ctx_unsubscribe(view.protocol.pipe.items[view.index].raw_ctx, topic.ptr, topic.len);
            }
        }

        pub fn unsubscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.unsubscribe(topic);
            }
        }

        pub fn extractScopeSubscriptions(view: *View, allocator: std.mem.Allocator, buf: *std.ArrayList([]const u8)) !void {
            const dedupe_ids = try allocator.alloc(bool, view.protocol.interner.count() + 1);
            defer allocator.free(dedupe_ids);

            subscriptionIds(view.protocol.topic_ids.slice(), &[_]@EnumLiteral(){ .pipe }, dedupe_ids);
            try view.protocol.interner.projection(allocator, dedupe_ids, buf);
        }

        pub fn extractSubscriptions(view: *View, allocator: std.mem.Allocator, buf: *std.ArrayList([]const u8)) !void {
            const dedupe_ids = try allocator.alloc(bool, view.protocol.interner.count() + 1);
            defer allocator.free(dedupe_ids);

            subscriptionIds(view.protocol.topic_ids.slice(), &[_]@EnumLiteral(){ .socket, .pipe }, dedupe_ids);
            try view.protocol.interner.projection(allocator, dedupe_ids, buf);
        }
    };
}

pub const pipe_subscription = struct {
    const test_support = @import("../supports/test.zig");

    test "Subscription pipe only" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pusb_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var view = socket.subscriptionView();
        var sub_view = view.lane_at(1);

        subscription: {
            try sub_view.enableWildcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try sub_view.subscribe("qwerty");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try sub_view.subscribeMany(&.{ "abc", "def" });
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try sub_view.subscribe("qwerty");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        unsubscribe: {
            try sub_view.unsubscribe("abc");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "def" }, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
        unsubscribe: {
            try sub_view.disableWildcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "def" }, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
        unsubscribe: {
            try sub_view.unsubscribeMany(&.{ "def", "qwerty",  });
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
    }

    test "Subscription mixed socket and pipe" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const url = try test_support.make_ipc_sock(tmp.dir, "pusb_sub");
        defer std.testing.allocator.free(url);

        const ctx = Context.init(std.testing.io, std.testing.allocator);
        var socket: Sub.Protocol(Transport.Listener, Pipe.Parallel) = socket: {
            var b = try Sub.open(ctx);
            break:socket try b.parallel(3).as_listener(url);
        };
        try socket.transport.start(.{});
        defer socket.close();

        var view = socket.subscriptionView();
        var sub_view = view.lane_at(1);

        subscription: {
            try sub_view.enableWildcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try view.subscribe("qwerty");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty" }, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try view.subscribeMany(&.{ "abc", "def" });
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "abc", "def" }, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        subscription: {
            try sub_view.subscribe("qwerty");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "abc", "def" }, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc", "def" }, subscriptions.items);
                break:pipe;
            }
            break:subscription;
        }
        unsubscribe: {
            try view.unsubscribe("def");
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "abc" }, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "", "qwerty", "abc" }, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
        unsubscribe: {
            try sub_view.disableWildcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "abc" }, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty", "abc" }, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
        unsubscribe: {
            try view.unsubscribeMany(&.{ "abc", "qwerty",  });
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractScopeSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{}, subscriptions.items);
                break:socket;
            }
            pipe: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try sub_view.extractSubscriptions(std.testing.allocator, &subscriptions);

                try std.testing.expectEqualDeep(&[_][]const u8{ "qwerty" }, subscriptions.items);
                break:pipe;
            }
            break:unsubscribe;
        }
    }
};
