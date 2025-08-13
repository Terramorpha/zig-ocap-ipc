const std = @import("std");
const fd_t = std.posix.fd_t;

const unix = @import("./unix.zig");

const reflection = @import("./reflection.zig");

fn printerr(err: std.c.E) void {
    std.debug.print("error: {}\n", .{err});
}

pub fn Channel(comptime T: type) type {
    return struct {
        socket: unix.UnixConn,

        const process = reflection.processType(T);

        pub fn send(self: @This(), obj: T) !void {
            var buffer: [process.size]reflection.Fd = undefined;
            const len = process.extract(obj, &buffer);

            var filedesc: [process.size]fd_t = undefined;
            for (0..len) |i| {
                filedesc[i] = buffer[i].fd;
            }

            try self.socket.sendmsg(
                process.size,
                std.mem.asBytes(&obj),
                filedesc[0..len],
            );
        }

        pub fn recv(self: @This()) !T {
            var obj: T = undefined;

            var fd_ts: [process.size]fd_t = undefined;

            const r = try self.socket.recvmsg(process.size, std.mem.asBytes(&obj), fd_ts[0..]);

            var fdts: [process.size]reflection.Fd = undefined;

            for (0..r.fds_len) |i| {
                fdts[i].fd = fd_ts[i];
            }

            std.debug.print("result: {any}\n", .{r});

            _ = process.insert(fdts[0..process.size].*, &obj);

            return obj;
        }
    };
}
