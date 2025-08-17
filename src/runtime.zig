const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const c = std.c;
const uring_mod = @import("./uring.zig");
const Uring = uring_mod.Uring;
const UringConfig = uring_mod.UringConfig;
const posix = std.posix;
const print = std.debug.print;

const h = @cImport({
    @cInclude("ucontext.h");
    @cInclude("time.h");
    @cInclude("sys/time.h");
    @cInclude("signal.h");
});

pub usingnamespace @import("./uring.zig");

/// This is to have a (relatively) easy way to allocate and deallocate the
/// closure of some function.
const Closure = struct {
    data: [*]u8,
    len: usize,
    alignment: u29,

    fn create(t: anytype, alloc: std.mem.Allocator) !@This() {
        const T = @TypeOf(t);

        const len = @sizeOf(T) + 1;
        const ptr = alloc.rawAlloc(
            len,
            std.mem.Alignment.fromByteUnits(@alignOf(T)),
            0,
        ) orelse return std.mem.Allocator.Error.OutOfMemory;

        const out: @This() = .{
            .data = @ptrCast(ptr),
            .len = len,
            .alignment = @alignOf(T),
        };

        out.as(T).* = t;
        return out;
    }

    fn destroy(self: @This(), alloc: std.mem.Allocator) void {
        alloc.rawFree(self.data[0..self.len], std.mem.Alignment.fromByteUnits(self.alignment), 0);
    }

    fn as(self: @This(), comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }
};

pub const Task = struct {
    const State = union(enum) {
        init,
        started,
        waiting: struct {
            result: *usize,
        },
        preempted,
        done,
    };

    /// The context of the task. The stack is allocated using the Runtime
    /// allocator.
    context: h.ucontext_t,

    /// The runtime this task is attached to.
    runtime: *Runtime,

    /// Its state
    state: State = .init,

    /// The closure of the function which is executed inside.
    closure: Closure,

    fn destroy(self: @This(), alloc: std.mem.Allocator) void {
        const stack = self.context.uc_stack;

        const stack_sp = stack.ss_sp orelse @panic("The task should have a non null stack pointer.");

        const stack_sp_many: [*]u8 = @ptrCast(stack_sp);

        const stack_slice = stack_sp_many[0..stack.ss_size];

        alloc.free(stack_slice);

        self.closure.destroy(alloc);
    }

    fn suspend_me(self: *@This()) void {
        const sched_ctx = self.runtime.sched_ctx orelse @panic("REEE");

        const result = h.swapcontext(&self.context, sched_ctx);
        if (result < 0) {
            @panic("should be unreachable");
        }
    }

    pub fn read(self: *@This(), fd: posix.fd_t, buffer: []u8) !usize {
        var uring = self.runtime.uring;
        var result: usize = undefined;
        self.state = .{ .waiting = .{ .result = &result } };

        try uring.put_fd_buffer(.READ, fd, buffer, self);

        const parent = self.runtime.sched_ctx orelse @panic("stuff");
        _ = h.swapcontext(&self.context, parent);

        return result;
    }

    pub fn write(self: *@This(), fd: posix.fd_t, buffer: []const u8) !usize {
        var uring = self.runtime.uring;
        var result: usize = undefined;
        self.state = .{ .waiting = .{ .result = &result } };

        try uring.put_fd_buffer(.WRITE, fd, @constCast(buffer), self);

        const parent = self.runtime.sched_ctx orelse @panic("stuff");
        _ = h.swapcontext(&self.context, parent);

        return result;
    }
};

threadlocal var current_task: ?*Task = null;

pub const RuntimeConfig = struct {
    stack_size: usize = 1 << 13,
    time_slice_ns: usize = 10_000_000,
};

