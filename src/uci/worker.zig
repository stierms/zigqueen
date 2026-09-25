const std = @import("std");
const eval_backend = @import("../eval/backend.zig");
const build_options = @import("build_options");
const basin = @import("../search/basin.zig");
const runtime = @import("../util/search_runtime.zig");
const move_mod = @import("../core/move.zig");
const engine_mod = @import("../search/engine.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_time = @import("../search/time.zig");
const search_info = @import("../search/search_info.zig");
const tt = @import("../search/tt.zig");
const parallel_mod = @import("../search/parallel_pool.zig");
const info = @import("info.zig");

pub const OutputSink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn writeAll(self: OutputSink, bytes: []const u8) anyerror!void {
        return self.write_fn(self.ctx, bytes);
    }

    pub fn print(self: OutputSink, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(text);
    }

    pub fn writeByte(self: OutputSink, byte: u8) anyerror!void {
        var buffer = [1]u8{byte};
        try self.writeAll(&buffer);
    }
};

pub const SearchRequest = struct {
    position: position.Position,
    history: repetition.History,
    limits: search_time.GoLimits,
    root_moves: ?move_mod.MoveList = null,
    move_overhead_ms: u32 = @intCast(search_time.DEFAULT_MOVE_OVERHEAD_MS),
};

// Keep the old public spelling for existing tools/tests. This type now owns
// the process network/runtime, private coordinator and optional helper pool.
pub const Worker = Pool;

const Coordinator = struct {
    engine: engine_mod.Engine,
    info_streamed: bool = false,
};

const ConfigSnapshot = struct {
    scale: u16,
    scale_explicit: bool,
    contempt: @import("../core/types.zig").Score,
    hash_mb: u32,
    basin_params: if (build_options.tuning) basin.Params else void,
};

const Job = struct {
    id: u64,
    network_epoch: u64,
    config_epoch: u64,
    config: ConfigSnapshot,
    request: SearchRequest,
};

