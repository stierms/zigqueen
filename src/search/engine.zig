const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const build_options = @import("build_options");
const types = @import("../core/types.zig");
const context_mod = @import("context.zig");
const eval_backend = @import("../eval/backend.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const pv = @import("pv.zig");
const repetition = @import("repetition.zig");
const rfp_hint_mod = @import("rfp_hint.zig");
const rule50 = @import("rule50.zig");
const eval_cache_mod = @import("eval_cache.zig");
const hugealloc = @import("../util/hugealloc.zig");
const root = @import("root.zig");
const qsearch = @import("qsearch.zig");
const score_mod = @import("score.zig");
const search_info = @import("search_info.zig");
const syzygy = @import("syzygy.zig");
const stats = @import("stats.zig");
const time = @import("time.zig");
const tt = @import("tt.zig");
const history_mod = @import("history.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const basin = @import("basin.zig");

pub const MAX_TRACE: usize = 64;
const ASPIRATION_MIN_DEPTH: u16 = 3;
const ASPIRATION_START_CP: i32 = if (basin.ENABLED) basin.ASPIRATION_INITIAL_CP else 30;
/// The reviewed mate regressions became visible at depths 11, 12, and 13.
/// Require all of depth 13 to complete before a stable TB decision may stop
/// iterative deepening, leaving that short-mate horizon available.
const TB_DECISION_MIN_COMPLETED_DEPTH: u16 = 13;

pub const IterationStopReason = enum {
    maximum_elapsed,
    maximum_projected,
    optimum_elapsed,
    optimum_projected,
};

pub const IterationTrace = struct {
    depth: u16 = 0,
    seldepth: u16 = 0,
    score: i32 = 0,
    nodes: u64 = 0,
    best_move: ?move_mod.Move = null,
    pv: pv.Line = .{},
    root_order: root.RootOrderTrace = .{},
};

pub const SearchDiagnostics = struct {
    trace: [MAX_TRACE]IterationTrace = [_]IterationTrace{.{}} ** MAX_TRACE,
    trace_len: usize = 0,
    stats: stats.SearchStats = .{},
    last_iteration_elapsed_ns: u64 = 0,
    projected_next_iteration_ns: u64 = 0,
    stable_iteration_streak: u8 = 0,
    iteration_stop_reason: ?IterationStopReason = null,
    /// Last combined three-signal soft-limit factor (percent, 100 = neutral).
    /// Stays 100 unless a ZQ_TM_NF/BM/SC signal is enabled.
    soft_scale_pct: u32 = 100,
    /// Completed search scores contradicted a clock-aware root TB outcome.
    /// The legal root set remains protected; published scores use that oracle.
    /// Compiled out with other search diagnostics; preserves the production ABI.
    root_tb_conflicts: if (build_options.search_stats) u32 else void = if (build_options.search_stats) 0 else {},
    /// TM v2 C1: an interrupted iteration supplied the played move (a
    /// challenger proven against the previous iteration's best move).
    interrupted_challenger: bool = false,
};

pub const SearchResult = struct {
    best_move: ?move_mod.Move = null,
    score: i32 = 0,
    /// `.lower` when the result comes from an interrupted iteration: the root
    /// value is at least `score` at `depth`, other moves were not all searched.
    score_bound: search_info.ScoreBound = .exact,
    depth: u16 = 0,
    seldepth: u16 = 0,
    nodes: u64 = 0,
    pv: pv.Line = .{},
    diagnostics: SearchDiagnostics = .{},
};

pub const EvalOptions = eval_backend.Options;
/// Re-exported so the CLI fallback (main.zig) shares the one source of truth.
pub const default_nnue_scale_percent = eval_backend.builtin_nnue_scale_percent;
/// Shared-net plumbing (datagen --threads): the net type and the loader for
/// the ONE shared copy, re-exported so tools only need this module. Pair with
/// `Engine.initWithSharedNet`; free with `net.destroy(allocator)` last.
pub const Net = eval_backend.Net;
pub const loadDefaultNet = eval_backend.loadDefaultNet;

pub const Engine = struct {
    tt: tt.TranspositionTable,
    rfp_hint: rfp_hint_mod.HintTable,
    /// Raw-eval memo (perf-r11): position-keyed cache of the exact raw static
    /// eval, sized off Hash (Hash/4, clamped [4,64] MB; 2-way since perf-r12;
    /// split across engines at Threads > 1, see PrivateTableSizes).
    /// No UCI option.
    eval_cache: eval_cache_mod.EvalCache,
    history: history_mod.HistoryTable = .{},
    evaluator: eval_backend.EngineState,
    /// Runtime basin state exists only in the tuning flavour.
    basin_config: if (build_options.tuning) basin.Config else void,
    allocator: std.mem.Allocator = undefined,
    /// Heap-owned search context. The per-ply accumulator stack is ~1 MB at the
    /// 1024-wide net, too large for the call stack (overflows smaller worker /
    /// test threads), so it lives on the heap and is reset per search.
    ctx: *context_mod.SearchContext = undefined,
    /// How `ctx` is backed. The context is ~1.8 MB since the combined
    /// accumulator (128 plies of stack entries, each spanning several 4 KB
    /// pages), touched at random plies by every accumulator materialization;
    /// hugealloc maps it on one whole 2 MB page where the OS grants it (below
    /// 2 MB the plain ladder would leave it on 4 KB heap pages). Frees go
    /// through hugealloc with this.
    ctx_method: hugealloc.Method = .heap,
    record_static_search_outcomes: bool = false,
    record_move_order_outcomes: bool = false,
    /// Draw contempt in engine cp (UCI "Contempt"), forwarded into the search
    /// context each search. 0 = off (bit-identical to pre-contempt play).
    contempt_cp: types.Score = 0,
    /// Optional UCI info sink, forwarded into the search context each search.
    /// Null unless the UCI worker installs one (tools/tests stay silent).
    info_emitter: ?search_info.InfoEmitter = null,

    pub fn init(allocator: std.mem.Allocator, hash_mb: u32) !Engine {
        return initWithOptions(allocator, hash_mb, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, hash_mb: u32, eval_options: EvalOptions) !Engine {
        var evaluator = try eval_backend.EngineState.init(allocator, eval_options);
        errdefer evaluator.deinit();
        return initWithEvaluator(allocator, hash_mb, &evaluator);
    }

    /// Per-thread search state around a SHARED read-only net (datagen
    /// --threads): TT/hint/eval-cache/history/context are private per engine,
    /// only the weight blob is borrowed. The caller owns `net`, must keep it
    /// alive for this engine's lifetime, and frees it after deinit.
    pub fn initWithSharedNet(allocator: std.mem.Allocator, hash_mb: u32, net: *const eval_backend.Net) !Engine {
        var evaluator = eval_backend.EngineState.initBorrowedNet(allocator, net, .{});
        errdefer evaluator.deinit();
        return initWithEvaluator(allocator, hash_mb, &evaluator);
    }

    /// The process/pool owns the loaded network; worker scale selection is
    /// copied exactly, without re-running family-default scale adoption.
    pub fn initWithBorrowedEvaluator(allocator: std.mem.Allocator, hash_mb: u32, owner: *const eval_backend.EngineState) !Engine {
        var evaluator = owner.borrow(allocator);
        errdefer evaluator.deinit();
        return initWithEvaluator(allocator, hash_mb, &evaluator);
    }

    /// Takes ownership of `evaluator` (moved into the returned engine); on
    /// error the caller's errdefer still owns it.
    fn initWithEvaluator(allocator: std.mem.Allocator, hash_mb: u32, evaluator: *eval_backend.EngineState) !Engine {
        return initWithTables(allocator, hash_mb, PrivateTableSizes.forThreads(hash_mb, 1), evaluator, true);
    }

    /// A parallel worker has private search/caches but no private serial TT.
    /// `threads` is the whole configuration (coordinator plus helpers): every
    /// engine of it receives the same 1/threads share of the private-table
    /// budget, so the shared TT plus all private tables stay near Hash.
    pub fn initForParallel(allocator: std.mem.Allocator, hash_mb: u32, threads: u32, owner: *const eval_backend.EngineState) !Engine {
        var evaluator = owner.borrow(allocator);
        errdefer evaluator.deinit();
        return initWithTables(allocator, hash_mb, PrivateTableSizes.forThreads(hash_mb, threads), &evaluator, false);
    }

    fn initWithTables(allocator: std.mem.Allocator, hash_mb: u32, sizes: PrivateTableSizes, evaluator: *eval_backend.EngineState, comptime serial_table: bool) !Engine {
        @import("startup.zig").ensure();
        var tt_table = if (serial_table) try tt.TranspositionTable.init(allocator, hash_mb) else tt.TranspositionTable{ .allocator = allocator };
        errdefer tt_table.deinit();
        var hint_table = try rfp_hint_mod.HintTable.init(allocator, sizes.hint_mb);
        errdefer hint_table.deinit();
        var eval_cache = try eval_cache_mod.EvalCache.init(allocator, sizes.eval_mb);
        errdefer eval_cache.deinit();
        var history = history_mod.HistoryTable{};
        try history.initContinuation(allocator);
        errdefer history.deinitContinuation(allocator);
        // Correction history, A3 form (history.zig): learned only from exact
        // search scores, applied to the main search's eval-gated decisions. The
        // earlier forms (parked 2026-06; C15 field form -12.7 +/-7.0, 2026-08)
        // learned from window-pinned bounds; see the A3 diagnosis.
        if (comptime build_options.correction_history) try history.initCorrection(allocator);
        errdefer if (comptime build_options.correction_history) history.deinitCorrection(allocator);
        const ctx_backed = try hugealloc.allocWholePages(context_mod.SearchContext, allocator, 1);
        errdefer hugealloc.free(context_mod.SearchContext, allocator, ctx_backed);
        const ctx = &ctx_backed.items[0];
        return .{
            .tt = tt_table,
            .rfp_hint = hint_table,
            .eval_cache = eval_cache,
            .history = history,
            .evaluator = evaluator.*,
            .basin_config = if (build_options.tuning) basin.Config.init(.{}) else {},
            .allocator = allocator,
            .ctx = ctx,
            .ctx_method = ctx_backed.method,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.evaluator.deinit();
        self.tt.deinit();
        self.rfp_hint.deinit();
        self.eval_cache.deinit();
        self.history.deinitContinuation(self.allocator);
        self.history.deinitCorrection(self.allocator);
        const ctx_items: []context_mod.SearchContext = @as([*]context_mod.SearchContext, @ptrCast(self.ctx))[0..1];
        hugealloc.free(context_mod.SearchContext, self.allocator, .{ .items = ctx_items, .method = self.ctx_method });
    }

    pub fn reset(self: *Engine) void {
        self.tt.clear();
        self.rfp_hint.clear();
        self.eval_cache.clear();
        self.history.clear();
    }

    pub fn setNnueScalePercent(self: *Engine, nnue_scale_percent: u16) void {
        self.evaluator.setNnueScalePercent(nnue_scale_percent);
        self.reset();
    }

    /// Caller has stopped every search (no Job is live), so the replaced
    /// tables are freed here, on the caller's thread.
    pub fn setSyzygyPath(self: *Engine, path: []const u8) bool {
        // TB availability changes what searches return -> cached scores stale.
        self.reset();
        if (path.len == 0) {
            syzygy.disable();
            return true;
        }
        return syzygy.init(path);
    }

    pub fn setContempt(self: *Engine, contempt_cp: types.Score) void {
        self.contempt_cp = contempt_cp;
        // Contempt shifts draw scores, so cached TT scores from the old setting
        // would be inconsistent with the new search.
        self.reset();
    }

    pub fn setBasinParams(self: *Engine, params: basin.Params) void {
        if (comptime build_options.tuning) {
            if (self.basin_config.applyParams(params)) self.reset();
        }
    }

    pub fn loadNnueFile(self: *Engine, path: []const u8) !void {
        try self.evaluator.loadModelFile(path);
        self.reset();
    }

    pub fn resizeHash(self: *Engine, hash_mb: u32) !void {
        var factory = HashTableFactory{};
        try self.resizeHashWithFactory(hash_mb, &factory);
    }

    /// Quiescent configuration transaction: every fallible preparation finishes
    /// before any live table or history changes. The pool/worker owns the idle
    /// barrier; this method neither stops a search nor publishes to live readers.
    /// Serial (Threads = 1) engines only: a parallel configuration is rebuilt
    /// whole by the UCI worker, with its per-thread table shares.
    fn resizeHashWithFactory(self: *Engine, hash_mb: u32, factory: anytype) !void {
        const sizes = PrivateTableSizes.forThreads(hash_mb, 1);
        const hint_mb = sizes.hint_mb;
        const eval_mb = sizes.eval_mb;
        if (hash_mb == self.tt.hashSizeMb() and
            hint_mb == self.rfp_hint.hintSizeMb() and
            eval_mb == self.eval_cache.cacheSizeMb())
        {
            self.reset();
            return;
        }

        var new_tt = try factory.create(tt.TranspositionTable, self.tt.allocator, hash_mb);
        errdefer new_tt.deinit();
        var new_hint = try factory.create(rfp_hint_mod.HintTable, self.rfp_hint.allocator, hint_mb);
        errdefer new_hint.deinit();
        const new_eval = try factory.create(eval_cache_mod.EvalCache, self.eval_cache.allocator, eval_mb);

        self.tt.deinit();
        self.rfp_hint.deinit();
        self.eval_cache.deinit();
        self.tt = new_tt;
        self.rfp_hint = new_hint;
        self.eval_cache = new_eval;
        self.history.clear();
    }

    pub fn hashSizeMb(self: *const Engine) u32 {
        return self.tt.hashSizeMb();
    }

    pub fn hashfullPermille(self: *const Engine) u16 {
        return self.tt.hashfullPermille();
    }

    pub fn search(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
    ) SearchResult {
        return self.searchWithRootMoves(pos, root_history, limits, stop_flag, null);
    }

    pub fn searchWithRootMoves(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
        root_moves: ?*const move_mod.MoveList,
    ) SearchResult {
        self.tt.newSearch();
        return self.searchWithTable(pos, root_history, limits, stop_flag, root_moves, &self.tt, null);
    }

    /// Single-worker shared-TT integration entry. The caller owns the table's
    /// idle/job transitions and holds this view through return. This entry still
    /// acquires its own TB lease and clock: it must NOT be used as a helper API.
    /// The P2 pool will supply the shared job/clock/node policy separately.
    pub fn searchWithSharedTable(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
        root_moves: ?*const move_mod.MoveList,
        table: *@import("shared_tt.zig").View,
    ) SearchResult {
        return self.searchWithTable(pos, root_history, limits, stop_flag, root_moves, table, null);
    }

    pub fn searchParallel(self: *Engine, comptime coordinator: bool, execution: *@import("shared_job.zig").Execution(coordinator)) SearchResult {
        const job = execution.job;
        const root_moves = if (job.root_moves) |*moves| moves else null;
        return self.searchWithTable(&job.position, &job.history, job.limits, job.control.external_stop, root_moves, &job.table, execution);
    }

    fn searchWithTable(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
        root_moves: ?*const move_mod.MoveList,
        table: anytype,
        execution: anytype,
    ) SearchResult {
        const parallel = @TypeOf(execution) != @TypeOf(null);
        const helper = if (parallel) @TypeOf(execution.*).is_helper else false;
        var working = pos.*;
        // Reset the heap-owned context (also zeroes the ~1MB accumulator stack),
        // matching the prior fresh-`.{}` behaviour exactly.
        const ctx = self.ctx;
        ctx.* = context_mod.SearchContext{
            .repetition = root_history.*,
            .control = if (helper) time.Controller{ .stop_flag = stop_flag, .limits = limits } else time.Controller.init(stop_flag, limits),
            .record_static_search_outcomes = self.record_static_search_outcomes,
            .record_move_order_outcomes = self.record_move_order_outcomes,
        };
        if (comptime parallel) {
            // Node limits are shared credits; helpers never own a clock.
            ctx.control.limits.node_limit = null;
            ctx.control.timer = if (helper) null else execution.job.timer;
            if (comptime helper) {
                ctx.control.limits.maximum_budget_ns = null;
                ctx.control.limits.optimum_budget_ns = null;
                ctx.control.limits.wider_maximum_budget_ns = null;
                ctx.control.limits.infinite = false;
            }
        }
        ctx.info_emitter = if (helper) null else self.info_emitter;
        ctx.contempt = self.contempt_cp;
        if (comptime build_options.tuning) ctx.basin_config = &self.basin_config;
        ctx.root_color = working.side_to_move;
        if (ctx.repetition.count == 0) ctx.repetition.push(working.zobrist_key);
        self.evaluator.prepareRoot(&ctx.stack, &working, &ctx.finny, &ctx.ft);

        var fallback = fallbackMove(&working, ctx.repetition.isRepetition(working.halfmove_clock), ctx.repetition.currentPreviousCycleChildKey(working.halfmove_clock), root_moves);
        var best = SearchResult{ .best_move = fallback };

        if (working.halfmove_clock >= 100 or ctx.repetition.isClaimableCurrentRepetition(working.halfmove_clock)) {
            best.score = 0;
            // Checkmate outranks the fifty-move claim: a mated root is lost,
            // and a mating move still wins where every other move draws.
            if (working.halfmove_clock >= 100) {
                if (fallback == null) {
                    if (legal.isInCheck(&working, working.side_to_move)) best.score = -score_mod.MATE_SCORE;
                } else if (rule50.matingMove(&working, root_moves)) |mv| {
                    best.best_move = mv;
                    best.score = score_mod.MATE_SCORE - 1;
                    best.pv.push(mv);
                }
            }
            return best;
        }

        if (comptime parallel) {
            if (limits.node_limit == 0 or fallback == null or execution.job.control.stopping()) {
                if (fallback == null and legal.isInCheck(&working, working.side_to_move)) best.score = -score_mod.MATE_SCORE;
                return best;
            }
        }
        var local_tablebase_job: ?syzygy.Job = if (parallel) null else syzygy.beginJob();
        defer if (local_tablebase_job) |*local| local.deinit();
        const tablebase_job = if (parallel) execution.job.tablebases else &local_tablebase_job.?;
        ctx.tablebases = if (tablebase_job.enabled()) tablebase_job else null;
        defer ctx.tablebases = null;

        // Establish a clock-aware result-preserving root set once, before
        // helper publication. Search keeps practical choices inside that set.
        // Helpers borrow the coordinator's copied policy and never root-probe.
        var root_policy: ?syzygy.RootPolicy = if (helper or limits.node_limit == 0 or fallback == null or stop_flag.load(.acquire))
            null
        else
            tablebase_job.probeRootMoves(&working, root_moves, &ctx.repetition);
        const safe_root_moves = if (root_policy) |*p| &p.moves else root_moves;
        // Only a proven outcome replaces searched scores (here, in the
        // fallback, interrupted results, info lines and helpers); a ranked
        // but unproven win leaves the score to the search (U-TB-DTZ100).
        const root_wdl = if (root_policy) |*p| p.authoritativeWdl() else if (helper) execution.job.root_wdl else null;
        if (root_policy) |*p| {
            fallback = fallbackMove(&working, ctx.repetition.isRepetition(working.halfmove_clock), ctx.repetition.currentPreviousCycleChildKey(working.halfmove_clock), &p.moves);
            best.best_move = fallback;
            if (root_wdl) |wdl| best.score = syzygy.wdlScore(wdl, 0);
            // A certain, non-repeating win is played at once; any other TB
            // root is searched inside its outcome-preserving move set.
            if (p.instant) |mv| {
                if (comptime parallel) {
                    if (!execution.job.control.count(true, execution.account)) return best;
                    ctx.nodes = 1;
                }
                best.best_move = mv;
                best.score = syzygy.TB_WIN_SCORE - @as(types.Score, @intCast(@min(p.dtz, 1000)));
                best.depth = 1;
                best.seldepth = 1;
                best.nodes = 1;
                best.pv.push(mv);
                best.diagnostics.stats = ctx.stats;
                return best;
            }
        }

        if (comptime parallel and !helper) {
            if (execution.ready) |ready| ready.call(ready.ctx, if (root_policy) |*p| p else null);
        }
        const resources = if (parallel) .{
            .tt = table,
            .rfp_hint = &self.rfp_hint,
            .eval_cache = &self.eval_cache,
            .history = &self.history,
            .evaluator = &self.evaluator,
            .execution = execution,
        } else context_mod.ResourcesFor(@TypeOf(table)){
            .tt = table,
            .rfp_hint = &self.rfp_hint,
            .eval_cache = &self.eval_cache,
            .history = &self.history,
            .evaluator = &self.evaluator,
        };
        const max_depth = limits.depth orelse 64;
        var previous_trace: ?IterationTrace = null;
        var previous_root_hints: ?root.RootMoveHints = null;
        var stable_iteration_streak: u8 = 0;
        var tb_decision_streak: u8 = 0;
        // TM arc r1: three-signal soft-limit scaling (all default OFF; the
        // policy then reduces to the legacy stop test bit-for-bit).
        const tm_cfg = time.tmConfig();
        const tm_signals_enabled = tm_cfg.signalsEnabled();
        var best_move_streak: u32 = 0;
        // TM v2: a forced root move gets a fraction of the soft target.
        // C3 (graded urgency) keeps the plan's target T for every other root.
        var c3_target_ns: ?u64 = null;
        var c3_capped = false;
        if (!helper and ctx.control.softMode()) {
            if (rootMoveCount(&working, safe_root_moves) == 1) {
                ctx.control.scaleSoftTarget(tm_cfg.v2_forced_pct);
            } else if (tm_cfg.v2_c3) {
                c3_target_ns = ctx.control.limits.optimum_budget_ns;
                // Low-clock guard, decided with the plan (time.c3LowClock).
                c3_capped = ctx.control.limits.soft == .low_clock;
            }
        }
        if (!helper and tm_cfg.trace) traceSearchStart(ctx);
        // Only stop/quit and node limits may interrupt depth 1; the clock waits
        // for its completion, up to the hold's node budget
        // (time.Controller.holdClockUntilFirstIteration).
        ctx.control.holdClockUntilFirstIteration();
        var depth: u16 = 1;
        search_loop: while (depth <= max_depth) : (depth += 1) {
            if (comptime parallel) {
                if (execution.job.control.stopping()) break;
            }
            if (ctx.control.stopReasonNow(ctx.nodes)) |reason| {
                ctx.noteHardStop(reason);
                break;
            }

            const guess = aspirationGuess(previous_trace, depth);
            var delta: i32 = ASPIRATION_START_CP;
            var alpha = initialAspirationAlpha(guess, delta);
            var beta = initialAspirationBeta(guess, delta);
            var iteration = root.IterationResult{ .depth = depth };
            var iteration_elapsed_ns: i128 = std.time.ns_per_ms;

            // Retain the last genuinely searched iteration as the result. Once
            // its finite-search decision is eligible for reuse, end ID cleanly
            // instead of fabricating deeper iterations with frozen counters.
            if (shouldStopOnTablebaseDecision(ctx.control.limits, tb_decision_streak, previous_trace)) break;

            // TM v2 C1 (anytime root): the incumbent is the last completed
            // iteration's move. Each aspiration pass that finished it and kept a
            // real score gives a verdict; an interruption plays the latest
            // proven challenger instead of discarding the whole depth.
            const incumbent: ?move_mod.Move = if (previous_trace != null) best.best_move else null;
            var depth_challenger: ?ProvenChallenger = null;

            while (true) {
                const reused_root_hints = if (previous_root_hints) |*hints| hints else null;
                var iteration_timer: ?runtime.Timer = if (helper) null else runtime.Timer.start() catch null;
                const pass_alpha = alpha;
                iteration = root.searchDepthWindow(
                    ctx,
                    resources,
                    &working,
                    depth,
                    alpha,
                    beta,
                    reused_root_hints,
                    safe_root_moves,
                    incumbent,
                );
                iteration_elapsed_ns = if (iteration_timer) |*timer|
                    @max(@as(i128, std.time.ns_per_ms), @as(i128, @intCast(timer.read())))
                else
                    std.time.ns_per_ms;
                switch (passVerdict(incumbent, pass_alpha, &iteration)) {
                    .none => {},
                    .incumbent => depth_challenger = null,
                    .challenger => depth_challenger = .{ .move = iteration.best_move.?, .score = iteration.score },
                }
                if (ctx.stopped) {
                    if (!helper) {
                        if (depth_challenger) |challenger| adoptInterruptedChallenger(ctx, &working, table, &best, challenger, depth, root_wdl);
                    }
                    break :search_loop;
                }
                if (!shouldResearchAspiration(guess, alpha, beta, iteration.score)) break;
                if (iteration.score <= alpha) {
                    ctx.noteAspirationFailLow();
                } else {
                    ctx.noteAspirationFailHigh();
                }
                // Only a direction-matching decisive bound proves the WDL:
                // fail-low can prove a loss, and fail-high can prove a win.
                // For oracle-covered roots, resolve aspiration bounds normally.
                // A search-derived decisive bound is not an independent proof.
                if (root_wdl == null and isTablebaseWdlProof(alpha, beta, iteration.score)) break;
                // A partial selective-search bound does not supersede the
                // authoritative root outcome. Keep it internal; completed
                // iteration output below reports the independently known WDL.
                if (if (root_wdl == null) ctx.info_emitter else null) |emitter| {
                    emitter.emit(.{ .iteration = .{
                        .depth = depth,
                        .seldepth = ctx.seldepth,
                        .score = iteration.score,
                        .bound = if (iteration.score <= alpha) .upper else .lower,
                        .nodes = ctx.nodes,
                        .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
                        .hashfull = table.hashfullPermille(),
                        .best_move = iteration.best_move,
                        .pv = &[_]move_mod.Move{},
                    } });
                }
                ctx.noteAspirationResearch();
                widenAspirationWindow(guess.?, &alpha, &beta, &delta, iteration.score);
            }

            // A completed iteration: the clock is live again (U-STOP-D1),
            // before any stop decision below.
            ctx.control.releaseClockHold();
            best.best_move = iteration.best_move orelse fallback;
            if (root_wdl) |wdl| {
                if (comptime build_options.search_stats) {
                    if (rootScoreContradicts(wdl, iteration.score)) best.diagnostics.root_tb_conflicts += 1;
                }
            }
            // This score is the known root outcome, not a promoted aspiration
            // bound. The search still chooses among outcome-preserving moves.
            best.score = if (root_wdl) |wdl| rootOutcomeScore(wdl, iteration.score) else iteration.score;
            best.depth = iteration.depth;
            best.seldepth = ctx.seldepth;
            best.nodes = ctx.nodes;
            pv.reconstructFromRootMoveLimited(&working, &ctx.repetition, table, best.best_move, &best.pv, pv.DEFAULT_ENGINE_PV_LIMIT);

            const current_trace = IterationTrace{
                .depth = iteration.depth,
                .seldepth = ctx.seldepth,
                .score = best.score,
                .nodes = ctx.nodes,
                .best_move = best.best_move,
                .pv = best.pv,
                .root_order = iteration.root_order,
            };

            if (best.diagnostics.trace_len < best.diagnostics.trace.len) {
                best.diagnostics.trace[best.diagnostics.trace_len] = current_trace;
                best.diagnostics.trace_len += 1;
            }
            tb_decision_streak = if (root_wdl == null) nextTablebaseDecisionStreak(tb_decision_streak, previous_trace, current_trace) else 0;
            stable_iteration_streak = nextStableIterationStreak(stable_iteration_streak, previous_trace, current_trace);
            best_move_streak = if (previous_trace) |prev|
                (if (prev.best_move == current_trace.best_move) best_move_streak + 1 else 1)
            else
                1;
            best.diagnostics.last_iteration_elapsed_ns = @intCast(@max(iteration_elapsed_ns, 0));
            best.diagnostics.projected_next_iteration_ns = @intCast(@max(estimateNextIterationNs(iteration_elapsed_ns), 0));
            best.diagnostics.stable_iteration_streak = stable_iteration_streak;

            // The wider hard deadline is evidence-gated: only this completed
            // trace can arm it for the next iteration. Stable traces restore
            // the legacy deadline before either the projection or next depth.
            ctx.control.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous_trace, current_trace));

            if (ctx.info_emitter) |emitter| {
                emitter.emit(.{ .iteration = .{
                    .depth = best.depth,
                    .seldepth = best.seldepth,
                    .score = best.score,
                    .bound = .exact,
                    .nodes = best.nodes,
                    .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
                    .hashfull = table.hashfullPermille(),
                    .best_move = best.best_move,
                    .pv = best.pv.slice(),
                } });
            }

            if (!helper and foundRequestedMate(ctx.control.limits, best.score)) break;

            var soft_policy = SoftLimitPolicy{};
            if (tm_signals_enabled) {
                soft_policy = .{
                    .scale_pct = time.signalScalePct(tm_cfg, .{
                        .best_move_node_permille = bestMoveNodePermille(&iteration.root_hints, current_trace.best_move),
                        .best_move_streak = best_move_streak,
                        .score_drop_cp = if (previous_trace) |prev| prev.score - current_trace.score else null,
                    }),
                    .ignore_best_move_gate = tm_cfg.bm,
                    .ignore_score_gate = tm_cfg.sc,
                };
                best.diagnostics.soft_scale_pct = soft_policy.scale_pct;
            }

            const iteration_stable = isStableIteration(previous_trace, current_trace);
            // TM v2 C3: every completed iteration arms the deadline of its
            // urgency class instead of step 2's stable-only arm.
            const urgency: ?u32 = if (c3_target_ns) |target|
                ctx.control.armUrgency(target, tm_cfg.v2_c3_k_pct, urgencyStreak(stable_iteration_streak), c3_capped)
            else
                null;
            const soft_armed = iteration_stable or urgency != null;
            if (!helper) ctx.control.setSoftArmed(soft_armed);
            if (!helper and tm_cfg.trace) traceIteration(ctx, current_trace, iteration_stable, bestMoveNodePermille(&iteration.root_hints, current_trace.best_move), urgency, c3_capped);

            // TM v2: no projection. A stable completed iteration arms the soft
            // deadline (it then also fires inside the next iteration); an
            // unstable one keeps searching until stable or the hard budget.
            const stop_reason: ?IterationStopReason = if (helper)
                null
            else if (ctx.control.softMode())
                softIterationStopReason(&ctx.control, soft_armed, ctx.control.elapsedNs())
            else
                iterationStopReasonWithPolicy(ctx.control.limits, previous_trace, current_trace, @as(i128, ctx.control.elapsedNs()), iteration_elapsed_ns, soft_policy);
            if (stop_reason) |reason| {
                best.diagnostics.iteration_stop_reason = reason;
                switch (reason) {
                    .maximum_elapsed => ctx.noteIterationStopMaximumElapsed(),
                    .maximum_projected => ctx.noteIterationStopMaximumProjected(),
                    .optimum_elapsed => ctx.noteIterationStopOptimumElapsed(),
                    .optimum_projected => ctx.noteIterationStopOptimumProjected(),
                }
                break;
            }
            previous_trace = current_trace;
            previous_root_hints = iteration.root_hints;
        }

        if (best.depth == 0) {
            best.seldepth = ctx.seldepth;
            best.nodes = ctx.nodes;
            if (best.best_move) |mv| best.pv.push(mv);
        }
        // TM v2 stops inside iterations by design: report the move's real
        // time and nodes (single-thread; the SMP worker writes its own final
        // line). An adopted challenger already emitted its line.
        if (comptime !parallel) {
            if (ctx.stopped and ctx.control.softMode() and best.depth > 0 and !best.diagnostics.interrupted_challenger) emitInterruptedFinal(ctx, table, &best);
        }
        if (!helper and tm_cfg.trace) traceSearchStop(ctx, &best, tm_cfg.v2);
        // Depth 64 is the engine's structural ID ceiling, not permission for
        // `go infinite` to emit bestmove. If it is ever reached, remain in the
        // search until the GUI sends `stop`.
        if (ctx.control.limits.infinite and !stop_flag.load(.acquire)) {
            while (!stop_flag.load(.acquire)) runtime.Thread.sleep(std.time.ns_per_ms);
        }
        best.diagnostics.stats = ctx.stats;
        return best;
    }
};

/// Cold-path construction seam; the generic caller also permits deterministic
/// stage failures in tests without changing the OS huge-page allocator.
const HashTableFactory = struct {
    fn create(_: *@This(), comptime Table: type, allocator: std.mem.Allocator, mb: u32) !Table {
        var table = Table{ .allocator = allocator };
        try table.resize(mb);
        return table;
    }
};

fn hintSizeFor(hash_mb: u32) u32 {
    const half = hash_mb / 2;
    if (half < rfp_hint_mod.MIN_HINT_MB) return rfp_hint_mod.MIN_HINT_MB;
    if (half > rfp_hint_mod.MAX_HINT_MB) return rfp_hint_mod.MAX_HINT_MB;
    return half;
}

/// Sizes of one engine's private, Hash-derived tables: the RFP-hint table and
/// the raw-eval cache. Both stay private per thread (the eval cache writes its
/// LRU bit on hits; hints carry thread-local search results), so with
/// Threads = N there are N copies. UCI Hash is the process budget: the
/// Threads = 1 sizes (hint Hash/2 in [1, 1024] MB, eval Hash/4 in [4, 64] MB)
/// are the budget of all private copies together, split N ways. Threads = 1 is
/// the identity. The per-table floors (1 MB hint, 4 MB eval) can exceed the
/// split budget by at most 5 MB per engine (e.g. eval at T32 >= Hash 256).
pub const PrivateTableSizes = struct {
    hint_mb: u32,
    eval_mb: u32,

    pub fn forThreads(hash_mb: u32, threads: u32) PrivateTableSizes {
        const ways = @max(threads, 1);
        return .{
            .hint_mb = @max(hintSizeFor(hash_mb) / ways, rfp_hint_mod.MIN_HINT_MB),
            .eval_mb = @max(eval_cache_mod.sizeForHash(hash_mb) / ways, eval_cache_mod.MIN_CACHE_MB),
        };
    }
};

fn aspirationGuess(previous: ?IterationTrace, depth: u16) ?i32 {
    const prior = previous orelse return null;
    if (depth < ASPIRATION_MIN_DEPTH) return null;
    if (score_mod.isMateLike(prior.score)) return null;
    return prior.score;
}

fn initialAspirationAlpha(guess: ?i32, delta: i32) i32 {
    const center = guess orelse return -qsearch.INF;
    return @max(-qsearch.INF, center - delta);
}

fn initialAspirationBeta(guess: ?i32, delta: i32) i32 {
    const center = guess orelse return qsearch.INF;
    return @min(qsearch.INF, center + delta);
}

fn shouldResearchAspiration(guess: ?i32, alpha: i32, beta: i32, score: i32) bool {
    _ = guess orelse return false;
    return score <= alpha or score >= beta;
}

fn rootScoreContradicts(wdl: syzygy.Wdl, score: i32) bool {
    if (!score_mod.isDecisive(score)) return false;
    return switch (wdl) {
        .draw => true,
        .win => score < 0,
        .loss => score > 0,
    };
}

fn rootOutcomeScore(wdl: syzygy.Wdl, searched: i32) i32 {
    return switch (wdl) {
        .draw => 0,
        .win => if (score_mod.isDecisive(searched) and searched > 0) searched else syzygy.TB_WIN_SCORE,
        .loss => if (score_mod.isDecisive(searched) and searched < 0) searched else -syzygy.TB_WIN_SCORE,
    };
}

fn isTablebaseWdlProof(alpha: i32, beta: i32, score: i32) bool {
    if (!score_mod.isTablebaseDecisive(score)) return false;
    return (score <= alpha and score <= -score_mod.TB_DECISIVE_THRESHOLD) or
        (score >= beta and score >= score_mod.TB_DECISIVE_THRESHOLD);
}

fn widenAspirationWindow(guess: i32, alpha: *i32, beta: *i32, delta: *i32, score: i32) void {
    delta.* = @min(qsearch.INF, delta.* * 2);
    // Fix 2026-09-29: once delta is capped, open the failing side fully. With the
    // bound pinned at guess -/+ INF, a previous score of +(1000+N) cp could never let
    // alpha reach a mated-in-N score (MATE_SCORE 29,000 < INF 30,000), so the fail-low
    // loop never ended; the mirror case failed high forever. Before the cap the window
    // is unchanged.
    const capped = delta.* >= qsearch.INF;
    if (score <= alpha.*) {
        alpha.* = if (capped) -qsearch.INF else @max(-qsearch.INF, guess - delta.*);
        return;
    }
    beta.* = if (capped) qsearch.INF else @min(qsearch.INF, guess + delta.*);
}

fn rootMoveAllowed(root_moves: ?*const move_mod.MoveList, mv: move_mod.Move) bool {
    const allowed = root_moves orelse return true;
    for (allowed.slice()) |candidate| {
        if (candidate == mv) return true;
    }
    return false;
}

fn fallbackMove(
    pos: *const position.Position,
    prefer_repetition_safe: bool,
    cycle_child_key: ?u64,
    root_moves: ?*const move_mod.MoveList,
) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    if (moves.count == 0) return null;

    if (cycle_child_key) |key| {
        for (moves.slice()) |mv| {
            if (!rootMoveAllowed(root_moves, mv)) continue;
            if (moveReachesKey(pos, mv, key)) return mv;
        }
    }

    if (prefer_repetition_safe) {
        for (moves.slice()) |mv| {
            if (!rootMoveAllowed(root_moves, mv)) continue;
            if (isRepetitionSafeFallback(pos, mv)) return mv;
        }
    }

    for (moves.slice()) |mv| {
        if (rootMoveAllowed(root_moves, mv)) return mv;
    }
    return null;
}

fn moveReachesKey(pos: *const position.Position, mv: move_mod.Move, key: u64) bool {
    var temp = pos.*;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&temp, mv, &state);
    return temp.zobrist_key == key;
}

