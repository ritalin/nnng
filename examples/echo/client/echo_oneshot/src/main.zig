const std = @import("std");
const clap = @import("clap");
const nnng = @import("nnng");
const supports = @import("echo_support");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit
        \\-s, --socket <string> IPC socket file name without extension
        \\<string>               Input value
    );
    const exe_path = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(exe_path);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        try showHelp(init.io, exe_path, &params);
        return;
    };
    defer res.deinit();

    if ((res.args.help != 0) or (res.args.socket == null and res.positionals[0] == null)) {
        try showHelp(init.io, exe_path, &params);
        return;
    }

    const ctx = nnng.Context.init(init.io, init.gpa);

    const url = try supports.make_ipc_url(init, res.args.socket.?);
    defer init.gpa.free(url);

    var socket = socket: {
        var b = try nnng.req.open(ctx);
        break:socket try b.as_dialer(url);
    };
    try socket.transport.start();
    defer socket.close();

    var iter = socket.pipe.iter();
    const pipe = iter.next() orelse unreachable;

    var msg = try nnng.Message.create();
    try msg.writer.writeAll(res.positionals[0].?);
    try msg.writer.flush();
    try pipe.sender().submit(msg, .{});

    msg = try pipe.receiver().drain(.{});
    const result = msg.bytes();

    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    try writer.interface.writeAll(result);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn showHelp(io: std.Io, exe_path: []const u8, params: []const clap.Param(clap.Help)) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);

    try writer.interface.print("\nUsage:\n{s} ", .{ std.fs.path.basename(exe_path) });
    try clap.usage(&writer.interface, clap.Help, params);

    try writer.interface.writeAll("\n" ** 2);
    try writer.interface.writeAll("Options:\n");
    try clap.help(&writer.interface, clap.Help, params, .{ .description_on_new_line = false, .spacing_between_parameters = 0 });
    try writer.interface.flush();

}
