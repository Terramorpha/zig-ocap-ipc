//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const posix = std.posix;
const fcntl = @cImport(@cInclude("fcntl.h"));
const socket = @cImport(@cInclude("sys/socket.h"));
const un = @cImport(@cInclude("sys/un.h"));

fn printerr(err: std.c.E) void {
    std.debug.print("error: {}\n", .{err});
}

fn Channel(comptime T: type) type {
    return struct {
        const MAX_FDS = 16;

        socket: UnixConn,

        const Cmsg = extern struct {
            header: socket.cmsghdr,
            fds: [MAX_FDS]posix.fd_t,
        };

        fn send(self: @This(), obj: T) !void {
            var fds: [MAX_FDS]posix.fd_t = undefined;
            var next: usize = 0;

            extractFds(T, obj, fds[0..].ptr, &next);

            // We do the sendmsg syscall

            var iov = [_]socket.iovec{.{
                .iov_base = @constCast(&obj),
                .iov_len = @sizeOf(T),
            }};

            var cmsg = [_]Cmsg{.{
                .header = .{
                    .cmsg_len = undefined,
                    .cmsg_level = socket.SOL_SOCKET,
                    .cmsg_type = socket.SCM_RIGHTS,
                },
                .fds = fds,
            }};

            cmsg[0].header.cmsg_len = @intCast(@intFromPtr(&cmsg[0].fds[next]) - @intFromPtr(&cmsg[0]));

            var msg: socket.msghdr = .{
                .msg_name = null,
                .msg_namelen = 0,
                .msg_iov = iov[0..].ptr,
                .msg_iovlen = 1,
                .msg_control = cmsg[0..].ptr,
                .msg_controllen = cmsg[0].header.cmsg_len,
                .msg_flags = 0,
            };
            const result = std.c.sendmsg(self.socket.fd, @ptrCast(&msg), 0);
            if (result < 0) {
                printerr(posix.errno(result));
                return error.SendMsgFailed;
            }
        }

        fn recv(self: @This()) !T {
            var into: T = undefined;
            // var fds: [MAX_FDS]posix.fd_t = undefined;

            var iov = [_]socket.iovec{.{
                .iov_base = @ptrCast(&into),
                .iov_len = @sizeOf(T),
            }};

            var cmsg: Cmsg = undefined;

            var msg: socket.msghdr = .{
                .msg_name = null,
                .msg_namelen = 0,
                .msg_iov = iov[0..].ptr,
                .msg_iovlen = 1,
                .msg_control = @ptrCast(&cmsg),
                .msg_controllen = @sizeOf(Cmsg),
                .msg_flags = 0,
            };

            const result = std.c.recvmsg(self.socket.fd, @ptrCast(&msg), 0);
            if (result < 0) {
                printerr(posix.errno(result));
                return error.RecvMsgFailed;
            }

            std.debug.print("{}\n", .{msg});
            std.debug.print("{}\n", .{cmsg});
            std.debug.print("into before: {}\n", .{into});
            // Extract received fds and insert them into the struct
            // const num_fds = (cmsg.header.cmsg_len - @offsetOf(Cmsg, "fds")) / @sizeOf(posix.fd_t);
            var fds_next: usize = 0;
            insertFds(T, &into, cmsg.fds[0..].ptr, &fds_next);
            std.debug.print("into after: {}\n", .{into});

            std.debug.print("{}\n", .{msg});

            return into;
        }
    };
}

const Fd = struct {
    fd: std.posix.fd_t,
};

// std.builtin.Type

fn extractFds(comptime T: type, s: T, fds: [*]posix.fd_t, fds_next: *usize) void {
    if (T == Fd) {
        std.debug.print("fd: {}\n", .{s.fd});
        fds[fds_next.*] = s.fd;
        fds_next.* += 1;
    } else {
        const info = @typeInfo(T);

        switch (info) {
            .@"struct" => {
                const struct_info = info.@"struct";
                inline for (struct_info.fields) |field| {
                    std.debug.print("name: {s}, type: {any}\n", .{ field.name, field.type });

                    const field_value = @field(s, field.name); // Get the actual field value
                    extractFds(field.type, field_value, fds, fds_next); // Recurse
                }
            },
            else => {
                @compileError("panic");
            },
        }
    }
}