fn isRepetitionSafeFallback(pos: *const position.Position, mv: move_mod.Move) bool {
    if (mv.flag != .quiet) return false;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return false;
    if (moving_piece.pieceType() == .pawn) return false;
    return !moveWouldChangeCastlingRights(pos, moving_piece, mv);
}

fn moveWouldChangeCastlingRights(pos: *const position.Position, moving_piece: piece.Piece, mv: move_mod.Move) bool {
    return switch (moving_piece) {
        .white_king => pos.castling_rights.white_king_side or pos.castling_rights.white_queen_side,
        .black_king => pos.castling_rights.black_king_side or pos.castling_rights.black_queen_side,
        .white_rook => (mv.from == .h1 and pos.castling_rights.white_king_side) or (mv.from == .a1 and pos.castling_rights.white_queen_side),
        .black_rook => (mv.from == .h8 and pos.castling_rights.black_king_side) or (mv.from == .a8 and pos.castling_rights.black_queen_side),
        else => false,
    };
}

/// TM v2 C3 streak: completed iterations since the best move last changed or
/// the score jumped >= 80 cp. The legacy stable count starts at 1 there.
fn urgencyStreak(stable_iteration_streak: u8) u32 {
    return stable_iteration_streak -| 1;
}

/// TM v2 step 2 stop at a completed iteration: re-arm (or keep disarmed) the
/// soft deadline from the legacy stability gate (C3: from the urgency class,
/// always armed) and stop once an armed search has used its deadline, or the
/// hard budget is gone.
fn softIterationStopReason(control: *time.Controller, stable: bool, elapsed_ns: u64) ?IterationStopReason {
    control.setSoftArmed(stable);
    if (control.limits.maximum_budget_ns) |maximum| {
        if (elapsed_ns >= maximum) return .maximum_elapsed;
    }
    if (stable) {
        if (control.limits.optimum_budget_ns) |optimum| {
            if (elapsed_ns >= optimum) return .optimum_elapsed;
        }
    }
    return null;
}