/// Control methods have one caller (the UCI command thread). The Pool must
/// remain at a stable address from start through join. That caller changes
/// configuration only after stopAndWait; the worker reads its frozen view
/// until it publishes completion under mutex. Helpers are joined at a job
/// barrier before that publication, establishing quiescence for reconfiguration.
pub const Pool = struct {
    mutex: runtime.Mutex = .{},
    command_ready: runtime.Condition = .{},
    became_idle: runtime.Condition = .{},
    thread: ?runtime.Thread = null,
    output: OutputSink,
    runtime_owner: runtime.Owner = .{},
    network_owner: eval_backend.EngineState,
    coordinator: Coordinator,
    pending_request: ?Job = null,
    network_epoch: u64 = 1,
    config_epoch: u64 = 1,
    parallel: ?*parallel_mod.Pool = null,
    last_started_id: u64 = 0,
    last_completed_id: u64 = 0,
    searching: bool = false,
    shutdown: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(output: OutputSink, hash_mb: u32) !Worker {
        return initWithOptions(output, hash_mb, .{});
    }

    pub fn initWithOptions(output: OutputSink, hash_mb: u32, eval_options: engine_mod.EvalOptions) !Worker {
        return initWithAllocator(std.heap.page_allocator, output, hash_mb, eval_options);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator, output: OutputSink, hash_mb: u32, eval_options: engine_mod.EvalOptions) !Pool {
        var owner = try eval_backend.EngineState.init(allocator, eval_options);
        errdefer owner.deinit();
        const engine = try engine_mod.Engine.initWithBorrowedEvaluator(allocator, hash_mb, &owner);
        return .{ .output = output, .network_owner = owner, .coordinator = .{ .engine = engine } };
    }

    const OsSpawner = struct {
        fn spawn(_: @This(), owner: *runtime.Owner, pool: *Pool) !runtime.Thread {
            return owner.spawn(.{}, threadMain, .{pool});
        }
    };

    pub fn start(self: *Worker) !void {
        try self.startWithSpawner(OsSpawner{});
    }

    fn startWithSpawner(self: *Pool, spawner: anytype) !void {
        std.debug.assert(self.thread == null and !self.shutdown);
        // Called only after the pool reaches its stable address. On failure
        // its initialized resources remain owned, and deinit/retry are valid.
        self.thread = try spawner.spawn(&self.runtime_owner, self);
    }

    pub fn deinit(self: *Worker) void {
        self.mutex.lock();
        self.shutdown = true;
        self.stop_requested.store(true, .release);
        self.pending_request = null;
        if (self.parallel) |pool| pool.cancel();
        self.command_ready.broadcast();
        self.mutex.unlock();

        if (self.thread) |thread| {
            self.runtime_owner.join(thread);
            self.thread = null;
        }
        if (self.parallel) |pool| pool.destroy();
        self.coordinator.engine.deinit();
        self.network_owner.deinit();
        self.runtime_owner.deinit();
    }

    pub fn resetEngine(self: *Worker) void {
        self.stopAndWait();
        self.coordinator.engine.reset();
        if (self.parallel) |pool| pool.reset();
    }

    fn syncParallelConfig(self: *Pool) void {
        self.config_epoch +|= 1;
        if (self.parallel) |pool| pool.syncConfig(&self.coordinator.engine, &self.network_owner, self.network_epoch, self.config_epoch);
    }

    pub fn threads(self: *const Pool) u8 {
        return if (self.parallel) |pool| @intCast(pool.helpers.len + 1) else 1;
    }

    /// Prepare the whole new configuration before releasing the old one. Newly
    /// spawned helpers wait without borrowing the old resources; failure joins
    /// and frees only the new pool. Serial Hash resizing keeps its original path.
    pub fn setThreads(self: *Pool, count: u8) !void {
        self.stopAndWait();
        if (count < 1 or count > parallel_mod.MAX_THREADS) return error.InvalidThreads;
        if (count == self.threads()) return;
        try self.replaceParallelConfiguration(count, self.hashSizeMb());
    }

    fn replaceParallelConfiguration(self: *Pool, count: u8, hash_mb: u32) !void {
        var next_engine = if (count == 1)
            try engine_mod.Engine.initWithBorrowedEvaluator(self.coordinator.engine.allocator, hash_mb, &self.network_owner)
        else
            try engine_mod.Engine.initForParallel(self.coordinator.engine.allocator, hash_mb, &self.network_owner);
        errdefer next_engine.deinit();
        next_engine.contempt_cp = self.coordinator.engine.contempt_cp;
        next_engine.basin_config = self.coordinator.engine.basin_config;
        next_engine.eval_cache.assoc = self.coordinator.engine.eval_cache.assoc;
        const next_epoch = self.config_epoch +| 1;
        const next_pool = if (count == 1) null else try parallel_mod.Pool.create(next_engine.allocator, count, hash_mb, &self.network_owner, &self.stop_requested, self.network_epoch, next_epoch);
        // Nothing fallible after both complete preparations.
        if (next_pool) |pool| pool.syncConfig(&next_engine, &self.network_owner, self.network_epoch, next_epoch);
        if (self.parallel) |pool| pool.destroy();
        self.coordinator.engine.deinit();
        self.coordinator.engine = next_engine;
        self.parallel = next_pool;
        self.config_epoch = next_epoch;
    }

    pub fn setNnueScalePercent(self: *Worker, nnue_scale_percent: u16) void {
        self.stopAndWait();
        self.network_owner.setNnueScalePercent(nnue_scale_percent);
        self.coordinator.engine.setNnueScalePercent(nnue_scale_percent);
        self.syncParallelConfig();
    }

    pub fn setContempt(self: *Worker, contempt_cp: i32) void {
        self.stopAndWait();
        self.coordinator.engine.setContempt(contempt_cp);
        self.syncParallelConfig();
    }

    pub fn setBasinParams(self: *Worker, params: @import("../search/basin.zig").Params) void {
        self.stopAndWait();
        self.coordinator.engine.setBasinParams(params);
        self.syncParallelConfig();
    }

    pub fn setSyzygyPath(self: *Worker, path: []const u8) bool {
        self.stopAndWait();
        const result = self.coordinator.engine.setSyzygyPath(path);
        self.syncParallelConfig();
        return result;
    }

    pub fn loadNnueFile(self: *Worker, path: []const u8) !void {
        self.stopAndWait();
        if (self.network_epoch == std.math.maxInt(u64)) return error.NetworkEpochExhausted;
        var next = eval_backend.EngineState{
            .allocator = self.network_owner.allocator,
            .nnue_scale_percent = self.network_owner.nnue_scale_percent,
            .scale_explicit = self.network_owner.scale_explicit,
        };
        errdefer next.deinit();
        try next.loadModelFile(path);
        // No fallible operation after preparation. Detach the old borrower
        // before freeing its owner, with every worker idle.
        var previous = self.network_owner;
        self.coordinator.engine.evaluator.deinit();
        self.network_owner = next;
        self.coordinator.engine.evaluator = self.network_owner.borrow(self.coordinator.engine.allocator);
        self.coordinator.engine.reset();
        self.network_epoch += 1;
        self.syncParallelConfig();
        previous.deinit();
    }

    pub fn resizeHash(self: *Worker, hash_mb: u32) !void {
        self.stopAndWait();
        if (self.parallel != null) {
            try self.replaceParallelConfiguration(self.threads(), hash_mb);
        } else {
            try self.coordinator.engine.resizeHash(hash_mb);
            self.syncParallelConfig();
        }
    }

    pub fn hashSizeMb(self: *const Worker) u32 {
        return if (self.parallel) |pool| pool.table.configured_hash_mb else self.coordinator.engine.hashSizeMb();
    }

    pub fn startSearch(self: *Worker, request: SearchRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.thread != null);
        std.debug.assert(!self.searching);

        if (self.last_started_id == std.math.maxInt(u64)) return error.JobIdentifierExhausted;
        if (self.config_epoch == std.math.maxInt(u64)) return error.ConfigEpochExhausted;
        self.last_started_id += 1;
        self.stop_requested.store(false, .release);
        self.pending_request = .{
            .id = self.last_started_id,
            .network_epoch = self.network_epoch,
            .config_epoch = self.config_epoch,
            .config = self.configSnapshot(),
            .request = request,
        };
        self.searching = true;
        self.command_ready.signal();
    }

    pub fn stop(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stop_requested.store(true, .release);
        if (self.parallel) |pool| pool.cancel();
        // The search may have finished immediately and parked with its result.
        // Serialize the predicate change with waitForInfiniteStop to avoid a
        // notification between its predicate check and condition wait.
        self.command_ready.broadcast();
    }

    pub fn stopAndWait(self: *Worker) void {
        self.stop();
        self.waitIdle();
    }

    pub fn waitIdle(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.searching) {
            self.became_idle.wait(&self.mutex);
        }
    }

    fn threadMain(self: *Worker) void {
        self.mutex.lock();
        while (true) {
            while (self.pending_request == null and !self.shutdown) {
                self.command_ready.wait(&self.mutex);
            }

            if (self.shutdown and self.pending_request == null) {
                self.searching = false;
                self.became_idle.broadcast();
                self.mutex.unlock();
                return;
            }

            const job = self.pending_request.?;
            self.pending_request = null;
            self.mutex.unlock();

            self.runSearch(job);

            self.mutex.lock();
            std.debug.assert(job.id == self.last_started_id);
            self.last_completed_id = job.id;
            self.searching = false;
            self.became_idle.broadcast();
        }
    }

    fn configSnapshot(self: *const Pool) ConfigSnapshot {
        return .{
            .scale = self.coordinator.engine.evaluator.nnue_scale_percent,
            .scale_explicit = self.coordinator.engine.evaluator.scale_explicit,
            .contempt = self.coordinator.engine.contempt_cp,
            .hash_mb = self.hashSizeMb(),
            .basin_params = if (comptime build_options.tuning) self.coordinator.engine.basin_config.params else {},
        };
    }

    fn runSearch(self: *Worker, job: Job) void {
        // Quiescent configuration publication makes both this snapshot and
        // the worker's matching local config immutable for the whole job.
        std.debug.assert(job.network_epoch == self.network_epoch);
        std.debug.assert(std.meta.eql(job.config, self.configSnapshot()));
        const request = job.request;
        var timer = runtime.Timer.start() catch null;
        const controller_limits = request.limits.toControllerLimits(request.position.side_to_move, request.move_overhead_ms, request.position.fullmove_number);

        // Install the per-iteration info sink for this search; the engine streams
        // `info depth ...` lines through it as each depth (or aspiration fail) lands.
        self.coordinator.info_streamed = false;
        self.coordinator.engine.info_emitter = .{ .ctx = self, .emit_fn = emitInfo };

        const root_moves = if (request.root_moves) |*moves| moves else null;
        var final_hashfull: ?u16 = null;
        const result = if (self.parallel) |pool| blk: {
            const outcome = pool.run(&self.coordinator.engine, job.id, job.network_epoch, job.config_epoch, &request, controller_limits) catch |err| {
                self.output.print("info string search rejected: {s}\n", .{@errorName(err)}) catch {};
                info.writeBestMoveLine(self.output, null) catch {};
                return;
            };
            final_hashfull = outcome.hashfull;
            break :blk outcome.result;
        } else self.coordinator.engine.searchWithRootMoves(&request.position, &request.history, controller_limits, &self.stop_requested, root_moves);
        const elapsed_ns: u64 = if (timer) |*search_timer| search_timer.read() else 0;
        const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
        const reported_depth = if (result.depth != 0) result.depth else request.limits.depth orelse 1;

        if (result.best_move != null) {
            // The last streamed exact line already IS the final line; only emit one
            // here for the paths that never stream (book move, immediate draw, a
            // depth-1 stop before any iteration completed).
            if (final_hashfull) |hashfull| {
                // Final totals and this snapshot are read after all helpers stop.
                info.writeFinalLine(self.output, &result, reported_depth, elapsed_ms, hashfull) catch {};
            } else if (!self.coordinator.info_streamed) self.writeInfoLine(&result, reported_depth, elapsed_ms) catch {};
        } else {
            self.output.print("info depth 0 score cp 0 nodes {d} time {d}\n", .{ result.nodes, elapsed_ms }) catch {};
        }

        // Rule-50/repetition and winning root-TB returns can bypass the engine's
        // depth-ceiling wait. Every UCI infinite result obeys the same contract.
        if (request.limits.infinite) self.waitForInfiniteStop();
        if (result.best_move) |mv| self.writeBestMove(mv) catch {} else info.writeBestMoveLine(self.output, null) catch {};
    }

    fn waitForInfiniteStop(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stop_requested.load(.acquire) and !self.shutdown) {
            self.command_ready.wait(&self.mutex);
        }
    }

    fn emitInfo(ctx: *anyopaque, msg: search_info.InfoMessage) void {
        const self: *Worker = @ptrCast(@alignCast(ctx));
        switch (msg) {
            .iteration => |it| {
                if (it.bound == .exact) self.coordinator.info_streamed = true;
                var current = it;
                if (self.parallel) |pool| current.nodes = pool.snapshotNodes();
                info.writeIterationLine(self.output, current) catch {};
            },
            .currmove => |cm| info.writeCurrMoveLine(self.output, cm) catch {},
        }
    }

    fn writeInfoLine(self: *Worker, result: *const engine_mod.SearchResult, depth: u16, elapsed_ms: u64) !void {
        try info.writeFinalLine(self.output, result, depth, elapsed_ms, self.coordinator.engine.hashfullPermille());
    }

    fn writeBestMove(self: *Worker, mv: @import("../core/move.zig").Move) !void {
        try info.writeBestMoveLine(self.output, mv);
    }
};

