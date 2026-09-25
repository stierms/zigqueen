//! Persistent helpers for one process. The existing UCI worker is coordinator.
//! All reconfiguration is quiescent. Jobs and leases survive the completion
//! barrier, and thread destruction joins before freeing any borrowed resource.
const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const engine_mod = @import("engine.zig");
const eval_backend = @import("../eval/backend.zig");
const shared = @import("shared_tt.zig");
const jobs = @import("shared_job.zig");
const budget_mod = @import("node_budget.zig");
const syzygy = @import("syzygy.zig");

pub const MAX_THREADS: u8 = 32;
const Slot = struct {
    engine: engine_mod.Engine,
    thread: ?runtime.Thread = null,
    account: ?budget_mod.Account = null,
    telemetry: jobs.Telemetry = .{},
    actual_nodes: u64 = 0,
    last_id: u64 = 0,
};

const TestRequest = struct {
    position: @import("../core/position.zig").Position,
    history: @import("repetition.zig").History = .{},
    root_moves: ?@import("../core/move.zig").MoveList = null,
};

test "pool strict credits, preflight and repeated job barriers" {
    const a = std.testing.allocator;
    var owner = try eval_backend.EngineState.init(a, .{});
    defer owner.deinit();
    var coordinator = try engine_mod.Engine.initForParallel(a, 1, &owner);
    defer coordinator.deinit();
    var external = std.atomic.Value(bool).init(false);
    const pool = try Pool.create(a, 4, 1, &owner, &external, 1, 1);
    defer pool.destroy();
    const request = TestRequest{ .position = try @import("../core/fen.zig").startpos() };
    var id: u64 = 0;
    for (0..3) |_| {
        for ([_]u64{ 0, 1, 63, 64, 65, 191, 192, 193, 255, 256, 257, 10_000, std.math.maxInt(u64) }) |n| {
            id += 1;
            const result = try pool.run(&coordinator, id, 1, 1, &request, .{ .node_limit = n, .depth = if (n == std.math.maxInt(u64)) 2 else null });
            try std.testing.expect(result.result.best_move != null and result.result.nodes <= n);
            try std.testing.expectEqual(if (n <= jobs.CREDIT_BLOCK) @as(usize, 1) else 4, result.participants);
            try std.testing.expect(pool.job == null and pool.running == 0 and !pool.table.active);
            try std.testing.expectEqual(n - result.result.nodes, pool.control.budget.?.available());
            var counted = coordinator.ctx.nodes;
            if (result.participants > 1) for (pool.helpers) |*slot| {
                try std.testing.expect(slot.account.?.closed);
                try std.testing.expectEqual(slot.actual_nodes, slot.account.?.counted());
                counted += slot.actual_nodes;
            };
            try std.testing.expectEqual(result.result.nodes, counted);
        }
    }
    for ([_][]const u8{
        "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", // mate
        "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", // stalemate
        "4k3/8/8/8/8/8/3Q4/4K3 w - - 100 1", // claimable draw
    }) |fen| {
        const terminal = TestRequest{ .position = try @import("../core/fen.zig").parse(fen) };
        id += 1;
        const result = try pool.run(&coordinator, id, 1, 1, &terminal, .{ .node_limit = 1000 });
        try std.testing.expectEqual(@as(usize, 1), result.participants);
        try std.testing.expectEqual(@as(u64, 0), result.result.nodes);
    }
    try std.testing.expectError(error.JobEpochMismatch, pool.run(&coordinator, id, 1, 1, &request, .{ .depth = 1 }));
    try std.testing.expectError(error.JobEpochMismatch, pool.run(&coordinator, id + 1, 2, 1, &request, .{ .depth = 1 }));
    try std.testing.expectError(error.JobEpochMismatch, pool.run(&coordinator, id + 1, 1, 2, &request, .{ .depth = 1 }));
}

test "pool partial spawn failure joins already started helpers" {
    const a = std.testing.allocator;
    var owner = try eval_backend.EngineState.init(a, .{});
    defer owner.deinit();
    var external = std.atomic.Value(bool).init(false);
    const Spawner = struct {
        starts: usize = 0,
        fn spawn(self: *@This(), pool: *Pool, slot: *Slot) !runtime.Thread {
            if (self.starts == 1) return error.InjectedSpawnFailure;
            self.starts += 1;
            return pool.runtime_owner.spawn(.{}, Pool.helperMain, .{ pool, slot });
        }
    };
    var spawner = Spawner{};
    try std.testing.expectError(error.InjectedSpawnFailure, Pool.createWithSpawner(a, 4, 1, &owner, &external, 1, 1, &spawner));
    try std.testing.expectEqual(@as(usize, 1), spawner.starts);
    // A fresh configuration must remain usable after the partial-start unwind.
    const pool = try Pool.create(a, 2, 1, &owner, &external, 1, 1);
    pool.destroy();
}