/// Legal root moves the search may choose from (the searchmoves/TB-safe set
/// when one applies).
noinline fn rootMoveCount(pos: *const position.Position, allowed: ?*const move_mod.MoveList) usize {
    if (allowed) |moves| return moves.count;
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    return moves.count;
}

/// ZQ_TM_TRACE output: one `info string tm ...` line, formatted out of line
/// so the iterative-deepening frame does not grow.
noinline fn emitTrace(ctx: *context_mod.SearchContext, comptime fmt: []const u8, args: anytype) void {
    const emitter = ctx.info_emitter orelse return;
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    emitter.emit(.{ .text = text });
}

noinline fn emitInterruptedFinal(ctx: *context_mod.SearchContext, table: anytype, best: *const SearchResult) void {
    const emitter = ctx.info_emitter orelse return;
    emitter.emit(.{ .iteration = .{
        .depth = best.depth,
        .seldepth = best.seldepth,
        .score = best.score,
        .bound = best.score_bound,
        .nodes = ctx.nodes,
        .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
        .hashfull = table.hashfullPermille(),
        .best_move = best.best_move,
        .pv = best.pv.slice(),
    } });
}

/// Why an interrupted search stopped. An armed soft deadline always fires
/// before the hard budget (hard >= soft), so `soft` identifies it.
fn interruptKind(ctx: *context_mod.SearchContext) []const u8 {
    if (!ctx.stopped) return "none";
    if (ctx.control.stop_flag.load(.acquire)) return "external";
    if (ctx.control.limits.node_limit) |limit| {
        if (ctx.nodes >= limit) return "node_limit";
    }
    return if (ctx.control.limits.soft == .armed) "soft_budget" else "maximum_budget";
}

noinline fn traceSearchStart(ctx: *context_mod.SearchContext) void {
    const limits = ctx.control.limits;
    // mode: legacy (ZQ_TM_V2 off), v2 (clock search with the soft deadline),
    // v2-legacy-plan (ZQ_TM_V2 on but movetime/depth/nodes/infinite or the
    // low-clock regime: the legacy plan applies).
    emitTrace(ctx, "tm plan mode {s} soft_ms {d} hard_ms {d}", .{
        if (limits.soft != .off) "v2" else if (time.tmConfig().v2) "v2-legacy-plan" else "legacy",
        (limits.optimum_budget_ns orelse 0) / std.time.ns_per_ms,
        (limits.maximum_budget_ns orelse 0) / std.time.ns_per_ms,
    });
}

noinline fn traceIteration(ctx: *context_mod.SearchContext, trace: IterationTrace, stable: bool, effort_permille: ?u32, urgency_permille: ?u32, c3_capped: bool) void {
    var move_text: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&move_text);
    if (trace.best_move) |mv| mv.writeUci(&writer) catch {} else writer.writeAll("none") catch {};
    const fmt = "tm iter depth {d} time_ms {d} nodes {d} score {d} best {s} stable {d} effort_permille {d} soft {s}";
    const args = .{
        trace.depth,
        ctx.control.elapsedNs() / std.time.ns_per_ms,
        trace.nodes,
        trace.score,
        writer.buffered(),
        @intFromBool(stable),
        effort_permille orelse 0,
        @tagName(ctx.control.limits.soft),
    };
    // TM v2 C3: the urgency class, the deadline it armed, and the low-clock cap.
    if (urgency_permille) |u| {
        emitTrace(ctx, fmt ++ " u {d} soft_ms {d} cap {d}", args ++ .{ u, (ctx.control.limits.optimum_budget_ns orelse 0) / std.time.ns_per_ms, @intFromBool(c3_capped) });
    } else {
        emitTrace(ctx, fmt, args);
    }
}

noinline fn traceSearchStop(ctx: *context_mod.SearchContext, best: *const SearchResult, v2_enabled: bool) void {
    emitTrace(ctx, "tm stop time_ms {d} depth {d} interrupted {d} interrupt {s} v2 {d} soft {s} reason {s} adopted {d}", .{
        ctx.control.elapsedNs() / std.time.ns_per_ms,
        best.depth,
        @intFromBool(ctx.stopped),
        interruptKind(ctx),
        @intFromBool(v2_enabled),
        @tagName(ctx.control.limits.soft),
        if (best.diagnostics.iteration_stop_reason) |reason| @tagName(reason) else "none",
        @intFromBool(best.diagnostics.interrupted_challenger),
    });
}

/// TM v2 C1: a move proven at the current depth to score strictly above the
/// incumbent's result there (exact or fail-high), from a pass that may later
/// be interrupted.
const ProvenChallenger = struct {
    move: move_mod.Move,
    score: types.Score,
};

const PassVerdict = enum { none, incumbent, challenger };

/// What one aspiration pass (complete or interrupted) proves about the
/// incumbent. Only a pass that finished the incumbent and whose best score
/// beat its lower window bound is evidence: then its best move is at least as
/// good as every move it finished, the incumbent included. A fail-low pass
/// only bounds the moves from above and proves nothing.
fn passVerdict(incumbent: ?move_mod.Move, pass_alpha: types.Score, pass: *const root.IterationResult) PassVerdict {
    const incumbent_move = incumbent orelse return .none;
    if (!pass.incumbent_completed) return .none;
    const pass_best = pass.best_move orelse return .none;
    if (pass.score <= pass_alpha) return .none;
    return if (pass_best == incumbent_move) .incumbent else .challenger;
}