const TestOutput = struct {
    mutex: runtime.Mutex = .{},
    changed: runtime.Condition = .{},
    buffer: [8192]u8 = [_]u8{0} ** 8192,
    len: usize = 0,

    fn sink(self: *TestOutput) OutputSink {
        return .{ .ctx = self, .write_fn = write };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestOutput = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len + bytes.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.changed.broadcast();
    }

    fn waitFor(self: *TestOutput, needle: []const u8, timeout_ns: u64) !void {
        var timer = try runtime.Timer.start();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (std.mem.indexOf(u8, self.buffer[0..self.len], needle) == null) {
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return error.Timeout;
            self.changed.timedWait(&self.mutex, timeout_ns - elapsed) catch {};
        }
    }

    fn contents(self: *const TestOutput) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "worker holds an immediate infinite result until stop or shutdown" {
    const fen = @import("../core/fen.zig");
    for ([_]bool{ false, true }) |shutdown| {
        var output = TestOutput{};
        var worker = try Worker.init(output.sink(), 1);
        var alive = true;
        defer if (alive) worker.deinit();
        try worker.start();
        const pos = try fen.parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 100 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        try worker.startSearch(.{ .position = pos, .history = history, .limits = .{ .infinite = true } });
        // Confirm completion output before testing that its result is retained.
        try output.waitFor("info depth ", 5 * std.time.ns_per_s);
        try std.testing.expectError(error.Timeout, output.waitFor("bestmove ", 20 * std.time.ns_per_ms));
        if (shutdown) {
            worker.deinit();
            alive = false;
        } else worker.stopAndWait();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.contents(), "bestmove "));
    }
}

