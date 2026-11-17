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
const progress = @import("progress.zig");
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
const qs_rules = @import("qs_rules.zig");
const stats_mod = @import("stats.zig");
const tt_eval = @import("tt_eval.zig");
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
    alpha_window: types.Score,
    beta_window: types.Score,
    ply: usize,
    qs_depth: u8,
    in_check_hint: ?bool,
    from_horizon: bool,
) align(64) types.Score { // align(64): pins hot entry placement (layout stability, not call speed)
    // Mate-distance pruning, as in negamax.
    const alpha_in: types.Score = @max(alpha_window, -MATE_SCORE + @as(types.Score, @intCast(ply)));
    const beta: types.Score = @min(beta_window, MATE_SCORE - @as(types.Score, @intCast(ply)) - 1);
    // A node re-entered by searchTwofold was counted and tested for draws.
    const resumed = ctx.twofold_resume;
    ctx.twofold_resume = false;
    if (!resumed) {
        if (if (comptime @hasField(@TypeOf(resources), "execution")) resources.execution.noteNode(ctx, true) else ctx.noteQNode()) return 0;
        ctx.observePly(ply);
        if (pos.halfmove_clock >= 100) return rule50.interiorScore(ctx, pos, ply, in_check_hint);
        if (ctx.repetition.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock)) {
            const draw = ctx.drawScore(pos.side_to_move);
            // As in negamax: only a second occurrence of a game-history
            // position with the root side's opponent to move is searched, as
            // the better of a draw and its value.
            if (draw >= beta or pos.side_to_move == ctx.root_color or
                !ctx.repetition.repeatsOnlyBeforeRoot(pos.zobrist_key, pos.halfmove_clock)) return draw;
            return searchTwofold(ctx, resources, pos, alpha_in, beta, ply, qs_depth, in_check_hint, from_horizon, draw);
        }
    }
    if (from_horizon) ctx.noteHorizonTransition();
    if (ply_limit.fallback(ctx, resources.evaluator, pos, ply, in_check_hint)) |score| return score;
    if (alpha_in >= beta) return alpha_in;

    const alpha_orig = alpha_in;
    // Out-pointer probe — same store-forward-stall fix as negamax (see the
    // probeInto doc comment in tt_probe.zig).
    var probe: tt_probe.Result = undefined;
    // The first ply needs an entry that searched quiet checks too (tt_mod.QS_FIRST_PLY_DEPTH).
    const ply_tt_depth: i16 = if (qs_depth == 0) tt_mod.QS_FIRST_PLY_DEPTH else tt_mod.QS_LATER_PLY_DEPTH;
    tt_probe.probeInto(&probe, ctx, resources.tt, pos.zobrist_key, ply_tt_depth, alpha_in, beta, null, pos.halfmove_clock, ply);
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
            resources.tt.prefetch(hinted_key ^ ctx.tableKey(progress.clockAfter(pos, hash_move)));
            resources.eval_cache.prefetch(hinted_key);
        }
    }
    // AFTER the TT cutoff: a cutoff returns without ever consulting in_check,
    // so computing it first wasted a full attack query on every TT-cutoff
    // qnode (probe + isInCheck were the two entry-path hot spots).
    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    // Evasions are the same move set at every quiescence ply.
    const tt_depth: i16 = if (in_check) tt_mod.QS_FIRST_PLY_DEPTH else ply_tt_depth;
    var alpha = probe.alpha;
    const beta_local = probe.beta;

    var stand_pat: ?types.Score = null;
    // TT slots keep the RAW static eval; `stand_pat` is the value the node
    // decides on (corrected when -Dcorr-qsearch, raw otherwise).
    var raw_stand_pat: ?types.Score = null;
    // What a capture starts from: the static value before the fifty-move
    // boundary rule. A capture resets the clock, so one ply before the draw
    // its bound is this value plus its gain, not the boundary's stand-pat
    // (a draw for a side that has no pawn to move). Equal below the boundary.
    var capture_base: ?types.Score = null;
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
        const eval_params: *const basin.Params = if (comptime build_options.tuning) &ctx.basin_config.params else &basin.defaults;
        // With the progress term, like the main search's eval.
        const static_value: types.Score = progress.searchEval(eval_params, if (comptime corr_qsearch)
            resources.history.correctedEval(pos, eval_score, .{}, eval_params)
        else
            eval_score, pos, ctx.root_color, ctx.progress_pressure);
        // The table's score where its bound contradicts the static value (tt_eval.zig; off by default).
        const table_trusted = shallow_arms.rule50TrustsTtScore(pos.halfmove_clock);
        const table_value: types.Score = if (tt_eval.enabled(.stand_pat)) tt_eval.refined(tt_entry, static_value, table_trusted) else static_value;
        if (comptime context_mod.stats_enabled) {
            ctx.stats.tt_eval_qs_nodes += 1;
            const taken = tt_eval.refinedWith(tt_entry, static_value, table_trusted, -1);
            if (taken != static_value) {
                ctx.stats.tt_eval_qs_differs += 1;
                if (taken >= beta_local and static_value < beta_local) ctx.stats.tt_eval_qs_gained += 1;
                if (taken < beta_local and static_value >= beta_local) ctx.stats.tt_eval_qs_refused += 1;
            }
        }
        // One ply before the fifty-move draw a quiet move keeps the static
        // value only if it is a pawn's (rule50.standPatAtBoundary). The table
        // is not trusted that late (rule50TrustsTtScore), so the value there
        // is the static one.
        const decided: types.Score = if (pos.halfmove_clock >= rule50.STAND_PAT_BOUNDARY)
            rule50.standPatAtBoundary(ctx, pos, table_value)
        else
            table_value;
        stand_pat = decided;
        capture_base = static_value;
        if (decided >= beta_local) {
            ctx.noteQsearchStandPatCutoff();
            const softness = if (comptime build_options.tuning) ctx.basin_config.params.standpat_softness else basin.defaults.standpat_softness;
            const value = fail_soft.evalCutoff(beta_local, decided, softness);
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, tt_depth, value, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
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
    // Stalemate at the horizon (S-STALEMATE). An empty tactical list outside
    // check is scored statically, and so was a stalemate (514 at depth 1 for a
    // stalemating queen move; -763 for `7k/5K1n/8/7Q/8/8/8/8 b`, where the
    // knight is pinned). A side with only king and pawns takes the bitboard
    // path; any other side is cleared by its first piece that cannot be pinned
    // and has an empty square to go to, and only otherwise asks the generator
    // (`isStalemate`).
    // Recorded limit (user decision 8): stand-pat runs before this test. With
    // beta above the draw score but not above the stalemated side's static
    // eval (a scout window), the node fails high on that eval instead of
    // returning the draw score. These patterns evaluate near the draw: at
    // most about 5 cp above it in every case tested (review round, judge A
    // F5). Testing before stand-pat cost about +0.5 % instructions/node in
    // K+P endgames.
    if (!in_check and moves.count == 0 and tt_quiet_move == null) {
        if (isStalemate(pos, &moves)) return ctx.drawScore(pos.side_to_move);
    }
    const delta_prune = shouldDeltaPruneNode(pos, stand_pat, alpha, in_check, &moves);
    // The first quiescence ply also searches quiet checks (below). An empty
    // capture list says nothing about them, so it does not end that ply: with
    // `7k/8/5KQ1/8/8/8/8/8 w` (no capture, Qg7 mates) the early return scored
    // 171 where the same position with an unrelated capture found the mate.
    // A delta-pruned node searches no checks with captures either, and keeps
    // its return. Without a check that raises the score, the node's value and
    // table store below equal this early return's.
    const quiet_checks_follow = !in_check and qs_depth == 0 and !delta_prune;
    if (moves.count == 0 and tt_quiet_move == null and !quiet_checks_follow) {
        if (in_check) return -MATE_SCORE + @as(types.Score, @intCast(ply));
        if (stand_pat) |static_eval| {
            const best_static = if (comptime QS_FAIL_LOW_MARGIN > 0)
                (if (static_eval > alpha) static_eval else failLowValue(alpha, static_eval, static_eval))
            else
                @max(alpha, static_eval);
            tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, tt_depth, alpha_orig, beta_local, best_static, null, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
            return best_static;
        }
        return alpha;
    }

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
        ordering.scoreMoves(pos, &moves, tt_move, .{}, null, resources.history, &cont, @import("../movegen/attacks.zig").attackedSquares(pos, pos.side_to_move.other()), .{}, &scores, &capture_see_scores);
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
        resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock));
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
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, tt_depth, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
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
    // Late endgame as the node rule has it (shouldDeltaPruneNode); asked once
    // per node, by the first capture a move rule names.
    var late_endgame: ?bool = null;
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
        // The move rules (qs_rules.zig; every switch off by default). A
        // skipped capture's upper bound enters the margin form of a fail low.
        var rule_note: RuleNote = .{};
        if (!in_check and is_promotion) {
            const under = qs_rules.isRookOrBishopPromotion(mv);
            if (comptime context_mod.stats_enabled) {
                rule_note.promotion = true;
                rule_note.under = under;
                rule_note.knight = mv.promotionPieceType().? == .knight;
            }
            if (under and qs_rules.noUnderpromotion()) {
                if (comptime context_mod.stats_enabled) noteRule(ctx, rule_note, false, false, 0);
                continue;
            }
        }
        if (!in_check and is_capture and !is_promotion) {
            const static_eval = capture_base.?;
            if (comptime context_mod.stats_enabled) rule_note.capture = true;
            if ((qs_rules.moveFutilityEnabled() or comptime context_mod.stats_enabled)) {
                const victim_class = qs_rules.victimClass(qs_rules.capturedType(pos, mv));
                const gain = qs_rules.gains()[victim_class];
                if (qs_rules.captureFutile(static_eval, gain, best)) {
                    const late = late_endgame orelse blk: {
                        const answer = phase.phase256(pos) >= LATE_ENDGAME_PHASE_256;
                        late_endgame = answer;
                        break :blk answer;
                    };
                    const exempt = late or (qs_rules.futilityKeepsChecks() and legal.givesCheck(pos, mv));
                    if (comptime context_mod.stats_enabled) {
                        rule_note.futile = true;
                        rule_note.late = late;
                        rule_note.victim_class = victim_class;
                        rule_note.gives_check = legal.givesCheck(pos, mv);
                    }
                    if (qs_rules.moveFutilityEnabled() and !exempt) {
                        if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, static_eval + gain);
                        if (comptime context_mod.stats_enabled) noteRule(ctx, rule_note, false, false, 0);
                        continue;
                    }
                }
            }
            // The equal-exchange rule acts on a computed exchange value
            // only. A 0 in the ordering's list is not one for the table move
            // (written without a computation) nor for en passant (the
            // exchange evaluator returns 0 for every one): those are left
            // alone.
            const equal_margin = qs_rules.equalExchangeMargin();
            const table_move = tt_move != null and tt_move.? == mv;
            const exchange_computed = qs_rules.exchangeValueComputed(mv, table_move);
            const uncomputed_en_passant = (comptime context_mod.stats_enabled) and mv.flag == .en_passant and !table_move;
            if (capture_see_score == 0 and (equal_margin > 0 or (comptime context_mod.stats_enabled)) and (exchange_computed or uncomputed_en_passant)) {
                const late = late_endgame orelse blk: {
                    const answer = phase.phase256(pos) >= LATE_ENDGAME_PHASE_256;
                    late_endgame = answer;
                    break :blk answer;
                };
                if (!late) {
                    const futile = qs_rules.equalExchangeFutile(equal_margin, capture_see_score, static_eval, best);
                    if (!exchange_computed) {
                        // Stats flavour: an en passant capture the rule would
                        // have skipped on its uncomputed 0.
                        if (comptime context_mod.stats_enabled) {
                            if (futile) ctx.stats.qs_rules.equal_en_passant_kept += 1;
                        }
                    } else {
                        if (comptime context_mod.stats_enabled) {
                            rule_note.equal = true;
                            rule_note.equal_distance = if (score_mod.isDecisive(best)) -1 else best - static_eval;
                        }
                        if (futile) {
                            if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, static_eval + equal_margin);
                            if (comptime context_mod.stats_enabled) noteRule(ctx, rule_note, false, false, 0);
                            continue;
                        }
                    }
                }
            }
        }
        const rule_nodes_before = if (comptime context_mod.stats_enabled) ctx.nodes else 0;
        const rule_best_before = best;

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
                resources.tt.prefetch(hinted_key ^ ctx.tableKey(progress.clockAfter(pos, upcoming)));
                resources.eval_cache.prefetch(hinted_key);
            }
        }
        searched_moves += 1;
        // Returned key = register value; avoids reloading the zobrist store
        // makeMove just issued (see makeMove's doc comment).
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock)); // overlap the child's TT miss with the work below
        resources.eval_cache.prefetch(child_key); // and the eval-cache set (probed on a TT eval miss)
        ctx.repetition.push(child_key);
        // Lazy accumulator: record the move only — boards/undo-state are
        // reconstructed at materialization time from the live position.
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null, false);
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);

        if (ctx.stopped) return 0;
        if (comptime context_mod.stats_enabled) noteRule(ctx, rule_note, true, score > rule_best_before, ctx.nodes - rule_nodes_before);
        if (score >= beta_local) {
            const move_index = index + @intFromBool(tt_quiet_move != null);
            ctx.noteBetaCutoff(move_index);
            if (is_capture and !is_promotion) ctx.noteCaptureCutoff(move_index, capture_see_score, true);
            const value = if (comptime fail_soft.ENABLED) score else beta_local;
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, tt_depth, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
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
        // The gate (qs_rules.checkGateOpen; QsCheckGate 0 = every node, as
        // before). A node without a capture or promotion always passes: its
        // quiet checks are all that can see a mate in one.
        const gate = qs_rules.checkGate();
        const empty_tactical = moves.count == 0;
        const far = qs_rules.checkFar(stand_pat.?, qs_rules.checkMargin(), best);
        var king_boxed: ?bool = if (qs_rules.checkGateAsksKing(gate, empty_tactical, far) or ((comptime context_mod.stats_enabled) and far))
            qs_rules.kingBoxed(pos)
        else
            null;
        const gate_open = qs_rules.checkGateOpen(gate, empty_tactical, far, king_boxed orelse false);
        const check_path: usize = if (empty_tactical) 0 else if (!far) 1 else if (king_boxed orelse false) 2 else 3;
        if (comptime context_mod.stats_enabled) {
            ctx.stats.qs_rules.check_stage_nodes[check_path] += 1;
            if (!gate_open) ctx.stats.qs_rules.check_gated_nodes += 1;
        }
        // Reuse the tactical list's storage: it is dead once the capture loop
        // above ends, and the generator clears the list before appending, so
        // the check list is the same moves in the same order. A second
        // MAX_MOVES list in this frame pushed the Windows x64 AVX2 frame past
        // 4 KB, which costs a ___chkstk_ms probe on every qsearch call.
        if (gate_open) legal.generateQuietChecksHinted(pos, &moves, false) else moves.clear();
        var see_pins: ?see.Pins = null;
        // The limited gate takes the checks by piece and ends after a number
        // of them that raise nothing, unless the king is boxed in.
        const by_piece = gate == .near_or_boxed_limited and !empty_tactical;
        var limited = by_piece;
        const passes: usize = if (by_piece) qs_rules.CHECK_CLASS_COUNT else 1;
        var fail_lows: u32 = 0;
        checks: for (0..passes) |pass| {
            for (moves.slice()) |mv| {
                if (by_piece and qs_rules.checkClass(pos.pieceAt(mv.from).pieceType()) != pass) continue;
                if (tt_quiet_move) |searched| {
                    if (mv == searched) continue;
                }
                if (see.quietBelowWith(pos, mv, 0, see.lazyPins(&see_pins, pos))) continue;
                const check_nodes_before = if (comptime context_mod.stats_enabled) ctx.nodes else 0;
                const entry = ctx.stack.entry(ply);
                const child_key = make_unmake.makeMove(pos, mv, &entry.state);
                resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock));
                resources.eval_cache.prefetch(child_key);
                ctx.repetition.push(child_key);
                resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
                const score = -searchDepth(ctx, resources, pos, -beta_local, -best, ply + 1, qs_depth +| 1, null, false);
                ctx.repetition.pop();
                make_unmake.unmakeMove(pos, mv, &entry.state);
                if (ctx.stopped) return 0;
                if (comptime context_mod.stats_enabled) {
                    ctx.stats.qs_rules.checks_searched[check_path] += 1;
                    ctx.stats.qs_rules.check_nodes[check_path] += ctx.nodes - check_nodes_before;
                    if (score > best) ctx.stats.qs_rules.check_raises[check_path] += 1;
                }
                if (score >= beta_local) {
                    const value = if (comptime fail_soft.ENABLED) score else beta_local;
                    tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, tt_depth, value, mv, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
                    return value;
                }
                if (comptime QS_FAIL_LOW_MARGIN > 0) soft_best = @max(soft_best, score);
                if (score > best) {
                    best = score;
                    best_move = mv;
                } else if (limited) {
                    fail_lows += 1;
                    if (fail_lows >= qs_rules.checkFailLowLimit()) {
                        const boxed = king_boxed orelse qs_rules.kingBoxed(pos);
                        king_boxed = boxed;
                        if (!boxed) {
                            if (comptime context_mod.stats_enabled) ctx.stats.qs_rules.check_fail_low_stops += 1;
                            break :checks;
                        }
                        // Boxed in: every check is searched, in the order begun.
                        limited = false;
                    }
                }
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
    tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, tt_depth, alpha_orig, beta_local, value, best_move, tt_store.evalToTt(raw_stand_pat), beta_local - alpha_orig > 1, ply, pos.halfmove_clock);
    return value;
}

