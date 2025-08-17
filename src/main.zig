const std = @import("std");
const linux = std.os.linux;

const ocap = @import("root.zig");

const testing_utils = @import("./testing.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 25 }){};
    const allocator = gpa.allocator();
    {
        var rt = try ocap.Runtime.create(allocator, .{});
        defer rt.destroy();

        const thing = struct {
            pub fn run(_: @This(), task: *ocap.Task) void {
                const stdout = std.io.getStdOut().handle;

                const n = task.write(stdout, "salut\n") catch
                    @panic("");
                std.debug.print("n: {}\n", .{n});

                for (0..1_000_000_000) |i| {
                    if (@mod(i, 1_000_000) == 0) {
                        std.debug.print("i: {}\n", .{i});
                    }
                }
            }
        }{};

        try rt.spawn(thing);
        try rt.run();
    }

    _ = gpa.detectLeaks();
}