/// Plays a proven challenger from an interrupted iteration: the root value is
/// at least its score at `depth` (a lowerbound unless the root is TB-scored).
/// Kept out of line so the iterative-deepening frame does not grow.
noinline fn adoptInterruptedChallenger(
    ctx: *context_mod.SearchContext,
    working: *position.Position,
    table: anytype,
    best: *SearchResult,
    challenger: ProvenChallenger,
    depth: u16,
    root_wdl: ?syzygy.Wdl,
) void {
    best.best_move = challenger.move;
    best.score = if (root_wdl) |wdl| rootOutcomeScore(wdl, challenger.score) else challenger.score;
    best.score_bound = if (root_wdl == null) .lower else .exact;
    best.depth = depth;
    best.seldepth = ctx.seldepth;
    best.nodes = ctx.nodes;
    pv.reconstructFromRootMoveLimited(working, &ctx.repetition, table, best.best_move, &best.pv, pv.DEFAULT_ENGINE_PV_LIMIT);
    best.diagnostics.interrupted_challenger = true;
    ctx.noteInterruptedChallenger();
    if (ctx.info_emitter) |emitter| {
        emitter.emit(.{ .iteration = .{
            .depth = best.depth,
            .seldepth = best.seldepth,
            .score = best.score,
            .bound = best.score_bound,
            .nodes = best.nodes,
            .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
            .hashfull = table.hashfullPermille(),
            .best_move = best.best_move,
            .pv = best.pv.slice(),
        } });
    }
}

/// TM arc r1: how the optimum (soft) budget check is shaped by the enabled
/// three-signal scalers. The default policy reproduces the legacy behavior
/// exactly (scale 100%, both binary stability gates active).
///
/// When a signal gate is enabled, it REPLACES its binary counterpart with a
/// graded multiplicative factor already folded into `scale_pct`:
///   ZQ_TM_BM  -> ignore_best_move_gate (streak factor prices the change)
///   ZQ_TM_SC  -> ignore_score_gate (drop factor prices the swing)
///   ZQ_TM_NF has no binary counterpart; it only contributes to scale_pct.
const SoftLimitPolicy = struct {
    scale_pct: u32 = 100,
    ignore_best_move_gate: bool = false,
    ignore_score_gate: bool = false,
};

fn shouldStopAfterIterationWithElapsed(
    limits: time.Limits,
    previous: ?IterationTrace,
    current: IterationTrace,
    elapsed_ns: i128,
    iteration_elapsed_ns: i128,
) bool {
    return iterationStopReasonWithElapsed(limits, previous, current, elapsed_ns, iteration_elapsed_ns) != null;
}

fn iterationStopReasonWithElapsed(
    limits: time.Limits,
    previous: ?IterationTrace,
    current: IterationTrace,
    elapsed_ns: i128,
    iteration_elapsed_ns: i128,
) ?IterationStopReason {
    return iterationStopReasonWithPolicy(limits, previous, current, elapsed_ns, iteration_elapsed_ns, .{});
}

fn iterationStopReasonWithPolicy(
    limits: time.Limits,
    previous: ?IterationTrace,
    current: IterationTrace,
    elapsed_ns: i128,
    iteration_elapsed_ns: i128,
    policy: SoftLimitPolicy,
) ?IterationStopReason {
    const projected_elapsed_ns = projectedElapsedNs(elapsed_ns, iteration_elapsed_ns);
    if (budgetStopReason(elapsed_ns, projected_elapsed_ns, limits.maximum_budget_ns, .maximum_elapsed, .maximum_projected)) |reason| return reason;
    if (!isStableIterationWithPolicy(previous, current, policy)) return null;
    const scaled_optimum = scaledOptimumBudgetNs(limits, policy.scale_pct);
    return budgetStopReason(elapsed_ns, projected_elapsed_ns, scaled_optimum, .optimum_elapsed, .optimum_projected);
}

/// Optimum budget scaled by the combined signal factor. The soft budget never
/// exceeds the maximum (hard) budget: signals shape WHEN we willingly stop,
/// the hard cap still protects the clock.
fn scaledOptimumBudgetNs(limits: time.Limits, scale_pct: u32) ?u64 {
    const optimum = limits.optimum_budget_ns orelse return null;
    if (scale_pct == 100) return optimum;
    const scaled = optimum / 100 * scale_pct + (optimum % 100) * scale_pct / 100;
    if (limits.maximum_budget_ns) |maximum| return @min(scaled, maximum);
    return scaled;
}

fn projectedElapsedNs(elapsed_ns: i128, iteration_elapsed_ns: i128) i128 {
    return elapsed_ns + estimateNextIterationNs(iteration_elapsed_ns);
}

fn nextStableIterationStreak(previous_streak: u8, previous: ?IterationTrace, current: IterationTrace) u8 {
    if (isStableIteration(previous, current)) {
        return if (previous_streak == std.math.maxInt(u8)) previous_streak else previous_streak + 1;
    }
    return 1;
}

fn nextTablebaseDecisionStreak(previous_streak: u8, previous: ?IterationTrace, current: IterationTrace) u8 {
    if (!score_mod.isTablebaseDecisive(current.score)) return 0;
    const prior = previous orelse return 1;
    if (!score_mod.isTablebaseDecisive(prior.score)) return 1;
    if ((prior.score < 0) != (current.score < 0)) return 1;
    if (prior.best_move != current.best_move) return 1;
    return if (previous_streak == std.math.maxInt(u8)) previous_streak else previous_streak + 1;
}

/// `go mate N` is answered by the first completed iteration whose score is a
/// mate for the side to move in N moves or fewer.
fn foundRequestedMate(limits: time.Limits, score: types.Score) bool {
    if (limits.mate_in_moves == 0) return false;
    return score > 0 and score_mod.isMateLike(score) and score_mod.scoreToMate(score) <= limits.mate_in_moves;
}

fn shouldStopOnTablebaseDecision(limits: time.Limits, streak: u8, previous: ?IterationTrace) bool {
    if (!limits.hasFiniteLimit() or streak < 2) return false;
    const prior = previous orelse return false;
    return prior.depth >= TB_DECISION_MIN_COMPLETED_DEPTH and score_mod.isTablebaseDecisive(prior.score);
}

fn budgetStopReason(
    elapsed_ns: i128,
    projected_elapsed_ns: i128,
    budget_ns: ?u64,
    elapsed_reason: IterationStopReason,
    projected_reason: IterationStopReason,
) ?IterationStopReason {
    const budget = budget_ns orelse return null;
    const budget_i128: i128 = @intCast(budget);
    if (elapsed_ns >= budget_i128) return elapsed_reason;
    if (projected_elapsed_ns >= budget_i128) return projected_reason;
    return null;
}

fn estimateNextIterationNs(iteration_elapsed_ns: i128) i128 {
    return @max(@as(i128, 2) * std.time.ns_per_ms, iteration_elapsed_ns * 2);
}

const STABILITY_SCORE_WINDOW_CP: i32 = 80;
const WIDER_MAX_SCORE_DROP_CP: i32 = 30;

fn completedIterationArmsWiderMaximum(previous: ?IterationTrace, current: IterationTrace) bool {
    const prior = previous orelse return false;
    if (prior.best_move != current.best_move) return true;
    const score_drop = @as(i64, prior.score) - @as(i64, current.score);
    return score_drop >= WIDER_MAX_SCORE_DROP_CP;
}

fn isStableIteration(previous: ?IterationTrace, current: IterationTrace) bool {
    return isStableIterationWithPolicy(previous, current, .{});
}

fn isStableIterationWithPolicy(previous: ?IterationTrace, current: IterationTrace, policy: SoftLimitPolicy) bool {
    const prior = previous orelse return true;
    if (!policy.ignore_best_move_gate and prior.best_move != current.best_move) return false;
    if (!policy.ignore_score_gate) {
        const delta = current.score - prior.score;
        if (delta >= STABILITY_SCORE_WINDOW_CP or delta <= -STABILITY_SCORE_WINDOW_CP) return false;
    }
    return true;
}

/// Permille of the iteration's root-move subtree nodes spent under the best
/// move (the node-fraction TM signal). Null when the best move is unknown,
/// absent from the hints, or no nodes were attributed.
fn bestMoveNodePermille(hints: *const root.RootMoveHints, best_move: ?move_mod.Move) ?u32 {
    const mv = best_move orelse return null;
    var total: u64 = 0;
    var best_nodes: ?u64 = null;
    for (hints.hints[0..hints.count]) |hint| {
        total += hint.subtree_nodes;
        if (hint.mv == mv) best_nodes = hint.subtree_nodes;
    }
    if (total == 0) return null;
    const nodes = best_nodes orelse return null;
    return @intCast(nodes * 1000 / total);
}

test "aspiration windows start from previous stable score" {
    const previous = IterationTrace{ .depth = 3, .score = 24 };
    try std.testing.expectEqual(@as(?i32, 24), aspirationGuess(previous, 4));
    try std.testing.expectEqual(@as(i32, -26), initialAspirationAlpha(aspirationGuess(previous, 4), 50));
    try std.testing.expectEqual(@as(i32, 74), initialAspirationBeta(aspirationGuess(previous, 4), 50));
}

