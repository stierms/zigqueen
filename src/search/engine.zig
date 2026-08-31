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
const opening_book = @import("opening_book.zig");
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
pub const default_nnue_scale_percent = eval_backend.builtin_nnue_scale_percent;

pub const OpeningBookPolicy = enum {
    use_book,
    skip_book,
};

pub const Engine = struct {
    tt: tt.TranspositionTable,
    rfp_hint: rfp_hint_mod.HintTable,
    /// Raw-eval memo (perf-r11): position-keyed cache of the exact raw static
    /// eval, sized off Hash (Hash/4, clamped [4,64] MB; 2-way since perf-r12).
    /// No UCI option.
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
        // Correction history is PARKED (tables not allocated -> corrhist reads/updates
        // are no-ops, play is identical to v4.0.3): v1 (+/-72cp, qsearch read) self-SPRT
        // -17.4 +/-13.2; v2 (+/-32cp, main-search only) -3.5 +/-7.4 = flat. Hypothesis:
        // the PSQT-anchored eval has little systematic error to correct, and the pruning
        // margins want CO-TUNING with the correction (the deferred SPSA campaign).
        // Revive by uncommenting when SPSA can co-tune the constants:
        // try history.initCorrection(allocator);
        // errdefer history.deinitCorrection(allocator);
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
        return self.searchWithOpeningBookPolicy(pos, root_history, limits, stop_flag, .use_book);
    }

    pub fn searchRawNoBook(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
    ) SearchResult {
        return self.searchWithOpeningBookPolicy(pos, root_history, limits, stop_flag, .skip_book);
    }

    fn searchWithOpeningBookPolicy(
        self: *Engine,
        pos: *const position.Position,
        root_history: *const repetition.History,
        limits: time.Limits,
        stop_flag: *const std.atomic.Value(bool),
        opening_book_policy: OpeningBookPolicy,
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
        self.evaluator.prepareRoot(&ctx.stack, &working, &ctx.finny, &ctx.ft);

        const fallback = fallbackMove(&working, ctx.repetition.isRepetition(working.halfmove_clock), ctx.repetition.currentPreviousCycleChildKey(working.halfmove_clock));
        var best = SearchResult{ .best_move = fallback };

        if (working.halfmove_clock >= 100 or ctx.repetition.isClaimableCurrentRepetition(working.halfmove_clock)) {
            best.score = 0;
            return best;
        }

        // Root DTZ probe (rule-50-aware): in a TB-covered WINNING root, play
        // Fathom's DTZ-optimal move directly — search cannot outplay the table,
        // and pawnless wins (KBN vs K et al.) are invisible to the in-search
        // WDL probe (no zeroing move ever resets the clock, so its rule-50
        // gate never opens; measured live: 50 shuffled moves, drawn win).
        // Draws/losses fall through to the normal search: against imperfect
        // opposition the search keeps practical winning/swindle chances that
        // "any TB-optimal move" would forfeit.
        if (syzygy.probeRoot(&working)) |tbv| {
            if (tbv.win) {
                if (matchLegalMove(&working, tbv)) |mv| {
                    best.best_move = mv;
                    best.score = syzygy.TB_WIN_SCORE - @as(types.Score, @intCast(@min(tbv.dtz, 1000)));
                    best.depth = 1;
                    best.seldepth = 1;
                    best.nodes = 1;
                    best.pv.push(mv);
                    best.diagnostics.stats = ctx.stats;
                    return best;
                }
            }
        }

        if (opening_book_policy == .use_book) {
            if (opening_book.findRootMove(&working)) |book_move| {
                best.best_move = book_move;
                best.score = self.evaluator.evaluate(&ctx.stack, 0, &working, &ctx.finny, &ctx.ft);
                best.depth = 1;
                best.seldepth = 1;
                best.nodes = 1;
                best.pv.push(book_move);
                best.diagnostics.stats = ctx.stats;
                return best;
            }
        }

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

            // Retain the last genuinely searched iteration as the result. Once
            // its finite-search decision is eligible for reuse, end ID cleanly
            // instead of fabricating deeper iterations with frozen counters.
            if (shouldStopOnTablebaseDecision(ctx.control.limits, tb_decision_streak, previous_trace)) break;

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
                // Only a direction-matching decisive bound proves the WDL:
                // fail-low can prove a loss, and fail-high can prove a win.
                if (isTablebaseWdlProof(alpha, beta, iteration.score)) break;
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
            tb_decision_streak = nextTablebaseDecisionStreak(tb_decision_streak, previous_trace, current_trace);
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
                    .hashfull = self.hashfullPermille(),
                    .best_move = best.best_move,
                    .pv = best.pv.slice(),
                } });
            }

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

            if (iterationStopReasonWithPolicy(ctx.control.limits, previous_trace, current_trace, @as(i128, ctx.control.elapsedNs()), iteration_elapsed_ns, soft_policy)) |reason| {
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
        // Depth 64 is the engine's structural ID ceiling, not permission for
        // `go infinite` to emit bestmove. If it is ever reached, remain in the
        // search until the GUI sends `stop`.
        if (ctx.control.limits.infinite and !stop_flag.load(.acquire)) {
            while (!stop_flag.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
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

fn isTablebaseWdlProof(alpha: i32, beta: i32, score: i32) bool {
    if (!score_mod.isTablebaseDecisive(score)) return false;
    return (score <= alpha and score <= -score_mod.TB_DECISIVE_THRESHOLD) or
        (score >= beta and score >= score_mod.TB_DECISIVE_THRESHOLD);
}

fn widenAspirationWindow(guess: i32, alpha: *i32, beta: *i32, delta: *i32, score: i32) void {
    delta.* = @min(qsearch.INF, delta.* * 2);
    if (score <= alpha.*) {
        alpha.* = @max(-qsearch.INF, guess - delta.*);
        return;
    }
    beta.* = @min(qsearch.INF, guess + delta.*);
}

/// Find the legal move matching a Fathom root-probe verdict (from/to squares
/// plus promotion piece). Null if no legal move matches — the caller then
/// falls through to the normal search rather than trusting the probe.
fn matchLegalMove(pos: *const position.Position, tbv: syzygy.RootVerdict) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        if (mv.from.index() != tbv.from or mv.to.index() != tbv.to) continue;
        const want_promo: ?piece.PieceType = switch (tbv.promo) {
            1 => .queen,
            2 => .rook,
            3 => .bishop,
            4 => .knight,
            else => null,
        };
        const have_promo = mv.promotionPieceType();
        if ((want_promo == null) != (have_promo == null)) continue;
        if (want_promo) |wp| {
            if (have_promo.? != wp) continue;
        }
        return mv;
    }
    return null;
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
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return;
    defer std.testing.allocator.free(path);

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();
    try std.testing.expect(engine.setSyzygyPath(path));
    defer _ = engine.setSyzygyPath("");

    const pos = try fen.parse("k7/8/1P6/K7/p1P5/1p4Q1/8/8 w - - 2 40");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);
    const result = engine.searchRawNoBook(&pos, &history, .{ .depth = 14 }, &stop_flag);

    var saw_tb_decision = false;
    for (result.diagnostics.trace[0..result.diagnostics.trace_len]) |trace| {
        if (score_mod.isTablebaseDecisive(trace.score)) saw_tb_decision = true;
    }
    try std.testing.expect(saw_tb_decision);
    try std.testing.expect(score_mod.isMateLike(result.score));
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

test "engine opening book policy preserves default and enables raw no-book search" {
    const fen = @import("../core/fen.zig");

    var engine = try Engine.init(std.testing.allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();

    const pos = try fen.parse("r1bqkb1r/1ppp1ppp/p1n2n2/4p3/B3P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 2 5");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const booked = engine.search(&pos, &history, .{ .depth = 2 }, &stop_flag);
    try std.testing.expectEqual(move_mod.Move.init(.e1, .g1, .castle), booked.best_move.?);
    try std.testing.expectEqual(@as(u16, 1), booked.depth);
    try std.testing.expectEqual(@as(u64, 1), booked.nodes);

    const raw = engine.searchRawNoBook(&pos, &history, .{ .depth = 2 }, &stop_flag);
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

    const limits = (time.GoLimits{ .movetime_ms = 20 }).toControllerLimits(.white, time.DEFAULT_MOVE_OVERHEAD_MS, 1);
    const result = engine.search(&pos, &history, limits, &stop_flag);
    try std.testing.expect(result.best_move != null);
    try std.testing.expect(result.depth >= 1);
    try std.testing.expect(result.nodes > 0);
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
