const std = @import("std");
const posix = std.posix;
const io_uring = @cImport(@cInclude("linux/io_uring.h"));
const linux = std.os.linux;
const testing = std.testing;
const testing_utils = @import("./testing.zig");

/// A common type made to use the in mmaped queue from io_uring.
fn Queue(comptime T: type) type {
    return struct {
        head: *u32,
        tail: *u32,
        buf: []T,

        pub fn put(self: @This(), value: T) !void {
            if (self.tail.* - self.head.* >= self.buf.len) {
                return error.FULL;
            }

            const mod_tail = @mod(self.tail.*, self.buf.len);

            self.buf[mod_tail] = value;
            self.tail.* += 1;
        }

        pub fn get(self: @This()) ?T {
            if (self.tail.* == self.head.*)
                return null;

            const v = self.buf[self.head.*];
            self.head.* += 1;
            return v;
        }
    };
}

pub const UringConfig = struct {
    max_sqe_size: usize = 1 << 10,
};

pub fn Uring(comptime T: type, comptime config: UringConfig) type {
    return struct {
        const T2 = T;
        fd: posix.fd_t,
        params: linux.io_uring_params,

        submission_mem: []u8,
        submission_queue: Queue(u32),
        completion_mem: []u8,
        completion_queue: Queue(linux.io_uring_cqe),

        sqe_mem: []linux.io_uring_sqe,

        sqe_freelist: SqeFreelist,
        sqe_data: [config.max_sqe_size]T,

        const SqeFreelist = std.BoundedArray(u32, config.max_sqe_size);

        pub fn create() !@This() {
            var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);

            const r1 = linux.io_uring_setup(1 << 10, &params);
            const fd_isize: isize = @bitCast(r1);

            if (fd_isize < 0) {
                return error.FailedSetup;
            }

            const fd: posix.fd_t = @intCast(fd_isize);

            const submission_mem = submission_mem: {
                const submission_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
                const submission_ring_addr = linux.mmap(
                    null,
                    submission_ring_size,
                    linux.PROT.READ | linux.PROT.WRITE,
                    .{ .TYPE = .SHARED },
                    @intCast(fd),
                    linux.IORING_OFF_SQ_RING,
                );

                const ptr: [*]u8 = @ptrFromInt(submission_ring_addr);
                break :submission_mem ptr[0..submission_ring_size];
            };

            const submission_queue = submission_queue: {
                const start: [*]u32 = @ptrCast(@alignCast(submission_mem.ptr + params.sq_off.array));

                const queue = Queue(u32){
                    .head = @ptrCast(@alignCast(submission_mem.ptr + params.sq_off.head)),
                    .tail = @ptrCast(@alignCast(submission_mem.ptr + params.sq_off.tail)),
                    .buf = start[0..params.sq_entries],
                };

                break :submission_queue queue;
            };

            const completion_mem = completion_mem: {
                const completion_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
                const completion_ring_addr = linux.mmap(
                    null,
                    completion_ring_size,
                    linux.PROT.READ | linux.PROT.WRITE,
                    .{ .TYPE = .SHARED },
                    @intCast(fd),
                    linux.IORING_OFF_CQ_RING,
                );

                const ptr: [*]u8 = @ptrFromInt(completion_ring_addr);
                break :completion_mem ptr[0..completion_ring_size];
            };

            const completion_queue = completion_queue: {
                const start: [*]linux.io_uring_cqe = @ptrCast(@alignCast(completion_mem.ptr + params.cq_off.cqes));

                const queue = Queue(linux.io_uring_cqe){
                    .head = @ptrCast(@alignCast(completion_mem.ptr + params.cq_off.head)),
                    .tail = @ptrCast(@alignCast(completion_mem.ptr + params.cq_off.tail)),
                    .buf = start[0..params.cq_entries],
                };

                break :completion_queue queue;
            };

            const sqe_array = sqe_array: {
                const sqe_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);

                const address = linux.mmap(
                    null,
                    sqe_size,
                    linux.PROT.READ | linux.PROT.WRITE,
                    .{ .TYPE = .SHARED },
                    fd,
                    linux.IORING_OFF_SQES,
                );

                const ptr: [*]linux.io_uring_sqe = @ptrFromInt(address);

                break :sqe_array ptr[0..params.sq_entries];
            };

            const sqe_freelist = freelist: {
                var freelist = try SqeFreelist.init(0);

                for (0..params.sq_entries) |i| {
                    try freelist.append(@intCast(i));
                }
                break :freelist freelist;
            };

            return @This(){
                .fd = fd,
                .params = params,
                .submission_mem = submission_mem,
                .submission_queue = submission_queue,
                .completion_mem = completion_mem,
                .completion_queue = completion_queue,
                .sqe_mem = sqe_array,
                .sqe_freelist = sqe_freelist,
                .sqe_data = undefined,
            };
        }

        pub fn destroy(self: @This()) void {
            _ = linux.munmap(self.submission_mem.ptr, self.submission_mem.len);
            _ = linux.munmap(self.completion_mem.ptr, self.completion_mem.len);
            _ = linux.munmap(@ptrCast(self.sqe_mem.ptr), self.sqe_mem.len * @sizeOf(linux.io_uring_sqe));
            _ = linux.close(self.fd);
        }

        pub fn enter(self: @This(), to_submit: u32, min_complete: u32) !usize {
            const results: isize = @intCast(linux.io_uring_enter(
                self.fd,
                to_submit,
                min_complete,
                linux.IORING_ENTER_GETEVENTS,
                null,
            ));
            if (results < 0) {
                return error.EnterFailed;
            }

            return @intCast(results);
        }

        pub fn in_flight(self: @This()) usize {
            return @as(usize, @intCast(self.params.sq_entries)) - self.sqe_freelist.len;
        }

        pub fn put_fd_buffer(self: *@This(), opcode: linux.IORING_OP, fd: posix.fd_t, buffer: []u8, obj: T) !void {
            const id = self.sqe_freelist.pop() orelse return error.OutOfSQEs;
            errdefer self.sqe_freelist.appendAssumeCapacity(id);

            self.sqe_data[id] = obj;
            const place = &self.sqe_mem[id];
            place.* = std.mem.zeroes(linux.io_uring_sqe);

            place.opcode = opcode;
            place.fd = fd;
            place.addr = @intFromPtr(buffer.ptr);
            place.len = @intCast(buffer.len);

            place.user_data = id;

            try self.submission_queue.put(id);
            const n = try self.enter(1, 0);
            if (n != 1) {
                return error.KernelFull;
            }
        }
    };
}