test "helper pickup rejects an epoch mismatch in every build mode" {
    const a = std.testing.allocator;
    var owner = try eval_backend.EngineState.init(a, .{});
    defer owner.deinit();
    var coordinator = try engine_mod.Engine.initForParallel(a, 1, &owner);
    defer coordinator.deinit();
    var external = std.atomic.Value(bool).init(false);
    const Spawner = struct {
        fn enter(pool: *Pool, slot: *Slot) void {
            pool.mutex.lock();
            while (!pool.shutdown and pool.dispatch_id == 0) pool.ready.wait(&pool.mutex);
            // Fault injection after publication, before the real pickup check.
            // No search reads this owner metadata after publishing the job.
            pool.network_epoch += 1;
            pool.mutex.unlock();
            Pool.helperMain(pool, slot);
        }
        fn spawn(_: @This(), pool: *Pool, slot: *Slot) !runtime.Thread {
            return pool.runtime_owner.spawn(.{}, enter, .{ pool, slot });
        }
    };
    const pool = try Pool.createWithSpawner(a, 2, 1, &owner, &external, 1, 1, Spawner{});
    defer pool.destroy();
    const request = TestRequest{ .position = try @import("../core/fen.zig").startpos() };
    try std.testing.expectError(error.JobEpochMismatch, pool.run(&coordinator, 1, 1, 1, &request, .{ .node_limit = 1000 }));
    try std.testing.expect(pool.failed.load(.acquire) and pool.running == 0 and pool.job == null);
}