/// What the move rules said about one move of the capture loop (stats flavour).
const RuleNote = struct {
    capture: bool = false,
    futile: bool = false,
    late: bool = false,
    gives_check: bool = false,
    victim_class: usize = 0,
    promotion: bool = false,
    under: bool = false,
    knight: bool = false,
    equal: bool = false,
    /// Best value so far minus the stand-pat; -1 when the best is decisive.
    equal_distance: types.Score = -1,
};

/// Count a move the rules looked at: `searched` with its subtree and whether
/// it raised the node's best value, or skipped.
fn noteRule(ctx: *context_mod.SearchContext, note: RuleNote, searched: bool, raised: bool, nodes: u64) void {
    if (comptime !context_mod.stats_enabled) return;
    const counters = &ctx.stats.qs_rules;
    const late = @intFromBool(note.late);
    if (note.capture) {
        counters.captures += 1;
        if (searched) {
            counters.captures_searched += 1;
            counters.capture_nodes += nodes;
            if (raised) counters.capture_raises += 1;
        }
    }
    if (note.futile) {
        counters.fut_candidates[late][note.victim_class] += 1;
        if (note.gives_check) counters.fut_check_candidates[late][note.victim_class] += 1;
        if (searched) {
            counters.fut_searched[late][note.victim_class] += 1;
            counters.fut_nodes[late][note.victim_class] += nodes;
            if (raised) counters.fut_misses[late][note.victim_class] += 1;
            if (note.gives_check) {
                counters.fut_check_searched[late][note.victim_class] += 1;
                if (raised) counters.fut_check_misses[late][note.victim_class] += 1;
            }
        } else {
            counters.fut_skipped += 1;
        }
    }
    if (note.promotion) {
        if (searched) counters.promotions_searched += 1;
        if (note.knight and searched) {
            counters.knight_promotions_searched += 1;
            if (raised) counters.knight_promotion_raises += 1;
        }
        if (note.under) {
            if (searched) {
                counters.under_searched += 1;
                counters.under_nodes += nodes;
                if (raised) counters.under_raises += 1;
            } else {
                counters.under_skipped += 1;
            }
        }
    }
    if (note.equal) {
        counters.equal_captures += 1;
        if (!searched) {
            counters.equal_skipped += 1;
        } else {
            for (stats_mod.QS_EQUAL_BAND_MARGINS, 0..) |margin, band| {
                if (note.equal_distance < margin) break;
                counters.equal_far_searched[band] += 1;
                counters.equal_far_nodes[band] += nodes;
                if (raised) counters.equal_far_misses[band] += 1;
            }
        }
    }
}