test "iteration stability treats first completed iteration as stable enough" {
    const trace = IterationTrace{ .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    try std.testing.expect(isStableIteration(null, trace));
    try std.testing.expectEqual(@as(u8, 1), nextStableIterationStreak(0, null, trace));
}

test "TM v2 C3 streak restarts on a best-move change or a score jump of 80" {
    const e4 = move_mod.Move.init(.e2, .e4, .double_push);
    const d4 = move_mod.Move.init(.d2, .d4, .double_push);
    const Case = struct { trace: IterationTrace, streak: u32, u: u32 };
    const cases = [_]Case{
        .{ .trace = .{ .score = 0, .best_move = e4 }, .streak = 0, .u = 5540 }, // first iteration
        .{ .trace = .{ .score = 10, .best_move = e4 }, .streak = 1, .u = 2870 },
        .{ .trace = .{ .score = 89, .best_move = e4 }, .streak = 2, .u = 2870 }, // +79: kept
        .{ .trace = .{ .score = 89, .best_move = e4 }, .streak = 3, .u = 2870 },
        .{ .trace = .{ .score = 89, .best_move = e4 }, .streak = 4, .u = 1410 },
        .{ .trace = .{ .score = 89, .best_move = d4 }, .streak = 0, .u = 5540 }, // move change
        .{ .trace = .{ .score = 89, .best_move = d4 }, .streak = 1, .u = 2870 },
        .{ .trace = .{ .score = 9, .best_move = d4 }, .streak = 0, .u = 5540 }, // -80: jump
        .{ .trace = .{ .score = 89, .best_move = d4 }, .streak = 0, .u = 5540 }, // +80: jump
    };
    var previous: ?IterationTrace = null;
    var stable_streak: u8 = 0;
    for (cases) |case| {
        stable_streak = nextStableIterationStreak(stable_streak, previous, case.trace);
        try std.testing.expectEqual(case.streak, urgencyStreak(stable_streak));
        try std.testing.expectEqual(case.u, time.c3UrgencyPermille(urgencyStreak(stable_streak)));
        previous = case.trace;
    }
    // Further stable iterations walk down the long-streak classes: 12, 20, 30.
    const long_classes = [_]struct { more: usize, u: u32 }{ .{ .more = 12, .u = 640 }, .{ .more = 8, .u = 360 }, .{ .more = 10, .u = 80 } };
    for (long_classes) |step| {
        for (0..step.more) |_| stable_streak = nextStableIterationStreak(stable_streak, previous, previous.?);
        try std.testing.expectEqual(step.u, time.c3UrgencyPermille(urgencyStreak(stable_streak)));
    }
    // The legacy count saturates; the class stays put.
    try std.testing.expectEqual(@as(u32, 80), time.c3UrgencyPermille(urgencyStreak(std.math.maxInt(u8))));
}

test "tablebase decision reuse requires two matching decisive iterations" {
    const best = move_mod.Move.init(.e2, .e4, .double_push);
    const other = move_mod.Move.init(.d2, .d4, .double_push);
    const loss = IterationTrace{ .score = -score_mod.TB_WIN_SCORE + 8, .best_move = best };
    const later_loss = IterationTrace{ .score = -score_mod.TB_WIN_SCORE + 10, .best_move = best };

    try std.testing.expectEqual(@as(u8, 1), nextTablebaseDecisionStreak(0, null, loss));
    try std.testing.expectEqual(@as(u8, 2), nextTablebaseDecisionStreak(1, loss, later_loss));
    try std.testing.expectEqual(@as(u8, 1), nextTablebaseDecisionStreak(2, later_loss, .{ .score = score_mod.TB_WIN_SCORE - 8, .best_move = best }));
    try std.testing.expectEqual(@as(u8, 1), nextTablebaseDecisionStreak(2, later_loss, .{ .score = -score_mod.TB_WIN_SCORE + 9, .best_move = other }));
    try std.testing.expectEqual(@as(u8, 0), nextTablebaseDecisionStreak(2, later_loss, .{ .score = score_mod.MATE_SCORE - 1, .best_move = best }));
}

test "aspiration widening reaches the full window when a mate lies beyond guess -/+ INF" {
    // Fail low: previous score +1284, the side is actually mated in 1 (-(MATE_SCORE - 1)).
    const mated = -(score_mod.MATE_SCORE - 1);
    var alpha: i32 = 1284 - ASPIRATION_START_CP;
    var beta: i32 = 1284 + ASPIRATION_START_CP;
    var delta: i32 = ASPIRATION_START_CP;
    var passes: usize = 0;
    while (mated <= alpha) : (passes += 1) {
        try std.testing.expect(passes < 32);
        widenAspirationWindow(1284, &alpha, &beta, &delta, mated);
    }
    try std.testing.expectEqual(@as(i32, -qsearch.INF), alpha);
    try std.testing.expectEqual(@as(i32, 1284 + ASPIRATION_START_CP), beta);
    // Fail high mirror: previous score -1284, a mate in 1 exists for the side to move.
    const mating = score_mod.MATE_SCORE - 1;
    alpha = -1284 - ASPIRATION_START_CP;
    beta = -1284 + ASPIRATION_START_CP;
    delta = ASPIRATION_START_CP;
    passes = 0;
    while (mating >= beta) : (passes += 1) {
        try std.testing.expect(passes < 32);
        widenAspirationWindow(-1284, &alpha, &beta, &delta, mating);
    }
    try std.testing.expectEqual(@as(i32, qsearch.INF), beta);
    // Before the cap the window is exactly the old one.
    alpha = 100 - ASPIRATION_START_CP;
    beta = 100 + ASPIRATION_START_CP;
    delta = ASPIRATION_START_CP;
    widenAspirationWindow(100, &alpha, &beta, &delta, 50);
    try std.testing.expectEqual(@as(i32, 100 - 2 * ASPIRATION_START_CP), alpha);
}

test "tablebase WDL aspiration proof requires matching bound direction" {
    const win = score_mod.TB_DECISIVE_THRESHOLD;
    const loss = -score_mod.TB_DECISIVE_THRESHOLD;
    try std.testing.expect(isTablebaseWdlProof(-50, 50, win));
    try std.testing.expect(isTablebaseWdlProof(-50, 50, loss));
    try std.testing.expect(!isTablebaseWdlProof(loss - 50, loss - 10, loss));
    try std.testing.expect(!isTablebaseWdlProof(win + 10, win + 50, win));
    try std.testing.expect(!isTablebaseWdlProof(-50, 50, score_mod.MATE_SCORE - 1));
}

test "tablebase decision stop requires a finite limit and completed depth floor" {
    const best = move_mod.Move.init(.e2, .e4, .double_push);
    const before_floor = IterationTrace{ .depth = TB_DECISION_MIN_COMPLETED_DEPTH - 1, .score = score_mod.TB_WIN_SCORE, .best_move = best };
    const at_floor = IterationTrace{ .depth = TB_DECISION_MIN_COMPLETED_DEPTH, .score = score_mod.TB_WIN_SCORE, .best_move = best };
    try std.testing.expect(!shouldStopOnTablebaseDecision(.{ .depth = 35 }, 2, before_floor));
    try std.testing.expect(shouldStopOnTablebaseDecision(.{ .depth = 35 }, 2, at_floor));
    try std.testing.expect(!shouldStopOnTablebaseDecision(.{ .infinite = true }, 2, at_floor));
    try std.testing.expect(!shouldStopOnTablebaseDecision(.{}, 2, at_floor));
}

test "iterative deepening searches through an early TB decision to a short mate" {
    const fen = @import("../core/fen.zig");
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer std.testing.allocator.free(path);

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();
    try std.testing.expect(engine.setSyzygyPath(path));
    defer _ = engine.setSyzygyPath("");
    // Six men: the root stays outside 3-4-5 tables (with 6-man tables it would
    // be a tablebase root, decided before iterative deepening).
    if (syzygy.pieceLimit() != 5) return error.SkipZigTest;

    // Fixture repaired 2026-10-14 (the old one, k7/8/1P6/K7/p1P5/1p4Q1/8/8 w,
    // now finds its mate at depth 5 before any TB score). Here depths 4-7 agree
    // on a tablebase win with d6d7 (d7h7 then reaches 3-4-5 tables), a streak
    // that alone would end iterative deepening; the mate in 2 (e8e7) appears
    // at depth 8. Only the completed-depth floor (13) keeps the search going:
    // without it the search ends after depth 5 with a TB score and this fails.
    const pos = try fen.parse("4R3/k6p/3R4/p7/8/8/8/2K5 w - - 0 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);
    const result = engine.search(&pos, &history, .{ .depth = 14 }, &stop_flag);

    const traces = result.diagnostics.trace[0..result.diagnostics.trace_len];
    const first_mate = for (traces, 0..) |trace, i| {
        if (score_mod.isMateLike(trace.score)) break i;
    } else traces.len;
    var streak: u8 = 0;
    var longest_streak_before_mate: u8 = 0;
    var previous: ?IterationTrace = null;
    for (traces[0..first_mate]) |trace| {
        streak = nextTablebaseDecisionStreak(streak, previous, trace);
        longest_streak_before_mate = @max(longest_streak_before_mate, streak);
        previous = trace;
    }
    try std.testing.expect(longest_streak_before_mate >= 2);
    try std.testing.expect(first_mate < TB_DECISION_MIN_COMPLETED_DEPTH);
    try std.testing.expect(score_mod.isMateLike(result.score) and result.score > 0);
    try std.testing.expectEqual(@as(u16, 14), result.depth);
    try std.testing.expectEqual(@as(usize, 14), result.diagnostics.trace_len);
}

test "engine tracks selective depth during search" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expect(result.seldepth >= result.depth);
}

test "next iteration estimate keeps a minimum floor" {
    try std.testing.expectEqual(@as(i128, 2) * std.time.ns_per_ms, estimateNextIterationNs(std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i128, 20) * std.time.ns_per_ms, estimateNextIterationNs(@as(i128, 10) * std.time.ns_per_ms));
}

test "projected elapsed time adds the next-iteration estimate" {
    try std.testing.expectEqual(@as(i128, 15) * std.time.ns_per_ms, projectedElapsedNs(@as(i128, 5) * std.time.ns_per_ms, @as(i128, 5) * std.time.ns_per_ms));
}

test "unstable iterations ignore optimum-budget projection" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const current = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.d2, .d4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    try std.testing.expect(!shouldStopAfterIterationWithElapsed(limits, previous, current, 40 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
}

test "stable iterations stop when the projected next iteration crosses optimum budget" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const current = IterationTrace{ .score = 20, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    try std.testing.expect(shouldStopAfterIterationWithElapsed(limits, previous, current, 40 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?IterationStopReason, .optimum_projected), iterationStopReasonWithElapsed(limits, previous, current, 40 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
}

test "maximum budget stops even unstable iterations" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const current = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.d2, .d4, .double_push) };
    const limits = time.Limits{ .maximum_budget_ns = 50 * std.time.ns_per_ms };

    try std.testing.expect(shouldStopAfterIterationWithElapsed(limits, previous, current, 40 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?IterationStopReason, .maximum_projected), iterationStopReasonWithElapsed(limits, previous, current, 40 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
}

test "wider maximum arms only after completed instability" {
    const e4 = move_mod.Move.init(.e2, .e4, .double_push);
    const d4 = move_mod.Move.init(.d2, .d4, .double_push);
    const previous = IterationTrace{ .score = 100, .best_move = e4 };
    const stable = IterationTrace{ .score = 71, .best_move = e4 };
    const changed = IterationTrace{ .score = 100, .best_move = d4 };
    const dropped = IterationTrace{ .score = 70, .best_move = e4 };
    const legacy_ns = 50 * std.time.ns_per_ms;
    const wide_ns = 100 * std.time.ns_per_ms;
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = time.Controller.init(&stop_flag, .{
        .maximum_budget_ns = legacy_ns,
        .wider_maximum_budget_ns = wide_ns,
    });

    // No predecessor and a stable predecessor both retain the legacy cap.
    controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(null, stable));
    try std.testing.expectEqual(@as(?u64, legacy_ns), controller.limits.maximum_budget_ns);
    controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous, stable));
    try std.testing.expectEqual(@as(?u64, legacy_ns), controller.limits.maximum_budget_ns);

    // Either trigger arms the wider cap for the next iteration. A subsequent
    // stable completion disarms it again.
    controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous, changed));
    try std.testing.expectEqual(@as(?u64, wide_ns), controller.limits.maximum_budget_ns);
    controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous, dropped));
    try std.testing.expectEqual(@as(?u64, wide_ns), controller.limits.maximum_budget_ns);
    controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous, stable));
    try std.testing.expectEqual(@as(?u64, legacy_ns), controller.limits.maximum_budget_ns);

    // At <=1s, the planner makes the stored wide cap equal the legacy cap, so
    // even an unstable completed trace cannot widen the deadline.
    const low = time.GoLimits{ .wtime_ms = 1_000, .winc_ms = 100 };
    const wide_plan = low.planWithConfig(.{}, .white, time.DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    const legacy_plan = low.planWithConfig(.{ .max_growth_pct = 50, .max_fraction_divisor = 8 }, .white, time.DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(legacy_plan.maximum_ms, wide_plan.maximum_ms);
    var low_controller = time.Controller.init(&stop_flag, .{
        .maximum_budget_ns = legacy_plan.maximum_ms * std.time.ns_per_ms,
        .wider_maximum_budget_ns = wide_plan.maximum_ms * std.time.ns_per_ms,
    });
    low_controller.setWiderMaximumArmed(completedIterationArmsWiderMaximum(previous, changed));
    try std.testing.expectEqual(@as(?u64, legacy_plan.maximum_ms * std.time.ns_per_ms), low_controller.limits.maximum_budget_ns);
}

test "no budgets means no iteration stop signal" {
    const current = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    try std.testing.expect(!shouldStopAfterIterationWithElapsed(.{}, null, current, 10 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
}

test "default soft policy reproduces the legacy stop decision" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const stable = IterationTrace{ .score = 20, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const changed = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.d2, .d4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    // Stable + past optimum -> stop; unstable -> optimum ignored. Same as legacy.
    try std.testing.expectEqual(
        @as(?IterationStopReason, .optimum_elapsed),
        iterationStopReasonWithPolicy(limits, previous, stable, 60 * std.time.ns_per_ms, 2 * std.time.ns_per_ms, .{}),
    );
    try std.testing.expectEqual(
        @as(?IterationStopReason, null),
        iterationStopReasonWithPolicy(limits, previous, changed, 60 * std.time.ns_per_ms, 2 * std.time.ns_per_ms, .{}),
    );
}

test "bm policy replaces the binary best-move gate with the graded factor" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const changed = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.d2, .d4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    // Legacy: a changed best move skips the optimum check entirely (no stop
    // even far past budget). With the BM gate replaced and a 130% factor,
    // the scaled optimum (65ms) DOES stop once elapsed crosses it.
    const policy = SoftLimitPolicy{ .scale_pct = 130, .ignore_best_move_gate = true };
    try std.testing.expectEqual(
        @as(?IterationStopReason, null),
        iterationStopReasonWithPolicy(limits, previous, changed, 60 * std.time.ns_per_ms, 1 * std.time.ns_per_ms, policy),
    );
    try std.testing.expectEqual(
        @as(?IterationStopReason, .optimum_elapsed),
        iterationStopReasonWithPolicy(limits, previous, changed, 66 * std.time.ns_per_ms, 1 * std.time.ns_per_ms, policy),
    );
}

test "sc policy replaces the score window with the graded factor" {
    const previous = IterationTrace{ .score = 100, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const dropped = IterationTrace{ .score = -50, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    // Legacy: a 150cp drop is "unstable" -> optimum ignored at 60ms.
    try std.testing.expectEqual(
        @as(?IterationStopReason, null),
        iterationStopReasonWithPolicy(limits, previous, dropped, 60 * std.time.ns_per_ms, 2 * std.time.ns_per_ms, .{}),
    );
    // SC policy prices the drop as a 160% extension instead: no stop at
    // 60ms (< 80ms scaled), stop once elapsed crosses the scaled budget.
    const policy = SoftLimitPolicy{ .scale_pct = 160, .ignore_score_gate = true };
    try std.testing.expectEqual(
        @as(?IterationStopReason, null),
        iterationStopReasonWithPolicy(limits, previous, dropped, 60 * std.time.ns_per_ms, 2 * std.time.ns_per_ms, policy),
    );
    try std.testing.expectEqual(
        @as(?IterationStopReason, .optimum_elapsed),
        iterationStopReasonWithPolicy(limits, previous, dropped, 81 * std.time.ns_per_ms, 2 * std.time.ns_per_ms, policy),
    );
}

test "shrinking soft scale stops earlier than the unscaled optimum" {
    const previous = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const stable = IterationTrace{ .score = 12, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    const limits = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };

    // 80% factor -> 40ms scaled budget: 42ms elapsed stops where legacy would not.
    const policy = SoftLimitPolicy{ .scale_pct = 80 };
    try std.testing.expectEqual(
        @as(?IterationStopReason, .optimum_elapsed),
        iterationStopReasonWithPolicy(limits, previous, stable, 42 * std.time.ns_per_ms, 1 * std.time.ns_per_ms, policy),
    );
    try std.testing.expectEqual(
        @as(?IterationStopReason, null),
        iterationStopReasonWithPolicy(limits, previous, stable, 42 * std.time.ns_per_ms, 1 * std.time.ns_per_ms, .{}),
    );
}

test "scaled optimum budget never exceeds the maximum budget" {
    const limits = time.Limits{
        .optimum_budget_ns = 50 * std.time.ns_per_ms,
        .maximum_budget_ns = 70 * std.time.ns_per_ms,
    };
    try std.testing.expectEqual(@as(?u64, 70 * std.time.ns_per_ms), scaledOptimumBudgetNs(limits, 200));
    try std.testing.expectEqual(@as(?u64, 50 * std.time.ns_per_ms), scaledOptimumBudgetNs(limits, 100));
    try std.testing.expectEqual(@as(?u64, 40 * std.time.ns_per_ms), scaledOptimumBudgetNs(limits, 80));

    const uncapped = time.Limits{ .optimum_budget_ns = 50 * std.time.ns_per_ms };
    try std.testing.expectEqual(@as(?u64, 100 * std.time.ns_per_ms), scaledOptimumBudgetNs(uncapped, 200));
    try std.testing.expectEqual(@as(?u64, null), scaledOptimumBudgetNs(.{}, 200));
}

test "best-move node permille reflects root subtree concentration" {
    var hints = root.RootMoveHints{};
    const e4 = move_mod.Move.init(.e2, .e4, .double_push);
    const d4 = move_mod.Move.init(.d2, .d4, .double_push);
    const c4 = move_mod.Move.init(.c2, .c4, .double_push);
    hints.record(e4, 30, 750);
    hints.record(d4, 10, 200);
    hints.record(c4, -5, 50);

    try std.testing.expectEqual(@as(?u32, 750), bestMoveNodePermille(&hints, e4));
    try std.testing.expectEqual(@as(?u32, 200), bestMoveNodePermille(&hints, d4));
    try std.testing.expectEqual(@as(?u32, 50), bestMoveNodePermille(&hints, c4));
    // Unknown move or missing best move -> no signal.
    try std.testing.expectEqual(@as(?u32, null), bestMoveNodePermille(&hints, move_mod.Move.init(.g1, .f3, .quiet)));
    try std.testing.expectEqual(@as(?u32, null), bestMoveNodePermille(&hints, null));
    // Zero attributed nodes -> no signal.
    var empty = root.RootMoveHints{};
    empty.record(e4, 0, 0);
    try std.testing.expectEqual(@as(?u32, null), bestMoveNodePermille(&empty, e4));
}

test "engine search diagnostics expose search counters" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    if (context_mod.stats_enabled) try std.testing.expect(result.diagnostics.stats.qnodes > 0);
    if (context_mod.stats_enabled) try std.testing.expect(result.diagnostics.stats.tt_probes > 0);
    if (context_mod.stats_enabled) try std.testing.expect(result.diagnostics.stats.pvs_scouts > 0);
}

test "engine searches with the pure-NNUE evaluator" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.initWithOptions(std.testing.allocator, tt.DEFAULT_HASH_MB, .{});
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
}

test "engine search is stable across repeated fixed-depth runs" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const first = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    const second = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);

    try std.testing.expect(first.best_move != null);
    try std.testing.expectEqual(first.best_move.?, second.best_move.?);
}

test "engine respects node limit and still returns a legal move" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 6, .node_limit = 1 }, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expectEqual(@as(u64, 1), result.nodes);
}