test "io_uring create" {
    const uring = try Uring(void, .{}).create();

    defer uring.destroy();
}

test "io_uring nop" {
    const uring = try Uring(void, .{}).create();
    defer uring.destroy();

    // We chose a submission queue entry and fill it with the relevant stuff.
    const sqe = &uring.sqe_mem[0];

    sqe.* = std.mem.zeroes(linux.io_uring_sqe);

    sqe.opcode = .NOP;
    sqe.user_data = 12345;

    try uring.submission_queue.put(0);

    _ = try uring.enter(1, 1);

    _ = uring.completion_queue.get() orelse return error.NoCQE;
}

test "io_uring sqe length" {
    const uring = try Uring(void, .{}).create();
    defer uring.destroy();

    try std.testing.expectEqual(1 << 10, uring.sqe_mem.len);
}

test "io_uring pipe" {
    var uring = try Uring(usize, .{}).create();

    const text = "hello";

    const file = try testing_utils.pipeWithText(text);

    var buf: [128]u8 = undefined;

    const thing: usize = 123;

    try uring.put_fd_buffer(.READ, file.handle, buf[0..], thing);

    _ = try uring.enter(0, 1);

    const completion = uring.completion_queue.get() orelse return error.ShouldExist;

    const n = @as(usize, @intCast(completion.res));

    try testing.expectEqual(text.len, n);

    try testing.expectEqualDeep(text, buf[0..n]);
}
