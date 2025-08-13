const std = @import("std");
const testing = std.testing;

pub const Fd = struct {
    fd: std.posix.fd_t,
};

pub fn processType(comptime T: type) type {
    if (T == Fd) {
        return struct {
            pub const size = 1;

            pub fn extract(obj: Fd, dst: *[size]Fd) usize {
                dst.*[0] = obj;
                return 1;
            }

            pub fn insert(fds: [size]Fd, obj: *Fd) usize {
                obj.* = fds[0];
                return 1;
            }
        };
    } else {
        switch (@typeInfo(T)) {
            .@"struct" => |info| comptime {
                var processors: [info.fields.len]type = undefined;

                for (0.., info.fields) |i, field| {
                    processors[i] = processType(field.type);
                }

                const total_size = total_size: {
                    var t = 0;
                    for (processors) |p| {
                        t += p.size;
                    }
                    break :total_size t;
                };

                return struct {
                    pub const size = total_size;

                    pub fn extract(obj: T, dst: *[size]Fd) usize {
                        var i: usize = 0;

                        inline for (info.fields, processors) |field_info, proc| {
                            const num = proc.extract(@field(obj, field_info.name), dst[i..][0..proc.size]);
                            i += num;
                        }
                        return i;
                    }

                    pub fn insert(fds: [size]Fd, obj: *T) usize {
                        var i: usize = 0;
                        inline for (info.fields, processors) |field_info, proc| {
                            const num = proc.insert(
                                fds[i..][0..proc.size].*,
                                &@field(obj.*, field_info.name),
                            );
                            i += num;
                        }
                        return i;
                    }
                };
            },
            .@"union" => |info| comptime {
                if (info.tag_type == null) {
                    @compileError("Only tagged unions are supported");
                }

                var processors: [info.fields.len]type = undefined;

                var max_size: usize = 0;
                for (0.., info.fields) |i, field_info| {
                    const proc = processType(field_info.type);
                    processors[i] = proc;
                    max_size = @max(max_size, proc.size);
                }

                return struct {
                    pub const size = max_size;

                    pub fn extract(obj: T, dst: *[size]Fd) usize {
                        inline for (info.fields, processors) |field, proc| {
                            if (std.mem.eql(u8, @tagName(obj), field.name)) {
                                const n = proc.extract(
                                    @field(obj, field.name),
                                    dst[0..proc.size],
                                );
                                return n;
                            }
                        }
                        unreachable;
                    }

                    pub fn insert(fds: [size]Fd, obj: *T) usize {
                        inline for (info.fields, processors) |field, proc| {
                            if (std.mem.eql(u8, @tagName(obj.*), field.name)) {
                                return proc.insert(
                                    fds[0..proc.size].*,
                                    &@field(obj.*, field.name),
                                );
                            }
                        }
                        unreachable;
                    }
                };
            },
            else => {
                @compileError("TODO");
            },
        }
    }
}

test "process simple" {
    const v1 = Fd{ .fd = 12345 };

    const p = processType(Fd);

    var fds: [p.size]Fd = undefined;

    const n1 = p.extract(v1, &fds);

    try testing.expectEqual(1, n1);

    try testing.expectEqual(12345, fds[0].fd);

    var v2: Fd = undefined;

    const n2 = p.insert(fds, &v2);

    try testing.expectEqual(1, n2);

    try testing.expectEqual(v1, v2);
}

test "process struct" {
    const FdPair = struct { a: Fd, b: Fd };
    const p = processType(FdPair);

    const v1 = FdPair{ .a = Fd{ .fd = 12345 }, .b = Fd{ .fd = 67890 } };

    var fds: [p.size]Fd = undefined;

    const n1 = p.extract(v1, &fds);

    try testing.expectEqual(2, n1);

    try testing.expectEqual(
        [2]Fd{ .{ .fd = 12345 }, .{ .fd = 67890 } },
        fds,
    );

    var v2: FdPair = undefined;

    const n2 = p.insert(fds, &v2);

    try testing.expectEqual(2, n2);

    try testing.expectEqual(v1, v2);
}

test "process union" {
    const AB = union(enum) { a: Fd, b: Fd };
    const p = processType(AB);

    const v1 = AB{ .a = Fd{ .fd = 12345 } };

    var fds: [p.size]Fd = undefined;

    const n1 = p.extract(v1, &fds);

    try testing.expectEqual(1, n1);

    try testing.expectEqual([1]Fd{Fd{ .fd = 12345 }}, fds);

    var v2 = AB{ .a = Fd{ .fd = 67890 } };

    const n2 = p.insert(fds, &v2);

    try testing.expectEqual(1, n2);

    try testing.expectEqual(v1, v2);
}