test "worker stop before an infinite result parks is not lost across repeated jobs" {
    const fen = @import("../core/fen.zig");
    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), 1);
    defer worker.deinit();
    try worker.start();
    const pos = try fen.parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 100 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    for (0..32) |_| {
        try worker.startSearch(.{ .position = pos, .history = history, .limits = .{ .infinite = true } });
        worker.stopAndWait();
    }
    try std.testing.expectEqual(@as(usize, 32), std.mem.count(u8, output.contents(), "bestmove "));
}

test "worker emits bestmove after stop on infinite search" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .infinite = true },
    });

    runtime.Thread.sleep(5 * std.time.ns_per_ms);
    worker.stopAndWait();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
}

test "TB-decisive go infinite stays active until stop" {
    const fen = @import("../core/fen.zig");
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return;
    defer std.testing.allocator.free(path);

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();
    try std.testing.expect(worker.setSyzygyPath(path));

    var history = repetition.History{};
    const pos = try fen.parse("8/8/3Qkpp1/2P5/8/1r5P/4K3/8 b - - 2 57");
    history.push(pos.zobrist_key);
    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .infinite = true },
    });

    runtime.Thread.sleep(100 * std.time.ns_per_ms);
    worker.mutex.lock();
    const still_searching = worker.searching;
    worker.mutex.unlock();
    try std.testing.expect(still_searching);

    worker.stopAndWait();
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "bestmove ") != null);
}