/// No legal move for a side to move that is not in check and has no capture
/// or promotion. `scratch` (the empty tactical list) is reused and left empty.
fn isStalemate(pos: *const position.Position, scratch: *move_mod.MoveList) bool {
    if (kingAndPawnsOnly(pos)) return kingAndPawnsStalemated(pos, scratch);
    const side = pos.side_to_move;
    const king = pos.kingSquare(side) orelse return false;
    const occupied = pos.occupancy();
    const empty = ~occupied;
    // A piece off every line through its own king cannot be pinned: any empty
    // square it reaches is a legal move. Nearly every position ends here.
    const free = ~(attacks.BISHOP_RAYS[@intFromEnum(king)] | attacks.ROOK_RAYS[@intFromEnum(king)]);
    const queens = pos.pieceBitboard(side, .queen);
    var knights = pos.pieceBitboard(side, .knight) & free;
    while (knights != 0) {
        const sq = bitboard.popLsbUnchecked(&knights);
        if ((attacks.knightAttacksFrom(sq) & empty) != 0) return false;
    }
    var rook_like = (pos.pieceBitboard(side, .rook) | queens) & free;
    while (rook_like != 0) {
        const sq = bitboard.popLsbUnchecked(&rook_like);
        if ((attacks.rookAttacksOnTheFly(sq, occupied) & empty) != 0) return false;
    }
    var bishop_like = (pos.pieceBitboard(side, .bishop) | queens) & free;
    while (bishop_like != 0) {
        const sq = bitboard.popLsbUnchecked(&bishop_like);
        if ((attacks.bishopAttacksOnTheFly(sq, occupied) & empty) != 0) return false;
    }
    // Every piece is on a king line or boxed in: the generator decides.
    legal.generateHinted(pos, scratch, false);
    const no_move = scratch.count == 0;
    scratch.clear();
    return no_move;
}