test "pass verdict needs a finished incumbent and a real score" {
    const incumbent = move_mod.Move.init(.e2, .e4, .double_push);
    const other = move_mod.Move.init(.d2, .d4, .double_push);
    const alpha: types.Score = 10;

    // No incumbent (first iteration) or an unfinished incumbent proves nothing.
    try std.testing.expectEqual(PassVerdict.none, passVerdict(null, alpha, &.{ .best_move = other, .score = 50, .incumbent_completed = true }));
    try std.testing.expectEqual(PassVerdict.none, passVerdict(incumbent, alpha, &.{ .best_move = other, .score = 50, .incumbent_completed = false }));
    // A fail-low pass only bounds every move from above.
    try std.testing.expectEqual(PassVerdict.none, passVerdict(incumbent, alpha, &.{ .best_move = other, .score = 10, .incumbent_completed = true }));
    try std.testing.expectEqual(PassVerdict.none, passVerdict(incumbent, alpha, &.{ .best_move = null, .score = 50, .incumbent_completed = true }));
    // Above the window's lower bound the pass ranks the incumbent.
    try std.testing.expectEqual(PassVerdict.incumbent, passVerdict(incumbent, alpha, &.{ .best_move = incumbent, .score = 11, .incumbent_completed = true }));
    try std.testing.expectEqual(PassVerdict.challenger, passVerdict(incumbent, alpha, &.{ .best_move = other, .score = 11, .incumbent_completed = true }));
}

test "interrupted iterations only replace the move with a proven challenger" {
    const fen = @import("../core/fen.zig");
    // Middlegame/endgame roots whose best move changes between depths under
    // small node budgets (game 16 of the 6.4.0 CCRL gauntlet).
    const fens = [_][]const u8{
        "r2r2k1/1pp2ppp/6b1/4p3/p3N3/bPPBPP2/P5PP/R2R2K1 w - - 0 20",
        "8/1pp2bp1/2k4p/4p3/2P1N2b/1K2PP2/P3B2P/8 w - - 36 47",
        "rn1qk2r/ppp2ppp/3b4/3npb2/8/1P2PP2/PB1PN1PP/RN1QKB1R w KQkq - 1 8",
    };
    const limits = [_]u64{ 5_000, 10_000, 20_000, 35_000, 50_000, 75_000 };

    var engine = try Engine.init(std.testing.allocator, 16);
    defer engine.deinit();
    var adopted: usize = 0;
    for (fens) |text| {
        const pos = try fen.parse(text);
        for (limits) |node_limit| {
            engine.reset();
            var history = repetition.History{};
            history.push(pos.zobrist_key);
            var stop_flag = std.atomic.Value(bool).init(false);
            const result = engine.search(&pos, &history, .{ .node_limit = node_limit }, &stop_flag);
            try std.testing.expect(result.best_move != null);
            try std.testing.expect(result.diagnostics.trace_len > 0);
            const last = result.diagnostics.trace[result.diagnostics.trace_len - 1];
            if (result.diagnostics.interrupted_challenger) {
                adopted += 1;
                try std.testing.expectEqual(search_info.ScoreBound.lower, result.score_bound);
                try std.testing.expectEqual(last.depth + 1, result.depth);
                try std.testing.expect(result.best_move.? != last.best_move.?);
                try std.testing.expect(pv.isLegal(&pos, &history, &result.pv));
                try std.testing.expectEqual(result.best_move.?, result.pv.slice()[0]);
            } else {
                try std.testing.expectEqual(search_info.ScoreBound.exact, result.score_bound);
                try std.testing.expectEqual(last.best_move, result.best_move);
                try std.testing.expectEqual(last.depth, result.depth);
            }
        }
    }
    // The sweep must exercise the adoption path; if a search change moves
    // every proof off these budgets, pick new budgets rather than drop this.
    try std.testing.expect(adopted > 0);
}

test "engine finds a mate in one at depth one" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("6k1/5Q2/6K1/8/8/8/8/8 w - - 0 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 1 }, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expectEqual(move_mod.Move.init(.f7, .g7, .quiet), result.best_move.?);
    try std.testing.expect(result.score >= 28_999);
    try std.testing.expect(pv.isLegal(&pos, &history, &result.pv));
}

test "go mate stops at the first iteration that proves the requested mate" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("k7/8/1P6/K7/p1P5/1p4Q1/8/8 w - - 2 40");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .mate_in_moves = 2 }, &stop_flag);
    try std.testing.expectEqual(score_mod.MATE_SCORE - 3, result.score);
    try std.testing.expect(result.depth < 64);
    try std.testing.expect(pv.isLegal(&pos, &history, &result.pv));

    try std.testing.expect(foundRequestedMate(.{ .mate_in_moves = 2 }, score_mod.MATE_SCORE - 3));
    try std.testing.expect(foundRequestedMate(.{ .mate_in_moves = 2 }, score_mod.MATE_SCORE - 1));
    try std.testing.expect(!foundRequestedMate(.{ .mate_in_moves = 1 }, score_mod.MATE_SCORE - 3));
    try std.testing.expect(!foundRequestedMate(.{ .mate_in_moves = 2 }, -score_mod.MATE_SCORE + 2));
    try std.testing.expect(!foundRequestedMate(.{ .mate_in_moves = 2 }, 500));
    try std.testing.expect(!foundRequestedMate(.{}, score_mod.MATE_SCORE - 1));
}

test "engine treats fifty-move root as draw" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("4k3/8/8/8/8/8/4N3/4K3 w - - 100 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 3 }, &stop_flag);
    try std.testing.expectEqual(@as(i32, 0), result.score);
    try std.testing.expect(result.best_move != null);
}

test "checkmate outranks the fifty-move clock" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();
    var stop_flag = std.atomic.Value(bool).init(false);

    // Every mating move here is the hundredth reversible ply. The game ends
    // by mate, not by the fifty-move claim, at the horizon and in the main
    // search alike.
    const depths = [_]u16{ 1, 2, 5 };
    for (depths) |depth| {
        const pos = try fen.parse("7k/4Q3/6K1/8/8/8/8/8 w - - 99 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        engine.reset();
        const result = engine.search(&pos, &history, .{ .depth = depth }, &stop_flag);
        try std.testing.expectEqual(score_mod.MATE_SCORE - 1, result.score);
        var child = pos;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&child, result.best_move.?, &state);
        try std.testing.expect(rule50.isCheckmated(&child, null));
    }

    // Mate in two whose last move lands on clock 100: Kg6 Kg8, Qd8#.
    {
        const pos = try fen.parse("7k/8/5K2/8/8/8/8/3Q4 w - - 97 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        engine.reset();
        const result = engine.search(&pos, &history, .{ .depth = 6 }, &stop_flag);
        try std.testing.expectEqual(score_mod.MATE_SCORE - 3, result.score);
    }

    // A root that is already mated stays lost past the clock.
    {
        const pos = try fen.parse("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        engine.reset();
        const result = engine.search(&pos, &history, .{ .depth = 3 }, &stop_flag);
        try std.testing.expectEqual(-score_mod.MATE_SCORE, result.score);
        try std.testing.expect(result.best_move == null);
    }

    // A root past the clock still plays an available mate.
    {
        const pos = try fen.parse("7k/4Q3/6K1/8/8/8/8/8 w - - 100 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        engine.reset();
        const result = engine.search(&pos, &history, .{ .depth = 3 }, &stop_flag);
        try std.testing.expectEqual(score_mod.MATE_SCORE - 1, result.score);
        var child = pos;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&child, result.best_move.?, &state);
        try std.testing.expect(rule50.isCheckmated(&child, null));
    }

    // No mate on the board: the clock still draws, as before.
    {
        const pos = try fen.parse("4k3/8/8/8/8/8/4N3/4K3 w - - 99 1");
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        engine.reset();
        const result = engine.search(&pos, &history, .{ .depth = 4 }, &stop_flag);
        try std.testing.expectEqual(@as(i32, 0), result.score);
    }
}

test "engine treats repeated root position as draw" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    history.push(0xABCD);
    history.push(pos.zobrist_key);
    history.push(0x1234);
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    var drawn = pos;
    drawn.halfmove_clock = 4;
    const result = engine.search(&drawn, &history, .{ .depth = 3 }, &stop_flag);
    try std.testing.expectEqual(@as(i32, 0), result.score);
    try std.testing.expect(result.best_move != null);
}

test "engine searches root positions with only one prior occurrence" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("8/1k6/7p/1pP3pP/pP2K3/P7/8/8 w - - 20 82");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    history.push(0xABCD);
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
}

test "repetition fallback prefers quiet non-pawn moves over first legal pawn pushes" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("8/1k6/7p/1pP3pP/pP2K3/P7/8/8 w - - 20 82");
    try std.testing.expectEqual(move_mod.Move.init(.c5, .c6, .quiet), fallbackMove(&pos, false, null, null).?);

    const safe = fallbackMove(&pos, true, null, null).?;
    try std.testing.expect(safe != move_mod.Move.init(.c5, .c6, .quiet));
    try std.testing.expect(safe.from == .e4);
    try std.testing.expect(isRepetitionSafeFallback(&pos, safe));
}

test "engine stopped before iteration uses repetition-safe fallback" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("8/1k6/7p/1pP3pP/pP2K3/P7/8/8 w - - 20 82");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    history.push(0xABCD);
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(true);

    const result = engine.search(&pos, &history, .{ .depth = 4 }, &stop_flag);
    try std.testing.expectEqual(@as(u64, 0), result.nodes);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.best_move.? != move_mod.Move.init(.c5, .c6, .quiet));
    try std.testing.expect(isRepetitionSafeFallback(&pos, result.best_move.?));
}

test "engine stopped before iteration prefers previous repetition cycle move" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("8/1k6/7p/1pP3pP/pP2K3/P7/8/8 w - - 20 82");
    const cycle_move = move_mod.Move.init(.e4, .f5, .quiet);
    var child = pos;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&child, cycle_move, &state);

    var history = repetition.History{};
    history.push(pos.zobrist_key);
    history.push(child.zobrist_key);
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(true);

    const result = engine.search(&pos, &history, .{ .depth = 4 }, &stop_flag);
    try std.testing.expectEqual(@as(u64, 0), result.nodes);
    try std.testing.expectEqual(cycle_move, result.best_move.?);
}

test "engine reconstructs legal pv on representative search" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.pv.len != 0);
    try std.testing.expect(pv.isLegal(&pos, &history, &result.pv));
    try std.testing.expectEqual(result.best_move.?, result.pv.slice()[0]);
}

test "engine can resize hash without reallocating in search" {
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();

    const before = engine.tt.entryCount();
    try engine.resizeHash(2);
    try std.testing.expect(engine.tt.entryCount() >= before);
}

test "engine stops after a finite movetime and returns completed iteration" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const limits = (time.GoLimits{ .movetime_ms = 20 }).toControllerLimits(.white, time.DEFAULT_MOVE_OVERHEAD_MS, 1);
    const result = engine.search(&pos, &history, limits, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
}

test "a clock that is gone before depth 1 still plays a searched depth-1 move" {
    // Audit D (U-STOP-D1): an expired deadline used to stop at node 0 and play
    // the first generated move. The clock now waits for depth 1; an external
    // stop still ends the search at once (the stopped-before-iteration tests).
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    // A 1 ns deadline has always passed at the first clock check (node 0), so
    // this is the deterministic witness: exactly depth 1, searched.
    const expired = engine.search(&pos, &history, .{ .optimum_budget_ns = 1, .maximum_budget_ns = 1 }, &stop_flag);
    try std.testing.expectEqual(@as(u16, 1), expired.depth);
    try std.testing.expect(expired.nodes > 0);
    try std.testing.expectEqual(expired.best_move.?, expired.pv.slice()[0]);
    // The UCI shapes of the same situation (a 1 ms plan).
    for ([_]time.GoLimits{
        .{ .wtime_ms = 0, .btime_ms = 60_000 },
        .{ .movetime_ms = 0 },
    }) |go| {
        const result = engine.search(&pos, &history, go.toControllerLimits(.white, time.DEFAULT_MOVE_OVERHEAD_MS, 1), &stop_flag);
        try std.testing.expect(result.depth >= 1);
        try std.testing.expect(result.nodes > 0);
        try std.testing.expectEqual(result.best_move.?, result.pv.slice()[0]);
    }
}

test "after the held depth 1 only the hard budget can stop the search, and it does" {
    // Judge D finding A: the depth-1 hold must leave the planned hard deadline
    // in place. In both limits nothing but the hard budget can end the search
    // before depth 6; it expired at node 0, so the search stops at depth 1.
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    for ([_]time.Limits{
        .{ .maximum_budget_ns = 1, .depth = 6 },
        // Clock-shaped: soft stopping disarmed and an hour of optimum (C3's
        // deadline is capped by the hard budget, so only that budget counts).
        .{ .optimum_budget_ns = std.time.ns_per_hour, .maximum_budget_ns = 1, .soft = .disarmed, .depth = 6 },
    }) |limits| {
        const result = engine.search(&pos, &history, limits, &stop_flag);
        try std.testing.expectEqual(@as(u16, 1), result.depth);
        try std.testing.expectEqual(IterationStopReason.maximum_elapsed, result.diagnostics.iteration_stop_reason.?);
    }
}

test "a first iteration that cannot finish answers at the hold's node budget" {
    // Judge B J2: on impossible dense-queen boards depth 1 takes 159k or 2.4M
    // nodes (48 queens: it never ends). The hold ends after
    // FIRST_ITERATION_CLOCK_HOLD_NODES; then the planned deadline applies.
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();
    var stop_flag = std.atomic.Value(bool).init(false);

    for ([_][]const u8{
        "rrbbkbnn/qqqqqqqq/8/8/8/8/QQQQQQQQ/RRBBKBNN w - - 0 1",
        "rn2k3/qqqqqqqq/8/8/8/8/QQQQQQQQ/RN2K3 w - - 0 1",
    }) |text| {
        const pos = try fen.parse(text);
        var history = repetition.History{};
        history.push(pos.zobrist_key);

        // An expired deadline: the first clock check after the hold stops.
        // (Depth 1 only, so that a hold without a backstop fails, not hangs.)
        const expired = engine.search(&pos, &history, .{ .maximum_budget_ns = 1, .depth = 1 }, &stop_flag);
        try std.testing.expectEqual(@as(u16, 0), expired.depth);
        try std.testing.expectEqual(time.FIRST_ITERATION_CLOCK_HOLD_NODES, expired.nodes);
        try std.testing.expect(expired.best_move != null);

        // A 500 ms clock (hard budget 28 ms): the move comes well inside what
        // the clock can afford, the remaining time less the move overhead.
        const clock = (time.GoLimits{ .wtime_ms = 500, .btime_ms = 500 }).toControllerLimits(.white, time.DEFAULT_MOVE_OVERHEAD_MS, 1);
        var timer = try runtime.Timer.start();
        const timed = engine.search(&pos, &history, clock, &stop_flag);
        try std.testing.expect(timer.read() < (500 - time.DEFAULT_MOVE_OVERHEAD_MS) * std.time.ns_per_ms);
        try std.testing.expect(timed.best_move != null);
    }
}

test "stop and node limits still end a held depth 1 at once" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);

    // An expired clock on top of each limit changes nothing.
    var go_flag = std.atomic.Value(bool).init(false);
    const one = engine.search(&pos, &history, .{ .node_limit = 1, .maximum_budget_ns = 1 }, &go_flag);
    try std.testing.expectEqual(@as(u64, 1), one.nodes);
    try std.testing.expect(one.best_move != null);
    const zero = engine.search(&pos, &history, .{ .node_limit = 0, .maximum_budget_ns = 1 }, &go_flag);
    try std.testing.expectEqual(@as(u64, 0), zero.nodes);
    try std.testing.expect(zero.best_move != null);
    var stopped = std.atomic.Value(bool).init(true);
    const halted = engine.search(&pos, &history, .{ .maximum_budget_ns = 1 }, &stopped);
    try std.testing.expectEqual(@as(u64, 0), halted.nodes);
    try std.testing.expect(halted.best_move != null);
}

