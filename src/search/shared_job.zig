//! Immutable job publication and shared cancellation/node policy for P2.
//! Lifecycle mutation is pool-owned and quiescent; no account outlives its job.
const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const budget_mod = @import("node_budget.zig");
const search_time = @import("time.zig");

pub const CREDIT_BLOCK: u32 = 64;
pub const Telemetry = struct { nodes: std.atomic.Value(u64) align(64) = .init(0) };
pub const Control = struct {
    mutex: runtime.Mutex = .{},
    changed: runtime.Condition = .{},
    external_stop: *const std.atomic.Value(bool),
    cancelled: std.atomic.Value(bool) = .init(false),
    budget: ?budget_mod.Budget = null,
    parked: std.atomic.Value(u32) = .init(0),

    pub fn reset(self: *Control, limit: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.parked.load(.monotonic) == 0);
        self.budget = if (limit) |n| budget_mod.Budget.init(n, CREDIT_BLOCK) catch unreachable else null;
        self.cancelled.store(false, .release);
        // A concurrent external stop remains set: reset cannot erase it.
    }

    pub inline fn stopping(self: *const Control) bool {
        return self.cancelled.load(.acquire) or self.external_stop.load(.acquire);
    }

    pub fn cancel(self: *Control) void {
        self.mutex.lock();
        self.cancelled.store(true, .release);
        self.changed.broadcast();
        self.mutex.unlock();
    }

    pub fn finish(self: *Control, account: ?*budget_mod.Account) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (account) |a| a.finish();
        self.changed.broadcast();
    }

    /// Retain the helper's search stack while parked. It owns zero credits
    /// here, so parking cannot hoard a reservation. Recheck under the lock
    /// used by refund/cancel publishers, closing the lost-wakeup window.
    pub fn count(self: *Control, comptime coordinator: bool, account: ?*budget_mod.Account) bool {
        if (self.stopping()) return false;
        const a = account orelse return true;
        switch (a.tryCount()) {
            .counted => return true,
            .closed => return false,
            .empty => {},
        }
        if (comptime coordinator) {
            self.cancel();
            return false;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.parked.fetchAdd(1, .monotonic);
        defer _ = self.parked.fetchSub(1, .monotonic);
        while (!self.stopping()) {
            switch (a.tryCount()) {
                .counted => return true,
                .closed => return false,
                .empty => self.changed.wait(&self.mutex),
            }
        }
        return false;
    }
};

pub const Job = struct {
    id: u64,
    network_epoch: u64,
    config_epoch: u64,
    position: @import("../core/position.zig").Position,
    history: @import("repetition.zig").History,
    root_moves: ?@import("../core/move.zig").MoveList,
    root_wdl: ?@import("syzygy.zig").Wdl = null,
    limits: search_time.Limits,
    table: @import("shared_tt.zig").View,
    tablebases: *const @import("syzygy.zig").Job,
    control: *Control,
    /// Only worker0 copies/reads this clock. No helper deadline or timer.
    timer: ?runtime.Timer,
};

pub const Ready = struct {
    ctx: *anyopaque,
    call: *const fn (*anyopaque, ?*const @import("syzygy.zig").RootPolicy) void,
};

pub fn Execution(comptime coordinator: bool) type {
    return struct {
        pub const is_helper = !coordinator;
        job: *const Job,
        account: ?*budget_mod.Account,
        telemetry: *Telemetry,
        ready: ?Ready = null,

        pub fn noteNode(self: *@This(), ctx: anytype, comptime qnode: bool) bool {
            if (!self.job.control.count(coordinator, self.account)) {
                ctx.stopped = true;
                return true;
            }
            ctx.nodes += 1;
            if (comptime qnode and @import("context.zig").stats_enabled) ctx.stats.qnodes += 1;
            if (ctx.nodes & 1023 == 0) self.telemetry.nodes.store(ctx.nodes, .monotonic);
            if (comptime coordinator) {
                if (ctx.control.stopReasonNow(ctx.nodes)) |reason| {
                    ctx.noteHardStop(reason);
                    ctx.stopped = true;
                    self.job.control.cancel();
                    return true;
                }
            }
            return false;
        }
    };
}

test "empty helper parks without cancelling and resumes after a refund" {
    var external = std.atomic.Value(bool).init(false);
    var control = Control{ .external_stop = &external };
    control.reset(65);
    var coordinator = try control.budget.?.coordinator();
    defer control.finish(&coordinator);
    var helper = try control.budget.?.helper();
    try std.testing.expect(control.count(false, &helper)); // only unreserved credit
    const Task = struct {
        control: *Control,
        account: *budget_mod.Account,
        done: runtime.ResetEvent = .{},
        counted: bool = false,
        fn run(self: *@This()) void {
            self.counted = self.control.count(false, self.account);
            self.control.finish(self.account);
            self.done.set();
        }
    };
    var task = Task{ .control = &control, .account = &helper };
    const thread = try runtime.Thread.spawn(.{}, Task.run, .{&task});
    defer {
        control.cancel();
        thread.join();
    }
    var timer = try runtime.Timer.start();
    while (control.parked.load(.monotonic) == 0) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.Timeout;
        runtime.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(!control.stopping() and !task.done.isSet());
    control.finish(&coordinator);
    try task.done.timedWait(5 * std.time.ns_per_s);
    try std.testing.expect(task.counted and !control.stopping());
    try std.testing.expectEqual(@as(u64, 2), helper.counted());
    try std.testing.expectEqual(@as(u64, 63), control.budget.?.available());
}

test "helper cancel wake has no lost notification before or after parking" {
    const Task = struct {
        control: *Control,
        account: *budget_mod.Account,
        done: runtime.ResetEvent = .{},
        counted: bool = true,
        fn run(self: *@This()) void {
            self.counted = self.control.count(false, self.account);
            self.control.finish(self.account);
            self.done.set();
        }
    };
    for (0..32) |round| {
        var external = std.atomic.Value(bool).init(false);
        var control = Control{ .external_stop = &external };
        control.reset(65);
        var coordinator = try control.budget.?.coordinator();
        defer control.finish(&coordinator);
        var helper = try control.budget.?.helper();
        try std.testing.expect(control.count(false, &helper));
        var task = Task{ .control = &control, .account = &helper };
        const thread = try runtime.Thread.spawn(.{}, Task.run, .{&task});
        defer {
            control.cancel();
            thread.join();
        }
        if (round % 2 == 0) {
            var timer = try runtime.Timer.start();
            while (control.parked.load(.monotonic) == 0) {
                if (timer.read() > 5 * std.time.ns_per_s) return error.Timeout;
                runtime.Thread.sleep(std.time.ns_per_ms);
            }
        }
        external.store(true, .release);
        control.cancel();
        try task.done.timedWait(5 * std.time.ns_per_s);
        try std.testing.expect(!task.counted);
        try std.testing.expectEqual(@as(u32, 0), control.parked.load(.monotonic));
    }
}