/// Quiescence form of root.searchTwofold: the better of a draw and the node's
/// own quiescence value.
noinline fn searchTwofold(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    alpha: types.Score,
    beta: types.Score,
    ply: usize,
    qs_depth: u8,
    in_check_hint: ?bool,
    from_horizon: bool,
    draw: types.Score,
) types.Score {
    @branchHint(.cold);
    ctx.twofold_resume = true;
    const score = searchDepth(ctx, resources, pos, @max(alpha, draw), beta, ply, qs_depth, in_check_hint, from_horizon);
    return @max(score, draw);
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

test "qsearch searches quiet checks at the first ply when no capture exists" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Code-read finding 2 (2026-11-10): White has no capture or promotion and
    // six quiet checks, one of them Qg7 mate. The second position adds a black
    // pawn the queen can take; it found the mate before the fix too.
    const cases = [_][]const u8{
        "7k/8/5KQ1/8/8/8/8/8 w - - 0 1",
        "7k/8/5KQ1/8/8/8/6p1/8 w - - 0 1",
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
        ecache.clear();
        var pos = try fen.parse(case);
        context.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
        const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
        try std.testing.expectEqual(MATE_SCORE - 1, score);
    }
}

test "mate in one and stalemate at the horizon hold with every quiescence rule on" {
    // The switches exist in the tuning flavour; the release flavour has
    // nothing to turn on.
    if (!build_options.tuning) return error.SkipZigTest;
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");
    const tunables = @import("tunables.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    const Expect = enum { mate_in_one, mate_behind_capture, draw, live };
    const Case = struct { fen: []const u8, expect: Expect };
    const cases = [_]Case{
        // Qg7 mates: without a capture, and with one (Qxg2) beside it.
        .{ .fen = "7k/8/5KQ1/8/8/8/8/8 w - - 0 1", .expect = .mate_in_one },
        .{ .fen = "7k/8/5KQ1/8/8/8/6p1/8 w - - 0 1", .expect = .mate_behind_capture },
        .{ .fen = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", .expect = .draw },
        .{ .fen = "7k/5Q2/6K1/8/8/p7/P7/8 b - - 0 1", .expect = .draw },
        .{ .fen = "7k/5Q2/6K1/8/8/p7/8/8 b - - 0 1", .expect = .live },
        .{ .fen = "k7/P7/K7/8/8/8/8/8 b - - 0 1", .expect = .draw },
        .{ .fen = "7k/5K1n/8/7Q/8/8/8/8 b - - 0 1", .expect = .draw },
        .{ .fen = "k7/1b6/1K6/3B4/8/8/8/8 b - - 0 1", .expect = .draw },
    };
    tunables.reset();
    defer tunables.reset();
    try std.testing.expect(tunables.set("QsMoveFutility", 1));
    try std.testing.expect(tunables.set("QsEqualExchangeMargin", 150));
    try std.testing.expect(tunables.set("QsNoUnderpromotion", 1));
    for ([_]types.Score{ 1, 2, 3 }) |gate| {
        try std.testing.expect(tunables.set("QsCheckGate", gate));
        for (cases) |case| {
            // The full window, and for the mates an alpha far above the
            // stand-pat: the gate's margin clause is closed there, and the
            // empty capture list or the boxed-in king has to open it.
            const alphas = [_]types.Score{ -INF, 5000 };
            for (alphas) |alpha| {
                const mate = case.expect == .mate_in_one or case.expect == .mate_behind_capture;
                if (alpha != -INF and !mate) continue;
                var test_basin_config = basin.Config.init(.{});
                var stop_flag = std.atomic.Value(bool).init(false);
                var context = context_mod.SearchContext{
                    .repetition = .{},
                    .control = @import("time.zig").Controller.init(&stop_flag, .{}),
                    .basin_config = &test_basin_config,
                };
                var history_table = history.HistoryTable{};
                table.clear();
                ecache.clear();
                var pos = try fen.parse(case.fen);
                context.repetition.push(pos.zobrist_key);
                evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
                const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, alpha, INF, 0, null);
                switch (case.expect) {
                    .mate_in_one => try std.testing.expectEqual(MATE_SCORE - 1, score),
                    // The control arm (3) searches no quiet check beside a
                    // capture: it is the arm that gives this mate up.
                    .mate_behind_capture => if (gate == 3)
                        try std.testing.expect(!score_mod.isMateLike(score))
                    else
                        try std.testing.expectEqual(MATE_SCORE - 1, score),
                    .draw => try std.testing.expect(basin.isDrawAtDefault(score)),
                    .live => try std.testing.expect(!basin.isDrawAtDefault(score)),
                }
            }
        }
    }
}

test "the quiescence rules skip what they name and search what can reach alpha" {
    if (!build_options.tuning) return error.SkipZigTest;
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");
    const tunables = @import("tunables.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    const Probe = struct {
        fn run(ev: anytype, tbl: anytype, cache: anytype, fen_text: []const u8, alpha_over_static: ?types.Score) !struct { score: types.Score, nodes: u64, static: types.Score } {
            var test_basin_config = basin.Config.init(.{});
            var stop_flag = std.atomic.Value(bool).init(false);
            var context = context_mod.SearchContext{
                .repetition = .{},
                .control = @import("time.zig").Controller.init(&stop_flag, .{}),
                .basin_config = &test_basin_config,
            };
            var history_table = history.HistoryTable{};
            tbl.clear();
            cache.clear();
            var pos = try fen.parse(fen_text);
            context.repetition.push(pos.zobrist_key);
            ev.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
            const static = ev.evaluate(&context.stack, 0, &pos, &context.finny, &context.ft);
            // A scout window that far above the static value, or the full one.
            const alpha = if (alpha_over_static) |distance| static + distance else -INF;
            const beta = if (alpha_over_static != null) alpha + 1 else INF;
            const score = search(&context, .{ .tt = tbl, .eval_cache = cache, .history = &history_table, .evaluator = ev }, &pos, alpha, beta, 0, null);
            return .{ .score = score, .nodes = context.nodes, .static = static };
        }
    };
    // Every rule off and the pawn's gain at 300, whatever the defaults are.
    const Rules = struct {
        fn off() !void {
            inline for (.{ "QsMoveFutility", "QsFutilityKeepChecks", "QsEqualExchangeMargin", "QsNoUnderpromotion", "QsCheckGate" }) |name| {
                try std.testing.expect(tunables.set(name, 0));
            }
            try std.testing.expect(tunables.set("QsGainPawn", 300));
        }
    };
    tunables.reset();
    defer tunables.reset();
    try Rules.off();

    // exd5 and Nxd5 each take a pawn and pass the exchange test. 400 below
    // alpha a pawn's gain of 300 cannot reach it: the rule skips both and the
    // fail low reports stand-pat + 300, the bound of the moves it did not
    // search.
    const pawn_only = "r1bqkbnr/ppp1pppp/2n5/3p4/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 1";
    const pawn_off = try Probe.run(&evaluator, &table, &ecache, pawn_only, 400);
    try std.testing.expect(tunables.set("QsMoveFutility", 1));
    const pawn_on = try Probe.run(&evaluator, &table, &ecache, pawn_only, 400);
    try std.testing.expect(pawn_off.nodes > 1);
    try std.testing.expectEqual(@as(u64, 1), pawn_on.nodes);
    try std.testing.expect(pawn_off.score <= pawn_off.static + 400);
    if (comptime QS_FAIL_LOW_MARGIN > 0 and QS_FAIL_LOW_MARGIN <= 300) {
        try std.testing.expectEqual(pawn_on.static + 300, pawn_on.score);
    }
    // 250 below alpha the pawn can reach it and is searched as before.
    const pawn_near = try Probe.run(&evaluator, &table, &ecache, pawn_only, 250);
    try std.testing.expect(pawn_near.nodes > 1);
    // A queen's gain reaches an alpha 400 above: Bxd5 is searched under the
    // rule and fails high as it does without it. (The two values are soft
    // bounds from different replies and need not be equal.)
    const queen_hangs = "r3k2r/p4ppp/8/3q4/8/5B2/5PPP/R3K2R w KQkq - 0 1";
    const queen_on = try Probe.run(&evaluator, &table, &ecache, queen_hangs, 400);
    try Rules.off();
    const queen_off = try Probe.run(&evaluator, &table, &ecache, queen_hangs, 400);
    try std.testing.expect(queen_on.nodes > 1);
    try std.testing.expect(queen_on.score > queen_on.static + 400);
    try std.testing.expect(queen_off.score > queen_off.static + 400);

    // Under-promotion: the promotion is found without the rook's and the
    // bishop's, in fewer nodes. (The two values need not be equal: in this
    // position the evaluation rates king and rook against king above king
    // and queen against king, 646 to 551, both won.)
    const promotion = "8/4P1k1/8/8/8/8/6K1/8 w - - 0 1";
    const promo_off = try Probe.run(&evaluator, &table, &ecache, promotion, null);
    try std.testing.expect(tunables.set("QsNoUnderpromotion", 1));
    const promo_on = try Probe.run(&evaluator, &table, &ecache, promotion, null);
    try std.testing.expect(promo_on.score > promo_on.static);
    try std.testing.expect(promo_off.score >= promo_on.score);
    try std.testing.expect(promo_on.nodes > 1);
    try std.testing.expect(promo_on.nodes < promo_off.nodes);
    try Rules.off();

    // The control arm searches no quiet check where a capture exists. Qxd7
    // loses the queen to the bishop and is not searched, so the best value
    // stays the stand-pat; the quiet checks are on b3 and d5.
    const checks = "2b3k1/3p2pp/8/8/8/8/5PPP/3Q2K1 w - - 0 1";
    const checks_off = try Probe.run(&evaluator, &table, &ecache, checks, null);
    try std.testing.expect(tunables.set("QsCheckGate", 3));
    const checks_none = try Probe.run(&evaluator, &table, &ecache, checks, null);
    try std.testing.expect(checks_none.nodes < checks_off.nodes);
    // The gated arm keeps them near alpha and drops them far below it: this
    // king has three free squares. (The distance is to the best value so
    // far: a capture that has raised it by the margin closes the gate too.)
    try std.testing.expect(tunables.set("QsCheckGate", 1));
    const checks_near = try Probe.run(&evaluator, &table, &ecache, checks, null);
    try std.testing.expectEqual(checks_off.nodes, checks_near.nodes);
    const gated_far = try Probe.run(&evaluator, &table, &ecache, checks, 2000);
    try Rules.off();
    const open_far = try Probe.run(&evaluator, &table, &ecache, checks, 2000);
    try std.testing.expect(gated_far.nodes < open_far.nodes);
}

test "the capture rules count from the static value one ply before the fifty-move draw" {
    if (!build_options.tuning) return error.SkipZigTest;
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");
    const tunables = @import("tunables.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    tunables.reset();
    defer tunables.reset();
    try std.testing.expect(tunables.set("QsMoveFutility", 1));
    try std.testing.expect(tunables.set("QsGainPawn", 350));
    try std.testing.expect(tunables.set("QsEqualExchangeMargin", 450));
    // White is far ahead and has no pawn: at clock 99 its stand-pat is the
    // draw (rule50.standPatAtBoundary). Qxd4 resets the clock and keeps the
    // advantage, so against an alpha of 400 the capture must be searched:
    // counted from the draw, 0 + 350 would not reach it and the node would
    // fail low on its quiet checks, which all draw. (The static value is far
    // above alpha + 200, the margin the reply's fail low reports within.)
    // Not a late endgame (queen, two rooks and a bishop), so the rule acts.
    const boundary = "r3kb2/8/8/8/3p4/8/8/1R1QK3 w - - 99 1";
    var test_basin_config = basin.Config.init(.{});
    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
        .basin_config = &test_basin_config,
    };
    var history_table = history.HistoryTable{};
    var pos = try fen.parse(boundary);
    try std.testing.expect(phase.phase256(&pos) < LATE_ENDGAME_PHASE_256);
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
    const static = evaluator.evaluate(&context.stack, 0, &pos, &context.finny, &context.ft);
    try std.testing.expect(static >= 700);
    const alpha: types.Score = 400;
    const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, alpha, alpha + 1, 0, null);
    try std.testing.expect(score > alpha);
}