test "worker prints a pv line starting with the reported bestmove" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 2 },
    });
    worker.waitIdle();

    const out = output.contents();
    const bestmove_index = std.mem.indexOf(u8, out, "bestmove ").? + "bestmove ".len;
    // We now stream a pv line per iteration; the final iteration's pv (the last
    // one) is the one that must agree with the reported bestmove.
    const pv_index = std.mem.lastIndexOf(u8, out, " pv ").? + " pv ".len;

    try std.testing.expect(std.mem.eql(u8, out[bestmove_index .. bestmove_index + 4], out[pv_index .. pv_index + 4]));
}

test "worker hash can be resized via engine ownership" {
    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), 1);
    defer worker.deinit();

    const before = worker.hashSizeMb();
    try worker.resizeHash(2);
    try std.testing.expect(worker.hashSizeMb() >= before);
}

test "worker info line includes nps and hashfull" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .movetime_ms = 10 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, " seldepth ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " nps ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " hashfull ") != null);
}

test "worker formats mate scores in uci info lines" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.parse("6k1/5Q2/6K1/8/8/8/8/8 w - - 0 1");
    history.push(pos.zobrist_key);

    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 1 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "score mate 1") != null);
}

test "worker can search with nnue backend enabled" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.initWithOptions(output.sink(), tt.DEFAULT_HASH_MB, .{});
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    try worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 2 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nodes 0") == null);
}

const PoolFixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    other_path: []u8,

    fn init() !PoolFixture {
        const a = std.testing.allocator;
        const blob = try @import("../eval/nnue768.zig").buildZqb9TestBlob(a);
        defer a.free(blob);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "first.zqb", .data = blob });
        // Change the network scale in a second valid net, so the evaluation
        // changes without depending on an arbitrary move's feature activity.
        std.mem.writeInt(i32, blob[36..40], 200, .little);
        try tmp.dir.writeFile(.{ .sub_path = "second.zqb", .data = blob });
        const path = try tmp.dir.realpathAlloc(a, "first.zqb");
        errdefer a.free(path);
        const other = try tmp.dir.realpathAlloc(a, "second.zqb");
        return .{ .tmp = tmp, .path = path, .other_path = other };
    }

    fn deinit(self: *PoolFixture) void {
        std.testing.allocator.free(self.other_path);
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn poolConstructionFailureProbe(a: std.mem.Allocator, path: []const u8) !void {
    var output = TestOutput{};
    var pool = try Pool.initWithAllocator(a, output.sink(), 1, .{ .eval_file_path = path });
    defer pool.deinit();
    try std.testing.expect(pool.network_owner.owned_net != null);
    try std.testing.expect(pool.coordinator.engine.evaluator.owned_net == null);
    try std.testing.expectEqual(pool.network_owner.net, pool.coordinator.engine.evaluator.net);
}

test "pool construction unwinds every allocation failure" {
    var fixture = try PoolFixture.init();
    defer fixture.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, poolConstructionFailureProbe, .{fixture.path});
}

test "pool startup failure retains ownership and permits retry" {
    var fixture = try PoolFixture.init();
    defer fixture.deinit();
    var output = TestOutput{};
    var pool = try Pool.initWithAllocator(std.testing.allocator, output.sink(), 1, .{ .eval_file_path = fixture.path });
    defer pool.deinit();
    const original = pool.network_owner.net;
    const FailingSpawner = struct {
        fn spawn(_: @This(), _: *runtime.Owner, _: *Pool) !runtime.Thread {
            return error.InjectedSpawnFailure;
        }
    };
    try std.testing.expectError(error.InjectedSpawnFailure, pool.startWithSpawner(FailingSpawner{}));
    try std.testing.expect(pool.thread == null and !pool.shutdown);
    try std.testing.expectEqual(@as(usize, 0), pool.runtime_owner.live_threads);
    try std.testing.expectEqual(original, pool.coordinator.engine.evaluator.net);
    try pool.start();
    try std.testing.expectEqual(@as(usize, 1), pool.runtime_owner.live_threads);
}

