const std = @import("std");
const types = @import("../core/types.zig");

pub const DEFAULT_MOVE_OVERHEAD_MS: u64 = 20;
const LOW_TIME_THRESHOLD_MS: u64 = 1_000;
const SUDDEN_DEATH_DIVISOR: u64 = 24;
const SUDDEN_DEATH_NO_INCREMENT_DIVISOR: u64 = 28;
const LOW_TIME_DIVISOR: u64 = 32;

pub const Plan = struct {
    optimum_ms: u64,
    maximum_ms: u64,
};

pub const Limits = struct {
    depth: ?u16 = null,
    node_limit: ?u64 = null,
    optimum_budget_ns: ?u64 = null,
    maximum_budget_ns: ?u64 = null,
};

pub const GoLimits = struct {
    depth: ?u16 = null,
    movetime_ms: ?u64 = null,
    node_limit: ?u64 = null,
    wtime_ms: ?u64 = null,
    btime_ms: ?u64 = null,
    winc_ms: u64 = 0,
    binc_ms: u64 = 0,
    movestogo: ?u32 = null,
    infinite: bool = false,

    pub fn hasExplicitLimit(self: GoLimits) bool {
        return self.depth != null or
            self.movetime_ms != null or
            self.node_limit != null or
            self.wtime_ms != null or
            self.btime_ms != null or
            self.infinite;
    }

    pub fn plan(self: GoLimits, side: types.Color, move_overhead_ms: u64) ?Plan {
        if (self.infinite) return null;

        if (self.movetime_ms) |ms| {
            const maximum_ms = @max(@as(u64, 1), ms);
            const optimum_ms = @max(@as(u64, 1), (maximum_ms * 17) / 20);
            return .{ .optimum_ms = optimum_ms, .maximum_ms = maximum_ms };
        }

        const remaining = switch (side) {
            .white => self.wtime_ms,
            .black => self.btime_ms,
        } orelse return null;
        const increment = switch (side) {
            .white => self.winc_ms,
            .black => self.binc_ms,
        };
        const hard_cap = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);

        if (self.movestogo) |moves_to_go| {
            return planMovesToGo(remaining, increment, move_overhead_ms, moves_to_go, hard_cap);
        }

        return planSuddenDeath(remaining, increment, move_overhead_ms, hard_cap);
    }

    pub fn toControllerLimits(self: GoLimits, side: types.Color, move_overhead_ms: u64) Limits {
        var limits = Limits{
            .depth = self.depth,
            .node_limit = self.node_limit,
        };

        if (self.plan(side, move_overhead_ms)) |timing| {
            limits.optimum_budget_ns = timing.optimum_ms * std.time.ns_per_ms;
            limits.maximum_budget_ns = timing.maximum_ms * std.time.ns_per_ms;
        }

        return limits;
    }
};

fn planMovesToGo(remaining: u64, increment: u64, move_overhead_ms: u64, moves_to_go: u32, hard_cap: u64) Plan {
    const mtg = std.math.clamp(moves_to_go, 1, 50);
    const reserve = move_overhead_ms * (@as(u64, mtg) + 2);
    const future_increment = increment * (@as(u64, mtg) - 1);
    const time_pool = if (remaining + future_increment > reserve)
        remaining + future_increment - reserve
    else
        1;

    var optimum_ms = @max(@as(u64, 1), time_pool / mtg);
    if (remaining <= LOW_TIME_THRESHOLD_MS) {
        const safe_remaining = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
        const emergency_cap = @max(@as(u64, 1), safe_remaining / 16 + increment / 4);
        optimum_ms = @min(optimum_ms, emergency_cap);
    }

    var maximum_ms = optimum_ms + @max(@as(u64, 1), optimum_ms / 2);
    maximum_ms = @min(maximum_ms, hard_cap);
    return .{ .optimum_ms = optimum_ms, .maximum_ms = @max(optimum_ms, maximum_ms) };
}

