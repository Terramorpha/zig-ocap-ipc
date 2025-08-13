const std = @import("std");
const fcntl = @cImport(@cInclude("fcntl.h"));
const socket = @cImport(@cInclude("sys/socket.h"));
const un = @cImport(@cInclude("sys/un.h"));
const reflection = @import("./reflection.zig");
const posix = std.posix;

pub const UnixConn = struct {
    fd: reflection.Fd,

    pub fn stream(self: @This()) std.net.Stream {
        return std.net.Stream{
            .handle = self.fd,
        };
    }

    pub fn connect(socket_path: [:0]const u8) !@This() {
        const sock = std.c.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0);
        if (sock < 0) {
            return error.SocketFailed;
        }

        var addr = un.sockaddr_un{
            .sun_family = socket.AF_UNIX,
            .sun_path = undefined,
        };

        std.mem.copyForwards(u8, addr.sun_path[0..], socket_path[0 .. socket_path.len + 1]);

        const result = std.c.connect(sock, @ptrCast(&addr), @sizeOf(un.sockaddr_un));
        if (result < 0) {
            return error.ConnectFailed;
        }

        return @This(){
            .fd = reflection.Fd{ .fd = sock },
        };
    }

    fn Cmsg(comptime MAX_FDS: usize) type {
        return extern struct {
            header: socket.cmsghdr,
            fds: [MAX_FDS]posix.fd_t,
        };
    }

    pub fn sendmsg(self: @This(), comptime MAX_FDS: usize, main: []const u8, fds: []const posix.fd_t) !void {
        if (fds.len > MAX_FDS) {
            @panic("you lied 😠");
        }

        // The main data.
        var iov = [_]socket.iovec{.{
            .iov_base = @constCast(main.ptr),
            .iov_len = main.len,
        }};

        // The control message
        var cmsg = [_]Cmsg(MAX_FDS){.{
            .header = .{
                .cmsg_len = undefined,
                .cmsg_level = socket.SOL_SOCKET,
                .cmsg_type = socket.SCM_RIGHTS,
            },
            .fds = undefined,
        }};

        std.mem.copyForwards(posix.fd_t, cmsg[0].fds[0..], fds);

        const end_offset = @offsetOf(@TypeOf(cmsg[0]), "fds") + fds.len * @sizeOf(posix.fd_t);

        // We compute the useful message length
        cmsg[0].header.cmsg_len = end_offset;

        const msg = socket.msghdr{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = iov[0..].ptr,
            .msg_iovlen = 1,
            .msg_control = cmsg[0..].ptr,
            .msg_controllen = cmsg[0].header.cmsg_len,
            .msg_flags = 0,
        };

        const result = std.c.sendmsg(
            self.fd.fd,
            @ptrCast(&msg),
            0,
        );
        if (result < 0) {
            std.debug.print("errno: {}\n", .{posix.errno(result)});
            return error.SendMsgFailed;
        }
    }

    pub const RecvResult = struct {
        data_len: usize,
        fds_len: usize,
    };

    pub fn recvmsg(self: @This(), comptime MAX_FDS: usize, data: []u8, fds: []posix.fd_t) !RecvResult {

        // Regular pieces of data
        var iov = [_]socket.iovec{.{
            .iov_base = data.ptr,
            .iov_len = data.len,
        }};

        // Control messages
        var cmsg: Cmsg(MAX_FDS) = undefined;

        var msg: socket.msghdr = .{
            .msg_name = null,
            .msg_namelen = 0,
            .msg_iov = iov[0..].ptr,
            .msg_iovlen = 1,
            .msg_control = @ptrCast(&cmsg),
            .msg_controllen = @sizeOf(@TypeOf(cmsg)),
            .msg_flags = 0,
        };

        const result = std.c.recvmsg(self.fd.fd, @ptrCast(&msg), 0);
        if (result < 0) {
            std.debug.print("errno: {}\n", .{posix.errno(result)});
            return error.SendMsgFailed;
        }

        std.mem.copyForwards(posix.fd_t, fds, cmsg.fds[0..]);

        return RecvResult{
            .data_len = iov[0].iov_len,
            .fds_len = (cmsg.header.cmsg_len - @offsetOf(@TypeOf(cmsg), "fds")) / @sizeOf(posix.fd_t),
        };
    }
};

pub const UnixListener = struct {
    fd: c_int,

    pub fn bind(socket_path: [:0]const u8) !@This() {
        const sock = std.c.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0);

        if (sock < 0) {
            return error.Problem;
        }

        var addr = un.sockaddr_un{
            .sun_family = socket.AF_UNIX,
            .sun_path = undefined,
        };

        std.mem.copyForwards(u8, addr.sun_path[0..], socket_path[0 .. socket_path.len + 1]);

        _ = std.c.unlink(socket_path);

        const result = std.c.bind(sock, @ptrCast(&addr), @sizeOf(un.sockaddr_un));
        if (result < 0) {
            return error.BindFailed;
        }

        return @This(){ .fd = sock };
    }

    pub fn listen(self: @This()) !void {
        if (std.c.listen(self.fd, 0) < 0) {
            return error.ListenFailed;
        }
    }

    pub fn accept(self: @This()) !UnixConn {
        const fd = std.c.accept(self.fd, null, null);
        if (fd < 0) {
            return error.AcceptFailed;
        }

        return UnixConn{ .fd = reflection.Fd{ .fd = fd } };
    }

    pub fn close(self: @This()) !void {
        if (std.c.close(self.fd) < 0) {
            return error.Failed;
        }
    }
};
