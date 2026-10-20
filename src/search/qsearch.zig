const std = @import("std");
const context_mod = @import("context.zig");
const eval_cache_mod = @import("eval_cache.zig");
const phase = @import("../eval/phase.zig");
const attacks = @import("../movegen/attacks.zig");
const bitboard = @import("../core/bitboard.zig");
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
    // Not inlined: the qsearch body exists once, the horizon flag passed at
    // run time (it only gates the horizon-transition count).
    return @call(.never_inline, searchDepth, .{ ctx, resources, pos, alpha_in, beta, ply, 0, in_check_hint, true });
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
    from_horizon: bool,
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
    tt_probe.probeInto(&probe, ctx, resources.tt, pos.zobrist_key, 0, alpha_in, beta, null, pos.halfmove_clock, ply);
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
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
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
    // Stalemate at the horizon (S-STALEMATE, narrow form). An empty tactical
    // list outside check is scored statically, and so was a stalemate (514 at
    // depth 1 for a stalemating queen move). Only a side with nothing but king
    // and pawns, the material a stalemate needs in practice, is tested;
    // heavier sides keep the static score.
    // Recorded limit (user decision 8): stand-pat runs before this test. With
    // beta above the draw score but not above the stalemated side's static
    // eval (a scout window), the node fails high on that eval instead of
    // returning the draw score. These patterns evaluate near the draw: at
    // most about 5 cp above it in every case tested (review round, judge A
    // F5). Testing before stand-pat cost about +0.5 % instructions/node in
    // K+P endgames.
    if (!in_check and moves.count == 0 and tt_quiet_move == null and kingAndPawnsOnly(pos)) {
        if (kingAndPawnsStalemated(pos, &moves)) return ctx.drawScore(pos.side_to_move);
    }
    if (moves.count == 0 and tt_quiet_move == null) {
        if (in_check) return -MATE_SCORE + @as(types.Score, @intCast(ply));
        if (stand_pat) |static_eval| {
            const best_static = if (comptime QS_FAIL_LOW_MARGIN > 0)
                (if (static_eval > alpha) static_eval else failLowValue(alpha, static_eval, static_eval))
            else
                @max(alpha, static_eval);
            tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, best_static, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
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
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
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
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
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
        var see_pins: ?see.Pins = null;
        for (moves.slice()) |mv| {
            if (tt_quiet_move) |searched| {
                if (mv == searched) continue;
            }
            if (see.quietBelowWith(pos, mv, 0, see.lazyPins(&see_pins, pos))) continue;
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
                tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
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
    tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, value, best_move, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply);
    return value;
}

inline fn kingAndPawnsOnly(pos: *const position.Position) bool {
    const side = pos.side_to_move;
    return (pos.pieceBitboard(side, .knight) | pos.pieceBitboard(side, .bishop) |
        pos.pieceBitboard(side, .rook) | pos.pieceBitboard(side, .queen)) == 0;
}

/// No legal move for a king-and-pawns side to move that is not in check and
/// has no capture or promotion. Its only other moves are single pawn pushes
/// (a double push needs the single one) and king steps to empty squares;
/// there is no rook to castle with. Exact without a full generation in the
/// common cases:
/// - a pushable pawn off every line through its own king cannot be pinned,
///   so its push is legal;
/// - a king step is legal when no enemy piece attacks the target, sliders
///   seeing through the king's own square;
/// - only when every pushable pawn sits on a king line and the king is boxed
///   in does the legal generator decide (pins). `scratch` (the empty tactical
///   list) is reused and left empty.
fn kingAndPawnsStalemated(pos: *const position.Position, scratch: *move_mod.MoveList) bool {
    const side = pos.side_to_move;
    const enemy = side.other();
    const king = pos.kingSquare(side) orelse return false;
    const occupied = pos.occupancy();
    const empty = ~occupied;
    const pawns = pos.pieceBitboard(side, .pawn);
    const pushers = if (side == .white) (empty >> 8) & pawns else (empty << 8) & pawns;
    const enemy_queens = pos.pieceBitboard(enemy, .queen);
    const enemy_bishop_like = pos.pieceBitboard(enemy, .bishop) | enemy_queens;
    const enemy_rook_like = pos.pieceBitboard(enemy, .rook) | enemy_queens;
    const king_lines = if ((enemy_bishop_like | enemy_rook_like) == 0)
        0
    else
        attacks.BISHOP_RAYS[@intFromEnum(king)] | attacks.ROOK_RAYS[@intFromEnum(king)];
    if ((pushers & ~king_lines) != 0) return false;

    const without_king = occupied & ~bitboard.bit(king);
    var guarded = attacks.pawnAttacks(enemy, pos.pieceBitboard(enemy, .pawn));
    if (pos.kingSquare(enemy)) |enemy_king| guarded |= attacks.kingAttacksFrom(enemy_king);
    var knights = pos.pieceBitboard(enemy, .knight);
    while (knights != 0) {
        const sq = bitboard.popLsbUnchecked(&knights);
        guarded |= attacks.knightAttacksFrom(sq);
    }
    var bishop_like = enemy_bishop_like;
    while (bishop_like != 0) {
        const sq = bitboard.popLsbUnchecked(&bishop_like);
        guarded |= attacks.bishopAttacksOnTheFly(sq, without_king);
    }
    var rook_like = enemy_rook_like;
    while (rook_like != 0) {
        const sq = bitboard.popLsbUnchecked(&rook_like);
        guarded |= attacks.rookAttacksOnTheFly(sq, without_king);
    }
    if ((attacks.kingAttacksFrom(king) & empty & ~guarded) != 0) return false;
    if (pushers == 0) return true;

    legal.generateHinted(pos, scratch, false);
    const stalemated = scratch.count == 0;
    scratch.clear();
    return stalemated;
}

/// Margin form of a quiescence fail low: below alpha only by what the
/// position is short of alpha beyond QS_FAIL_LOW_MARGIN over the stand-pat.
/// The margin estimate is an ordinary score: it stays below the tablebase
/// band even when alpha lies in it (score.ORDINARY_SCORE_LIMIT).
inline fn failLowValue(alpha: types.Score, stand_pat: types.Score, soft_best: types.Score) types.Score {
    return @min(alpha, @max(soft_best, @min(stand_pat + QS_FAIL_LOW_MARGIN, score_mod.ORDINARY_SCORE_LIMIT)));
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

test "the qsearch fail-low margin stays below the tablebase band" {
    // Review round (S-TB-PLY, Astra judge A finding 4): with alpha a tablebase
    // bound, stand-pat + margin landed inside the band and was stored as a
    // tablebase distance.
    if (comptime QS_FAIL_LOW_MARGIN == 0) return error.SkipZigTest;
    const limit = score_mod.ORDINARY_SCORE_LIMIT;
    const tb_alpha = score_mod.TB_WIN_SCORE - 500;
    try @import("std").testing.expectEqual(limit, failLowValue(tb_alpha, limit - 1, -INF));
    try @import("std").testing.expectEqual(limit, failLowValue(tb_alpha, limit, limit));
    // Ordinary margins are unchanged; a genuine tablebase child score is kept.
    try @import("std").testing.expectEqual(@as(types.Score, 300 + QS_FAIL_LOW_MARGIN), failLowValue(tb_alpha, 300, -INF));
    try @import("std").testing.expectEqual(tb_alpha - 7, failLowValue(tb_alpha, limit, tb_alpha - 7));
    try @import("std").testing.expectEqual(@as(types.Score, 10), failLowValue(10, 300, -INF));
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

test "qsearch scores a king-and-pawns stalemate as a draw, not statically" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint.HintTable.init(std.testing.allocator, rfp_hint.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    const Case = struct { fen: []const u8, draw: bool };
    const cases = [_]Case{
        // Judge A repro: Black is stalemated (the raw eval is -410).
        .{ .fen = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", .draw = true },
        // Blocked pawn too: still no legal move.
        .{ .fen = "7k/5Q2/6K1/8/8/p7/P7/8 b - - 0 1", .draw = true },
        // Same with a free pawn push: a live position, scored as before.
        .{ .fen = "7k/5Q2/6K1/8/8/p7/8/8 b - - 0 1", .draw = false },
        // No enemy slider (the bitboard path): pawn and king box the king in.
        .{ .fen = "k7/P7/K7/8/8/8/8/8 b - - 0 1", .draw = true },
        .{ .fen = "k7/P7/K7/8/8/7p/8/8 b - - 0 1", .draw = false },
        .{ .fen = "8/8/8/8/8/k7/p7/K7 w - - 0 1", .draw = true },
        // An enemy knight guards the last escape square (b8).
        .{ .fen = "k7/8/1KN5/8/8/8/8/8 b - - 0 1", .draw = true },
        .{ .fen = "k7/8/1K6/8/8/8/P7/2N5 b - - 0 1", .draw = false },
    };
    for (cases) |case| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var context = context_mod.SearchContext{
            .repetition = .{},
            .control = @import("time.zig").Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history_table = history.HistoryTable{};
        table.clear();
        var pos = try fen.parse(case.fen);
        context.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
        const score = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
        if (case.draw) {
            try std.testing.expectEqual(@as(types.Score, 0), score);
        } else {
            try std.testing.expect(score != 0);
        }
        // The bitboard path agrees with the legal generator.
        var all = move_mod.MoveList.init();
        legal.generate(&pos, &all);
        var scratch = move_mod.MoveList.init();
        if (!legal.isInCheck(&pos, pos.side_to_move) and kingAndPawnsOnly(&pos)) {
            try std.testing.expectEqual(all.count == 0, kingAndPawnsStalemated(&pos, &scratch));
            try std.testing.expectEqual(@as(usize, 0), scratch.count);
        }
    }
}

test "king-and-pawns stalemate test agrees with the legal generator on random endgame walks" {
    const fen = @import("../core/fen.zig");
    const seeds = [_][]const u8{
        "k7/P7/K7/8/8/8/8/8 b - - 0 1",
        "8/8/1p1k4/1P6/2PK4/8/8/8 w - - 0 1",
        "8/5pk1/6p1/8/5PK1/6P1/8/2n5 w - - 0 1",
        "8/k7/3p4/p2P1p2/P2P1P2/8/1N6/K7 b - - 0 1",
        "7k/5Q2/6K1/8/8/p7/P7/8 b - - 0 1",
        "8/8/8/2k5/8/1n1p4/3P4/3K4 w - - 0 1",
        "8/8/8/8/1k6/1p6/1P6/1K1r4 w - - 0 1",
        "4k3/4p3/8/8/b7/8/3PP3/4K3 w - - 0 1",
        "6k1/5ppp/8/8/8/8/5PPP/1q4K1 w - - 0 1",
    };
    var prng = std.Random.DefaultPrng.init(0x57a1_e7a7);
    const rand = prng.random();
    var checked: usize = 0;
    var stalemates: usize = 0;
    for (seeds) |seed| {
        for (0..60) |_| {
            var pos = try fen.parse(seed);
            for (0..40) |_| {
                var all = move_mod.MoveList.init();
                legal.generate(&pos, &all);
                var tactical = move_mod.MoveList.init();
                legal.generateCapturesAndPromotions(&pos, &tactical);
                if (tactical.count == 0 and kingAndPawnsOnly(&pos) and !legal.isInCheck(&pos, pos.side_to_move)) {
                    var scratch = move_mod.MoveList.init();
                    try std.testing.expectEqual(all.count == 0, kingAndPawnsStalemated(&pos, &scratch));
                    try std.testing.expectEqual(@as(usize, 0), scratch.count);
                    checked += 1;
                    if (all.count == 0) stalemates += 1;
                }
                if (all.count == 0) break;
                const mv = all.moves[rand.uintLessThan(usize, all.count)];
                var state = make_unmake.StateInfo{};
                _ = make_unmake.makeMove(&pos, mv, &state);
            }
        }
    }
    try std.testing.expect(checked > 1000);
    try std.testing.expect(stalemates >= 1);
}

test "qsearch keeps a mating capture whose recapturer is pinned" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
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
    // Judge C repro (C-SEE-PIN): Qxf7 is mate (Nd8 pinned by Ra8, Bc4 covers
    // f7). With the pin-blind SEE it scored -800 and the negative-SEE skip
    // dropped it (qsearch 1052).
    var pos = try fen.parse("R2nkb2/3pppp1/8/7Q/2B5/8/8/6K1 w - - 0 1");
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);

    const score = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expectEqual(MATE_SCORE - 1, score);
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

test "qsearch does not return a stale TT lower bound from the rule-50 gate clock on" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint.HintTable.init(std.testing.allocator, rfp_hint.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    // Review-round witness (S-RULE50-TT): White is in check and every evasion
    // is quiet, so at clock 99 each one reaches clock 100, a draw. A lower
    // bound of 387 from a low-clock search raised alpha at this full-window
    // node without closing the window, and qsearch returned it.
    const Case = struct { fen: []const u8, seed: bool };
    const cases = [_]Case{
        .{ .fen = "7k/8/8/1Q6/8/8/8/K6r w - - 99 1", .seed = false },
        .{ .fen = "7k/8/8/1Q6/8/8/8/K6r w - - 99 1", .seed = true },
        // Control below the gate: the bound is trusted and raises alpha.
        .{ .fen = "7k/8/8/1Q6/8/8/8/K6r w - - 0 1", .seed = true },
    };
    var scores: [cases.len]types.Score = undefined;
    for (cases, 0..) |case, i| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var context = context_mod.SearchContext{
            .repetition = .{},
            .control = @import("time.zig").Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history_table = history.HistoryTable{};
        table.clear();
        ecache.clear();
        var pos = try fen.parse(case.fen);
        context.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
        if (case.seed) table.store(pos.zobrist_key, 10, 387, .lower, null);
        scores[i] = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    }
    try std.testing.expectEqual(@as(types.Score, 0), scores[0]);
    try std.testing.expectEqual(@as(types.Score, 0), scores[1]);
    try std.testing.expect(scores[2] >= 387);
}