fn planSuddenDeath(remaining: u64, increment: u64, move_overhead_ms: u64, hard_cap: u64) Plan {
    const safe_remaining = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
    const divisor: u64 = if (remaining <= LOW_TIME_THRESHOLD_MS)
        LOW_TIME_DIVISOR
    else if (increment == 0)
        SUDDEN_DEATH_NO_INCREMENT_DIVISOR
    else
        SUDDEN_DEATH_DIVISOR;

    var optimum_ms = safe_remaining / divisor;
    optimum_ms += increment / 4;
    optimum_ms = @max(@as(u64, 1), optimum_ms);

    if (remaining <= LOW_TIME_THRESHOLD_MS) {
        const emergency_cap = @max(@as(u64, 1), safe_remaining / 16 + increment / 4);
        optimum_ms = @min(optimum_ms, emergency_cap);
    }

    const growth_margin = @max(@as(u64, 1), @max(optimum_ms / 2, increment / 2));
    const fraction_cap = @max(@as(u64, 1), safe_remaining / 8 + increment / 2);
    var maximum_ms = optimum_ms + growth_margin;
    maximum_ms = @min(maximum_ms, fraction_cap);
    maximum_ms = @min(maximum_ms, hard_cap);

    return .{ .optimum_ms = optimum_ms, .maximum_ms = @max(optimum_ms, maximum_ms) };
}

pub const StopNowReason = enum {
    external,
    node_limit,
    maximum_budget,
};

pub const Controller = struct {
    stop_flag: *const std.atomic.Value(bool),
    limits: Limits,
    timer: ?std.time.Timer = null,

    pub fn init(stop_flag: *const std.atomic.Value(bool), limits: Limits) Controller {
        return .{
            .stop_flag = stop_flag,
            .limits = limits,
            .timer = std.time.Timer.start() catch null,
        };
    }

    pub fn elapsedNs(self: *Controller) u64 {
        if (self.timer) |*timer| return timer.read();
        return 0;
    }

    pub fn stopReasonNow(self: *Controller, nodes: u64) ?StopNowReason {
        if (self.stop_flag.load(.acquire)) return .external;
        if (self.limits.node_limit) |limit| {
            if (nodes >= limit) return .node_limit;
        }
        // The wall-clock read (clock_gettime) is ~4% of search time when done every
        // node; throttle it to every 1024 nodes. node_limit + external stop stay exact
        // every node; the time deadline can overshoot by <=1023 nodes (<~1ms at our
        // nps), which is negligible vs any move budget. Fixed-nodes search is unaffected.
        if (self.limits.maximum_budget_ns) |budget_ns| {
            if (nodes & 1023 == 0 and self.elapsedNs() >= budget_ns) return .maximum_budget;
        }
        return null;
    }

    pub fn shouldStopNow(self: *Controller, nodes: u64) bool {
        return self.stopReasonNow(nodes) != null;
    }
};

test "controller stops at node limit" {
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .node_limit = 8 });

    try std.testing.expect(!controller.shouldStopNow(7));
    try std.testing.expect(controller.shouldStopNow(8));
}

test "go limits compute sudden-death plan with wider hard headroom" {
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
    };

    const plan = limits.plan(.white, DEFAULT_MOVE_OVERHEAD_MS).?;
    try std.testing.expectEqual(@as(u64, 1_499), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 2_248), plan.maximum_ms);
}

test "go limits compute moves-to-go plan with wider hard headroom" {
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
        .movestogo = 40,
    };

    const plan = limits.plan(.white, DEFAULT_MOVE_OVERHEAD_MS).?;
    try std.testing.expectEqual(@as(u64, 1_704), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 2_556), plan.maximum_ms);
}

test "go limits keep some safety margin under short time controls" {
    const limits = GoLimits{
        .wtime_ms = 500,
        .winc_ms = 50,
    };

    const plan = limits.plan(.white, DEFAULT_MOVE_OVERHEAD_MS).?;
    try std.testing.expectEqual(@as(u64, 27), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 52), plan.maximum_ms);
}

test "go limits keep short moves-to-go plans on low time" {
    const limits = GoLimits{
        .wtime_ms = 500,
        .winc_ms = 50,
        .movestogo = 10,
    };

    const plan = limits.plan(.white, DEFAULT_MOVE_OVERHEAD_MS).?;
    try std.testing.expectEqual(@as(u64, 42), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 63), plan.maximum_ms);
}

test "go limit conversion carries node limits and deadlines" {
    const limits = GoLimits{ .depth = 4, .node_limit = 128, .movetime_ms = 20 };
    const converted = limits.toControllerLimits(.white, DEFAULT_MOVE_OVERHEAD_MS);
    try std.testing.expectEqual(@as(?u16, 4), converted.depth);
    try std.testing.expectEqual(@as(?u64, 128), converted.node_limit);
    try std.testing.expect(converted.optimum_budget_ns != null);
    try std.testing.expect(converted.maximum_budget_ns != null);
}