test "lazy accumulator reconstruction matches full refresh across real searches" {
    const fen = @import("../core/fen.zig");

    // R4b (2026-07-18): materialization reconstructs ancestor boards from the
    // live position (unmake/re-make) instead of eager per-make snapshots. With
    // verify_threats_incremental on, every eval in these searches (Debug builds)
    // asserts incremental == full refresh — covering single- and multi-ply dirty
    // chains, null-move plies, probcut makes, and qsearch check chains.
    eval_backend.verify_threats_incremental = true;
    defer eval_backend.verify_threats_incremental = false;

    var engine = try Engine.initWithOptions(std.testing.allocator, tt.DEFAULT_HASH_MB, .{});
    defer engine.deinit();

    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r1b1k2r/2qnbppp/p2ppn2/1p4B1/3NPPP1/2N2Q2/PPP4P/2KR1B1R w kq - 0 11",
        "8/2k5/3p4/p2P1p2/P2P1P2/8/8/4K3 w - - 0 1",
    };
    for (fens) |fen_text| {
        const pos = try fen.parse(fen_text);
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        var stop_flag = std.atomic.Value(bool).init(false);
        const result = engine.search(&pos, &history, .{ .depth = 6 }, &stop_flag);
        try std.testing.expect(result.best_move != null);
    }
}

test "lazy accumulator reconstruction matches full refresh across real searches (ZQB9 full threats)" {
    const fen = @import("../core/fen.zig");
    const nnue768 = @import("../eval/nnue768.zig");

    // Block B mirror of the test above for the v6 FULL-threats incremental path:
    // real searches over a synthetic ZQB9 net with verify_threats_incremental on,
    // so every evaluated node (Debug builds) asserts evaluateFull9Incremental ==
    // the evaluateFull9 full refresh — across single- and multi-ply dirty chains,
    // null-move plies, probcut makes, qsearch check chains, and the shared
    // bitset-state unwind/advance (incl. flip barriers) those searches produce.
    eval_backend.verify_threats_incremental = true;
    defer eval_backend.verify_threats_incremental = false;

    const allocator = std.testing.allocator;
    const blob = try nnue768.buildZqb9TestBlob(allocator);
    defer allocator.free(blob);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "zqb9-test.zqb", .data = blob });
    const net_path = try tmp.dir.realpathAlloc(allocator, "zqb9-test.zqb");
    defer allocator.free(net_path);

    var engine = try Engine.initWithOptions(allocator, tt.DEFAULT_HASH_MB, .{ .eval_file_path = net_path });
    defer engine.deinit();
    try std.testing.expect(engine.evaluator.net.?.full_threats);

    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r1b1k2r/2qnbppp/p2ppn2/1p4B1/3NPPP1/2N2Q2/PPP4P/2KR1B1R w kq - 0 11",
        "8/2k5/3p4/p2P1p2/P2P1P2/8/8/4K3 w - - 0 1", // king walks -> mirror-flip barriers
    };
    for (fens) |fen_text| {
        const pos = try fen.parse(fen_text);
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        var stop_flag = std.atomic.Value(bool).init(false);
        const result = engine.search(&pos, &history, .{ .depth = 5 }, &stop_flag);
        try std.testing.expect(result.best_move != null);
    }
}

const FailingHashTableFactory = struct {
    fail_at: usize,
    calls: usize = 0,

    fn create(self: *@This(), comptime Table: type, allocator: std.mem.Allocator, mb: u32) !Table {
        const call = self.calls;
        self.calls += 1;
        if (call == self.fail_at) return error.OutOfMemory;
        var factory = HashTableFactory{};
        return factory.create(Table, allocator, mb);
    }
};

test "hash resize failure at every preparation stage preserves live resources" {
    // Hash 1 -> 2 keeps the temporary TT and hint allocations below the huge
    // mapping threshold, so testing.allocator also detects failed-stage leaks.
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();
    engine.tt.entries[0].entries[0] = .{ .key = 17, .depth = 7, .score = 31 };
    engine.rfp_hint.entries[0].entries[0] = .{ .key = 19, .depth = 5, .score = 37 };
    engine.eval_cache.sets[0].slots[0] = 23 << 16 | 41;
    engine.history.quiet[0][0][0][0] = 43;
    engine.tt.generation = 11;
    const old_tt = engine.tt;
    const old_hint = engine.rfp_hint;
    const old_eval = engine.eval_cache;
    for (0..3) |stage| {
        var factory = FailingHashTableFactory{ .fail_at = stage };
        try std.testing.expectError(error.OutOfMemory, engine.resizeHashWithFactory(2, &factory));
        try std.testing.expectEqual(stage + 1, factory.calls);
        try std.testing.expectEqual(old_tt.entries.ptr, engine.tt.entries.ptr);
        try std.testing.expectEqual(old_tt.entries.len, engine.tt.entries.len);
        try std.testing.expectEqual(old_tt.mask, engine.tt.mask);
        try std.testing.expectEqual(old_tt.generation, engine.tt.generation);
        try std.testing.expectEqual(@as(u32, 1), engine.hashSizeMb());
        try std.testing.expectEqual(old_hint.entries.ptr, engine.rfp_hint.entries.ptr);
        try std.testing.expectEqual(old_hint.mask, engine.rfp_hint.mask);
        try std.testing.expectEqual(old_eval.sets.ptr, engine.eval_cache.sets.ptr);
        try std.testing.expectEqual(old_eval.index_shift, engine.eval_cache.index_shift);
        try std.testing.expectEqual(@as(u64, 17), engine.tt.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 19), engine.rfp_hint.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 23 << 16 | 41), engine.eval_cache.sets[0].slots[0]);
        try std.testing.expectEqual(@as(i16, 43), engine.history.quiet[0][0][0][0]);
    }
    // The original engine remains usable after all three failures.
    const pos = try @import("../core/fen.zig").startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop = std.atomic.Value(bool).init(false);
    const result = engine.search(&pos, &history, .{ .depth = 3 }, &stop);
    try std.testing.expect(result.best_move != null);
    try std.testing.expectEqual(@as(u16, 3), result.depth);
}

test "hash resize commits all tables" {
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();
    const net = engine.evaluator.net;
    const context = engine.ctx;
    for ([_]u32{ 2, 4, 1 }) |mb| {
        engine.tt.entries[0].entries[0].key = 17;
        engine.rfp_hint.entries[0].entries[0].key = 19;
        engine.eval_cache.sets[0].slots[0] = 23;
        engine.history.quiet[0][0][0][0] = 43;
        try engine.resizeHash(mb);
        try std.testing.expectEqual(mb, engine.hashSizeMb());
        try std.testing.expectEqual(hintSizeFor(mb), engine.rfp_hint.hintSizeMb());
        try std.testing.expectEqual(eval_cache_mod.sizeForHash(mb), engine.eval_cache.cacheSizeMb());
        try std.testing.expectEqual(@as(u64, 0), engine.tt.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 0), engine.rfp_hint.entries[0].entries[0].key);
        try std.testing.expectEqual(@as(u64, 0), engine.eval_cache.sets[0].slots[0]);
        try std.testing.expectEqual(@as(i16, 0), engine.history.quiet[0][0][0][0]);
        try std.testing.expectEqual(net, engine.evaluator.net);
        try std.testing.expectEqual(context, engine.ctx);
    }
}

test "private table sizes are the serial sizes at one thread and a split budget beyond" {
    // Threads = 1 is the identity on every Hash a GUI can send (bit-identical
    // single-thread search depends on it).
    var mb: u32 = 1;
    while (mb <= 65_536) : (mb += if (mb < 4_096) 1 else 61) {
        const serial = PrivateTableSizes.forThreads(mb, 1);
        try std.testing.expectEqual(hintSizeFor(mb), serial.hint_mb);
        try std.testing.expectEqual(eval_cache_mod.sizeForHash(mb), serial.eval_mb);
    }
    // CCRL-style configurations: each engine gets 1/T of the serial budget.
    const cases = [_]struct { hash: u32, threads: u32, hint: u32, eval: u32 }{
        .{ .hash = 1024, .threads = 4, .hint = 128, .eval = 16 },
        .{ .hash = 2048, .threads = 8, .hint = 128, .eval = 8 },
        .{ .hash = 256, .threads = 8, .hint = 16, .eval = 8 },
        .{ .hash = 2048, .threads = 32, .hint = 32, .eval = 4 }, // eval floor (64/32 = 2)
        .{ .hash = 16, .threads = 32, .hint = 1, .eval = 4 }, // both floors
        .{ .hash = 65_536, .threads = 2, .hint = 512, .eval = 32 },
    };
    for (cases) |c| {
        const sizes = PrivateTableSizes.forThreads(c.hash, c.threads);
        try std.testing.expectEqual(c.hint, sizes.hint_mb);
        try std.testing.expectEqual(c.eval, sizes.eval_mb);
    }
    // All private copies together never exceed the serial budget by more than
    // the per-table floors (1 MB hint + 4 MB eval per engine).
    for ([_]u32{ 1, 16, 64, 256, 1024, 2048, 4096, 65_536 }) |hash| {
        const serial = PrivateTableSizes.forThreads(hash, 1);
        for (1..33) |t| {
            const threads: u32 = @intCast(t);
            const sizes = PrivateTableSizes.forThreads(hash, threads);
            try std.testing.expect(threads * sizes.hint_mb <= serial.hint_mb + threads * rfp_hint_mod.MIN_HINT_MB);
            try std.testing.expect(threads * sizes.eval_mb <= serial.eval_mb + threads * eval_cache_mod.MIN_CACHE_MB);
        }
    }
}

test "parallel engines size their private tables from the thread share" {
    var owner = try eval_backend.EngineState.init(std.testing.allocator, .{});
    defer owner.deinit();
    var serial = try Engine.initWithBorrowedEvaluator(std.testing.allocator, 32, &owner);
    defer serial.deinit();
    try std.testing.expectEqual(@as(u32, 16), serial.rfp_hint.hintSizeMb());
    try std.testing.expectEqual(@as(u32, 8), serial.eval_cache.cacheSizeMb());
    var one = try Engine.initForParallel(std.testing.allocator, 32, 1, &owner);
    defer one.deinit();
    try std.testing.expectEqual(serial.rfp_hint.entries.len, one.rfp_hint.entries.len);
    try std.testing.expectEqual(serial.eval_cache.sets.len, one.eval_cache.sets.len);
    var quarter = try Engine.initForParallel(std.testing.allocator, 32, 4, &owner);
    defer quarter.deinit();
    try std.testing.expectEqual(@as(u32, 4), quarter.rfp_hint.hintSizeMb());
    try std.testing.expectEqual(@as(u32, 4), quarter.eval_cache.cacheSizeMb());
    try std.testing.expectEqual(serial.rfp_hint.entries.len / 4, quarter.rfp_hint.entries.len);
    try std.testing.expectEqual(@as(usize, 0), quarter.tt.entries.len);
}

test "same hash reset requires no replacement allocations" {
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();
    engine.tt.entries[0].entries[0].key = 17;
    engine.tt.generation = 11;
    engine.history.quiet[0][0][0][0] = 43;
    const ptr = engine.tt.entries.ptr;
    var factory = FailingHashTableFactory{ .fail_at = 0 };
    try engine.resizeHashWithFactory(1, &factory);
    try std.testing.expectEqual(@as(usize, 0), factory.calls);
    try std.testing.expectEqual(ptr, engine.tt.entries.ptr);
    try std.testing.expectEqual(@as(u64, 0), engine.tt.entries[0].entries[0].key);
    try std.testing.expectEqual(@as(u8, 0), engine.tt.generation);
    try std.testing.expectEqual(@as(i16, 0), engine.history.quiet[0][0][0][0]);
}

test "real allocator failure preserves the original hash allocation" {
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();
    engine.tt.entries[0].entries[0].key = 17;
    const old_entries = engine.tt.entries;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    // The 2-MB request rounds down to a 1.5-MB TT: hugealloc uses its real
    // fallback allocator, so this induces an actual allocation failure.
    engine.tt.allocator = failing.allocator();
    defer engine.tt.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, engine.resizeHash(2));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(old_entries.len, engine.tt.entries.len);
    try std.testing.expectEqual(old_entries.ptr, engine.tt.entries.ptr);
    try std.testing.expectEqual(@as(u64, 17), engine.tt.entries[0].entries[0].key);
}

fn netWeightHash(net: *const Net) u64 {
    var hash = std.hash.Wyhash.init(0);
    inline for (.{
        "feature_weights", "feature_bias", "output_weights", "output_biases",
        "psqtw",           "psqtb",        "threat_w8",      "l1_weights",
        "l1_byte_weights", "l1_blocked",   "l1_bias",        "l2_weights",
        "l2_weights_t",    "l2_bias",      "l3_weights",     "l3_bias",
    }) |field| hash.update(std.mem.sliceAsBytes(@field(net, field)));
    return hash.final();
}

const SharedNetSearchParticipant = struct {
    engine: *Engine,
    pos: position.Position,
    history: repetition.History,
    start: *runtime.ResetEvent,
    result: ?SearchResult = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        self.start.timedWait(10 * std.time.ns_per_s) catch |err| {
            self.failure = err;
            return;
        };
        var stop = std.atomic.Value(bool).init(false);
        self.result = self.engine.search(&self.pos, &self.history, .{ .depth = 5 }, &stop);
    }
};

test "shared const net searches keep mutable worker resources independent" {
    const allocator = std.testing.allocator;
    const nnue = @import("../eval/nnue768.zig");
    const fen = @import("../core/fen.zig");
    const blob = try nnue.buildZqb9TestBlob(allocator);
    defer allocator.free(blob);
    const owner = try nnue.loadFromBytes(allocator, blob);
    defer owner.destroy(allocator);
    const shared: *const Net = owner;
    const weight_hash = netWeightHash(shared);
    var engines: [4]Engine = undefined;
    var initialized: usize = 0;
    defer for (engines[0..initialized]) |*engine| engine.deinit();
    for (&engines) |*engine| {
        engine.* = try Engine.initWithSharedNet(allocator, 1, shared);
        initialized += 1;
        try std.testing.expect(engine.evaluator.owned_net == null);
        try std.testing.expect(engine.evaluator.net == shared);
    }
    var start = runtime.ResetEvent{};
    var participants: [4]SharedNetSearchParticipant = undefined;
    var expected: [4]SearchResult = undefined;
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/2pP4/1p2P3/2N2N2/PPQBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "4k3/P7/8/8/8/8/7p/4K3 w - - 0 1",
    };
    for (&participants, &engines, 0..) |*participant, *engine, i| {
        const pos = try fen.parse(fens[i]);
        var history = repetition.History{};
        history.push(pos.zobrist_key);
        participant.* = .{ .engine = engine, .pos = pos, .history = history, .start = &start };
        var stop = std.atomic.Value(bool).init(false);
        expected[i] = engine.search(&pos, &history, .{ .depth = 5 }, &stop);
        engine.reset();
        for (engines[0..i]) |*other| {
            try std.testing.expect(engine.ctx != other.ctx);
            try std.testing.expect(engine.tt.entries.ptr != other.tt.entries.ptr);
            try std.testing.expect(engine.rfp_hint.entries.ptr != other.rfp_hint.entries.ptr);
            try std.testing.expect(engine.eval_cache.sets.ptr != other.eval_cache.sets.ptr);
        }
    }
    var threads: [4]runtime.Thread = undefined;
    var started: usize = 0;
    defer {
        start.set();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&participants, 0..) |*participant, i| {
        threads[i] = try runtime.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, SharedNetSearchParticipant.run, .{participant});
        started += 1;
    }
    start.set();
    for (threads) |thread| thread.join();
    started = 0;
    for (&participants, expected) |*participant, reference| {
        if (participant.failure) |err| return err;
        const actual = participant.result orelse return error.MissingSearchResult;
        try std.testing.expectEqual(reference.best_move, actual.best_move);
        try std.testing.expectEqual(reference.score, actual.score);
        try std.testing.expectEqual(reference.depth, actual.depth);
        try std.testing.expectEqual(reference.nodes, actual.nodes);
        try std.testing.expectEqualSlices(move_mod.Move, reference.pv.slice(), actual.pv.slice());
    }
    try std.testing.expectEqual(weight_hash, netWeightHash(shared));
}

