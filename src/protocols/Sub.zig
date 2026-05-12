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
            if (TPipe == Pipe.Sync) GlobalSyncSubscriptionView(TTransport)
            else GlobalParallelSubscriptionView(TTransport)
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
    socket: u64,
    pipe: u64,
};

fn indexOfFilterId(filter_ids: []const u64, id: u64) ?usize {
    return std.mem.findScalar(u64, filter_ids, id);
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

pub fn GlobalSyncSubscriptionView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Sync),

        const View = @This();

        pub fn enableWidlcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWidlcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.socket), id) == null) {
                try view.protocol.topic_ids.append(allocator, .{ .socket = id, .pipe = 0 });
                _ = c.nng_sub0_socket_subscribe(view.protocol.pipe.pipe.socket.raw_socket, topic.ptr, topic.len);
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.socket), id)) |index| {
                view.protocol.topic_ids.orderedRemove(index);
                _ = c.nng_sub0_socket_unsubscribe(view.protocol.pipe.pipe.socket.raw_socket, topic.ptr, topic.len);
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

pub fn GlobalParallelSubscriptionView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Parallel),

        const View = @This();

        pub fn enableWidlcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWidlcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.socket), id) == null) {
                try view.protocol.topic_ids.append(allocator, .{ .socket = id, .pipe = 0 });
                _ = c.nng_sub0_socket_subscribe(view.protocol.pipe.socket.raw_socket, topic.ptr, topic.len);
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.socket), id)) |index| {
                view.protocol.topic_ids.orderedRemove(index);
                _ = c.nng_sub0_socket_unsubscribe(view.protocol.pipe.socket.raw_socket, topic.ptr, topic.len);
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

        pub fn lane_at(view: View, index: usize) ParallelSubscriptionItemView(TTransport) {
            std.debug.assert(index < view.protocol.pipe.items.len);

            return .{
                .protocol = view.protocol,
                .item = view.protocol.pipe.items[index],
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
            try view.enableWidlcard();
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
            try view.disableWidlcard();
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
            try view.enableWidlcard();
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
            try view.disableWidlcard();
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
};

pub fn ParallelSubscriptionItemView(comptime TTransport: type) type {
    return struct {
        protocol: *Sub.Protocol(TTransport, Pipe.Parallel),
        item: Pipe.Parallel.Item,

        const View = @This();

        pub fn enableWidlcard(view: *View) !void {
            try view.subscribe("");
        }

        pub fn disableWidlcard(view: *View) !void {
            try view.unsubscribe("");
        }

        pub fn subscribe(view:* View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.pipe), id) == null) {
                try view.protocol.topic_ids.append(allocator, .{ .socket = 0, .pipe = id });
                _ = c.nng_sub0_ctx_subscribe(view.item.raw_ctx, topic.ptr, topic.len);
            }
        }

        pub fn subscribeMany(view: *View, topics: []const []const u8) !void {
            for (topics) |topic| {
                try view.subscribe(topic);
            }
        }

        pub fn unsubscribe(view: *View, topic: []const u8) !void {
            const allocator = view.protocol.transport.socket.context.allocator;
            const id = try view.protocol.interner.intern(allocator, topic);

            if (indexOfFilterId(view.protocol.topic_ids.items(.pipe), id)) |index| {
                view.protocol.topic_ids.orderedRemove(index);
                _ = c.nng_sub0_ctx_unsubscribe(view.item.raw_ctx, topic.ptr, topic.len);
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
            try sub_view.enableWidlcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
            try sub_view.disableWidlcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
            try sub_view.enableWidlcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
            try sub_view.disableWidlcard();
            socket: {
                var subscriptions: std.ArrayList([]const u8) = .empty;
                defer subscriptions.deinit(std.testing.allocator);
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
                try view.extractSubscriptions(std.testing.allocator, &subscriptions);

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
