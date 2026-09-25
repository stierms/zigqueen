//! Accounting/lifecycle stress only. This does not run search or implement the
//! production pool's helper parking, completion or cancellation policy.
const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const credits = @import("node_budget.zig");
const timeout_ns = 10 * std.time.ns_per_s;
const capacity = 16;
const Mode = enum { drain, cancel_before, coordinator_cancel, partial_start };

const Worker = struct {
    account: credits.Account,
    go: *runtime.ResetEvent,
    stop: *std.atomic.Value(bool),
    coordinator_cancel: bool,
    done: runtime.ResetEvent = .{},

    fn run(self: *Worker) void {
        self.go.wait();
        while (!self.stop.load(.acquire)) {
            switch (self.account.tryCount()) {
                .counted => if (self.coordinator_cancel) {
                    // Only worker 0 receives this capability in the harness.
                    self.stop.store(true, .release);
                },
                .empty, .closed => break,
            }
        }
        self.account.finish();
        self.done.set();
    }
};

fn executeWorkers(workers: []Worker, go: *runtime.ResetEvent, stop: *std.atomic.Value(bool), partial_start: bool) !void {
    var threads: [capacity]runtime.Thread = undefined;
    var started: usize = 0;
    var completed = false;
    defer {
        if (!completed) stop.store(true, .release);
        go.set();
        for (threads[0..started]) |thread| thread.join();
    }
    for (workers, 0..) |*worker, i| {
        // This returns through the same cleanup as a genuine spawn error.
        if (partial_start and i == 2) return error.InjectedSpawnFailure;
        threads[i] = try runtime.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    go.set();
    for (workers) |*worker| try worker.done.timedWait(timeout_ns);
    completed = true;
}

fn runTeam(limit: u64, block: u32, requested: usize, mode: Mode) !void {
    std.debug.assert(requested > 0 and requested <= capacity);
    var budget = try credits.Budget.init(limit, block);
    var go = runtime.ResetEvent{};
    var stop = std.atomic.Value(bool).init(mode == .cancel_before);
    var workers: [capacity]Worker = undefined;
    var initialized: usize = 0;
    const participants = if (budget.helpersAllowed()) requested else 1;
    defer for (workers[0..initialized]) |*worker| worker.account.finish();
    for (workers[0..participants], 0..) |*worker, i| {
        worker.* = .{
            .account = if (i == 0) try budget.coordinator() else try budget.helper(),
            .go = &go,
            .stop = &stop,
            .coordinator_cancel = mode == .coordinator_cancel and i == 0,
        };
        initialized += 1;
    }
    var injected = false;
    executeWorkers(workers[0..participants], &go, &stop, mode == .partial_start) catch |err| {
        if (err != error.InjectedSpawnFailure or mode != .partial_start) return err;
        injected = true;
    };
    try std.testing.expectEqual(mode == .partial_start, injected);
    var actual: u64 = 0;
    for (workers[0..initialized]) |*worker| {
        worker.account.finish();
        actual += worker.account.counted();
    }
    try std.testing.expect(actual <= limit);
    try std.testing.expectEqual(limit, actual + budget.available());
    switch (mode) {
        .drain => {
            try std.testing.expectEqual(limit, actual);
            try std.testing.expect(!stop.load(.acquire));
        },
        .cancel_before, .partial_start => try std.testing.expectEqual(@as(u64, 0), actual),
        .coordinator_cancel => try std.testing.expect(stop.load(.acquire)),
    }
}

test "node budget concurrent full drain conserves every credit across block boundaries" {
    for ([_]usize{ 1, 2, 4, 16 }) |workers| {
        for ([_]u32{ 1, 8, 256 }) |block| {
            for ([_]u64{ 0, 1, block - 1, block, block + 1, 4099, 100003 }) |limit| {
                try runTeam(limit, block, workers, .drain);
            }
        }
    }
}

test "node budget cancellation and partial publication return unused reservations" {
    for (0..8) |_| {
        for ([_]usize{ 4, 16 }) |workers| {
            try runTeam(100003, 64, workers, .cancel_before);
            try runTeam(100003, 64, workers, .coordinator_cancel);
            try runTeam(100003, 64, workers, .partial_start);
        }
    }
}
