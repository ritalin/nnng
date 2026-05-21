const std = @import("std");
const nnng = @import("nnng");
const Poller = nnng.ReceivePoller(1);

pub fn main(init: std.process.Init) !void {
    const ctx = nnng.Context.init(init.io, init.gpa);
    const url = "inproc://shell";

    std.log.info("Inproc url: {s}", .{url});

    // Open PUSH socket
    var push_socket: nnng.Push.Protocol(nnng.Transport.Dialer, nnng.Pipe.Sync) = socket: {
        var b = try nnng.Push.open(ctx);
        break:socket try b.as_dialer(url);
    };
    errdefer push_socket.close();

    try push_socket.transport.start(.{});
    defer push_socket.close();

    // Open PULL socket
    var pull_socket: nnng.Pull.Protocol(nnng.Transport.Listener, nnng.Pipe.Sync) = socket: {
        var b = try nnng.Pull.open(ctx);
        break:socket try b.as_listener(url);
    };
    errdefer pull_socket.close();

    try pull_socket.transport.start(.{});
    defer pull_socket.close();

    const pusg_pipe = pipe: {
        var iter = push_socket.pipe.iter();
        break:pipe iter.next().?;
    };

    var cb = try PollerCallback.create(ctx, pusg_pipe, std.Io.File.stdout(), std.Io.File.stdin());
    defer cb.deinit();

    try Poller.Sync.attach(&cb.poller, &pull_socket.pipe);

    try cb.put("Quit by typing `:q` or `:quit`\n", .{});
    try cb.watchStdin();

    var i: i32 = 0;

    while(i < 4) {
        i += 1;
        try cb.reaper.tick();
        _ = try cb.poller.poll(PollerCallback.handleMessage);

        if (cb.is_quit) break;
    }
}

const PollerCallback = struct {
    context: nnng.Context,
    push_pipe: *const nnng.Pipe.Sync.Item,
    poller: Poller,
    stdout: std.Io.File.Writer,
    stdin: std.Io.File.Reader,
    is_quit: bool = false,
    reaper: *DetachedTaskReaper(1),

    const Self = @This();

    pub fn create(ctx: nnng.Context, push_pipe: *const nnng.Pipe.Sync.Item, stdout: std.Io.File, stdin: std.Io.File) !Self {
        const out_buffer = try ctx.allocator.alloc(u8, 4096);
        const in_buffer = try ctx.allocator.alloc(u8, 4096);

        return .{
            .context = ctx,
            .push_pipe = push_pipe,
            .poller = try Poller.create(ctx),
            .stdout = stdout.writer(ctx.io, out_buffer),
            .stdin = stdin.reader(ctx.io, in_buffer),
            .reaper = try DetachedTaskReaper(1).create(ctx.io, ctx.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.context.allocator.free(self.stdout.interface.buffer);
        self.context.allocator.free(self.stdin.interface.buffer);
        self.reaper.deinit(self.context.allocator);
        self.poller.deinit();
    }

    pub fn put(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.stdout.interface.print(fmt, args);
        try self.stdout.flush();
    }

    fn watchStdin(self: *Self) !void {
        try self.put("$ ", .{});

        // invoke as fire and forget
        try self.reaper.spawn(watchStdinInternal, .{ self.push_pipe, &self.stdin });
    }

    pub fn handleMessage(poller: *Poller, results: []const Poller.WakeupResult) anyerror!void {
        if (results.len == 0) return;

        var self: *Self = @alignCast(@fieldParentPtr("poller", poller));

        if (std.meta.activeTag(results[0].event) == .ready) {
            const channel = results[0].event.ready;
            var msg = try channel.receiver().drain(.{});
            // PULL socket is responsible for freeing this msg
            defer msg.deinit();

            const line = msg.bytes();

            if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":quit")) {
                self.is_quit = true;
            }
            else {
                try self.put("> {s}\n", .{ line });
                try self.watchStdin();
            }
        }

    }
};

fn watchStdinInternal(pipe: *const nnng.Pipe.Sync.Item, stdin: *std.Io.File.Reader) !void {
    var msg = try nnng.Message.create();
    _ = try stdin.interface.streamDelimiter(&msg.writer, '\n');
    _ = try stdin.interface.take(1); // drop CR/LF

    try msg.writer.flush();
    try pipe.sender().submit(msg, .{ .flags = .{ .nonblocking = true } });
}

fn DetachedTaskReaper(comptime buffer_size: comptime_int) type {
    return struct {
        buffer: [buffer_size]TaskResult = undefined,
        tasks: std.Io.Select(TaskResult),

        const Self = @This();

        pub fn create(io: std.Io, allocator: std.mem.Allocator) !*Self {
            var self = try allocator.create(Self);
            self.* =  .{
                .tasks = std.Io.Select(TaskResult).init(io, &self.buffer),
            };

            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.tasks.cancelDiscard();
            allocator.destroy(self);
        }

        pub fn spawn(self: *Self, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
            return self.tasks.concurrent(.item, function, args);
        }

        pub fn tick(self: *Self) !void {
            var buffer: [buffer_size]TaskResult = undefined;
            const len = try self.tasks.awaitMany(&buffer, 0);

            for (buffer[0..len]) |result| {
                result.item catch |err| {
                    std.log.err("Detached task has error: {s}", .{ @errorName(err) });
                };
            }
        }

        const TaskResult = union(enum) { item: anyerror!void };
    };
}