test "winning root tablebase result starts no helper and charges once" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_P2_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try std.testing.expect(syzygy.init(path_z));
    defer syzygy.disable();
    var owner = try eval_backend.EngineState.init(a, .{});
    defer owner.deinit();
    var coordinator = try engine_mod.Engine.initForParallel(a, 1, &owner);
    defer coordinator.deinit();
    var external = std.atomic.Value(bool).init(false);
    const pool = try Pool.create(a, 4, 1, &owner, &external, 1, 1);
    defer pool.destroy();
    const request = TestRequest{ .position = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1") };
    for ([_]u64{ 0, 1, 65, 10000 }, 1..) |n, id| {
        const result = try pool.run(&coordinator, id, 1, 1, &request, .{ .node_limit = n });
        try std.testing.expectEqual(@as(usize, 1), result.participants);
        try std.testing.expectEqual(@as(u64, if (n == 0) 0 else 1), result.result.nodes);
        try std.testing.expect(result.result.best_move != null);
        try std.testing.expectEqual(n - result.result.nodes, pool.control.budget.?.available());
        if (n > 0) try std.testing.expect(result.result.score >= syzygy.TB_WIN_SCORE - 1000);
    }
}
pub const Outcome = struct {
    result: engine_mod.SearchResult,
    hashfull: u16,
    participants: usize,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    runtime_owner: runtime.Owner = .{},
    table: shared.SharedTable,
    helpers: []Slot,
    initialized: usize = 0,
    mutex: runtime.Mutex = .{},
    ready: runtime.Condition = .{},
    done: runtime.Condition = .{},
    shutdown: bool = false,
    running: usize = 0,
    dispatch_id: u64 = 0,
    last_id: u64 = 0,
    network_epoch: u64,
    config_epoch: u64,
    job: ?jobs.Job = null,
    control: jobs.Control,
    coordinator_telemetry: jobs.Telemetry = .{},
    failed: std.atomic.Value(bool) = .init(false),
    last_participants: usize = 1,

    pub fn create(allocator: std.mem.Allocator, threads: u8, hash_mb: u32, owner: *const eval_backend.EngineState, external_stop: *const std.atomic.Value(bool), network_epoch: u64, config_epoch: u64) !*Pool {
        return createWithSpawner(allocator, threads, hash_mb, owner, external_stop, network_epoch, config_epoch, OsSpawner{});
    }

    const OsSpawner = struct {
        fn spawn(_: @This(), pool: *Pool, slot: *Slot) !runtime.Thread {
            return pool.runtime_owner.spawn(.{}, helperMain, .{ pool, slot });
        }
    };

    fn createWithSpawner(allocator: std.mem.Allocator, threads: u8, hash_mb: u32, owner: *const eval_backend.EngineState, external_stop: *const std.atomic.Value(bool), network_epoch: u64, config_epoch: u64, spawner: anytype) !*Pool {
        if (threads < 2 or threads > MAX_THREADS) return error.InvalidThreads;
        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);
        var table = try shared.SharedTable.init(allocator, hash_mb);
        errdefer table.deinit();
        const helpers = try allocator.alloc(Slot, threads - 1);
        errdefer allocator.free(helpers);
        self.* = .{ .allocator = allocator, .table = table, .helpers = helpers, .network_epoch = network_epoch, .config_epoch = config_epoch, .control = .{ .external_stop = external_stop } };
        errdefer self.closeWorkers();
        for (helpers) |*slot| {
            slot.* = .{ .engine = try engine_mod.Engine.initForParallel(allocator, hash_mb, owner) };
            self.initialized += 1;
            slot.thread = try spawner.spawn(self, slot);
        }
        return self;
    }

    fn closeWorkers(self: *Pool) void {
        self.control.cancel();
        self.mutex.lock();
        self.shutdown = true;
        self.ready.broadcast();
        self.mutex.unlock();
        for (self.helpers[0..self.initialized]) |*slot| {
            if (slot.thread) |thread| self.runtime_owner.join(thread);
            slot.engine.deinit();
        }
        self.runtime_owner.deinit();
    }

    pub fn destroy(self: *Pool) void {
        std.debug.assert(self.job == null and self.running == 0);
        self.closeWorkers();
        self.table.deinit();
        self.allocator.free(self.helpers);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn reset(self: *Pool) void {
        std.debug.assert(self.job == null and self.running == 0);
        self.table.clear() catch unreachable;
        for (self.helpers) |*slot| slot.engine.reset();
    }

    /// Caller has drained the old job and still owns the old net until all
    /// these borrowers have detached. No fallible operation or new allocation.
    pub fn syncConfig(self: *Pool, coordinator: *const engine_mod.Engine, owner: *const eval_backend.EngineState, network_epoch: u64, config_epoch: u64) void {
        std.debug.assert(self.job == null and self.running == 0);
        for (self.helpers) |*slot| {
            slot.engine.evaluator.deinit();
            slot.engine.evaluator = owner.borrow(slot.engine.allocator);
            slot.engine.contempt_cp = coordinator.contempt_cp;
            slot.engine.basin_config = coordinator.basin_config;
            slot.engine.eval_cache.assoc = coordinator.eval_cache.assoc;
        }
        self.network_epoch = network_epoch;
        self.config_epoch = config_epoch;
        self.reset();
    }

    pub fn snapshotNodes(self: *const Pool) u64 {
        var total = self.coordinator_telemetry.nodes.load(.monotonic);
        for (self.helpers) |*slot| total +|= slot.telemetry.nodes.load(.monotonic);
        return total;
    }

    pub fn cancel(self: *Pool) void {
        self.control.cancel();
    }

    pub fn run(self: *Pool, coordinator: *engine_mod.Engine, id: u64, network_epoch: u64, config_epoch: u64, request: anytype, limits: @import("time.zig").Limits) !Outcome {
        if (id == 0 or id <= self.last_id or network_epoch != self.network_epoch or config_epoch != self.config_epoch) return error.JobEpochMismatch;
        std.debug.assert(self.job == null and self.running == 0);
        const start = runtime.Timer.start() catch null;
        self.control.reset(limits.node_limit);
        var account = if (self.control.budget) |*budget| try budget.coordinator() else null;
        defer self.control.finish(if (account) |*a| a else null);
        const view = try self.table.beginSearch();
        defer self.table.endSearch();
        // One coordinator-owned lease; helpers can only borrow this Job.
        var lease = syzygy.beginJob();
        defer lease.deinit();
        self.mutex.lock();
        self.failed.store(false, .release);
        self.coordinator_telemetry.nodes.store(0, .monotonic);
        for (self.helpers) |*slot| {
            slot.actual_nodes = 0;
            slot.telemetry.nodes.store(0, .monotonic);
        }
        self.job = .{ .id = id, .network_epoch = network_epoch, .config_epoch = config_epoch, .position = request.position, .history = request.history, .root_moves = request.root_moves, .limits = limits, .table = view, .tablebases = &lease, .control = &self.control, .timer = start };
        self.last_participants = 1;
        self.mutex.unlock();
        var execution = jobs.Execution(true){ .job = &self.job.?, .account = if (account) |*a| a else null, .telemetry = &self.coordinator_telemetry, .ready = .{ .ctx = self, .call = startHelpers } };
        var result = coordinator.searchParallel(true, &execution);
        // Normal completion cancels the JOB, never the external infinite flag.
        self.control.cancel();
        self.coordinator_telemetry.nodes.store(coordinator.ctx.nodes, .monotonic);
        self.mutex.lock();
        while (self.running != 0) self.done.wait(&self.mutex);
        var total = coordinator.ctx.nodes;
        for (self.helpers) |*slot| total +|= slot.actual_nodes;
        self.last_id = id;
        const hashfull = self.job.?.table.hashfullPermille();
        self.job = null;
        self.mutex.unlock();
        if (self.failed.load(.acquire)) return error.JobEpochMismatch;
        if (limits.node_limit) |limit| std.debug.assert(total <= limit);
        result.nodes = total;
        return .{ .result = result, .hashfull = hashfull, .participants = self.last_participants };
    }

    fn startHelpers(ctx: *anyopaque, policy: ?*const syzygy.RootPolicy) void {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        // Before dispatch, install the coordinator's result-preserving set by
        // value. Helpers never borrow a coordinator-local move buffer.
        if (policy) |p| {
            self.job.?.root_moves = p.moves;
            self.job.?.root_wdl = p.wdl;
        }
        if (self.control.stopping()) return;
        if (self.control.budget) |*budget| {
            if (!budget.helpersAllowed()) return;
            for (self.helpers) |*slot| slot.account = budget.helper() catch unreachable;
        } else {
            for (self.helpers) |*slot| slot.account = null;
        }
        self.running = self.helpers.len;
        self.last_participants = self.helpers.len + 1;
        self.dispatch_id = self.job.?.id;
        self.ready.broadcast();
    }

    fn helperMain(self: *Pool, slot: *Slot) void {
        self.mutex.lock();
        while (true) {
            while (!self.shutdown and self.dispatch_id == slot.last_id) self.ready.wait(&self.mutex);
            if (self.shutdown) {
                self.mutex.unlock();
                return;
            }
            const job: *const jobs.Job = &self.job.?;
            const valid = job.id == self.dispatch_id and job.id > slot.last_id and
                job.network_epoch == self.network_epoch and job.config_epoch == self.config_epoch;
            self.mutex.unlock();
            if (valid) {
                var execution = jobs.Execution(false){ .job = job, .account = if (slot.account) |*a| a else null, .telemetry = &slot.telemetry };
                _ = slot.engine.searchParallel(false, &execution);
                slot.actual_nodes = slot.engine.ctx.nodes;
                slot.telemetry.nodes.store(slot.actual_nodes, .monotonic);
            } else {
                self.failed.store(true, .release);
                self.control.cancel();
            }
            self.control.finish(if (slot.account) |*a| a else null);
            self.mutex.lock();
            slot.last_id = self.dispatch_id;
            self.running -= 1;
            self.done.broadcast();
        }
    }
};