test "root outcome authority distinguishes actual loss from restricted draw" {
    try std.testing.expect(rootScoreContradicts(.draw, -27990));
    try std.testing.expect(rootScoreContradicts(.draw, 27990));
    try std.testing.expect(!rootScoreContradicts(.loss, -27990));
    try std.testing.expectEqual(@as(i32, 0), rootOutcomeScore(.draw, -27990));
    try std.testing.expect(rootOutcomeScore(.loss, 12) < -score_mod.TB_DECISIVE_THRESHOLD);
}

/// Test helper: a FEN plus UCI moves, with the game history a GUI would send.
fn replayForTest(fen_text: []const u8, moves_text: []const []const u8, pos: *position.Position, history: *repetition.History) !void {
    pos.* = try @import("../core/fen.zig").parse(fen_text);
    history.* = .{};
    history.push(pos.zobrist_key);
    for (moves_text) |text| {
        var moves = move_mod.MoveList.init();
        legal.generate(pos, &moves);
        var found: ?move_mod.Move = null;
        for (moves.slice()) |mv| {
            var buffer: [5]u8 = undefined;
            if (std.mem.eql(u8, mv.toUci(&buffer), text)) found = mv;
        }
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(pos, found orelse return error.IllegalTestMove, &state);
        history.push(pos.zobrist_key);
    }
}

fn uciText(mv: move_mod.Move, buffer: *[5]u8) []const u8 {
    return mv.toUci(buffer);
}

/// Test helper: whether playing `mv` lets the opponent claim a threefold at
/// once or with one reply (the child, or a child of it, occurs a third time).
fn claimWithinOneReply(pos: *const position.Position, history: *const repetition.History, mv: move_mod.Move) bool {
    var child = pos.*;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&child, mv, &state);
    if (history.childOccurrences(child.zobrist_key, child.halfmove_clock) >= 2) return true;
    var line = history.*;
    line.push(child.zobrist_key);
    var replies = move_mod.MoveList.init();
    legal.generate(&child, &replies);
    for (replies.slice()) |reply| {
        var grandchild = child;
        var reply_state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&grandchild, reply, &reply_state);
        if (line.childOccurrences(grandchild.zobrist_key, grandchild.halfmove_clock) >= 2) return true;
    }
    return false;
}

/// Test helper: the tables' clock-aware verdict for the side to move after `mv`.
fn tablebaseVerdictAfter(pos: *const position.Position, mv: move_mod.Move) !syzygy.Wdl {
    var child = pos.*;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&child, mv, &state);
    var job = syzygy.beginJob();
    defer job.deinit();
    const policy = job.probeRootMoves(&child, null, null) orelse return error.MissingRootTables;
    return policy.wdl;
}

test "TB root: no instant win into a threefold, no rounded boundary win, no summary overwrite" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(syzygy.init(path));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var pos: position.Position = undefined;
    var history = repetition.History{};
    var buffer: [5]u8 = undefined;

    // Audit D (U-TB-REP), both judges' legal histories: the instant TB win
    // played e1e2 / e1f1, each the third occurrence of its position. Both
    // windows hold repeated positions, so since the review round the root is
    // searched (no instant move, no authoritative score); the move must keep
    // the win and give no claim.
    const repetitions = .{
        .{ "4k3/8/8/8/8/8/3QK3/8 b - - 1 1", &[_][]const u8{ "e8f8", "d2c2", "f8e8", "c2d2", "e8f8", "e2e1", "f8e8" }, "e1e2" },
        .{ "8/8/8/8/8/8/8/R4K1k b - - 1 1", &[_][]const u8{ "h1h2", "f1e1", "h2h1", "e1f1", "h1h2", "f1e1", "h2h1" }, "e1f1" },
    };
    inline for (repetitions) |case| {
        try replayForTest(case[0], case[1], &pos, &history);
        const result = engine.search(&pos, &history, .{ .depth = 10 }, &stop);
        try std.testing.expect(!std.mem.eql(u8, uciText(result.best_move.?, &buffer), case[2]));
        try std.testing.expect(result.nodes > 1);
        try std.testing.expect(result.score > 0);
        try std.testing.expect(!claimWithinOneReply(&pos, &history, result.best_move.?));
        try std.testing.expectEqual(syzygy.Wdl.loss, try tablebaseVerdictAfter(&pos, result.best_move.?));
    }

    // Audit D (U-TB-DTZ100): at clock 97 the rounded a6a2 (r = 3) tied with the
    // exact r = 3 wins and drew; an exact win is played instead.
    try replayForTest("8/8/Q7/6p1/8/8/8/3K2k1 w - - 97 1", &.{}, &pos, &history);
    const boundary = engine.search(&pos, &history, .{ .depth = 10 }, &stop);
    try std.testing.expect(!std.mem.eql(u8, uciText(boundary.best_move.?, &buffer), "a6a2"));
    try std.testing.expectEqual(@as(u64, 1), boundary.nodes);
    try std.testing.expect(boundary.score >= score_mod.TB_DECISIVE_THRESHOLD);
    // After a6a2 Kh1 every move reaches the 50-move claim; the root summary
    // (a DTZ-1 "win") no longer overrides the moves' own states.
    try replayForTest("8/8/Q7/6p1/8/8/8/3K2k1 w - - 97 1", &.{ "a6a2", "g1h1" }, &pos, &history);
    const cursed = engine.search(&pos, &history, .{ .depth = 6 }, &stop);
    try std.testing.expectEqual(@as(i32, 0), cursed.score);
    try std.testing.expect(cursed.nodes > 1);
}

test "TB root: no instant win once the window holds a repeated position" {
    // Review round (U-TB-REP): e1f1 was played at once (child new), but Black's
    // only reply h1h2 recreates the start position a third time. e1f2 mates in 3.
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(syzygy.init(path));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var pos: position.Position = undefined;
    var history = repetition.History{};
    var buffer: [5]u8 = undefined;
    try replayForTest("8/8/8/8/8/8/7k/R4K2 w - - 1 1", &.{ "f1e1", "h2h3", "e1f1", "h3h2", "f1e1", "h2h1" }, &pos, &history);
    try std.testing.expect(claimWithinOneReply(&pos, &history, move_mod.Move.init(.e1, .f1, .quiet)));
    const result = engine.search(&pos, &history, .{ .depth = 8 }, &stop);
    try std.testing.expect(!std.mem.eql(u8, uciText(result.best_move.?, &buffer), "e1f1"));
    try std.testing.expect(result.nodes > 1);
    try std.testing.expect(result.score > 0);
    try std.testing.expect(!claimWithinOneReply(&pos, &history, result.best_move.?));
    try std.testing.expectEqual(syzygy.Wdl.loss, try tablebaseVerdictAfter(&pos, result.best_move.?));
    // Winning control: restricted to e1f2, the search finds the mate.
    var only = move_mod.MoveList.init();
    only.add(move_mod.Move.init(.e1, .f2, .quiet));
    const control = engine.searchWithRootMoves(&pos, &history, .{ .depth = 8 }, &stop, &only);
    try std.testing.expectEqual(only.moves[0], control.best_move.?);
    try std.testing.expect(score_mod.isMateLike(control.score) and control.score > 0);
}

test "TB root: an unproven boundary win keeps the searched score" {
    // Review round (U-TB-DTZ100): restricted to the rounded boundary win a6a2,
    // the root still reported 28000 although the search found the draw (after
    // a6a2 g1h1 every White move reaches the 50-move claim).
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(syzygy.init(path));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var pos: position.Position = undefined;
    var history = repetition.History{};
    try replayForTest("8/8/Q7/6p1/8/8/8/3K2k1 w - - 97 1", &.{}, &pos, &history);
    var only = move_mod.MoveList.init();
    only.add(move_mod.Move.init(.a6, .a2, .quiet));
    const searched = engine.searchWithRootMoves(&pos, &history, .{ .depth = 8 }, &stop, &only);
    try std.testing.expectEqual(only.moves[0], searched.best_move.?);
    try std.testing.expectEqual(@as(i32, 0), searched.score);
    // Early stops: the pre-iteration fallback and interrupted iterations
    // carry no TB score either.
    for ([_]u64{ 1, 2, 64, 200 }) |n| {
        const early = engine.searchWithRootMoves(&pos, &history, .{ .node_limit = n }, &stop, &only);
        try std.testing.expectEqual(only.moves[0], early.best_move.?);
        try std.testing.expect(!score_mod.isDecisive(early.score));
    }
}

test "TB root: a certain win keeps uncertain wins out of the searched set" {
    // Review round (three-way review, Astra F1): a6a5 is the certain win but
    // returns to a child seen once (no instant move); a6a2 is a rounded
    // boundary win that draws (after g1h1 no zeroing move or mate comes before
    // the claim). With both in the set the engine played a6a2 with cp 28000,
    // also at one node.
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(syzygy.init(path));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var pos: position.Position = undefined;
    var history = repetition.History{};
    var buffer: [5]u8 = undefined;
    try replayForTest("8/8/8/Q5p1/8/8/8/3K2k1 b - - 94 1", &.{ "g1h1", "a5a6", "h1g1" }, &pos, &history);
    var allowed = move_mod.MoveList.init();
    allowed.add(move_mod.Move.init(.a6, .a2, .quiet));
    allowed.add(move_mod.Move.init(.a6, .a5, .quiet));
    const searched = engine.searchWithRootMoves(&pos, &history, .{ .depth = 8 }, &stop, &allowed);
    try std.testing.expectEqualStrings("a6a5", uciText(searched.best_move.?, &buffer));
    for ([_]u64{ 1, 2, 64, 200 }) |n| {
        const early = engine.searchWithRootMoves(&pos, &history, .{ .node_limit = n }, &stop, &allowed);
        try std.testing.expectEqualStrings("a6a5", uciText(early.best_move.?, &buffer));
    }
}

test "TB root: an unproven boundary loss keeps the searched score" {
    // Review round follow-up: a2b2 has r = -6 at clock 94 (opponent DTZ 5,
    // rounded), but White needs 6 plies, so Black reaches the 50-move claim.
    // The engine played a2b2 and still reported -28000. Without the proof the
    // score is the search's own (at depth 10 the horizon hides the claim).
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(syzygy.init(path));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var pos: position.Position = undefined;
    var history = repetition.History{};
    var buffer: [5]u8 = undefined;
    try replayForTest("8/8/8/Q7/8/1p6/k6K/8 b - - 94 1", &.{}, &pos, &history);
    const searched = engine.search(&pos, &history, .{ .depth = 10 }, &stop);
    try std.testing.expectEqualStrings("a2b2", uciText(searched.best_move.?, &buffer));
    try std.testing.expect(!score_mod.isDecisive(searched.score));
    for ([_]u64{ 1, 2, 64, 200 }) |n| {
        const early = engine.search(&pos, &history, .{ .node_limit = n }, &stop);
        try std.testing.expect(!score_mod.isDecisive(early.score));
    }
}

test "NNUE Scale Percent 360: an evaluation keeps its value through a TT store and probe at other plies" {
    // Review round (S-TB-PLY, Astra judge A finding 4): this five-queen position
    // evaluated to 27,396 at scale 360; stored as a lower bound at ply 2 it
    // was written as 27,398 and read back at ply 4 as 27,394.
    const tt_store = @import("tt_store.zig");
    const tt_probe = @import("tt_probe.zig");
    var engine = try Engine.init(std.testing.allocator, 1);
    defer engine.deinit();
    engine.setNnueScalePercent(360);
    var stop = std.atomic.Value(bool).init(false);
    engine.ctx.* = .{ .repetition = .{}, .control = time.Controller.init(&stop, .{}) };
    // Both signs (the second: a sixth queen, the bare king to move, -27,939).
    const cases = .{
        .{ "7k/8/8/8/Q7/8/Q1Q1Q1Q1/K7 w - - 0 1", @as(i32, 1) },
        .{ "7k/8/8/8/Q7/8/Q1Q1Q1Q1/K1Q5 b - - 0 1", @as(i32, -1) },
    };
    inline for (cases) |case| {
        const pos = try @import("../core/fen.zig").parse(case[0]);
        engine.evaluator.prepareRoot(&engine.ctx.stack, &pos, &engine.ctx.finny, &engine.ctx.ft);
        const eval = engine.evaluator.evaluate(&engine.ctx.stack, 0, &pos, &engine.ctx.finny, &engine.ctx.ft);
        try std.testing.expectEqual(case[1] * score_mod.ORDINARY_SCORE_LIMIT, eval);
        tt_store.storeLowerBound(null, &engine.tt, pos.zobrist_key, 6, eval, null, tt.STATIC_EVAL_NONE, false, 2);
        var probe: tt_probe.Result = undefined;
        tt_probe.probeInto(&probe, engine.ctx, &engine.tt, pos.zobrist_key, 6, -30_000, 30_000, null, 0, 4);
        try std.testing.expectEqual(eval, probe.entry.?.score);
    }
}

test "drawn Horsie root cannot accept false TB loss or stop on its streak" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_ROOT_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try std.testing.expect(syzygy.init(path_z));
    defer syzygy.disable();
    var engine = try Engine.init(a, 16);
    defer engine.deinit();
    const pos = try @import("../core/fen.zig").parse("7k/6P1/7P/5N2/2r5/5K2/8/8 b - - 0 91");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop = std.atomic.Value(bool).init(false);
    const result = engine.search(&pos, &history, .{ .node_limit = 20000 }, &stop);
    try std.testing.expectEqual(@as(i32, 0), result.score);
    try std.testing.expect(result.best_move != null);
    try std.testing.expectEqual(@as(u64, 20000), engine.ctx.nodes);
    var job = syzygy.beginJob();
    defer job.deinit();
    const policy = job.probeRootMoves(&pos, null, null).?;
    try std.testing.expect(rootMoveAllowed(&policy.moves, result.best_move.?));
}