fn insertFds(comptime T: type, s: *T, fds: [*]posix.fd_t, fds_next: *usize) void {
    if (T == Fd) {
        s.*.fd = fds[fds_next.*];
        fds_next.* += 1;
    } else {
        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => {
                const struct_info = info.@"struct";
                inline for (struct_info.fields) |field| {
                    insertFds(field.type, &@field(s.*, field.name), fds, fds_next);
                }
            },
            else => {
                @compileError("panic");
            },
        }
    }
}

const UnixConn = struct {
    fd: std.posix.fd_t,

    fn stream(self: @This()) std.net.Stream {
        return std.net.Stream{
            .handle = self.fd,
        };
    }

    fn sendFd(self: @This(), fd: usize) !void {
        var dummy: u8 = 0;
        const iov = std.c.iovec_const{
            .base = @ptrCast(&dummy),
            .len = 1,
        };

        var msg: std.c.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iov),
            .iovlen = 0,
            .controllen = 1,
            .control = &fd,
            .flags = 0,
        };

        if (std.c.sendmsg(self.fd, &msg, 0) < 0) {
            return error.SendMsgFailed;
        }
    }

    fn connect(socket_path: [:0]const u8) !@This() {
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
            .fd = sock,
        };
    }
};

const UnixListener = struct {
    fd: c_int,

    fn bind(socket_path: [:0]const u8) !@This() {
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

    fn listen(self: @This()) !void {
        if (std.c.listen(self.fd, 0) < 0) {
            return error.ListenFailed;
        }
    }

    fn accept(self: @This()) !UnixConn {
        const fd = std.c.accept(self.fd, null, null);
        if (fd < 0) {
            return error.AcceptFailed;
        }

        return UnixConn{ .fd = fd };
    }

    fn close(self: @This()) !void {
        if (std.c.close(self.fd) < 0) {
            return error.Failed;
        }
    }
};

fn copy(w: std.io.AnyWriter, r: std.io.AnyReader) !void {
    var buffer: [128]u8 = undefined;

    while (true) {
        const total_read = try r.read(buffer[0..]);
        if (total_read == 0) {
            break;
        }
        var total_written: usize = 0;

        while (total_written < total_read) {
            const written = try w.write(buffer[total_written..total_read]);
            total_written += written;
        }
    }
}

const PairOfFds = struct {
    a: Fd,
    b: Fd,
};

pub fn main() !void {
    var args = std.process.args();

    _ = args.skip();

    if (args.next()) |path| {
        const conn = try UnixConn.connect(path);
        const chan = Channel(Fd){ .socket = conn };

        const received = try chan.recv();
        const flags = std.c.fcntl(received.fd, fcntl.F_GETFL);
        std.debug.print("flags: {}", .{flags});
        if (flags < 0) {
            std.debug.print("Received fd {} is invalid\n", .{received.fd});
        }
        if (flags & fcntl.O_RDONLY == fcntl.O_RDONLY) std.debug.print("Read-only\n", .{});
        if (flags & fcntl.O_WRONLY == fcntl.O_WRONLY) std.debug.print("Write-only\n", .{});
        if (flags & fcntl.O_RDWR == fcntl.O_RDWR) std.debug.print("Read-write\n", .{});
        if (flags & fcntl.O_NONBLOCK == fcntl.O_NONBLOCK) std.debug.print("Non-blocking\n", .{});

        std.debug.print("{}\n", .{received.fd});

        var buf: [32]u8 = undefined;

        const result = std.c.read(received.fd, &buf, 16);
        if (result < 0) {
            printerr(posix.errno(result));
            return error.ReadFailed;
        }

        std.debug.print("n: {} {s}\n", .{ result, buf });
    } else { // note pour le screenshot: c'est la même ligne des deux côtés
        const default_path = "/tmp/my-socket";
        const sock = try UnixListener.bind(default_path);
        std.debug.print("listening on {s}\n", .{default_path});

        try sock.listen();

        const s = try sock.accept();

        const chan = Channel(Fd){ .socket = s };

        // read, write
        var pipes: [2]posix.fd_t = undefined;

        const r1 = std.c.pipe(&pipes);
        if (r1 < 0) {
            printerr(posix.errno(r1));
            return error.PipeFailed;
        }
        const read = pipes[0];
        const write = pipes[1];

        try chan.send(Fd{
            .fd = read,
        });

        const str = "salut, ça va\n";

        const r2 = std.c.write(write, str, str.len);
        if (r2 < 0) {
            printerr(posix.errno(r2));
            return error.WriteFailed;
        }

        std.time.sleep(10_000_000_000);
    }
}