test "drawn root policy is copied before helpers and survives tiny budgets" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_ROOT_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try std.testing.expect(syzygy.init(path_z));
    defer syzygy.disable();
    var owner = try eval_backend.EngineState.init(a, .{});
    defer owner.deinit();
    var coordinator = try engine_mod.Engine.initForParallel(a, 1, &owner);
    defer coordinator.deinit();
    var external = std.atomic.Value(bool).init(false);
    const pool = try Pool.create(a, 4, 1, &owner, &external, 1, 1);
    defer pool.destroy();
    const request = TestRequest{ .position = try @import("../core/fen.zig").parse("7k/1q6/7P/6P1/2Q3K1/8/8/8 b - - 54 170") };
    var lease = syzygy.beginJob();
    const policy = lease.probeRootMoves(&request.position, null).?;
    lease.deinit();
    for ([_]u64{ 1, 64, 129, 20000 }, 1..) |n, id| {
        const outcome = try pool.run(&coordinator, id, 1, 1, &request, .{ .node_limit = n });
        try std.testing.expect(outcome.result.nodes <= n);
        try std.testing.expectEqual(@as(i32, 0), outcome.result.score);
        var safe = false;
        for (policy.moves.slice()) |mv| {
            if (outcome.result.best_move == mv) safe = true;
        }
        try std.testing.expect(safe);
        if (n > 64) {
            try std.testing.expectEqual(@as(usize, 4), outcome.participants);
        }
    }
}
