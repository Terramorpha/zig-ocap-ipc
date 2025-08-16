const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn pipeWithText(text: []const u8) !std.fs.File {
    var fds: [2]posix.fd_t = undefined;
    const results = linux.pipe(&fds);
    if (results < 0) return error.PipeFailed;

    const writer = std.fs.File{ .handle = fds[1] };

    try writer.writeAll(text);

    return std.fs.File{ .handle = fds[0] };
}