test "an en passant capture is not an equal exchange: its mate is found from far below alpha" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");
    const tunables = @import("tunables.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    const Probe = struct {
        fn run(ev: anytype, tbl: anytype, cache: anytype, fen_text: []const u8, alpha_over_static: types.Score) !struct { score: types.Score, nodes: u64 } {
            var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
            var stop_flag = std.atomic.Value(bool).init(false);
            var context = context_mod.SearchContext{
                .repetition = .{},
                .control = @import("time.zig").Controller.init(&stop_flag, .{}),
                .basin_config = if (build_options.tuning) &test_basin_config else {},
            };
            var history_table = history.HistoryTable{};
            tbl.clear();
            cache.clear();
            var pos = try fen.parse(fen_text);
            try std.testing.expect(phase.phase256(&pos) < LATE_ENDGAME_PHASE_256);
            context.repetition.push(pos.zobrist_key);
            ev.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
            const static = ev.evaluate(&context.stack, 0, &pos, &context.finny, &context.ft);
            const alpha = static + alpha_over_static;
            const score = search(&context, .{ .tt = tbl, .eval_cache = cache, .history = &history_table, .evaluator = ev }, &pos, alpha, alpha + 1, 0, null);
            return .{ .score = score, .nodes = context.nodes };
        }
    };
    // The rules are the defaults of both flavours here (the integration
    // default), so this runs in both.
    tunables.reset();
    defer tunables.reset();
    // Reviewer's witness: e5xd6 en passant is mate. The exchange evaluator
    // returns 0 for every en passant capture without computing anything;
    // read as an equal exchange, the mate was skipped 1000 below alpha and
    // the node failed low at alpha in 6 nodes (the futility rule keeps the
    // capture because it checks; the node rule's 1100 is not reached; the
    // phase is 192, not a late endgame).
    const witness = "nn3B2/8/8/R2pP2k/5K2/6P1/2B5/8 w - d6 0 2";
    const found = try Probe.run(&evaluator, &table, &ecache, witness, 1000);
    try std.testing.expectEqual(MATE_SCORE - 1, found.score);
}

