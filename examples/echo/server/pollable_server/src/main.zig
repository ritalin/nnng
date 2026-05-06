const std = @import("std");
const nnng = @import("nnng");
const supports = @import("echo_support");

pub fn main(init: std.process.Init) !void {
    const ctx = nnng.Context.init(init.io, init.gpa);

    const url = try supports.make_ipc_url(init, "echo-pollable");
    defer init.gpa.free(url);

    var rep_socket: nnng.rep.Rep(nnng.Transport.Listener, nnng.Pipe.Parallel) = socket: {
        var b = try nnng.rep.open(ctx);
        break:socket try b.parallel(3).as_listener(url);
    };
    errdefer rep_socket.close();

    try rep_socket.transport.start();
    defer rep_socket.close();

    var poller = try nnng.ReceivePoller.create(ctx, 4);
    defer poller.deinit();

    try poller.attach(&rep_socket.pipe);

    while (true) {
        _ = try poller.poll(PollerCallback.replyMessage);
    }
}

const PollerCallback = struct {
    pub fn replyMessage(poller: *nnng.ReceivePoller, results: []const nnng.ReceivePoller.WakeupResult) anyerror!void {
        for (results) |result| {
            switch (result.event) {
                .failed => |err| {
                    outputReceiveErrorLog(err.id, err.err);
                },
                .ready => |channel| {
                    var msg = try channel.receiver().drain(.{});
                    const v = try poller.context.allocator.dupe(u8, msg.bytes());
                    defer poller.context.allocator.free(v);

                    msg.writer.end = 0;
                    try msg.writer.print("{s}{s}", .{ v, v });
                    try  msg.writer.flush();

                    try channel.sender().submit(msg, .{ .nonblocking = true });
                }
            }
        }
    }
};

fn outputReceiveErrorLog(id: u64, err: nnng.ReceiveError) void {
    std.log.err("{s}/id: {}\n", .{ @errorName(err), id });
}