test "pool network replacement is transactional at every allocation and clears old evaluation state" {
    var fixture = try PoolFixture.init();
    defer fixture.deinit();
    var succeeded = false;
    for (0..128) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var output = TestOutput{};
        var pool = try Pool.initWithAllocator(failing.allocator(), output.sink(), 1, .{ .eval_file_path = fixture.path });
        defer pool.deinit();
        pool.setNnueScalePercent(eval_backend.builtin_nnue_scale_percent);
        const original = pool.network_owner.net;
        const original_path = pool.network_owner.net_path;
        const engine = &pool.coordinator.engine;
        engine.tt.entries[0].entries[0].key = 17;
        engine.rfp_hint.entries[0].entries[0].key = 19;
        engine.eval_cache.entries[0].key = 23;
        engine.history.quiet[0][0][0][0] = 43;
        const pos = try @import("../core/fen.zig").startpos();
        engine.evaluator.prepareRoot(&engine.ctx.stack, &pos, &engine.ctx.finny, &engine.ctx.ft);
        failing.fail_index = failing.alloc_index + fail_offset;
        pool.loadNnueFile(fixture.other_path) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(original, pool.network_owner.net);
            try std.testing.expectEqual(original, engine.evaluator.net);
            try std.testing.expectEqual(original_path, pool.network_owner.net_path);
            try std.testing.expectEqual(@as(u64, 1), pool.network_epoch);
            try std.testing.expectEqual(@as(u64, 17), engine.tt.entries[0].entries[0].key);
            try std.testing.expectEqual(@as(u64, 19), engine.rfp_hint.entries[0].entries[0].key);
            try std.testing.expectEqual(@as(u64, 23), engine.eval_cache.entries[0].key);
            try std.testing.expectEqual(@as(i16, 43), engine.history.quiet[0][0][0][0]);
            continue;
        };
        succeeded = true;
        try std.testing.expect(pool.network_owner.net != original);
        try std.testing.expectEqual(pool.network_owner.net, engine.evaluator.net);
        try std.testing.expect(engine.evaluator.owned_net == null and engine.evaluator.net_path == null);
        try std.testing.expectEqualStrings(fixture.other_path, pool.network_owner.evalFilePath());
        try std.testing.expectEqual(@as(u64, 2), pool.network_epoch);
        try std.testing.expectEqual(eval_backend.builtin_nnue_scale_percent, engine.evaluator.nnue_scale_percent);
        try std.testing.expect(engine.evaluator.scale_explicit and pool.network_owner.scale_explicit);
        try std.testing.expectEqual(@as(u64, 0), engine.tt.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 0), engine.rfp_hint.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 0), engine.eval_cache.entries[0].key);
        try std.testing.expectEqual(@as(i16, 0), engine.history.quiet[0][0][0][0]);
        // The first post-reload search must refresh accumulators as well as
        // cleared tables. Compare it to a freshly constructed replacement.
        var reference = try engine_mod.Engine.initWithOptions(std.testing.allocator, 1, .{ .eval_file_path = fixture.other_path });
        defer reference.deinit();
        reference.setNnueScalePercent(eval_backend.builtin_nnue_scale_percent);
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        var stop = std.atomic.Value(bool).init(false);
        const actual = engine.search(&pos, &history, .{ .depth = 3 }, &stop);
        const expected = reference.search(&pos, &history, .{ .depth = 3 }, &stop);
        try std.testing.expectEqual(expected.best_move, actual.best_move);
        try std.testing.expectEqual(expected.score, actual.score);
        try std.testing.expectEqual(expected.nodes, actual.nodes);
        break;
    }
    try std.testing.expect(succeeded);
}

