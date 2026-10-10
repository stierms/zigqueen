const std = @import("std");
const context_mod = @import("context.zig");
const eval_cache_mod = @import("eval_cache.zig");
const phase = @import("../eval/phase.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const ordering = @import("ordering.zig");
const piece_values = @import("../core/piece_values.zig");
const ply_limit = @import("ply_limit.zig");
const position = @import("../core/position.zig");
const rule50 = @import("rule50.zig");
const score_mod = @import("score.zig");
const see = @import("see.zig");
const shallow_arms = @import("shallow_arms.zig");
const tt_mod = @import("tt.zig");
const tt_probe = @import("tt_probe.zig");
const tt_store = @import("tt_store.zig");
const types = @import("../core/types.zig");
const build_options = @import("build_options");
const basin = @import("basin.zig");
const fail_soft = @import("fail_soft.zig");
/// Quiescence fail lows (-Dqs-fail-low-margin, default 200): outside check a
/// fail low returns min(alpha, max(best, stand-pat + M)), so it reports a value
/// below alpha only beyond what a quiet move is taken to gain. Fully soft values
/// were confirmed 68.8% against 90.1% for alpha (A3b); the margin form 89.5%
/// against 97.6% on its soft returns (bundle R1m). Hard fail lows everywhere
/// left 76% of correction-history events pinned. Fail-hard builds ignore it.
const QS_FAIL_LOW_MARGIN: types.Score = if (fail_soft.ENABLED) build_options.qs_fail_low_margin else 0;
/// Correct the quiescence stand-pat with correction history (-Dcorr-qsearch).
const corr_qsearch: bool = build_options.corr_qsearch;

const DELTA_MARGIN: types.Score = 200;
const LATE_ENDGAME_PHASE_256: u16 = 200;

pub const MATE_SCORE: types.Score = score_mod.MATE_SCORE;
pub const INF: types.Score = 30_000;

pub fn search(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    alpha_in: types.Score,
    beta: types.Score,
    ply: usize,
    in_check_hint: ?bool,
) types.Score {
    return searchDepth(ctx, resources, pos, alpha_in, beta, ply, 0, in_check_hint, false);
}

/// Enter qsearch through a transparent depth-0 negamax wrapper. Qsearch still
/// owns the position's one node count and stop/draw gate; only a position that
/// passes that gate records a removed legacy duplicate count.
pub fn searchFromHorizon(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    alpha_in: types.Score,
    beta: types.Score,
    ply: usize,
    in_check_hint: ?bool,
) align(64) types.Score { // align(64): pins hot entry placement (layout stability, not call speed)
    return searchDepth(ctx, resources, pos, alpha_in, beta, ply, 0, in_check_hint, true);
}

fn searchDepth(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    alpha_in: types.Score,
    beta: types.Score,
    ply: usize,
    qs_depth: u8,
    in_check_hint: ?bool,
    comptime from_horizon: bool,
) align(64) types.Score { // align(64): pins hot entry placement (layout stability, not call speed)
    if (if (comptime @hasField(@TypeOf(resources), "execution")) resources.execution.noteNode(ctx, true) else ctx.noteQNode()) return 0;
    ctx.observePly(ply);
    if (pos.halfmove_clock >= 100) return rule50.interiorScore(ctx, pos, ply, in_check_hint);
    if (ctx.repetition.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock)) return ctx.drawScore(pos.side_to_move);
    if (from_horizon) ctx.noteHorizonTransition();
    if (ply_limit.fallback(ctx, resources.evaluator, pos, ply, in_check_hint)) |score| return score;

    const alpha_orig = alpha_in;
    // Out-pointer probe — same store-forward-stall fix as negamax (see the
    // probeInto doc comment in tt_probe.zig).
    var probe: tt_probe.Result = undefined;
    tt_probe.probeInto(&probe, ctx, resources.tt, pos.zobrist_key, 0, alpha_in, beta, null);
    // Pointer into the local `probe`, not a second copy — the by-value reload
    // was a failed store-to-load forward (wide load over the narrower stores
    // that built the Result); same fix as negamax. Value semantics unchanged.
    const tt_entry: ?*const tt_mod.Entry = if (probe.entry) |*entry| entry else null;
    if (probe.cutoff) |score| return score;
    // The hash move, when this node searches it, goes first: start its
    // child's TT and eval-cache misses now, under the stand-pat eval. The key
    // is a prefetch hint only (make_unmake.prefetchKeyAfter).
    if (tt_entry) |entry| {
        if (tt_mod.moveFromEntry(entry.*)) |hash_move| {
            const hinted_key = make_unmake.prefetchKeyAfter(pos, hash_move);
            resources.tt.prefetch(hinted_key);
            resources.eval_cache.prefetch(hinted_key);
        }
    }
    // AFTER the TT cutoff: a cutoff returns without ever consulting in_check,
    // so computing it first wasted a full attack query on every TT-cutoff
    // qnode (probe + isInCheck were the two entry-path hot spots).
    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    var alpha = probe.alpha;
    const beta_local = probe.beta;

    var stand_pat: ?types.Score = null;
    // TT slots keep the RAW static eval; `stand_pat` is the value the node
    // decides on (corrected when -Dcorr-qsearch, raw otherwise).
    var raw_stand_pat: ?types.Score = null;
    if (!in_check) {
        // Stand-pat correction is a build option (bundle step 2): without it
        // quiescence decides on the raw eval, as it always has.
        // Lever 1: reuse the TT-cached raw static eval (identical to recomputing).
        // perf-r11: then the dedicated raw-eval cache (full-key verified; a hit
        // skips the NNUE forward AND the lazy-accumulator materialization,
        // exactly like the TT-eval path). See root.zig's twin block.
        const eval_score = blk: {
            if (tt_entry) |entry| {
                if (entry.static_eval != tt_mod.STATIC_EVAL_NONE) break :blk @as(types.Score, entry.static_eval);
            }
            if (resources.eval_cache.probe(pos.zobrist_key)) |cached| {
                ctx.noteQsearchEvalCacheProbe(true);
                break :blk @as(types.Score, cached);
            }
            ctx.noteQsearchEvalCacheProbe(false);
            const fresh = resources.evaluator.evaluate(&ctx.stack, ply, pos, &ctx.finny, &ctx.ft);
            if (std.math.cast(i16, fresh)) |memo| resources.eval_cache.store(pos.zobrist_key, memo);
            break :blk fresh;
        };
        raw_stand_pat = eval_score;
        const decided: types.Score = if (comptime corr_qsearch) blk: {
            const params: *const basin.Params = if (comptime build_options.tuning) &ctx.basin_config.params else &basin.defaults;
            break :blk resources.history.correctedEval(pos, eval_score, .{}, params);
        } else eval_score;
        stand_pat = decided;
        if (decided >= beta_local) {
            ctx.noteQsearchStandPatCutoff();
            const softness = if (comptime build_options.tuning) ctx.basin_config.params.standpat_softness else basin.defaults.standpat_softness;
            const value = fail_soft.evalCutoff(beta_local, decided, softness);
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
            return value;
        }
    }

    const tt_quiet_move = selectTtQuietMove(pos, tt_entry, alpha_in, beta, in_check, shallow_arms.qsearchTtQuietEnabled());

    var moves = move_mod.MoveList.init();
    if (in_check) {
        legal.generateHinted(pos, &moves, true);
    } else {
        legal.generateCapturesAndPromotionsHinted(pos, &moves, false);
        if (ctx.recordMoveOrder()) ctx.noteQsearchTacticalList(moves.count);
    }
    if (moves.count == 0 and tt_quiet_move == null) {
        if (in_check) return -MATE_SCORE + @as(types.Score, @intCast(ply));
        if (stand_pat) |static_eval| {
            const best_static = if (comptime QS_FAIL_LOW_MARGIN > 0)
                (if (static_eval > alpha) static_eval else failLowValue(alpha, static_eval, static_eval))
            else
                @max(alpha, static_eval);
            tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, best_static, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
            return best_static;
        }
        return alpha;
    }

    const delta_prune = shouldDeltaPruneNode(pos, stand_pat, alpha, in_check, &moves);
    if (tt_quiet_move == null and delta_prune) {
        return alpha;
    }
    if (stand_pat) |static_eval| {
        if (static_eval > alpha) alpha = static_eval;
    }

    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    var capture_see_scores: [move_mod.MAX_MOVES]i32 = undefined;
    const tt_move = if (tt_entry) |entry| tt_mod.moveFromEntry(entry.*) else null;
    if (in_check) {
        // Qsearch evasions: no continuation history (qsearch doesn't maintain the
        // predecessor stack and never updates conthist).
        const cont = @import("history.zig").ContContext{};
        ordering.scoreMoves(pos, &moves, tt_move, .{}, null, resources.history, &cont, @import("../movegen/attacks.zig").attackedSquares(pos, pos.side_to_move.other()), &scores, &capture_see_scores);
    } else {
        ordering.scoreTacticalMoves(pos, &moves, tt_move, &scores, &capture_see_scores);
    }

    // best starts at alpha: a capture-only value below alpha is not a bound
    // on the position (a quiet move overturned it in 31% of A3b's sampled
    // cases). The margin form (failLowValue) reports below alpha only beyond
    // stand-pat + QS_FAIL_LOW_MARGIN; fail-high cutoffs above are soft.
    var best: types.Score = alpha;
    // The best score including those below alpha (stand-pat included), for the
    // margin form of a fail low.
    var soft_best: types.Score = stand_pat orelse -INF;
    var best_move: ?move_mod.Move = null;
    if (tt_quiet_move) |mv| {
        const entry = ctx.stack.entry(ply);
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key);
        resources.eval_cache.prefetch(child_key);
        ctx.repetition.push(child_key);
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null, false);
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);

        if (ctx.stopped) return 0;
        if (score >= beta_local) {
            ctx.noteBetaCutoff(0);
            const value = if (comptime fail_soft.ENABLED) score else beta_local;
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
            return value;
        }
        if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, score);
        if (score > best) {
            best = score;
            best_move = mv;
        }
        // The arm delays the old node-level delta cutoff just long enough to
        // search the TT-backed quiet. The tactical tail remains pruned exactly
        // when it was before the arm.
        if (delta_prune) return best;
    }
    var move_picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    // Pick-ahead (same identity argument as negamax's): once a move has been
    // searched without a cutoff, the next pick is made before the current
    // child, and a child that will be searched gets its TT and eval-cache
    // misses started under the current one.
    var lookahead_ready = false;
    var searched_moves: usize = @intFromBool(tt_quiet_move != null);
    for (0..moves.count) |index| {
        const mv = if (lookahead_ready) moves.moves[index] else move_picker.next(index);
        lookahead_ready = false;
        const capture_see_score = move_picker.captureSee(index);
        const flag = @intFromEnum(mv.flag);
        const is_promotion = flag >= @intFromEnum(move_mod.MoveFlag.promo_knight);
        const is_capture = flag == @intFromEnum(move_mod.MoveFlag.capture) or
            flag == @intFromEnum(move_mod.MoveFlag.en_passant) or
            flag >= @intFromEnum(move_mod.MoveFlag.promo_knight_capture);
        if (!in_check and !is_capture and !is_promotion) continue;
        if (!in_check and is_capture and !is_promotion and capture_see_score < 0) {
            ctx.noteQsearchBadCaptureSkip();
            continue;
        }

        const entry = ctx.stack.entry(ply);
        if (searched_moves >= 1 and index + 1 < moves.count) {
            const upcoming = move_picker.next(index + 1);
            lookahead_ready = true;
            const upcoming_flag = @intFromEnum(upcoming.flag);
            const upcoming_searched = in_check or upcoming_flag >= @intFromEnum(move_mod.MoveFlag.promo_knight) or
                ((upcoming_flag == @intFromEnum(move_mod.MoveFlag.capture) or upcoming_flag == @intFromEnum(move_mod.MoveFlag.en_passant)) and
                    move_picker.captureSee(index + 1) >= 0);
            if (upcoming_searched) {
                const hinted_key = make_unmake.prefetchKeyAfter(pos, upcoming);
                resources.tt.prefetch(hinted_key);
                resources.eval_cache.prefetch(hinted_key);
            }
        }
        searched_moves += 1;
        // Returned key = register value; avoids reloading the zobrist store
        // makeMove just issued (see makeMove's doc comment).
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key); // overlap the child's TT miss with the work below
        resources.eval_cache.prefetch(child_key); // and the eval-cache set (probed on a TT eval miss)
        ctx.repetition.push(child_key);
        // Lazy accumulator: record the move only — boards/undo-state are
        // reconstructed at materialization time from the live position.
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null, false);
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);

        if (ctx.stopped) return 0;
        if (score >= beta_local) {
            const move_index = index + @intFromBool(tt_quiet_move != null);
            ctx.noteBetaCutoff(move_index);
            if (is_capture and !is_promotion) ctx.noteCaptureCutoff(move_index, capture_see_score, true);
            const value = if (comptime fail_soft.ENABLED) score else beta_local;
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
            return value;
        }
        if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, score);
        if (score > best) {
            best = score;
            best_move = mv;
        }
    }

    // Quiet checks at the FIRST quiescence ply only (SEE-gated): the horizon was
    // check-blind — captures/promotions alone cannot see one-move mating or
    // perpetual threats. Direct checks only; recursion answers them as evasions.
    if (!in_check and qs_depth == 0 and !ctx.stopped) {
        // Reuse the tactical list's storage: it is dead once the capture loop
        // above ends, and the generator clears the list before appending, so
        // the check list is the same moves in the same order. A second
        // MAX_MOVES list in this frame pushed the Windows x64 AVX2 frame past
        // 4 KB, which costs a ___chkstk_ms probe on every qsearch call.
        legal.generateQuietChecksHinted(pos, &moves, false);
        for (moves.slice()) |mv| {
            if (tt_quiet_move) |searched| {
                if (mv == searched) continue;
            }
            if (see.quietBelow(pos, mv, 0)) continue;
            const entry = ctx.stack.entry(ply);
            const child_key = make_unmake.makeMove(pos, mv, &entry.state);
            resources.tt.prefetch(child_key);
            resources.eval_cache.prefetch(child_key);
            ctx.repetition.push(child_key);
            resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
            const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null, false);
            ctx.repetition.pop();
            make_unmake.unmakeMove(pos, mv, &entry.state);
            if (ctx.stopped) return 0;
            if (score >= beta_local) {
                const value = if (comptime fail_soft.ENABLED) score else beta_local;
                tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
                return value;
            }
            if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, score);
            if (score > best) {
                best = score;
                best_move = mv;
            }
        }
    }

    // A fail low (best stayed at alpha) outside check may report less than
    // alpha in the margin form; in check every evasion was searched and the
    // value stays hard like the rest.
    const value = if (comptime QS_FAIL_LOW_MARGIN > 0)
        (if (best <= alpha_orig and !in_check and stand_pat != null) failLowValue(alpha_orig, stand_pat.?, soft_best) else best)
    else
        best;
    tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, value, best_move, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1);
    return value;
}

