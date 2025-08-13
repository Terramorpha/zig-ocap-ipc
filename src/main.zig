const std = @import("std");

const ocap = @import("root.zig");

const PairOfFds = struct {
    a: ocap.Fd,
    b: ocap.Fd,
};

pub fn main() !void {
    var args = std.process.args();

    _ = args.skip();

    if (args.next()) |path| {
        const conn = try ocap.UnixConn.connect(path);
        const chan = ocap.Channel(ocap.Fd){ .socket = conn };

        const received = try chan.recv();

        std.debug.print("received: {any}\n", .{received});

        const file = std.fs.File{ .handle = received.fd };

        try file.writer().print("Hello\n", .{});
    } else { // note pour le screenshot: c'est la même ligne des deux côtés
        const default_path = "/tmp/my-socket";
        const sock = try ocap.UnixListener.bind(default_path);
        std.debug.print("listening on {s}\n", .{default_path});

        try sock.listen();

        while (true) {
            const s = try sock.accept();

            const chan = ocap.Channel(ocap.Fd){ .socket = s };

            try chan.send(ocap.Fd{
                .fd = std.io.getStdOut().handle,
            });
        }
    }
}
