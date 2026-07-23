const std = @import("std");
const context_mod = @import("context.zig");
const eval_cache_mod = @import("eval_cache.zig");
const phase = @import("../eval/phase.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const ordering = @import("ordering.zig");
const piece_values = @import("../core/piece_values.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const see = @import("see.zig");
const tt_mod = @import("tt.zig");
const tt_probe = @import("tt_probe.zig");
const tt_store = @import("tt_store.zig");
const types = @import("../core/types.zig");

const DELTA_MARGIN: types.Score = 200;
const LATE_ENDGAME_PHASE_256: u16 = 200;

pub const MATE_SCORE: types.Score = score_mod.MATE_SCORE;
pub const INF: types.Score = 30_000;

pub fn search(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
    pos: *position.Position,
    alpha_in: types.Score,
    beta: types.Score,
    ply: usize,
    in_check_hint: ?bool,
) types.Score {
    return searchDepth(ctx, resources, pos, alpha_in, beta, ply, 0, in_check_hint);
}

fn searchDepth(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
    pos: *position.Position,
    alpha_in: types.Score,
    beta: types.Score,
    ply: usize,
    qs_depth: u8,
    in_check_hint: ?bool,
) types.Score {
    if (ctx.noteQNode()) return 0;
    ctx.observePly(ply);
    if (pos.halfmove_clock >= 100 or ctx.repetition.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock)) return ctx.drawScore(pos.side_to_move);

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
    // AFTER the TT cutoff: a cutoff returns without ever consulting in_check,
    // so computing it first wasted a full attack query on every TT-cutoff
    // qnode (probe + isInCheck were the two entry-path hot spots).
    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    var alpha = probe.alpha;
    const beta_local = probe.beta;

    var stand_pat: ?types.Score = null;
    if (!in_check) {
        // RAW stand-pat: applying corrhist here measured negative (stand-pat fires
        // at every leaf — too sensitive for half-trained corrections); corrhist is
        // a main-search device (RFP/futility/null/improving) for now.
        // Reuse the TT-cached raw static eval (identical to recomputing), then
        // the dedicated raw-eval cache (full-key verified; a hit skips the NNUE
        // forward AND the lazy-accumulator materialization, exactly like the
        // TT-eval path). See root.zig's twin block.
        const eval_score = blk: {
            if (tt_entry) |entry| {
                if (entry.static_eval != tt_mod.STATIC_EVAL_NONE) break :blk @as(types.Score, entry.static_eval);
            }
            if (resources.eval_cache.probe(pos.zobrist_key)) |cached| {
                ctx.noteQsearchEvalCacheProbe(true);
                break :blk @as(types.Score, cached);
            }
            ctx.noteQsearchEvalCacheProbe(false);
            const fresh = resources.evaluator.evaluate(&ctx.stack, ply, pos, &ctx.finny);
            if (std.math.cast(i16, fresh)) |memo| resources.eval_cache.store(pos.zobrist_key, memo);
            break :blk fresh;
        };
        stand_pat = eval_score;
        if (eval_score >= beta_local) {
            ctx.noteQsearchStandPatCutoff();
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, beta_local, null, tt_store.evalToTt(stand_pat));
            return beta_local;
        }
    }

    var moves = move_mod.MoveList.init();
    if (in_check) {
        legal.generateHinted(pos, &moves, true);
    } else {
        legal.generateCapturesAndPromotionsHinted(pos, &moves, false);
        if (ctx.recordMoveOrder()) ctx.noteQsearchTacticalList(moves.count);
    }
    if (moves.count == 0) {
        if (in_check) return -MATE_SCORE + @as(types.Score, @intCast(ply));
        if (stand_pat) |static_eval| {
            const best_static = @max(alpha, static_eval);
            tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, best_static, null, tt_store.evalToTt(stand_pat));
            return best_static;
        }
        return alpha;
    }

    if (shouldDeltaPruneNode(pos, stand_pat, alpha, in_check, &moves)) {
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
        ordering.scoreMoves(pos, &moves, tt_move, .{}, null, resources.history, &cont, &scores, &capture_see_scores);
    } else {
        ordering.scoreTacticalMoves(pos, &moves, tt_move, &scores, &capture_see_scores);
    }

    var best = alpha;
    var best_move: ?move_mod.Move = null;
    var move_picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    for (0..moves.count) |index| {
        const mv = move_picker.next(index);
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
        // Returned key = register value; avoids reloading the zobrist store
        // makeMove just issued (see makeMove's doc comment).
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key); // overlap the child's TT miss with the work below
        ctx.repetition.push(child_key);
        // Lazy accumulator: record the move only — boards/undo-state are
        // reconstructed at materialization time from the live position.
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null);
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);

        if (ctx.stopped) return 0;
        if (score >= beta_local) {
            ctx.noteBetaCutoff(index);
            if (is_capture and !is_promotion) ctx.noteCaptureCutoff(index, capture_see_score, true);
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, beta_local, mv, tt_store.evalToTt(stand_pat));
            return beta_local;
        }
        if (score > best) {
            best = score;
            best_move = mv;
        }
    }

    // Quiet checks at the FIRST quiescence ply only (SEE-gated): the horizon was
    // check-blind — captures/promotions alone cannot see one-move mating or
    // perpetual threats. Direct checks only; recursion answers them as evasions.
    if (!in_check and qs_depth == 0 and !ctx.stopped) {
        var check_moves = move_mod.MoveList.init();
        legal.generateQuietChecksHinted(pos, &check_moves, false);
        for (check_moves.slice()) |mv| {
            if (see.quietScore(pos, mv) < 0) continue;
            const entry = ctx.stack.entry(ply);
            const child_key = make_unmake.makeMove(pos, mv, &entry.state);
            resources.tt.prefetch(child_key);
            ctx.repetition.push(child_key);
            resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
            const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null);
            ctx.repetition.pop();
            make_unmake.unmakeMove(pos, mv, &entry.state);
            if (ctx.stopped) return 0;
            if (score >= beta_local) {
                tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, 0, beta_local, mv, tt_store.evalToTt(stand_pat));
                return beta_local;
            }
            if (score > best) {
                best = score;
                best_move = mv;
            }
        }
    }

    tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, 0, alpha_orig, beta_local, best, best_move, tt_store.evalToTt(stand_pat));
    return best;
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
    evaluator.prepareRoot(&context.stack, &pos, &context.finny);

    _ = search(&context, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expect(table.bestMove(pos.zobrist_key) != null);
}
