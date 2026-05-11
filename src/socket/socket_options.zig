const std = @import("std");
const c = @import("c");

pub const Option = struct {
    pub const Values = struct {
        pub const Set = struct {
            /// This is the socket send timeout in milliseconds.
            send_timeout: ?i32 = null,
            /// This is the socket receive timeout in milliseconds.
            recv_timeout: ?i32 = null,
        };

        pub const Get = struct {
            /// file descriptor suitable for use with poll(), select() for send
            send_fd: ?c_int = null,
            /// file descriptor suitable for use with poll(), select() for recv
            recv_fd: ?c_int = null,
            /// This is the socket send timeout in milliseconds.
            send_timeout: ?i32 = null,
            /// This is the socket receive timeout in milliseconds.
            recv_timeout: ?i32 = null,
            /// A connected peer’s primary group id
            peer_gid: ?u64 = null,
            /// A process id of the connected peer,
            peer_pid: ?u64 = null,
            /// A connected peer’s user id
            peer_uid: ?u64 = null,
        };
    };
};

pub const OptionInfo = struct {
    raw_name: [*c]const u8,
    type: type,
};

const GetOptionInfoMap = std.StaticStringMap(OptionInfo).initComptime(.{
    .{ @tagName(.send_fd), OptionInfo{ .raw_name = c.NNG_OPT_SENDFD, .type = c_int } },
    .{ @tagName(.recv_fd), OptionInfo{ .raw_name = c.NNG_OPT_RECVFD, .type = c_int } },
    .{ @tagName(.send_timeout), OptionInfo{ .raw_name = c.NNG_OPT_SENDTIMEO, .type = i32 } },
    .{ @tagName(.recv_timeout), OptionInfo{ .raw_name = c.NNG_OPT_RECVTIMEO, .type = i32 } },
    .{ @tagName(.peer_gid), OptionInfo{ .raw_name = c.NNG_OPT_PEER_GID, .type = u64 } },
    .{ @tagName(.peer_pid), OptionInfo{ .raw_name = c.NNG_OPT_PEER_PID, .type = u64 } },
    .{ @tagName(.peer_uid), OptionInfo{ .raw_name = c.NNG_OPT_PEER_UID, .type = u64 } },
});

pub fn findGetOptionInfo(field: std.meta.FieldEnum(Option.Values.Get)) ?OptionInfo {
    return GetOptionInfoMap.get(@tagName(field));
}

const SetOptionInfoMap = std.StaticStringMap(OptionInfo).initComptime(.{
    .{ @tagName(.send_timeout), OptionInfo{ .raw_name = c.NNG_OPT_SENDTIMEO, .type = i32 } },
    .{ @tagName(.recv_timeout), OptionInfo{ .raw_name = c.NNG_OPT_RECVTIMEO, .type = i32 } },
});

pub fn findSetOptionInfo(field: std.meta.FieldEnum(Option.Values.Set)) ?OptionInfo {
    return SetOptionInfoMap.get(@tagName(field));
}
