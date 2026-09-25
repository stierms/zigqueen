const std = @import("std");
const runtime = @import("search_runtime.zig");
const capacity = 4;
const timeout_ns = 10 * std.time.ns_per_s;

// A bounded lifecycle probe, not the production search pool. All shared state
// is mutex-owned; the controller publishes generations and releases a rendezvous.
const Probe = struct {
    mutex: runtime.Mutex = .{},
    changed: runtime.Condition = .{},
    shutdown: bool = false,
    failed: bool = false,
    generation: u32 = 0,
    ready: usize = 0,
    arrived: usize = 0,
    completed: usize = 0,
    released: bool = false,
    cancelled: bool = false,
    work: [capacity]u32 = @splat(0),
    seen: [capacity]u32 = @splat(0),
    ids: [capacity]runtime.Thread.Id = undefined,
    threads: [capacity]runtime.Thread = undefined,
    started: usize = 0,

    // Caller holds mutex. A total deadline bounds each predicate wait even if
    // there are spurious notifications; timeout releases all other waiters.
    fn wait(self: *Probe, timer: *runtime.Timer) bool {
        const elapsed = timer.read();
        if (elapsed < timeout_ns) {
            self.changed.timedWait(&self.mutex, timeout_ns - elapsed) catch {
                self.fail();
                return false;
            };
            return true;
        }
        self.fail();
        return false;
    }

    fn fail(self: *Probe) void {
        self.failed = true;
        self.shutdown = true;
        self.changed.broadcast();
    }

    fn worker(self: *Probe, index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ids[index] = runtime.Thread.getCurrentId();
        self.ready += 1;
        self.changed.broadcast();
        while (!self.shutdown) {
            var timer = runtime.Timer.start() catch {
                self.fail();
                return;
            };
            while (!self.shutdown and self.generation == self.seen[index]) {
                if (!self.wait(&timer)) return;
            }
            if (self.shutdown) return;
            const job = self.generation;
            self.arrived += 1;
            self.changed.broadcast();
            timer.reset();
            while (!self.shutdown and !self.released) {
                if (!self.wait(&timer)) return;
            }
            if (self.shutdown) return;
            if (!self.cancelled) self.work[index] += 1;
            self.seen[index] = job;
            self.completed += 1;
            self.changed.broadcast();
        }
    }

    fn start(self: *Probe, fail_at: ?usize) !void {
        // Inject at the caller's spawn seam. This does not pretend to exhaust
        // the OS's actual thread limit. Already-created threads must still join.
        errdefer self.finish();
        for (0..capacity) |i| {
            if (fail_at == i) return error.InjectedSpawnFailure;
            self.threads[i] = try runtime.Thread.spawn(.{}, worker, .{ self, i });
            self.started += 1;
        }
    }

    fn finish(self: *Probe) void {
        self.mutex.lock();
        self.shutdown = true;
        self.changed.broadcast();
        self.mutex.unlock();
        for (self.threads[0..self.started]) |thread| thread.join();
        self.started = 0;
    }

    fn waitCount(self: *Probe, counter: *const usize) !void {
        var timer = try runtime.Timer.start();
        while (!self.failed and counter.* != capacity) {
            if (!self.wait(&timer)) break;
        }
        if (self.failed) return error.ProbeTimeout;
    }
};

test "runtime aliases preserve exact primitive types and monotonic timer" {
    comptime {
        std.debug.assert(runtime.Thread == std.Thread);
        std.debug.assert(runtime.Mutex == std.Thread.Mutex);
        std.debug.assert(runtime.Condition == std.Thread.Condition);
        std.debug.assert(runtime.Timer == std.time.Timer);
    }
    var timer = try runtime.Timer.start();
    const first = timer.read();
    try std.testing.expect(timer.read() >= first);
}

test "runtime persistent workers rendezvous cancel park and retain generation" {
    var probe = Probe{};
    try probe.start(null);
    defer probe.finish();
    probe.mutex.lock();
    defer probe.mutex.unlock();
    try probe.waitCount(&probe.ready);
    for (probe.ids, 0..) |id, i| {
        try std.testing.expect(id != runtime.Thread.getCurrentId());
        for (probe.ids[0..i]) |other| try std.testing.expect(id != other);
    }
    for (1..33) |generation| {
        probe.generation = @intCast(generation);
        probe.arrived = 0;
        probe.completed = 0;
        probe.released = false;
        probe.changed.broadcast();
        try probe.waitCount(&probe.arrived);
        probe.cancelled = generation % 2 == 0;
        probe.released = true;
        probe.changed.broadcast();
        try probe.waitCount(&probe.completed);
        for (probe.seen) |seen| try std.testing.expectEqual(generation, seen);
        for (probe.work) |work| try std.testing.expectEqual((generation + 1) / 2, work);
    }
}

test "runtime partial startup joins every created worker" {
    for (0..capacity) |fail_at| {
        var probe = Probe{};
        try std.testing.expectError(error.InjectedSpawnFailure, probe.start(fail_at));
        try std.testing.expectEqual(@as(usize, 0), probe.started);
        try std.testing.expectEqual(fail_at, probe.ready);
        try std.testing.expect(probe.shutdown and !probe.failed);
        for (probe.work) |work| try std.testing.expectEqual(@as(u32, 0), work);
    }
}

test "runtime shutdown releases workers blocked at interdependent barrier" {
    var probe = Probe{};
    try probe.start(null);
    defer probe.finish();
    {
        probe.mutex.lock();
        defer probe.mutex.unlock();
        try probe.waitCount(&probe.ready);
        probe.generation = 1;
        probe.changed.broadcast();
        try probe.waitCount(&probe.arrived);
        try std.testing.expect(!probe.released);
    }
    probe.finish();
    try std.testing.expect(!probe.failed);
    for (probe.work) |work| try std.testing.expectEqual(@as(u32, 0), work);
}