pub const Runtime = struct {
    config: RuntimeConfig,

    alloc: std.mem.Allocator,

    tasks: LinkedList,

    sched_ctx: ?*h.ucontext_t,

    uring: *TheUring,

    const TheUring = Uring(*Task, .{});

    const LinkedList = std.DoublyLinkedList(Task);

    pub fn create(alloc: std.mem.Allocator, config: RuntimeConfig) !@This() {
        const uring = try alloc.create(TheUring);
        errdefer alloc.destroy(uring);

        uring.* = try Uring(*Task, .{}).create();

        return Runtime{
            .config = config,
            .alloc = alloc,
            .tasks = LinkedList{},
            .sched_ctx = null,
            .uring = uring,
        };
    }

    /// Free all the memory (even if the loop still has active tasks).
    pub fn destroy(self: *@This()) void {
        while (self.tasks.pop()) |node| {
            self.alloc.destroy(node);
        }

        self.alloc.destroy(self.uring);
    }

    pub fn spawn(self: *@This(), thread_object: anytype) !void {
        const node = try self.alloc.create(LinkedList.Node);

        node.* = .{
            .data = Task{
                .context = undefined,
                .runtime = self,
                .state = .init,
                .closure = try Closure.create(thread_object, self.alloc),
            },
            .next = null,
            .prev = null,
        };
        var ctx = &node.*.data.context;

        const result = h.getcontext(ctx);
        if (result < 0) {
            return error.GetContextFailed;
        }

        ctx.*.uc_link = null;

        const stack = try self.alloc.alloc(u8, self.config.stack_size);

        ctx.uc_stack = .{
            .ss_flags = 0,
            .ss_sp = stack.ptr,
            .ss_size = stack.len,
        };

        const ThreadObject = @TypeOf(thread_object);

        const NS = struct {
            fn runTask(task: *Task) callconv(.c) void {
                const obj: *ThreadObject = task.closure.as(ThreadObject);
                obj.*.run(task);

                const sched_ctx = task.runtime.sched_ctx orelse {
                    @panic("There should be a pointer there.");
                };

                task.state = .done;

                const r = h.setcontext(sched_ctx);
                if (r < 0) {
                    @panic("should be unreachable unless error");
                }
            }
        };

        const task = &node.data;

        h.makecontext(ctx, @ptrCast(&NS.runTask), 1, task);

        self.tasks.append(node);
    }

    fn empty_uring(self: *@This()) !void {
        while (self.uring.completion_queue.get()) |cqe| {
            const id: u32 = @intCast(cqe.user_data);
            const task = self.uring.sqe_data[id];
            // give back the id
            try self.uring.sqe_freelist.append(id);

            switch (task.state) {
                .waiting => |r| {
                    r.result.* = @intCast(cqe.res);

                    task.state = .started;

                    // The task is intrusive in a linked list node.
                    const node: *LinkedList.Node = @fieldParentPtr("data", task);

                    self.tasks.append(node);
                },
                else => @panic("weird case"),
            }
        }
    }

    fn signal_handler(_: i32, _: *const linux.siginfo_t, _: *h.ucontext_t) callconv(.c) void {
        if (current_task) |task| {
            task.state = .preempted;

            const sched_ctx = task.runtime.sched_ctx orelse @panic("asdf");

            if (h.swapcontext(&task.context, sched_ctx) < 0) {
                @panic("err");
            }
        }
    }

    const PreemptionState = struct {
        timer_id: h.timer_t,
    };

    fn setup_preemption(time_slice_ns: usize) !PreemptionState {
        const action: linux.Sigaction = .{
            .handler = .{
                .sigaction = @ptrCast(&signal_handler),
            },
            .mask = std.mem.zeroes(linux.sigset_t),
            .flags = linux.SA.SIGINFO,
        };

        var old_action: linux.Sigaction = undefined;

        const r1: isize = @bitCast(linux.sigaction(linux.SIG.ALRM, &action, &old_action));
        if (r1 < 0) {
            return error.sigaction;
        }

        var event = h.sigevent{
            .sigev_notify = h.SIGEV_SIGNAL,
            .sigev_signo = linux.SIG.ALRM,
            .sigev_value = .{ .sival_ptr = @ptrFromInt(12345) },
        };

        var timer: h.timer_t = undefined;

        const r2 = h.timer_create(h.CLOCK_REALTIME, &event, &timer);

        if (r2 < 0) {
            return error.timer_create;
        }

        const timerspec = h.itimerspec{ .it_interval = .{
            .tv_sec = 0,
            .tv_nsec = @intCast(time_slice_ns),
        }, .it_value = .{
            .tv_sec = 1,
            .tv_nsec = @intCast(time_slice_ns),
        } };

        const r3 = h.timer_settime(timer, 0, &timerspec, null);
        if (r3 < 0) {
            return error.settime;
        }

        return .{
            .timer_id = timer,
        };
    }

    fn setdown_signal(state: PreemptionState) !void {
        if (h.timer_delete(state.timer_id) < 0) {
            return error.timer_delete;
        }
    }

    fn advance_task(self: *@This(), task: *Task) !void {
        const node: *LinkedList.Node = @fieldParentPtr("data", task);

        var current_ctx: h.ucontext_t = undefined;
        self.sched_ctx = &current_ctx;
        defer self.sched_ctx = null;

        task.runtime = self;
        task.state = .started;

        const task_ctx = &task.context;

        current_task = task;
        defer current_task = null;

        const result = h.swapcontext(&current_ctx, task_ctx);
        if (result < 0) {
            return error.SwapContextFailed;
        }
        current_task = null;

        switch (task.state) {
            .init => {
                @panic("wtf");
            },
            .started => {
                self.tasks.append(node);
            },
            .preempted => {
                self.tasks.append(node);
            },
            .waiting => {
                // Do nothing. The thread will be resumed when emptying the
                // uring.
            },
            .done => {
                task.destroy(self.alloc);
                self.alloc.destroy(node);
            },
        }
    }

    pub fn run(self: *@This()) !void {
        const preemption_state = try setup_preemption(self.config.time_slice_ns);
        defer setdown_signal(preemption_state) catch @panic("error");

        while (true) {
            while (self.tasks.popFirst()) |node| {
                const task = &node.data;

                try self.advance_task(task);
            }

            try self.empty_uring();

            if (self.tasks.len != 0) continue;

            if (self.uring.in_flight() != 0) {
                _ = try self.uring.enter(0, 1);
                continue;
            }

            break;
        }
        self.sched_ctx = null;
    }
};

const testing_utils = @import("./testing.zig");

test "some simple tests" {
    const TestThread = struct {
        id: usize,
        i: *usize,
        ids: []usize,

        fn run(self: @This(), task: *Task) void {
            self.ids[self.i.*] = self.id;
            self.i.* += 1;
            task.suspend_me();
            self.ids[self.i.*] = self.id;
            self.i.* += 1;
        }
    };

    var i: usize = 0;
    var ids: [4]usize = undefined;

    var rt = try Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const t1 = TestThread{
        .id = 0,
        .i = &i,
        .ids = ids[0..],
    };
    const t2 = TestThread{
        .id = 1,
        .i = &i,
        .ids = ids[0..],
    };

    try rt.spawn(t1);
    try rt.spawn(t2);
    try rt.run();

    try testing.expectEqual(.{ 0, 1, 0, 1 }, ids);
}

test "read" {
    var rt = try Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const thing = struct {
        fn run(_: @This(), task: *Task) void {
            var buf: [16]u8 = undefined;
            const file = testing_utils.pipeWithText("hello!!!") catch @panic("asdf");
            const handle = file.handle;

            buf[0] = 0;

            _ = task.read(handle, buf[0..]) catch
                @panic("");
        }
    }{};

    try rt.spawn(thing);
    try rt.run();
}
