//! Strict job-wide node credits for the future SMP path. Not used by serial
//! search. This module owns accounting only: it never reads a clock, changes a
//! stop flag, publishes a result, or decides whether an empty helper cancels.
const std = @import("std");

pub const Budget = struct {
    limit: u64,
    block: u32,
    remaining: std.atomic.Value(u64),
    coordinator_claimed: std.atomic.Value(bool) = .init(false),

    /// Move before publication only. Once any Account exists, keep this object
    /// at a stable address until every account has finished and its worker joins.
    /// No reset/reuse in place while a job is live. Block size is a caller choice,
    /// not a production tuning decision made by this primitive.
    pub fn init(limit: u64, block: u32) error{ZeroBlock}!Budget {
        if (block == 0) return error.ZeroBlock;
        return .{
            .limit = limit,
            .block = block,
            // Reserve worker 0's first block before any helper can claim one.
            .remaining = .init(limit - @min(limit, block)),
        };
    }

    pub fn coordinator(self: *Budget) error{CoordinatorAlreadyClaimed}!Account {
        if (self.coordinator_claimed.cmpxchgStrong(false, true, .release, .monotonic) != null)
            return error.CoordinatorAlreadyClaimed;
        return .{ .budget = self, .credits = @intCast(@min(self.limit, self.block)) };
    }

    pub fn helpersAllowed(self: *const Budget) bool {
        return self.limit > self.block;
    }

    /// The pool creates at most one live account per participating worker.
    /// A tiny budget runs on worker 0 alone, including N=0. Larger N<T
    /// remains safe even though some helpers may receive no credits.
    pub fn helper(self: *Budget) error{ CoordinatorNotClaimed, TinyBudget }!Account {
        if (!self.coordinator_claimed.load(.acquire)) return error.CoordinatorNotClaimed;
        if (!self.helpersAllowed()) return error.TinyBudget;
        return .{ .budget = self };
    }

    /// Available credits are NOT nodes executed: live workers may own unused
    /// reservations. Final actual totals come from accounts after all joins.
    pub fn available(self: *const Budget) u64 {
        return self.remaining.load(.monotonic);
    }

    fn reserve(self: *Budget) u32 {
        var available_now = self.remaining.load(.monotonic);
        while (available_now != 0) {
            const amount = @min(available_now, self.block);
            if (self.remaining.cmpxchgWeak(available_now, available_now - amount, .monotonic, .monotonic)) |new| {
                available_now = new;
            } else return @intCast(amount);
        }
        return 0;
    }

    fn refund(self: *Budget, amount: u32) void {
        if (amount == 0) return;
        const prior = self.remaining.fetchAdd(amount, .monotonic);
        // Under the ownership contract every returned credit was reserved from
        // this same budget exactly once. It cannot overflow even at u64 max.
        std.debug.assert(amount <= self.limit and prior <= self.limit - amount);
    }
};

pub const Count = enum { counted, empty, closed };

/// Worker-private, move-only by contract. Create/move before worker publication;
/// afterwards only that worker mutates it. Inspect totals only after join (or
/// publish a separate atomic telemetry snapshot). Never copy a live account.
pub const Account = struct {
    budget: *Budget,
    credits: u32 = 0,
    used: u64 = 0,
    closed: bool = false,

    /// Call immediately at the counted-node entry, before executing/counting it.
    /// An empty helper must unwind and park, without setting job cancellation.
    /// Only the coordinator/pool policy can terminate a job. Empty is not a
    /// claim that all reserved credits have been consumed: refunds may follow.
    pub fn tryCount(self: *Account) Count {
        if (self.closed) return .closed;
        if (self.credits == 0) self.credits = self.budget.reserve();
        if (self.credits == 0) return .empty;
        self.credits -= 1;
        self.used += 1;
        return .counted;
    }

    /// Return unused credits on every completion, parking, cancellation and
    /// partial-start cleanup path. Idempotent for the same owned Account, not
    /// for illicit copies. The owner must not finish while its worker can run.
    pub fn finish(self: *Account) void {
        if (self.closed) return;
        const unused = self.credits;
        self.credits = 0;
        self.closed = true;
        self.budget.refund(unused);
    }

    pub fn counted(self: *const Account) u64 {
        return self.used;
    }
};

