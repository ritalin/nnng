const std = @import("std");
const nnng = @import("nnng");
const supports = @import("echo_support");

pub fn main(init: std.process.Init) !void {
    const ctx = nnng.Context.init(init.io, init.gpa);

    const url = try supports.make_ipc_url(init, "echo-blocking");
    defer init.gpa.free(url);

    std.log.info("IPC url: {s}", .{url});

    var rep_socket: nnng.rep.Rep(nnng.Transport.Listener, nnng.Pipe.Parallel) = socket: {
        var b = try nnng.rep.open(ctx);
        break:socket try b.parallel(3).as_listener(url);
    };
    errdefer rep_socket.close();

    try rep_socket.transport.start();
    defer rep_socket.close();

    var pipes = rep_socket.pipe.iter();
    const pipe = pipes.next() orelse unreachable;

    while (true) {
        var msg = try pipe.receiver().drain(.{});
        const value = try init.gpa.dupe(u8, msg.bytes());
        defer init.gpa.free(value);

        msg.writer.end = 0;
        try msg.writer.print("{s} ... {s} ...", .{value, value});
        try msg.writer.flush();
        try pipe.sender().submit(msg, .{});
    }
    std.debug.print("Hello World\n", .{});
}