test "a first-ply quiescence node does not reuse a later ply's score" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    const resources = .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator };
    // Code-read finding 3 (2026-11-10): the queen can take on g2, and Qg7 is
    // a quiet mate. A later quiescence ply searches the capture only; its
    // exact score stayed in the table at the first ply's depth, and the
    // first-ply search then returned it in one node.
    var pos = try fen.parse("7k/8/5KQ1/8/8/8/6p1/8 w - - 0 1");
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
    const later_ply = searchDepth(&context, resources, &pos, -INF, INF, 0, 1, null, false);
    try std.testing.expect(!score_mod.isMateLike(later_ply));
    const first_ply = search(&context, resources, &pos, -INF, INF, 0, null);
    try std.testing.expectEqual(MATE_SCORE - 1, first_ply);
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

test "qsearch scores a stalemate as a draw, not statically" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
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
        // Code-read finding 5 (2026-11-10): a stalemate with a piece. The
        // knight is pinned on the h-file and the king has no square (the raw
        // eval is -763).
        .{ .fen = "7k/5K1n/8/7Q/8/8/8/8 b - - 0 1", .draw = true },
        // The same with the knight free to move: a live position.
        .{ .fen = "7k/5K2/7n/8/3Q4/8/8/8 b - - 0 1", .draw = false },
        // A bishop pinned on the long diagonal, the king boxed in.
        .{ .fen = "k7/1b6/1K6/3B4/8/8/8/8 b - - 0 1", .draw = true },
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
        const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
        if (case.draw) {
            try std.testing.expect(basin.isDrawAtDefault(score));
        } else {
            try std.testing.expect(!basin.isDrawAtDefault(score));
        }
        // The stalemate test agrees with the legal generator.
        var all = move_mod.MoveList.init();
        legal.generate(&pos, &all);
        var scratch = move_mod.MoveList.init();
        if (!legal.isInCheck(&pos, pos.side_to_move)) {
            try std.testing.expectEqual(all.count == 0, isStalemate(&pos, &scratch));
            try std.testing.expectEqual(@as(usize, 0), scratch.count);
        }
    }
}