/// Margin form of a quiescence fail low: below alpha only by what the
/// position is short of alpha beyond QS_FAIL_LOW_MARGIN over the stand-pat.
inline fn failLowValue(alpha: types.Score, stand_pat: types.Score, soft_best: types.Score) types.Score {
    return @min(alpha, @max(soft_best, stand_pat + QS_FAIL_LOW_MARGIN));
}

fn selectTtQuietMove(
    pos: *const position.Position,
    tt_entry: ?*const tt_mod.Entry,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    enabled: bool,
) ?move_mod.Move {
    if (!enabled) return null;
    const entry = tt_entry orelse return null;
    const candidate = tt_mod.moveFromEntry(entry.*) orelse return null;
    const is_quiet = !candidate.isCapture() and !candidate.isPromotion();
    const pv_node = beta - alpha > 1;
    const is_legal = is_quiet and legal.isLegalMoveHinted(pos, candidate, in_check);
    if (!shallow_arms.qsearchTtQuietAllowedWith(true, pv_node, in_check, entry.bound == .upper, is_quiet, is_legal)) return null;
    return candidate;
}

fn shouldDeltaPruneNode(
    pos: *const position.Position,
    stand_pat: ?types.Score,
    alpha: types.Score,
    in_check: bool,
    moves: *const move_mod.MoveList,
) bool {
    if (in_check) return false;
    const static_eval = stand_pat orelse return false;
    if (score_mod.isMateLike(alpha)) return false;
    if (phase.phase256(pos) >= LATE_ENDGAME_PHASE_256) return false;

    var big_delta: types.Score = piece_values.value(.queen) + DELTA_MARGIN;
    for (moves.slice()) |mv| {
        if (@intFromEnum(mv.flag) >= @intFromEnum(move_mod.MoveFlag.promo_knight)) {
            big_delta += piece_values.value(.queen) - piece_values.value(.pawn);
            break;
        }
    }

    return static_eval < alpha - big_delta;
}