test "pool publishes independent job values and rejects exhausted identities" {
    var fixture = try PoolFixture.init();
    defer fixture.deinit();
    var output = TestOutput{};
    var pool = try Pool.initWithAllocator(std.testing.allocator, output.sink(), 1, .{ .eval_file_path = fixture.path });
    try pool.setThreads(4);
    var released = runtime.ResetEvent{};
    // Hold only the test's entry point, before the production worker reads a
    // job, so mutation-after-publication is deterministic rather than a race.
    const HeldSpawner = struct {
        gate: *runtime.ResetEvent,
        fn enter(p: *Pool, gate: *runtime.ResetEvent) void {
            gate.wait();
            Pool.threadMain(p);
        }
        fn spawn(self: @This(), owner: *runtime.Owner, p: *Pool) !runtime.Thread {
            return owner.spawn(.{}, enter, .{ p, self.gate });
        }
    };
    defer {
        released.set();
        pool.deinit();
    }
    try pool.startWithSpawner(HeldSpawner{ .gate = &released });
    const pos = try @import("../core/fen.zig").startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var moves = move_mod.MoveList.init();
    moves.add(move_mod.Move.init(.e2, .e4, .double_push));
    var request = SearchRequest{ .position = pos, .history = history, .limits = .{ .depth = 2 }, .root_moves = moves };
    try pool.startSearch(request);
    request.position = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 100 1");
    request.history.clear();
    request.limits = .{ .infinite = true };
    request.root_moves.?.count = 0;
    pool.mutex.lock();
    const published = pool.pending_request.?;
    pool.mutex.unlock();
    try std.testing.expectEqual(pos.zobrist_key, published.request.position.zobrist_key);
    try std.testing.expectEqual(@as(usize, 1), published.request.history.count);
    try std.testing.expectEqual(@as(?u16, 2), published.request.limits.depth);
    try std.testing.expectEqual(@as(usize, 1), published.request.root_moves.?.count);
    released.set();
    try output.waitFor("bestmove e2e4", 5 * std.time.ns_per_s);
    pool.waitIdle();
    try std.testing.expectEqual(@as(u64, 1), pool.last_completed_id);
    pool.last_started_id = std.math.maxInt(u64) - 1;
    try pool.startSearch(.{ .position = request.position, .history = .{}, .limits = .{ .depth = 1 } });
    pool.waitIdle();
    try std.testing.expectEqual(std.math.maxInt(u64), pool.last_completed_id);
    const before = pool.network_owner.net;
    try std.testing.expectError(error.JobIdentifierExhausted, pool.startSearch(request));
    try std.testing.expect(pool.pending_request == null and !pool.searching);
    pool.network_epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.NetworkEpochExhausted, pool.loadNnueFile(fixture.other_path));
    try std.testing.expectEqual(before, pool.network_owner.net);
    try std.testing.expectEqual(std.math.maxInt(u64), pool.network_epoch);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.contents(), "bestmove "));
}

test "parallel reconfiguration is transactional at each allocation and detaches every net borrower" {
    var fixture = try PoolFixture.init();
    defer fixture.deinit();
    for ([_]u8{ 1, 4 }) |initial_threads| {
        var succeeded = false;
        for (0..64) |fail_offset| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var output = TestOutput{};
            var pool = try Pool.initWithAllocator(failing.allocator(), output.sink(), 1, .{ .eval_file_path = fixture.path });
            defer pool.deinit();
            try pool.setThreads(initial_threads);
            const old_pool = pool.parallel;
            const old_context = pool.coordinator.engine.ctx;
            const old_epoch = pool.config_epoch;
            const old_net = pool.network_owner.net;
            failing.fail_index = failing.alloc_index + fail_offset;
            pool.setThreads(2) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(initial_threads, pool.threads());
                try std.testing.expectEqual(old_pool, pool.parallel);
                try std.testing.expectEqual(old_context, pool.coordinator.engine.ctx);
                try std.testing.expectEqual(old_epoch, pool.config_epoch);
                try std.testing.expectEqual(old_net, pool.network_owner.net);
                continue;
            };
            succeeded = true;
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(@as(u8, 2), pool.threads());
            try std.testing.expectEqual(@as(usize, 0), pool.coordinator.engine.tt.entries.len);
            for (pool.parallel.?.helpers) |*slot| {
                try std.testing.expectEqual(@as(usize, 0), slot.engine.tt.entries.len);
                try std.testing.expectEqual(old_net, slot.engine.evaluator.net);
            }
            try pool.loadNnueFile(fixture.other_path);
            pool.setNnueScalePercent(53);
            pool.setContempt(17);
            for (pool.parallel.?.helpers) |*slot| {
                try std.testing.expectEqual(pool.network_owner.net, slot.engine.evaluator.net);
                try std.testing.expect(slot.engine.evaluator.owned_net == null);
                try std.testing.expectEqual(@as(u16, 53), slot.engine.evaluator.nnue_scale_percent);
                try std.testing.expectEqual(@as(i32, 17), slot.engine.contempt_cp);
            }
            try pool.resizeHash(2);
            try std.testing.expectEqual(@as(u32, 2), pool.hashSizeMb());
            try pool.setThreads(1);
            try std.testing.expect(pool.parallel == null and pool.coordinator.engine.tt.entries.len > 0);
            break;
        }
        try std.testing.expect(succeeded);
    }
}
