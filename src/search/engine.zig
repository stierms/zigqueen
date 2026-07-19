const std = @import("std");
const types = @import("../core/types.zig");
const context_mod = @import("context.zig");
const eval_backend = @import("../eval/backend.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const pv = @import("pv.zig");
const repetition = @import("repetition.zig");
const rfp_hint_mod = @import("rfp_hint.zig");
const eval_cache_mod = @import("eval_cache.zig");
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

pub const MAX_TRACE: usize = 64;
const ASPIRATION_MIN_DEPTH: u16 = 3;
const ASPIRATION_START_CP: i32 = 30;

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
};

pub const SearchResult = struct {
    best_move: ?move_mod.Move = null,
    score: i32 = 0,
    depth: u16 = 0,
    seldepth: u16 = 0,
    nodes: u64 = 0,
    pv: pv.Line = .{},
    diagnostics: SearchDiagnostics = .{},
};

pub const EvalOptions = eval_backend.Options;
/// Re-exported so the CLI fallback (main.zig) shares the one source of truth.
pub const default_nnue_scale_percent = eval_backend.default_nnue_scale_percent;

pub const Engine = struct {
    tt: tt.TranspositionTable,
    rfp_hint: rfp_hint_mod.HintTable,
    /// Raw-eval memo: position-keyed cache of the exact raw static eval,
    /// sized off Hash (Hash/4, clamped [4,64] MB; 2-way). No UCI option.
    eval_cache: eval_cache_mod.EvalCache,
    history: history_mod.HistoryTable = .{},
    evaluator: eval_backend.EngineState,
    allocator: std.mem.Allocator = undefined,
    /// Heap-owned search context. The per-ply accumulator stack is ~1 MB at the
    /// 1024-wide net, too large for the call stack (overflows smaller worker /
    /// test threads), so it lives on the heap and is reset per search.
    ctx: *context_mod.SearchContext = undefined,
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
        var tt_table = try tt.TranspositionTable.init(allocator, hash_mb);
        errdefer tt_table.deinit();
        var hint_table = try rfp_hint_mod.HintTable.init(allocator, hintSizeFor(hash_mb));
        errdefer hint_table.deinit();
        var eval_cache = try eval_cache_mod.EvalCache.init(allocator, eval_cache_mod.sizeForHash(hash_mb));
        errdefer eval_cache.deinit();
        var history = history_mod.HistoryTable{};
        try history.initContinuation(allocator);
        errdefer history.deinitContinuation(allocator);
        // Correction-history tables are deliberately not allocated: with a null
        // table every corrhist read/update is a no-op (it measured as a
        // regression for this eval, whose static error is small and whose
        // pruning margins would need co-tuning with any correction term).
        const ctx = try allocator.create(context_mod.SearchContext);
        errdefer allocator.destroy(ctx);
        return .{
            .tt = tt_table,
            .rfp_hint = hint_table,
            .eval_cache = eval_cache,
            .history = history,
            .evaluator = try eval_backend.EngineState.init(allocator, eval_options),
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.evaluator.deinit();
        self.tt.deinit();
        self.rfp_hint.deinit();
        self.eval_cache.deinit();
        self.history.deinitContinuation(self.allocator);
        self.history.deinitCorrection(self.allocator);
        self.allocator.destroy(self.ctx);
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

    pub fn setSyzygyPath(self: *Engine, path: []const u8) bool {
        // TB availability changes what searches return -> cached scores stale.
        self.reset();
        if (path.len == 0) {
            syzygy.disable();
            return true;
        }
        var buf: [520]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return syzygy.init(buf[0..path.len :0]);
    }

    pub fn setContempt(self: *Engine, contempt_cp: types.Score) void {
        self.contempt_cp = contempt_cp;
        // Contempt shifts draw scores, so cached TT scores from the old setting
        // would be inconsistent with the new search.
        self.reset();
    }

    pub fn loadNnueFile(self: *Engine, path: []const u8) !void {
        try self.evaluator.loadModelFile(path);
        self.reset();
    }

    pub fn resizeHash(self: *Engine, hash_mb: u32) !void {
        try self.tt.resize(hash_mb);
        try self.rfp_hint.resize(hintSizeFor(hash_mb));
        try self.eval_cache.resize(eval_cache_mod.sizeForHash(hash_mb));
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
        return self.searchImpl(pos, root_history, limits, stop_flag);
    }

    fn searchImpl(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
    ) SearchResult {
        self.tt.newSearch();
        var working = pos.*;
        // Reset the heap-owned context (also zeroes the ~1MB accumulator stack),
        // matching the prior fresh-`.{}` behaviour exactly.
        const ctx = self.ctx;
        ctx.* = context_mod.SearchContext{
            .repetition = root_history.*,
            .control = time.Controller.init(stop_flag, limits),
            .record_static_search_outcomes = self.record_static_search_outcomes,
            .record_move_order_outcomes = self.record_move_order_outcomes,
        };
        ctx.info_emitter = self.info_emitter;
        ctx.contempt = self.contempt_cp;
        ctx.root_color = working.side_to_move;
        if (ctx.repetition.count == 0) ctx.repetition.push(working.zobrist_key);
        self.evaluator.prepareRoot(&ctx.stack, &working, &ctx.finny);

        const fallback = fallbackMove(&working, ctx.repetition.isRepetition(working.halfmove_clock), ctx.repetition.currentPreviousCycleChildKey(working.halfmove_clock));
        var best = SearchResult{ .best_move = fallback };

        if (working.halfmove_clock >= 100 or ctx.repetition.isClaimableCurrentRepetition(working.halfmove_clock)) {
            best.score = 0;
            return best;
        }


        const max_depth = limits.depth orelse 64;
        var previous_trace: ?IterationTrace = null;
        var previous_root_hints: ?root.RootMoveHints = null;
        var stable_iteration_streak: u8 = 0;
        var depth: u16 = 1;
        search_loop: while (depth <= max_depth) : (depth += 1) {
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

            while (true) {
                const reused_root_hints = if (previous_root_hints) |*hints| hints else null;
                var iteration_timer = std.time.Timer.start() catch null;
                iteration = root.searchDepthWindow(
                    ctx,
                    .{ .tt = &self.tt, .rfp_hint = &self.rfp_hint, .eval_cache = &self.eval_cache, .history = &self.history, .evaluator = &self.evaluator },
                    &working,
                    depth,
                    alpha,
                    beta,
                    reused_root_hints,
                );
                iteration_elapsed_ns = if (iteration_timer) |*timer|
                    @max(@as(i128, std.time.ns_per_ms), @as(i128, @intCast(timer.read())))
                else
                    std.time.ns_per_ms;
                if (ctx.stopped) break :search_loop;
                if (!shouldResearchAspiration(guess, alpha, beta, iteration.score)) break;
                if (iteration.score <= alpha) {
                    ctx.noteAspirationFailLow();
                } else {
                    ctx.noteAspirationFailHigh();
                }
                if (ctx.info_emitter) |emitter| {
                    emitter.emit(.{ .iteration = .{
                        .depth = depth,
                        .seldepth = ctx.seldepth,
                        .score = iteration.score,
                        .bound = if (iteration.score <= alpha) .upper else .lower,
                        .nodes = ctx.nodes,
                        .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
                        .hashfull = self.hashfullPermille(),
                        .best_move = iteration.best_move,
                        .pv = &[_]move_mod.Move{},
                    } });
                }
                ctx.noteAspirationResearch();
                widenAspirationWindow(guess.?, &alpha, &beta, &delta, iteration.score);
            }

            best.best_move = iteration.best_move orelse fallback;
            best.score = iteration.score;
            best.depth = iteration.depth;
            best.seldepth = ctx.seldepth;
            best.nodes = ctx.nodes;
            pv.reconstructFromRootMoveLimited(&working, &ctx.repetition, &self.tt, best.best_move, &best.pv, pv.DEFAULT_ENGINE_PV_LIMIT);

            const current_trace = IterationTrace{
                .depth = iteration.depth,
                .seldepth = ctx.seldepth,
                .score = iteration.score,
                .nodes = ctx.nodes,
                .best_move = best.best_move,
                .pv = best.pv,
                .root_order = iteration.root_order,
            };

            if (best.diagnostics.trace_len < best.diagnostics.trace.len) {
                best.diagnostics.trace[best.diagnostics.trace_len] = current_trace;
                best.diagnostics.trace_len += 1;
            }
            stable_iteration_streak = nextStableIterationStreak(stable_iteration_streak, previous_trace, current_trace);
            best.diagnostics.last_iteration_elapsed_ns = @intCast(@max(iteration_elapsed_ns, 0));
            best.diagnostics.projected_next_iteration_ns = @intCast(@max(estimateNextIterationNs(iteration_elapsed_ns), 0));
            best.diagnostics.stable_iteration_streak = stable_iteration_streak;

            if (ctx.info_emitter) |emitter| {
                emitter.emit(.{ .iteration = .{
                    .depth = best.depth,
                    .seldepth = best.seldepth,
                    .score = best.score,
                    .bound = .exact,
                    .nodes = best.nodes,
                    .time_ms = ctx.control.elapsedNs() / std.time.ns_per_ms,
                    .hashfull = self.hashfullPermille(),
                    .best_move = best.best_move,
                    .pv = best.pv.slice(),
                } });
            }

            if (iterationStopReasonWithElapsed(ctx.control.limits, previous_trace, current_trace, @as(i128, ctx.control.elapsedNs()), iteration_elapsed_ns)) |reason| {
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
        best.diagnostics.stats = ctx.stats;
        return best;
    }
};

fn hintSizeFor(hash_mb: u32) u32 {
    const half = hash_mb / 2;
    if (half < rfp_hint_mod.MIN_HINT_MB) return rfp_hint_mod.MIN_HINT_MB;
    if (half > rfp_hint_mod.MAX_HINT_MB) return rfp_hint_mod.MAX_HINT_MB;
    return half;
}

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

fn widenAspirationWindow(guess: i32, alpha: *i32, beta: *i32, delta: *i32, score: i32) void {
    delta.* = @min(qsearch.INF, delta.* * 2);
    if (score <= alpha.*) {
        alpha.* = @max(-qsearch.INF, guess - delta.*);
        return;
    }
    beta.* = @min(qsearch.INF, guess + delta.*);
}

fn fallbackMove(pos: *const position.Position, prefer_repetition_safe: bool, cycle_child_key: ?u64) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    if (moves.count == 0) return null;

    if (cycle_child_key) |key| {
        for (moves.slice()) |mv| {
            if (moveReachesKey(pos, mv, key)) return mv;
        }
    }

    if (prefer_repetition_safe) {
        for (moves.slice()) |mv| {
            if (isRepetitionSafeFallback(pos, mv)) return mv;
        }
    }

    return moves.slice()[0];
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
    const projected_elapsed_ns = projectedElapsedNs(elapsed_ns, iteration_elapsed_ns);
    if (budgetStopReason(elapsed_ns, projected_elapsed_ns, limits.maximum_budget_ns, .maximum_elapsed, .maximum_projected)) |reason| return reason;
    if (!isStableIteration(previous, current)) return null;
    return budgetStopReason(elapsed_ns, projected_elapsed_ns, limits.optimum_budget_ns, .optimum_elapsed, .optimum_projected);
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

fn isStableIteration(previous: ?IterationTrace, current: IterationTrace) bool {
    const prior = previous orelse return true;
    if (prior.best_move != current.best_move) return false;

    const delta = current.score - prior.score;
    return delta < 80 and delta > -80;
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

test "no budgets means no iteration stop signal" {
    const current = IterationTrace{ .score = 10, .best_move = move_mod.Move.init(.e2, .e4, .double_push) };
    try std.testing.expect(!shouldStopAfterIterationWithElapsed(.{}, null, current, 10 * std.time.ns_per_ms, 10 * std.time.ns_per_ms));
}

test "engine search returns a legal searched move (no opening book)" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("r1bqkb1r/1ppp1ppp/p1n2n2/4p3/B3P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 2 5");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const raw = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expect(raw.best_move != null);
    try std.testing.expect(raw.nodes > 1);
    try std.testing.expect(pv.isLegal(&pos, &history, &raw.pv));
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
    try std.testing.expectEqual(move_mod.Move.init(.c5, .c6, .quiet), fallbackMove(&pos, false, null).?);

    const safe = fallbackMove(&pos, true, null).?;
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

    const limits = (time.GoLimits{ .movetime_ms = 20 }).toControllerLimits(.white, time.DEFAULT_MOVE_OVERHEAD_MS);
    const result = engine.search(&pos, &history, limits, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
}

test "lazy accumulator reconstruction matches full refresh across real searches" {
    const fen = @import("../core/fen.zig");

    // Materialization reconstructs ancestor boards from the
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