test "qsearch delta pruning triggers in obviously hopeless middlegame nodes" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("r3k2r/ppp2ppp/2n5/3p4/4Q3/8/PPPP1PPP/R3K2R w KQkq - 0 1");
    var moves = move_mod.MoveList.init();
    legal.generate(&pos, &moves);

    try @import("std").testing.expect(shouldDeltaPruneNode(&pos, 0, 1500, false, &moves));
}

test "qsearch TT quiet selector accepts one legal lower-bound quiet only when armed" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    const quiet = move_mod.Move.init(.e2, .e4, .double_push);
    var entry = tt_mod.Entry{ .move_bits = @bitCast(quiet), .bound = .lower };

    try std.testing.expect(selectTtQuietMove(&pos, &entry, 0, 1, false, false) == null);
    try std.testing.expectEqual(quiet, selectTtQuietMove(&pos, &entry, 0, 1, false, true).?);
    entry.bound = .upper;
    try std.testing.expect(selectTtQuietMove(&pos, &entry, 0, 1, false, true) == null);
}

test "qsearch delta pruning stays off in late endgames" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("7k/8/8/3p4/4Q3/8/4K3/8 w - - 0 1");
    var moves = move_mod.MoveList.init();
    legal.generate(&pos, &moves);

    try @import("std").testing.expect(!shouldDeltaPruneNode(&pos, 0, 1500, false, &moves));
}