test "node budget reserves coordinator first and disables helpers for tiny limits" {
    try std.testing.expectError(error.ZeroBlock, Budget.init(10, 0));
    for ([_]u64{ 0, 1, 2, 7, 8 }) |limit| {
        var budget = try Budget.init(limit, 8);
        try std.testing.expectError(error.CoordinatorNotClaimed, budget.helper());
        var coordinator = try budget.coordinator();
        defer coordinator.finish();
        try std.testing.expectError(error.CoordinatorAlreadyClaimed, budget.coordinator());
        try std.testing.expectError(error.TinyBudget, budget.helper());
        try std.testing.expect(!budget.helpersAllowed());
        for (0..limit) |_| try std.testing.expectEqual(Count.counted, coordinator.tryCount());
        try std.testing.expectEqual(Count.empty, coordinator.tryCount());
        try std.testing.expectEqual(limit, coordinator.counted());
        try std.testing.expectEqual(@as(u64, 0), budget.available());
    }
}

test "node budget empty helper does not consume the coordinator reservation" {
    var budget = try Budget.init(5, 4);
    var coordinator = try budget.coordinator();
    defer coordinator.finish();
    var helper = try budget.helper();
    defer helper.finish();
    try std.testing.expectEqual(Count.counted, helper.tryCount());
    try std.testing.expectEqual(Count.empty, helper.tryCount());
    try std.testing.expectEqual(@as(u64, 0), coordinator.counted());
    // Worker 0 can still search; the empty helper has no cancellation authority.
    for (0..4) |_| try std.testing.expectEqual(Count.counted, coordinator.tryCount());
    try std.testing.expectEqual(Count.empty, coordinator.tryCount());
    try std.testing.expectEqual(@as(u64, 5), coordinator.counted() + helper.counted());
}

test "node budget unused credits return once and can refill an empty coordinator" {
    var budget = try Budget.init(13, 4);
    var coordinator = try budget.coordinator();
    defer coordinator.finish();
    var helpers = [_]Account{ try budget.helper(), try budget.helper(), try budget.helper() };
    defer for (&helpers) |*helper| helper.finish();
    for (&helpers) |*helper| try std.testing.expectEqual(Count.counted, helper.tryCount());
    for (0..4) |_| try std.testing.expectEqual(Count.counted, coordinator.tryCount());
    try std.testing.expectEqual(Count.empty, coordinator.tryCount());
    try std.testing.expectEqual(@as(u64, 0), budget.available());
    // Two helpers own 3 unused credits each; a one-credit tail is fully spent.
    helpers[0].finish();
    helpers[0].finish();
    try std.testing.expectEqual(Count.closed, helpers[0].tryCount());
    try std.testing.expectEqual(@as(u64, 3), budget.available());
    helpers[1].finish();
    helpers[2].finish();
    for (0..6) |_| try std.testing.expectEqual(Count.counted, coordinator.tryCount());
    try std.testing.expectEqual(Count.empty, coordinator.tryCount());
    try std.testing.expectEqual(@as(u64, 13), coordinator.counted() + 3);
}

test "node budget cancelled before search refunds the reserved initial block" {
    var budget = try Budget.init(100, 8);
    var coordinator = try budget.coordinator();
    var helper = try budget.helper();
    helper.finish();
    coordinator.finish();
    coordinator.finish();
    try std.testing.expectEqual(@as(u64, 100), budget.available());
    try std.testing.expectEqual(@as(u64, 0), coordinator.counted() + helper.counted());
    try std.testing.expectEqual(Count.closed, coordinator.tryCount());
}

test "node budget reservation and refund arithmetic supports maximum limits" {
    const maximum = std.math.maxInt(u64);
    var budget = try Budget.init(maximum, std.math.maxInt(u32));
    var coordinator = try budget.coordinator();
    var helper = try budget.helper();
    try std.testing.expectEqual(Count.counted, coordinator.tryCount());
    try std.testing.expectEqual(Count.counted, helper.tryCount());
    helper.finish();
    coordinator.finish();
    try std.testing.expectEqual(maximum - 2, budget.available());
    try std.testing.expectEqual(@as(u64, 2), coordinator.counted() + helper.counted());
}