test "stalemate test agrees with the legal generator on random walks with pieces" {
    const fen = @import("../core/fen.zig");
    // Low-material positions with pieces near their own king's lines, where
    // pins and boxed-in kings occur, and two fuller ones.
    const seeds = [_][]const u8{
        "7k/5K1n/8/7Q/8/8/8/8 b - - 0 1",
        "k7/1b6/1K6/3B4/8/8/8/8 b - - 0 1",
        "6k1/6r1/8/8/8/8/5Q2/6RK b - - 0 1",
        "7k/6rp/5K2/8/8/8/8/6R1 b - - 0 1",
        "k1n5/2Q5/1K6/8/8/8/8/8 b - - 0 1",
        "5bk1/5p1p/6pB/8/8/8/8/R5K1 b - - 0 1",
        "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 0 1",
        "8/8/4k3/8/2q5/8/1r6/K7 w - - 0 1",
    };
    var prng = std.Random.DefaultPrng.init(0x57a1_e7a8);
    const rand = prng.random();
    var checked: usize = 0;
    var stalemates: usize = 0;
    for (seeds) |seed| {
        for (0..80) |_| {
            var pos = try fen.parse(seed);
            for (0..40) |_| {
                var all = move_mod.MoveList.init();
                legal.generate(&pos, &all);
                var tactical = move_mod.MoveList.init();
                legal.generateCapturesAndPromotions(&pos, &tactical);
                if (tactical.count == 0 and !legal.isInCheck(&pos, pos.side_to_move)) {
                    var scratch = move_mod.MoveList.init();
                    try std.testing.expectEqual(all.count == 0, isStalemate(&pos, &scratch));
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
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Judge C repro (C-SEE-PIN): Qxf7 is mate (Nd8 pinned by Ra8, Bc4 covers
    // f7). With the pin-blind SEE it scored -800 and the negative-SEE skip
    // dropped it (qsearch 1052).
    var pos = try fen.parse("R2nkb2/3pppp1/8/7Q/2B5/8/8/6K1 w - - 0 1");
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);

    const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expectEqual(MATE_SCORE - 1, score);
}

test "qsearch handles in-check nodes by generating evasions" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
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
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1");
    context.repetition.push(pos.zobrist_key);

    const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expect(score > -MATE_SCORE / 2);
}

test "qsearch stores shallow tt best move when tactical move exists" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
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
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Free queen capture (exd5): an unambiguous tactical move that beats stand-pat
    // for any eval net, so qsearch always stores a best move here.
    var pos = try fen.parse("4k3/8/8/3q4/4P3/8/4K3/8 w - - 0 1");
    context.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);

    _ = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    try std.testing.expect(table.bestMove(pos.zobrist_key) != null);
}

test "qsearch caps a deep repetition-free capture line before stack overflow" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var context = context_mod.SearchContext{
        .repetition = .{},
        .control = @import("time.zig").Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    // The test targets recursion/stack bounds; a model-less backend makes every
    // nonterminal cap fallback exactly zero without needing a synthetic 123-ply
    // accumulator path.
    var evaluator = @import("../eval/backend.zig").EngineState{ .allocator = std.testing.allocator };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // The natural qsearch line e4xd5 e6xd5 Nc3xd5 Nf6xd5 Qd1xd5 is
    // repetition-free and would reach ply 128 when qsearch starts at ply 123.
    var pos = try fen.parse("6k1/8/4pn2/3p4/4P3/2N5/8/3Q2K1 w - - 0 1");
    context.repetition.push(pos.zobrist_key);

    const start_ply = ply_limit.START - 1;
    _ = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, start_ply, null);
    try std.testing.expect(!context.stopped);
    try std.testing.expectEqual(@as(u16, @intCast(ply_limit.START)), context.seldepth);
}

test "qsearch does not return a stale TT lower bound from the rule-50 gate clock on" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
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
        if (case.seed) table.store(pos.zobrist_key, 10 + tt_mod.STORED_DEPTH_OFFSET, 387, .lower, null);
        scores[i] = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
    }
    try std.testing.expect(basin.isDrawAtDefault(scores[0]));
    try std.testing.expect(basin.isDrawAtDefault(scores[1]));
    try std.testing.expect(scores[2] >= 387);
}