test "qsearch handles in-check nodes by generating evasions" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint.HintTable.init(std.testing.allocator, rfp_hint.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1");
    context.repetition.push(pos.zobrist_key);

    const score = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expect(score > -MATE_SCORE / 2);
}

test "qsearch stores shallow tt best move when tactical move exists" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint.HintTable.init(std.testing.allocator, rfp_hint.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    // Free queen capture (exd5): an unambiguous tactical move that beats stand-pat
    // for any eval net, so qsearch always stores a best move here.
    var pos = try fen.parse("4k3/8/8/3q4/4P3/8/4K3/8 w - - 0 1");
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);

    _ = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expect(table.bestMove(pos.zobrist_key) != null);
}

test "qsearch caps a deep repetition-free capture line before stack overflow" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
    };
    var history_table = history.HistoryTable{};
    // The test targets recursion/stack bounds; a model-less backend makes every
    // nonterminal cap fallback exactly zero without needing a synthetic 123-ply
    // accumulator path.
    var evaluator = @import("../eval/backend.zig").EngineState{ .allocator = std.testing.allocator };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint.HintTable.init(std.testing.allocator, rfp_hint.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    // The natural qsearch line e4xd5 e6xd5 Nc3xd5 Nf6xd5 Qd1xd5 is
    // repetition-free and would reach ply 128 when qsearch starts at ply 123.
    var pos = try fen.parse("6k1/8/4pn2/3p4/4P3/2N5/8/3Q2K1 w - - 0 1");
    context.repetition.push(pos.zobrist_key);

    const start_ply = ply_limit.START - 1;
    _ = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, start_ply, null);
    try std.testing.expect(!context.stopped);
    try std.testing.expectEqual(@as(u16, @intCast(ply_limit.START)), context.seldepth);
}