test "quiescence does not stand pat on the static value one ply before the fifty-move draw" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // First-principles review, fp-leaves D1: `7k/8/8/8/8/8/8/3QK3 w - - 98 1`
    // scored 588 at depth 1 and 0 at depth 2. After any white move the clock
    // is 99 and Black, at the horizon, stood pat on the static value although
    // each of its moves ends the game drawn.
    const Expect = enum { draw, static_value };
    const Case = struct { fen: []const u8, expect: Expect };
    const cases = [_]Case{
        // The side behind, no pawn: every move draws.
        .{ .fen = "7k/8/8/8/8/8/8/3QK3 b - - 99 1", .expect = .draw },
        // The side ahead, no pawn: every move draws, the queen's checks too.
        .{ .fen = "7k/8/8/8/8/8/8/3QK3 w - - 99 1", .expect = .draw },
        // The side ahead with a pawn that can move keeps its value.
        .{ .fen = "6k1/8/8/8/8/8/4P3/3QK3 w - - 99 1", .expect = .static_value },
        // A blocked pawn keeps nothing.
        .{ .fen = "6k1/8/8/8/8/4p3/4P3/3QK3 w - - 99 1", .expect = .draw },
        // The side behind takes the draw whether or not it has a pawn move.
        .{ .fen = "6k1/4p3/8/8/8/8/8/3QK3 b - - 99 1", .expect = .draw },
        // One ply earlier nothing changes: the static value stands.
        .{ .fen = "7k/8/8/8/8/8/8/3QK3 w - - 98 1", .expect = .static_value },
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
        ecache.clear();
        var pos = try fen.parse(case.fen);
        context.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
        const score = search(&context, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, -INF, INF, 0, null);
        switch (case.expect) {
            .draw => std.testing.expect(basin.isDrawAtDefault(score)) catch |err| {
                std.debug.print("not a draw: {s}\n", .{case.fen});
                return err;
            },
            .static_value => std.testing.expect(score > 300) catch |err| {
                std.debug.print("value lost: {s} scored {d}\n", .{ case.fen, score });
                return err;
            },
        }
    }
}

test "a bound searched under the clock pressure is read only in its own context" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();

    // Review witness (roadmap 2026-11-11, progress): White is a rook and a
    // pawn up, Black is to move, clock 50. For a White root with the pressure
    // on, Black's view of the position is damped (less bad); a quiescence
    // search there stores that as a lower bound. The same position searched
    // in another context (the pressure off; a Black root) must come out as on
    // an empty table.
    const Run = struct {
        fn search_in(
            eval_state: anytype,
            search_table: *tt.TranspositionTable,
            cache: *eval_cache_mod.EvalCache,
            pos: *position.Position,
            root: types.Color,
            pressure: bool,
            beta: types.Score,
        ) types.Score {
            var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
            var stop_flag = std.atomic.Value(bool).init(false);
            var context = context_mod.SearchContext{
                .repetition = .{},
                .control = @import("time.zig").Controller.init(&stop_flag, .{}),
                .basin_config = if (build_options.tuning) &test_basin_config else {},
                .root_color = root,
            };
            context.setProgressPressure(pressure, basin.defaults.progress_clock_bucket);
            var history_table = history.HistoryTable{};
            context.repetition.push(pos.zobrist_key);
            eval_state.prepareRoot(&context.stack, pos, &context.finny, &context.ft);
            // The node's parity as it would be under that root.
            const ply: usize = if (pos.side_to_move == root) 2 else 1;
            return search(&context, .{ .tt = search_table, .eval_cache = cache, .history = &history_table, .evaluator = eval_state }, pos, -INF, beta, ply, null);
        }
    };

    var pos = try fen.parse("3k4/8/3K4/8/8/8/P7/R7 b - - 50 1");
    const raw = blk: {
        var probe_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var context = context_mod.SearchContext{
            .repetition = .{},
            .control = @import("time.zig").Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &probe_basin_config else {},
        };
        evaluator.prepareRoot(&context.stack, &pos, &context.finny, &context.ft);
        break :blk evaluator.evaluate(&context.stack, 0, &pos, &context.finny, &context.ft);
    };
    // The searches below enter at ply 1 or 2 with only the root's
    // accumulator prepared: they read the network's eval from the cache.
    ecache.store(pos.zobrist_key, @intCast(raw));
    const adjusted = progress.searchEval(&basin.defaults, raw, &pos, .white, true);
    try std.testing.expect(raw < -basin.defaults.progress_floor and adjusted > raw);
    const beta = @divTrunc(raw + adjusted, 2);

    // The pressure on, White's root: the damped stand-pat beats beta.
    const on = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    try std.testing.expect(on >= beta);
    // Then the pressure off (the next root, Black's): as on an empty table.
    table.newSearch();
    const off_warm = Run.search_in(&evaluator, &table, &ecache, &pos, .black, false, beta);
    table.clear();
    const off_fresh = Run.search_in(&evaluator, &table, &ecache, &pos, .black, false, beta);
    try std.testing.expectEqual(off_fresh, off_warm);
    try std.testing.expect(off_fresh < beta);

    // The reverse: the table now holds the undamped result; the pressure-on
    // search does not read it.
    table.newSearch();
    const on_warm = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    table.clear();
    const on_fresh = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    try std.testing.expectEqual(on_fresh, on_warm);
    try std.testing.expect(on_fresh >= beta);

    // And the root side: with the pressure on for a Black root nothing is
    // damped here (Black is behind), and White's damped bound is not read.
    table.newSearch();
    const other_root_warm = Run.search_in(&evaluator, &table, &ecache, &pos, .black, true, beta);
    table.clear();
    const other_root_fresh = Run.search_in(&evaluator, &table, &ecache, &pos, .black, true, beta);
    try std.testing.expectEqual(other_root_fresh, other_root_warm);
    try std.testing.expect(other_root_fresh < beta);

    // And the clock (the review's second case): the same root and the
    // pressure on, the position at clock 50 and then at clock 0, where
    // nothing is damped. The key of the position is the same; the bound of
    // clock 50 lies more than a clock bucket away and is not read.
    table.clear();
    _ = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    const key_at_50 = pos.zobrist_key;
    pos.halfmove_clock = 0;
    try std.testing.expectEqual(key_at_50, pos.zobrist_key);
    table.newSearch();
    const clock_warm = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    table.clear();
    const clock_fresh = Run.search_in(&evaluator, &table, &ecache, &pos, .white, true, beta);
    try std.testing.expectEqual(clock_fresh, clock_warm);
    try std.testing.expect(clock_fresh < beta);
}
