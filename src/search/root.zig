const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const context_mod = @import("context.zig");
const eval_cache_mod = @import("eval_cache.zig");
const history_mod = @import("history.zig");
const legal = @import("../movegen/legal.zig");
const attacks = @import("../movegen/attacks.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const node_context = @import("node_context.zig");
const extension_bound = @import("extension_bound.zig");
const piece = @import("../core/piece.zig");
const ordering = @import("ordering.zig");
const ply_limit = @import("ply_limit.zig");
const position = @import("../core/position.zig");
const progress = @import("progress.zig");
const pruning = @import("pruning.zig");
const qsearch = @import("qsearch.zig");
const rule50 = @import("rule50.zig");
const score_mod = @import("score.zig");
const reductions = @import("reductions.zig");
const basin = @import("basin.zig");
const shallow_arms = @import("shallow_arms.zig");
const see = @import("see.zig");
const syzygy = @import("syzygy.zig");
const stats_mod = @import("stats.zig");
const tt_mod = @import("tt.zig");
const tt_probe = @import("tt_probe.zig");
const tt_store = @import("tt_store.zig");
const types = @import("../core/types.zig");
const fail_soft = @import("fail_soft.zig");
const tt_eval = @import("tt_eval.zig");
const default_basin_policy = basin.Params{};

/// `currmove` info is only emitted once a search is both deep and long enough,
/// so it stays silent (and costs nothing) during fast games.
const CURRMOVE_MIN_DEPTH: u16 = 8;
const CURRMOVE_MIN_NS: u64 = 3 * std.time.ns_per_s;

/// True if `mv` is one of the node's killer moves (never pruned/SEE-skipped).
fn isKillerMove(entry: anytype, mv: move_mod.Move) bool {
    if (entry.killer_a) |killer| {
        if (killer == mv) return true;
    }
    if (entry.killer_b) |killer| {
        if (killer == mv) return true;
    }
    return false;
}

pub const RootMoveHint = struct {
    mv: move_mod.Move,
    score: types.Score,
    subtree_nodes: u64,
};

pub const RootMoveHints = struct {
    count: usize = 0,
    hints: [move_mod.MAX_MOVES]RootMoveHint = undefined,

    pub fn record(self: *RootMoveHints, mv: move_mod.Move, score: types.Score, subtree_nodes: u64) void {
        if (self.count >= self.hints.len) return;
        self.hints[self.count] = .{ .mv = mv, .score = score, .subtree_nodes = subtree_nodes };
        self.count += 1;
    }

    pub fn bonusFor(self: *const RootMoveHints, mv: move_mod.Move) i32 {
        for (self.hints[0..self.count], 0..) |hint, rank| {
            if (hint.mv == mv) return rootHintBonus(hint, rank, self.count);
        }
        return 0;
    }
};

pub const MAX_ROOT_ORDER_TRACE: usize = 16;

pub const RootOrderEntry = struct {
    mv: move_mod.Move = move_mod.Move.init(.a1, .a1, .quiet),
    initial_score: i32 = 0,
    previous_hint_bonus: i32 = 0,
    searched_score: ?types.Score = null,
    subtree_nodes: u64 = 0,
};

pub const RootOrderTrace = struct {
    tt_move: ?move_mod.Move = null,
    legal_count: usize = 0,
    count: usize = 0,
    entries: [MAX_ROOT_ORDER_TRACE]RootOrderEntry = [_]RootOrderEntry{.{}} ** MAX_ROOT_ORDER_TRACE,
};

pub const IterationResult = struct {
    best_move: ?move_mod.Move = null,
    score: types.Score = 0,
    depth: u16 = 0,
    root_hints: RootMoveHints = .{},
    root_order: RootOrderTrace = .{},
    /// The caller's incumbent (previous iteration's best move) finished its
    /// search in this pass. Lets an interrupted pass prove a challenger
    /// against it (TM v2 C1); false when no incumbent was given.
    incumbent_completed: bool = false,
};

// Checks extend only at shallow depth (0 = never). Unconditional extension made
// EBF position-blind; see the policy comment at the extension site.
const CHECK_EXTENSION_MAX_DEPTH: u16 = 0;
// The singular margin (2 per ply of depth; 8 + 4 per ply before round 3) and
// the extension's own margin (0; 16 before) are tunables.sweep_sing_margin_base,
// _per_ply, _ext_margin; tunables.zig has the whole form and its old values.
const sing_knobs = @import("tunables.zig");
const SINGULAR_CAPTURE_SEE_THRESHOLD: i32 = 96;
// ProbCut: REVIVED 2026-07-12 (v4.10.0) — the v4.0.6 parking note predicted its
// value concentrates at depth/long TC, and the revival measured exactly that:
// 0.00 +/- 11.1 @20+0.2, +13.2 +/- 10.3 @60+0.6 (LOS 99.4) vs v4.9.0, with
// -10.5% nodes at fixed depth; 200-game field veto-check clean (52.0%/3577 vs
// ref 53.2%/3587, all tiers within noise). Multicut stays enabled. Before
// round 3 the release build reached it only from the rule-50 gate clock on
// (trySingularPlan explains why) and widening the singular eligibility by
// single knobs had washed; round 3's full form (tunables.zig) reaches it at
// every budget through the table-depth slack.
const PROBCUT_ENABLED = true;
const MULTICUT_ENABLED = true;
const PROBCUT_MIN_DEPTH: u16 = 5;
const PROBCUT_MARGIN: i32 = 200;
const PROBCUT_DEPTH_REDUCTION: u16 = 4;
const ROOT_HINT_RANK_SCALE: i32 = 1_024;
const ROOT_HINT_NODE_SCALE: i32 = 768;
const ROOT_HINT_NODE_MAX: i32 = 12_288;
const ROOT_HINT_SCORE_SCALE: i32 = 16;
const ROOT_HINT_SCORE_CLAMP: i32 = 200;

const SingularPlan = struct {
    mv: move_mod.Move,
    extension: i16 = 1,
    /// Multicut: the singular verification (TT move EXCLUDED) failed high at
    /// singular_beta >= beta — a SECOND move beats beta at reduced depth, so the
    /// node has at least two refutations -> cut immediately with this bound.
    multicut: ?types.Score = null,
};

const SingularAttempt = struct {
    /// True only when the excluded-move verification search actually ran.
    applied: bool = false,
    plan: ?SingularPlan = null,
};

const SingularAlternativeQuality = struct {
    alternative_count: usize = 0,
    strongest_history: i32 = std.math.minInt(i32),
    positive_history_count: usize = 0,
    has_good_capture: bool = false,
    has_killer_or_countermove: bool = false,

    fn isWeak(self: SingularAlternativeQuality) bool {
        return self.alternative_count != 0 and !self.has_good_capture;
    }
};

const StagedMoveCounts = struct {
    quiet: usize = 0,
    tactical: usize = 0,
};

/// ZQ_TM_TRACE: what the running pass has proved about the incumbent (the
/// last completed iteration's move) once the incumbent is finished and the
/// pass's best score beats its lower bound: the incumbent holds, or another
/// move beats it. This is the verdict `engine.zig` reads when the pass is
/// interrupted, so with the completed iterations it gives the move a stop at
/// any node would have played. Out of line: the root frame does not grow.
noinline fn traceVerdict(ctx: *context_mod.SearchContext, depth: u16, mv: move_mod.Move, score: types.Score, holds: bool) void {
    const emitter = ctx.info_emitter orelse return;
    var move_text: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&move_text);
    mv.writeUci(&writer) catch {};
    var buffer: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "tm verdict depth {d} nodes {d} move {s} score {d} kind {s}", .{
        depth, ctx.nodes, writer.buffered(), score, if (holds) "incumbent" else "challenger",
    }) catch return;
    emitter.emit(.{ .text = text });
}

/// ZQ_TM_TRACE: the root disarmed the soft deadline before any verdict: the
/// incumbent failed low (`low`), or a full-depth scout of another move beat
/// alpha and its re-search starts (`scout`).
noinline fn traceDisarm(ctx: *context_mod.SearchContext, depth: u16, why: []const u8) void {
    const emitter = ctx.info_emitter orelse return;
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "tm disarm depth {d} nodes {d} why {s}", .{ depth, ctx.nodes, why }) catch return;
    emitter.emit(.{ .text = text });
}

pub fn searchDepth(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    depth: u16,
) IterationResult {
    return searchDepthWindow(ctx, resources, pos, depth, -qsearch.INF, qsearch.INF, null, null, null);
}

pub fn searchDepthWindow(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    depth: u16,
    alpha_in: types.Score,
    beta_in: types.Score,
    previous_root_hints: ?*const RootMoveHints,
    allowed_root_moves: ?*const move_mod.MoveList,
    incumbent: ?move_mod.Move,
) IterationResult {
    if (pos.halfmove_clock >= 100 or ctx.repetition.isClaimableCurrentRepetition(pos.halfmove_clock)) {
        return .{
            .score = if (pos.halfmove_clock >= 100 and rule50.isCheckmated(pos, null)) -score_mod.MATE_SCORE else 0,
            .depth = depth,
        };
    }

    const in_check = legal.isInCheck(pos, pos.side_to_move);
    const entry = ctx.stack.entry(0);
    ctx.root_depth = depth;
    entry.ext_sum = 0;
    // The root has no predecessor; clear it so ply-1 children get no stale
    // continuation context from an earlier iteration/search.
    entry.prev_move = null;
    entry.prev_piece_type = null;
    entry.prev_cont_piece = null;
    // The stack keeps the corrected eval (`improving` compares corrected
    // evals); the root has no previous moves for the continuation classes.
    const root_params: *const basin.Params = if (comptime build_options.tuning) &ctx.basin_config.params else &basin.defaults;
    entry.static_eval = if (in_check) null else blk: {
        const corrected = resources.history.correctedEval(pos, resources.evaluator.evaluate(&ctx.stack, 0, pos, &ctx.finny, &ctx.ft), .{}, root_params);
        break :blk progress.searchEval(root_params, corrected, pos, ctx.root_color, ctx.progress_pressure);
    };

    var moves = move_mod.MoveList.init();
    legal.generateHinted(pos, &moves, in_check);
    filterRootMoves(&moves, allowed_root_moves);
    if (moves.count == 0) {
        return .{
            .score = if (in_check) -score_mod.MATE_SCORE else 0,
            .depth = depth,
        };
    }

    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    // The root's table move orders the root moves only: where this search's
    // context has none yet (the gate has just opened), the plain context's does.
    const tt_move = resources.tt.bestMove(pos.zobrist_key ^ ctx.tableKey(pos.halfmove_clock)) orelse
        (if (ctx.progress_pressure) resources.tt.bestMove(pos.zobrist_key) else null);
    const root_move_counts = if (ctx.recordMoveOrder()) stagedMoveCounts(&moves) else StagedMoveCounts{};
    if (ctx.recordMoveOrder()) ctx.noteStagedMainMoveList(moves.count, root_move_counts.quiet, root_move_counts.tactical, containsMove(&moves, tt_move));
    const root_cont = history_mod.ContContext{}; // root has no predecessor moves
    const attacked = attacks.attackedSquares(pos, pos.side_to_move.other());
    ordering.scoreMoves(pos, &moves, tt_move, .{}, null, resources.history, &root_cont, attacked, .{}, &scores, null);
    var previous_hint_bonuses: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    applyRootHintBonuses(&moves, &scores, previous_root_hints, &previous_hint_bonuses);
    if (shallow_arms.rootNodeOrder()) applyRootNodeOrder(&moves, &scores, previous_root_hints, tt_move);
    var root_order = traceRootOrder(moves, scores, previous_hint_bonuses, tt_move);

    var alpha = alpha_in;
    const alpha_orig = alpha_in;
    const beta = beta_in;
    const cycle_child_key = ctx.repetition.currentPreviousCycleChildKey(pos.halfmove_clock);
    var best_move: ?move_mod.Move = null;
    var best_score: types.Score = -qsearch.INF;
    var best_repeats_cycle = false;
    var root_hints = RootMoveHints{};
    const child_entry = ctx.stack.entry(1);
    var root_searched_quiets: usize = 0;
    var incumbent_completed = false;
    var traced_verdict: ?move_mod.Move = null;

    var root_picker = ordering.MovePicker.init(&moves, &scores, null);
    for (0..moves.count) |index| {
        const mv = root_picker.next(index);
        // UCI currmove progress: only at deeper iterations and after a delay, so
        // it never fires during fast games (zero output/clock-read cost there).
        if (ctx.info_emitter) |emitter| {
            if (depth >= CURRMOVE_MIN_DEPTH) {
                const elapsed_ns = ctx.control.elapsedNs();
                if (elapsed_ns >= CURRMOVE_MIN_NS) {
                    emitter.emit(.{ .currmove = .{
                        .depth = depth,
                        .move = mv,
                        .move_number = @intCast(index + 1),
                        .time_ms = elapsed_ns / std.time.ns_per_ms,
                    } });
                }
            }
        }
        // Honest node reporting excludes the transparent depth-0 wrapper, but
        // root hint ordering is functional and must retain its legacy scale.
        const nodes_before = ctx.rootEffortNodes();
        const is_quiet_root = !mv.isCapture() and !mv.isPromotion();
        if (ctx.recordMoveOrder() and is_quiet_root) root_searched_quiets += 1;
        const moving_piece = pos.pieceAt(mv.from);
        const cont_piece = moving_piece.pieceType();
        const moved_piece_type = if (is_quiet_root) cont_piece else null;
        const root_history_score = if (is_quiet_root and index >= 2)
            resources.history.score(pos.side_to_move, cont_piece, mv.to, history_mod.quietBucket(attacked, mv))
        else
            0;
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock)); // overlap the child's TT miss with the work below
        resources.eval_cache.prefetch(child_key); // and the eval-cache set (probed on a TT eval miss)
        const repeats_cycle = if (cycle_child_key) |key| child_key == key else false;
        ctx.repetition.push(child_key);
        child_entry.prev_move = mv;
        child_entry.prev_piece_type = moved_piece_type;
        child_entry.prev_cont_piece = cont_piece;
        child_entry.ext_sum = 0;
        shallow_arms.setParentLmrReduction(child_entry, 0);
        // Lazy accumulator: record the move only — boards/undo-state are
        // reconstructed at materialization time from the live position.
        resources.evaluator.onMakeMove(&ctx.stack, mv, 0);

        var score: types.Score = undefined;
        if (index == 0) {
            score = -negamax(ctx, resources, pos, depth - 1, -beta, -alpha, 1, true, node_context.NodeContext.fromWindow(-beta, -alpha, false), null, null);
        } else {
            const reduction = rootLateMoveReduction(depth, index, mv, in_check, tt_move != null, root_history_score);
            if (reduction > 0) ctx.noteLmrReduction(reduction, index, true, false);
            ctx.notePvsScout();
            const full_depth = depth - 1;
            const reduced_depth = if (reduction >= full_depth) 0 else full_depth - reduction;
            shallow_arms.setParentLmrReduction(child_entry, reduction);
            score = -negamax(ctx, resources, pos, reduced_depth, -alpha - 1, -alpha, 1, true, node_context.NodeContext.fromWindow(-alpha - 1, -alpha, true), null, null);
            // A reduced scout is only a cheap rejection attempt. As in the
            // interior PVS loop, verify every alpha raise at the full depth
            // before it can affect the root score, PV, or root-node hints.
            if (!ctx.stopped and reduction > 0 and score > alpha) {
                ctx.noteLmrResearch(index, reduction, score, alpha, root_history_score, true, false);
                shallow_arms.setParentLmrReduction(child_entry, reduction);
                score = -negamax(ctx, resources, pos, full_depth, -alpha - 1, -alpha, 1, true, node_context.NodeContext.fromWindow(-alpha - 1, -alpha, true), null, null);
                if (!ctx.stopped) ctx.noteLmrVerificationOutcome(index, reduction, score, alpha, beta, root_history_score, true, false);
            }
            if (!ctx.stopped and score > alpha and score < beta) {
                // TM v2: a full-depth scout already proved this move beats the
                // finished incumbent; do not let the soft deadline discard its
                // re-search (no-op outside TM v2).
                if (incumbent_completed and mv != incumbent) {
                    ctx.control.disarmSoft();
                    if (ctx.control.trace_verdicts) traceDisarm(ctx, depth, "scout");
                }
                ctx.notePvsResearch();
                shallow_arms.setParentLmrReduction(child_entry, reduction);
                score = -negamax(ctx, resources, pos, depth - 1, -beta, -alpha, 1, true, node_context.NodeContext.fromWindow(-beta, -alpha, false), null, null);
            }
        }

        // The tie-break for the move that repeats the game's earlier cycle
        // (below) is asked on a draw score that is only a scout's upper
        // bound: the child is a second occurrence with the opponent to move,
        // and at a window that ends at the draw it returns the draw at its
        // gate without searching (negamax: `draw >= beta_in`). The opponent
        // need not repeat. So before the move may take the best move's place
        // it is searched at full depth with the window just below the draw,
        // where the child has to search: a result below the draw is the
        // move's score and the tie-break is refused. (Witness: a perpetual
        // was given up for the repeating move, which is mated in two.)
        var cycle_tie_verified = false;
        if (!ctx.stopped and cycleTieAsked(score, best_score, repeats_cycle, best_repeats_cycle, ctx.drawDither())) {
            if (comptime context_mod.stats_enabled) ctx.stats.root_cycle_tie_asked += 1;
            const verify_nodes_before = ctx.nodes;
            shallow_arms.setParentLmrReduction(child_entry, 0);
            if (comptime builtin.is_test) ctx.cycle_tie_verifying = true;
            const verified = -negamax(ctx, resources, pos, depth - 1, -score, -score + 1, 1, true, node_context.NodeContext.fromWindow(-score, -score + 1, false), null, null);
            if (comptime builtin.is_test) ctx.cycle_tie_verifying = ctx.stopped;
            if (comptime context_mod.stats_enabled) ctx.stats.root_cycle_tie_nodes += ctx.nodes - verify_nodes_before;
            if (!ctx.stopped) {
                if (verified < score) {
                    score = verified;
                    if (comptime context_mod.stats_enabled) ctx.stats.root_cycle_tie_refused += 1;
                } else {
                    cycle_tie_verified = true;
                    if (comptime context_mod.stats_enabled) ctx.stats.root_cycle_tie_granted += 1;
                }
            }
            // Cut by the stop flag (time, `stop`, the node limit): neither
            // granted nor refused; the loop breaks below before the best move
            // is touched, so the answer is the search so far.
        }

        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);
        const subtree_nodes = ctx.rootEffortNodes() - nodes_before;
        root_hints.record(mv, score, subtree_nodes);
        recordRootOrderSearch(&root_order, mv, score, subtree_nodes);

        if (ctx.stopped) break;
        if (incumbent) |incumbent_move| {
            if (mv == incumbent_move) {
                incumbent_completed = true;
                // TM v2: a failed-low incumbent is unresolved trouble; keep
                // searching past the soft target (no-op outside TM v2).
                if (score <= alpha_orig) {
                    ctx.control.disarmSoft();
                    if (ctx.control.trace_verdicts) traceDisarm(ctx, depth, "low");
                }
            }
        }
        if (score > best_score or cycle_tie_verified) {
            best_score = score;
            best_move = mv;
            best_repeats_cycle = repeats_cycle;
        }
        if (incumbent_completed and best_score > alpha_orig and best_move != incumbent) ctx.control.disarmSoft();
        if (ctx.control.trace_verdicts and incumbent_completed and best_score > alpha_orig and best_move != traced_verdict) {
            traced_verdict = best_move;
            traceVerdict(ctx, depth, best_move.?, best_score, best_move == incumbent);
        }
        if (score > alpha) alpha = score;
        if (alpha >= beta) break;
    }

    if (ctx.recordMoveOrder() and root_searched_quiets == 0) ctx.noteStagedMainNoQuietSearched(root_move_counts.quiet);

    // A bound over a restricted root subset is not valid for a later search of
    // the same position with a different (or absent) `searchmoves` set.
    if (!ctx.stopped and allowed_root_moves == null) {
        const score = if (best_move == null) 0 else best_score;
        tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, @intCast(depth), alpha_orig, beta_in, score, best_move, tt_mod.STATIC_EVAL_NONE, true, 0, pos.halfmove_clock);
    }

    return .{
        .best_move = best_move,
        .score = if (best_move == null) 0 else best_score,
        .depth = depth,
        .root_hints = root_hints,
        .root_order = root_order,
        .incumbent_completed = incumbent_completed,
    };
}

/// Whether a root move asks for the cycle tie-break: it scored exactly the
/// draw, the best move so far did too, it repeats the game's earlier cycle
/// and the best move does not. Asking is not getting: the move is then
/// searched below the draw (searchDepthWindow). With a draw dither
/// (basin.Params.draw_dither) a draw scores within `dither` of 0.
inline fn cycleTieAsked(score: types.Score, best_score: types.Score, repeats_cycle: bool, best_repeats_cycle: bool, dither: types.Score) bool {
    const is_draw = if (dither == 0) score == 0 else @abs(score) <= dither;
    return is_draw and score == best_score and repeats_cycle and !best_repeats_cycle;
}

fn filterRootMoves(moves: *move_mod.MoveList, allowed_root_moves: ?*const move_mod.MoveList) void {
    const allowed = allowed_root_moves orelse return;
    var kept: usize = 0;
    for (moves.slice()) |mv| {
        if (!containsMove(allowed, mv)) continue;
        moves.moves[kept] = mv;
        kept += 1;
    }
    moves.count = kept;
}

test "root move filter preserves generated order" {
    var generated = move_mod.MoveList.init();
    generated.add(move_mod.Move.init(.e2, .e4, .double_push));
    generated.add(move_mod.Move.init(.d2, .d4, .double_push));
    generated.add(move_mod.Move.init(.g1, .h3, .quiet));

    var allowed = move_mod.MoveList.init();
    allowed.add(move_mod.Move.init(.g1, .h3, .quiet));
    allowed.add(move_mod.Move.init(.e2, .e4, .double_push));

    filterRootMoves(&generated, &allowed);

    try std.testing.expectEqual(@as(usize, 2), generated.count);
    try std.testing.expectEqual(move_mod.Move.init(.e2, .e4, .double_push), generated.slice()[0]);
    try std.testing.expectEqual(move_mod.Move.init(.g1, .h3, .quiet), generated.slice()[1]);
}

/// Root LMR deliberately starts one move later than ordinary interior LMR:
/// rank 1 is the PV move and rank 2 is the unreduced control scout. This is the
/// root threshold tested by Stockfish's `moveCount > 1 + rootNode` change and
/// retained by Stormphrax's `legalMoves >= 2 + kRootNode` condition. Root has
/// no predecessor context, killer moves, or improving comparison, so its main
/// history score is the only non-neutral evidence passed to the shared policy.
fn rootLateMoveReduction(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    in_check: bool,
    has_tt_move: bool,
    history_score: i32,
) u16 {
    if (depth < 3 or move_index < 2 or in_check or mv.isCapture() or mv.isPromotion()) return 0;
    return reductions.lateMoveReduction(depth, move_index, mv, false, true, false, has_tt_move, history_score, null, null);
}

fn traceRootOrder(
    moves: move_mod.MoveList,
    scores: [move_mod.MAX_MOVES]i32,
    previous_hint_bonuses: [move_mod.MAX_MOVES]i32,
    tt_move: ?move_mod.Move,
) RootOrderTrace {
    var ordered_moves = moves;
    var ordered_scores = scores;
    var ordered_bonuses = previous_hint_bonuses;
    var trace = RootOrderTrace{ .tt_move = tt_move, .legal_count = moves.count };
    const cap = @min(moves.count, MAX_ROOT_ORDER_TRACE);
    for (0..cap) |index| {
        const best_index = bestScoreIndex(&ordered_scores, ordered_moves.count, index);
        std.mem.swap(move_mod.Move, &ordered_moves.moves[index], &ordered_moves.moves[best_index]);
        std.mem.swap(i32, &ordered_scores[index], &ordered_scores[best_index]);
        std.mem.swap(i32, &ordered_bonuses[index], &ordered_bonuses[best_index]);
        trace.entries[index] = .{
            .mv = ordered_moves.moves[index],
            .initial_score = ordered_scores[index],
            .previous_hint_bonus = ordered_bonuses[index],
        };
        trace.count += 1;
    }
    return trace;
}

fn bestScoreIndex(scores: *const [move_mod.MAX_MOVES]i32, count: usize, start: usize) usize {
    var best = start;
    var index = start + 1;
    while (index < count) : (index += 1) {
        if (scores[index] > scores[best]) best = index;
    }
    return best;
}

fn recordRootOrderSearch(trace: *RootOrderTrace, mv: move_mod.Move, score: types.Score, subtree_nodes: u64) void {
    for (trace.entries[0..trace.count]) |*entry| {
        if (entry.mv == mv) {
            entry.searched_score = score;
            entry.subtree_nodes = subtree_nodes;
            return;
        }
    }
}

/// RootNodeOrder (fp-root P3's measured simple form; vol-frame 4, "root
/// order by effort", whose code this is): with last iteration's hints, the
/// table move first, a move with a hint scored by its subtree nodes, a move
/// without one keeps its score clamped to at most 0. The root reduction then
/// follows the new index by itself.
fn applyRootNodeOrder(moves: *const move_mod.MoveList, scores: *[move_mod.MAX_MOVES]i32, previous_root_hints: ?*const RootMoveHints, tt_move: ?move_mod.Move) void {
    const hints = previous_root_hints orelse return;
    for (moves.slice(), 0..) |mv, idx| {
        if (tt_move != null and mv == tt_move.?) {
            scores[idx] = std.math.maxInt(i32);
            continue;
        }
        var found = false;
        for (hints.hints[0..hints.count]) |hint| {
            if (hint.mv == mv) {
                scores[idx] = @intCast(@min(hint.subtree_nodes, 2_000_000_000));
                found = true;
                break;
            }
        }
        if (!found) scores[idx] = @min(scores[idx], 0);
    }
}

fn applyRootHintBonuses(
    moves: *const move_mod.MoveList,
    scores: *[move_mod.MAX_MOVES]i32,
    previous_root_hints: ?*const RootMoveHints,
    previous_hint_bonuses: *[move_mod.MAX_MOVES]i32,
) void {
    const hints = previous_root_hints orelse return;
    for (moves.slice(), 0..) |mv, idx| {
        const bonus = hints.bonusFor(mv);
        scores[idx] += bonus;
        previous_hint_bonuses[idx] = bonus;
    }
}

fn rootHintBonus(hint: RootMoveHint, rank: usize, total: usize) i32 {
    const remaining = total - rank;
    const rank_bonus = @as(i32, @intCast(remaining)) * ROOT_HINT_RANK_SCALE;
    const score_bonus = std.math.clamp(hint.score, -ROOT_HINT_SCORE_CLAMP, ROOT_HINT_SCORE_CLAMP) * ROOT_HINT_SCORE_SCALE;
    const node_bonus = @min(log2Bonus(hint.subtree_nodes) * ROOT_HINT_NODE_SCALE, ROOT_HINT_NODE_MAX);
    return rank_bonus + score_bonus + node_bonus;
}

fn log2Bonus(value: u64) i32 {
    if (value <= 1) return 0;
    var temp = value;
    var bits: i32 = 0;
    while (temp > 1) : (temp >>= 1) {
        bits += 1;
    }
    return bits;
}

fn negamax(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    depth: u16,
    alpha_window: types.Score,
    beta_window: types.Score,
    ply: usize,
    allow_null: bool,
    node_ctx: node_context.NodeContext,
    excluded_move: ?move_mod.Move,
    // The parent's gives_check for the move that reached this node — provably
    // equal to the entry isInCheck recompute (null falls back to computing).
    // Kills the second-per-node isInCheck: every node paid it once as the
    // parent's gives_check and again here.
    in_check_hint: ?bool,
) align(64) types.Score { // align(64): pins hot entry placement (layout stability, not call speed)
    // A depth-0 negamax entry and the qsearch entry immediately beneath it are
    // one visited position. Dispatch before bookkeeping so qsearch performs the
    // sole node count, stop poll, seldepth observation, and draw check.
    if (depth == 0) {
        return qsearch.searchFromHorizon(ctx, resources, pos, alpha_window, beta_window, ply, in_check_hint);
    }
    // Mate-distance pruning: this node cannot score below being mated here
    // nor above mating with its next move. A window beyond those bounds is
    // clipped, and a window they close needs no search: a mate that short
    // already stands above this node.
    const alpha_in: types.Score = @max(alpha_window, -score_mod.MATE_SCORE + @as(types.Score, @intCast(ply)));
    const beta_in: types.Score = @min(beta_window, score_mod.MATE_SCORE - @as(types.Score, @intCast(ply)) - 1);
    const basin_config = if (comptime build_options.tuning) ctx.basin_config else {};
    // A node re-entered by searchTwofold was counted and tested for draws.
    const resumed = ctx.twofold_resume;
    ctx.twofold_resume = false;
    if (!resumed) {
        if (if (comptime @hasField(@TypeOf(resources), "execution")) resources.execution.noteNode(ctx, false) else ctx.noteNode()) return 0;
        ctx.observePly(ply);
        if (pos.halfmove_clock >= 100) return rule50.interiorScore(ctx, pos, ply, in_check_hint);
        if (ctx.repetition.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock)) {
            const draw = ctx.drawScore(pos.side_to_move);
            // A cycle of the search line and a third occurrence are draws. So is
            // a second occurrence of a game-history position when the root side
            // is to move; with its opponent to move it is the better of a draw
            // and the node's search (repetition.History.repeatsOnlyBeforeRoot).
            if (draw >= beta_in or pos.side_to_move == ctx.root_color or
                !ctx.repetition.repeatsOnlyBeforeRoot(pos.zobrist_key, pos.halfmove_clock)) return draw;
            return searchTwofold(ctx, resources, pos, depth, alpha_in, beta_in, ply, allow_null, node_ctx, excluded_move, in_check_hint, draw);
        }
    }
    if (ply_limit.fallback(ctx, resources.evaluator, pos, ply, in_check_hint)) |score| return score;
    if (alpha_in >= beta_in) return alpha_in;

    const alpha_orig = alpha_in;
    const stack_entry = ctx.stack.entry(ply);
    stack_entry.static_eval = null;
    // Out-pointer probe: fields are written directly into this slot (narrow
    // stores) and read back narrowly — no whole-Result temp + wide copy. See
    // the probeInto doc comment for the store-forward-stall history.
    var probe: tt_probe.Result = undefined;
    tt_probe.probeMainInto(
        &probe,
        ctx,
        resources.tt,
        pos.zobrist_key,
        @intCast(depth),
        alpha_in,
        beta_in,
        excluded_move,
        node_ctx.pv_node,
        node_ctx.cut_node,
        pos.halfmove_clock,
        ply,
    );

    // Syzygy WDL probe (no-op unless SyzygyPath is set): a table hit is ground
    // truth — return it. The inline scope gate (piece count, castling, fresh
    // rule-50 clock) rejects out-of-scope nodes before any call, and the
    // covered probe rechecks it under the lease. Nested rather than through
    // the optional-returning probeWdl so a rejection branches straight past
    // the probe. Singular verification nodes are excluded so the exclusion
    // window still searches.
    if (excluded_move == null) {
        if (ctx.tablebases) |job| {
            if (job.wdlInScope(pos)) {
                if (job.probeCoveredWdl(pos)) |wdl| return syzygy.wdlScore(wdl, ply);
            }
        }
    }
    // Pointer into the local `probe` value, NOT another 32-byte copy: the old
    // `const tt_entry = probe.entry;` re-loaded the just-built Result with one
    // wide (ymm) load spanning the narrower stores that wrote it — a failed
    // store-to-load forward that was the top hot spot in negamax (14.3% of its
    // endgame samples). Value semantics are unchanged (probe.entry is already
    // a snapshot taken at probe time; later TT stores can't mutate it).
    const tt_entry: ?*const tt_mod.Entry = if (probe.entry) |*entry| entry else null;
    if (probe.cutoff) |score| return score;
    var alpha = probe.alpha;
    const beta = probe.beta;
    const tt_move = if (tt_entry) |entry| tt_mod.moveFromEntry(entry.*) else null;
    // The hash move is searched first whenever the node gets to its move loop:
    // start its child's TT and eval-cache misses now, so they overlap this
    // node's static eval and pruning instead of only the make that precedes
    // the child. The key is a prefetch hint only (prefetchKeyAfter).
    if (tt_move) |hash_move| {
        const hinted_key = make_unmake.prefetchKeyAfter(pos, hash_move);
        resources.tt.prefetch(hinted_key ^ ctx.tableKey(progress.clockAfter(pos, hash_move)));
        resources.eval_cache.prefetch(hinted_key);
    }
    var outcome_flags = context_mod.StaticSearchOutcomeFlags{};

    // Internal Iterative Reduction: drop one ply at PV and expected cut-nodes
    // when the TT has no move to seed ordering. The first child's search then
    // lands a useful TT move for subsequent iterations instead of this node
    // running full width with blind ordering.
    var search_depth = depth;
    if (excluded_move == null and tt_move == null and search_depth >= 4 and (node_ctx.pv_node or node_ctx.cut_node)) {
        search_depth -= 1;
        ctx.noteIirReduction(node_ctx.pv_node, node_ctx.cut_node);
    }
    // Reverse futility claims a score from the static eval, which ignores the
    // halfmove clock. From the rule-50 gate clock on, where a table score is
    // no longer trusted (shallow_arms.rule50TrustsTtScore), it is off too: at
    // `7k/8/8/8/8/8/8/3QK3 w - - 99 1` every move draws, and a scout at
    // [0, 1] returned 146.
    const eval_cutoffs_trusted = shallow_arms.rule50TrustsTtScore(pos.halfmove_clock);

    const node_ttpv = basin.ENABLED and (node_ctx.pv_node or (if (tt_entry) |entry| entry.was_pv else false));
    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    if (!in_check and canTrySingular(search_depth, node_ctx, tt_entry, tt_move, excluded_move)) {
        ctx.noteSingularCandidate(search_depth, node_ctx.cut_node);
    }
    var static_eval: ?types.Score = null;
    // The value a static decision reads where its switch is on (tt_eval.zig):
    // the table's score where its bound contradicts the static eval.
    var table_eval: ?types.Score = null;
    var raw_static_eval: ?types.Score = null;
    // Uncertainty: |correction| widens the RFP and futility margins and shortens
    // LMR (basin.Params unc_rfp, unc_futility, lmr_complexity_coeff). With the
    // learned mean never applied, |c| measures class-specific error only.
    var complexity_cp: i32 = 0;
    var corr_cont = history_mod.CorrCont{};
    // This node's correction-history class keys (computed with its static
    // eval); the children's table entries are prefetched from them.
    var corr_keys: ?history_mod.CorrKeys = null;
    var improving = false;
    if (!in_check) {
        ctx.noteMainStaticEval();
        // Lever 1: reuse the raw static eval cached in the TT entry (position-
        // invariant, so identical to recomputing) — skips the NNUE forward on
        // TT hits that didn't cut; every downstream decision is unchanged.
        // perf-r11: on a TT static-eval miss, try the dedicated raw-eval cache
        // (full-64-bit-key verified, same collision class as the TT) before
        // paying the NNUE forward. Like the TT-eval path, a cache hit never
        // calls evaluate(), so the lazy-accumulator materialization is skipped
        // too. Fresh computes are memoized (skip only if outside i16 — exact
        // values only, never clamped).
        const raw = blk: {
            if (tt_entry) |entry| {
                if (entry.static_eval != tt_mod.STATIC_EVAL_NONE) break :blk @as(types.Score, entry.static_eval);
            }
            if (resources.eval_cache.probe(pos.zobrist_key)) |cached| {
                ctx.noteEvalCacheProbe(true);
                break :blk @as(types.Score, cached);
            }
            ctx.noteEvalCacheProbe(false);
            const fresh = resources.evaluator.evaluate(&ctx.stack, ply, pos, &ctx.finny, &ctx.ft);
            if (std.math.cast(i16, fresh)) |memo| resources.eval_cache.store(pos.zobrist_key, memo);
            break :blk fresh;
        };
        raw_static_eval = raw;
        // Correction history (bundle): reverse futility, null-move gates,
        // razoring, ProbCut, quiet futility, bad-capture pruning, the
        // check-extension gate and `improving` use the corrected eval (the stack
        // keeps it). TT and eval-cache slots keep the RAW eval and are corrected
        // on read; the update at the node's end measures against the RAW eval.
        const corr_params: *const basin.Params = if (comptime build_options.tuning) &basin_config.params else &basin.defaults;
        corr_cont = corrContFor(ctx, ply, pos.side_to_move);
        if (resources.history.correction != null) corr_keys = history_mod.corrKeys(pos);
        const corrected = if (corr_keys) |keys|
            resources.history.correctedEvalKeyed(pos.side_to_move, keys, raw, corr_cont, corr_params)
        else
            resources.history.correctedEval(pos, raw, corr_cont, corr_params);
        // With the progress term (progress.searchEval): every decision
        // below, the stack and `improving` use this value.
        const evaluated = progress.searchEval(corr_params, corrected, pos, ctx.root_color, ctx.progress_pressure);
        stack_entry.static_eval = evaluated;
        static_eval = evaluated;
        if (tt_eval.anyMain()) table_eval = tt_eval.refined(tt_entry, evaluated, eval_cutoffs_trusted and excluded_move == null);
        complexity_cp = @intCast(@abs(corrected - raw));
        if (shallow_arms.evalPolicyEnabled() and ply > 0) {
            if (stack_entry.prev_piece_type) |previous_piece| {
                if (stack_entry.prev_move) |previous_move| {
                    if (ctx.stack.entry(ply - 1).static_eval) |parent_eval| {
                        const gain = -parent_eval - evaluated;
                        // Frozen R2.2: this tuning-only parent update remains unconditioned.
                        resources.history.adjustMain(pos.side_to_move.other(), previous_piece, previous_move.to, shallow_arms.evalPolicyBonus(gain), 0);
                    }
                }
            }
        }
        if (shallow_arms.hindsightEnabled() and !node_ctx.pv_node and excluded_move == null and ply > 0) {
            if (ctx.stack.entry(ply - 1).static_eval) |parent_eval| {
                const adjustment = shallow_arms.hindsightAdjustmentWith(
                    true,
                    search_depth,
                    shallow_arms.parentLmrReduction(stack_entry),
                    parent_eval + evaluated,
                    shallow_arms.hindsightMargin(),
                );
                if (adjustment > 0 and search_depth < std.math.maxInt(u16)) {
                    search_depth += 1;
                    ctx.noteHindsightDepthExtension();
                } else if (adjustment < 0) {
                    search_depth -= 1;
                    ctx.noteHindsightDepthReduction();
                }
            }
        }
        improving = isImproving(ctx, ply, evaluated);
        const basin_rfp_max_depth: u16 = if (comptime build_options.tuning) @intCast(basin_config.params.rfp_max_depth) else basin.RFP_MAX_DEPTH;
        const basin_rfp_margin = if (comptime build_options.tuning) basin_config.params.rfpMargin(search_depth, improving) else basin.rfpMargin(search_depth, improving);
        const rfp_eval = if (tt_eval.enabled(.rfp)) table_eval.? else evaluated;
        const rfp_fires = if (basin.ENABLED)
            (eval_cutoffs_trusted and search_depth <= basin_rfp_max_depth and beta - alpha <= 1 and
                !score_mod.isMateLike(alpha) and !score_mod.isMateLike(beta) and
                rfp_eval - basin_rfp_margin - @divTrunc(complexity_cp * corr_params.unc_rfp, 16) >= beta)
        else
            pruning.shouldReverseFutilityPrune(search_depth, alpha, beta, in_check, evaluated, improving);
        if (comptime context_mod.stats_enabled) {
            // The table's score against the static value at this node, whatever the switches (tt_eval.zig).
            const st = &ctx.stats;
            st.tt_eval_nodes += 1;
            if (tt_entry) |entry| {
                if (!score_mod.isDecisive(entry.score) and excluded_move == null) {
                    st.tt_eval_entries += 1;
                    const taken = tt_eval.refinedWith(entry, evaluated, true, -1);
                    const rfp_gate = eval_cutoffs_trusted and search_depth <= basin_rfp_max_depth and beta - alpha <= 1 and
                        !score_mod.isMateLike(alpha) and !score_mod.isMateLike(beta);
                    const rfp_bar = beta + basin_rfp_margin + @divTrunc(complexity_cp * corr_params.unc_rfp, 16);
                    if (taken != evaluated) {
                        st.tt_eval_differs += 1;
                        st.tt_eval_distance += @abs(taken - evaluated);
                        if (@abs(taken - evaluated) > 50) st.tt_eval_differs_50 += 1;
                        if (entry.depth <= 0) st.tt_eval_differs_qs_entry += 1;
                        if (rfp_gate and taken >= rfp_bar and evaluated < rfp_bar) st.tt_eval_rfp_gained += 1;
                        if (rfp_gate and taken < rfp_bar and evaluated >= rfp_bar) st.tt_eval_rfp_refused += 1;
                    }
                    if (rfp_gate and evaluated >= rfp_bar) st.tt_eval_rfp_static += 1;
                    if (beta - alpha <= 1) {
                        if (evaluated < beta and entry.bound == .lower and entry.score >= beta) st.tt_eval_lower_over_beta += 1;
                        if (evaluated >= beta and entry.bound != .lower and entry.score < beta) st.tt_eval_upper_under_beta += 1;
                    }
                } else if (eval_cutoffs_trusted and search_depth <= basin_rfp_max_depth and beta - alpha <= 1 and !score_mod.isMateLike(alpha) and !score_mod.isMateLike(beta) and
                    evaluated - basin_rfp_margin - @divTrunc(complexity_cp * corr_params.unc_rfp, 16) >= beta) st.tt_eval_rfp_static += 1;
            } else if (eval_cutoffs_trusted and search_depth <= basin_rfp_max_depth and beta - alpha <= 1 and !score_mod.isMateLike(alpha) and !score_mod.isMateLike(beta) and
                evaluated - basin_rfp_margin - @divTrunc(complexity_cp * corr_params.unc_rfp, 16) >= beta) st.tt_eval_rfp_static += 1;
        }
        if (rfp_fires) {
            ctx.noteReverseFutilityPrune(search_depth);
            outcome_flags.rfp_cutoff = true;
            if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, beta, alpha_orig, beta, outcome_flags);
            const rfp_softness = if (comptime build_options.tuning) basin_config.params.rfp_softness else basin.defaults.rfp_softness;
            return fail_soft.evalCutoff(beta, if (tt_eval.rfpReturn()) rfp_eval else evaluated, rfp_softness);
        }
        if (pruning.shouldRazor(search_depth, alpha, beta, in_check, if (tt_eval.enabled(.razor)) table_eval.? else evaluated)) {
            const razor_score = qsearch.search(ctx, resources, pos, alpha, beta, ply, in_check);
            if (ctx.stopped) return 0;
            if (razor_score <= alpha) {
                if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, razor_score, alpha_orig, beta, outcome_flags);
                return razor_score;
            }
        }
    }
    // Both null-move gates read the same value.
    const null_eval = if (tt_eval.enabled(.null_move)) table_eval else static_eval;
    const basin_null_ok = if (basin.ENABLED) blk: {
        if (search_depth < 4) break :blk false;
        if (tt_entry) |entry| {
            if (entry.bound == .upper and entry.score < beta) break :blk false;
        }
        const evaluated = null_eval orelse break :blk false;
        const margin = if (comptime build_options.tuning) basin_config.params.nmpMargin(search_depth, improving) else basin.nmpMargin(search_depth, improving);
        break :blk evaluated >= beta + margin;
    } else true;
    // No null move inside a singular verification (excluded-move) search: a
    // pass that clears singular beta says nothing about the alternatives, and
    // its fail high would turn into a multicut the node's own null move refused.
    if (excluded_move == null and basin_null_ok and ply >= ctx.nmp_min_ply and pruning.shouldTryNullMove(allow_null, pos, search_depth, alpha, beta, in_check, null_eval)) {
        const reduction = if (basin.ENABLED)
            (if (comptime build_options.tuning) basin_config.params.nmpReduction(search_depth) else basin.nmpReduction(search_depth))
        else
            reductions.nullMoveReduction(search_depth);
        ctx.noteNullTry();
        make_unmake.makeNullMove(pos, &stack_entry.state);
        // The pass child and its subtree may only repeat positions reached
        // after the pass (repetition.History.floor).
        const saved_repetition_floor = ctx.repetition.pushNullBoundary(pos.zobrist_key);
        // The null child probes the same tables as a move child; start its
        // misses now, as the move loop does after makeMove.
        resources.tt.prefetch(pos.zobrist_key ^ ctx.tableKey(pos.halfmove_clock));
        resources.eval_cache.prefetch(pos.zobrist_key);
        resources.evaluator.onMakeNullMove(&ctx.stack, ply);
        ctx.stack.entry(ply + 1).prev_move = null;
        ctx.stack.entry(ply + 1).prev_piece_type = null;
        ctx.stack.entry(ply + 1).prev_cont_piece = null;
        ctx.stack.entry(ply + 1).ext_sum = stack_entry.ext_sum;
        shallow_arms.setParentLmrReduction(ctx.stack.entry(ply + 1), 0);
        const null_child_ctx = node_context.NodeContext.fromWindow(-beta, -beta + 1, true);
        const null_depth: u16 = if (basin.ENABLED)
            (if (search_depth > reduction) search_depth - reduction else 0)
        else
            (if (search_depth > reduction + 1) search_depth - 1 - reduction else 0);
        const null_score = -negamax(ctx, resources, pos, null_depth, -beta, -beta + 1, ply + 1, false, null_child_ctx, null, false);
        ctx.repetition.popNullBoundary(saved_repetition_floor);
        make_unmake.unmakeNullMove(pos, &stack_entry.state);

        if (ctx.stopped) return 0;
        if (null_score >= beta) {
            // VERIFICATION (the missing half of dynamic R): at depth the enlarged
            // reductions reach positions where a null fail-high can be a zugzwang /
            // deep-tactic illusion — confirm with a reduced REAL search before
            // trusting the cutoff. Cheap: only fires on deep fail-highs, and the
            // verify tree is itself reduced. Without this, the R=3+d/3 bundle won
            // +7.3 @20+0.2 but lost −14.6 @60+0.6 (depth-efficiency v2 gate).
            if (search_depth >= 14 and ctx.nmp_min_ply == 0) {
                // Verify ONCE per branch: disable null for the verify subtree
                // (and the next few plies) so verification cannot cascade.
                const verify_depth = search_depth - reduction;
                ctx.nmp_min_ply = ply + 3 * @as(usize, verify_depth) / 4;
                const verify_ctx = node_context.NodeContext.fromWindow(beta - 1, beta, false);
                const verify_score = negamax(ctx, resources, pos, verify_depth, beta - 1, beta, ply, false, verify_ctx, null, in_check);
                ctx.nmp_min_ply = 0;
                if (ctx.stopped) return 0;
                if (verify_score < beta) {
                    ctx.noteNullVerifyReject();
                } else {
                    ctx.noteNullCutoff();
                    if (static_eval) |evaluated| {
                        outcome_flags.null_cutoff = true;
                        if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, beta, alpha_orig, beta, outcome_flags);
                    }
                    const null_value = fail_soft.nullCutoff(beta, null_score);
                    if (excluded_move == null) tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), null_value, null, tt_store.evalToTt(raw_static_eval), node_ttpv, ply, pos.halfmove_clock);
                    return null_value;
                }
            } else {
                ctx.noteNullCutoff();
                if (static_eval) |evaluated| {
                    outcome_flags.null_cutoff = true;
                    if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, beta, alpha_orig, beta, outcome_flags);
                }
                const null_value = fail_soft.nullCutoff(beta, null_score);
                if (excluded_move == null) tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), null_value, null, tt_store.evalToTt(raw_static_eval), node_ttpv, ply, pos.halfmove_clock);
                return null_value;
            }
        }
    }

    // ProbCut (non-PV, not in check, not inside a singular-excluded search): a good
    // capture that beats beta+margin at reduced depth cuts the node now.
    if (PROBCUT_ENABLED and !node_ctx.pv_node and !in_check and excluded_move == null) {
        if (static_eval) |evaluated| {
            // The required gain reads the table's score where its switch is on (tt_eval.zig).
            const probcut_eval = if (tt_eval.enabled(.probcut)) table_eval.? else evaluated;
            if (tryProbCut(ctx, resources, pos, search_depth, beta, ply, node_ctx, tt_entry, tt_move, probcut_eval, raw_static_eval.?)) |probcut_score| {
                return probcut_score;
            }
            if (ctx.stopped) return 0;
        }
    }

    var moves = move_mod.MoveList.init();
    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    var capture_see_scores: [move_mod.MAX_MOVES]i32 = undefined;
    var staged_counts = StagedMoveCounts{};
    const counter_after_capture = (if (comptime build_options.tuning) ctx.basin_config.params.counter_after_capture else basin.defaults.counter_after_capture) != 0;
    const countermove = previousQuietCountermove(resources.history, stack_entry, pos.side_to_move, counter_after_capture);
    const cont = continuationContext(ctx, ply, pos.side_to_move);
    // Per-node conthist rows for the loop's LMR history evidence (same hoist
    // as inside scoreMoves — value-identical, reads stay live).
    const cont_rows = resources.history.contRows(&cont);

    // HASH MOVE FIRST (perf r12, lane S). When the TT move is legal and no
    // singular check needs the full list, it is searched BEFORE anything is
    // generated: at the nodes where it fails high, generation, legality
    // filtering, SEE scoring and picking never happen. Exact: the TT move is
    // always the first pick anyway (score 1e6, unique), it gets the same
    // capture_see_score (0 — scoreMoves returns before SEE for it) and the
    // same first-move treatment; when it does not cut off, the list is
    // generated and scored exactly as before and the picker's first pick is
    // REPLAYED (the swap that moves the TT move to slot 0 also decides the tie
    // order among the rest), then the loop resumes at slot 1. Legality comes
    // from legal.isLegalMoveHinted, proven equal to list membership on every
    // encoding (legal.zig tests), so an illegal/stale hash move takes the old
    // path unchanged. Null-move/razor/probcut make+unmake in balanced pairs
    // above, so `pos` is unchanged since `in_check` was computed — the hint
    // is exact for both the legality test and generation.
    const tt_first_move: ?move_mod.Move = blk: {
        const candidate = tt_move orelse break :blk null;
        if (excluded_move) |excluded| {
            if (candidate == excluded) break :blk null;
        }
        if (canTrySingular(search_depth, node_ctx, tt_entry, tt_move, excluded_move)) break :blk null;
        if (pos.kingSquare(pos.side_to_move) == null) break :blk null;
        if (!legal.isLegalMoveHinted(pos, candidate, in_check)) break :blk null;
        break :blk candidate;
    };
    var list_ready = false;
    var attacked: u64 = undefined;
    var singular_plan: ?SingularPlan = null;
    var singular_test_applied = false;
    if (tt_first_move == null) {
        legal.generateHinted(pos, &moves, in_check);
        if (moves.count == 0) {
            return if (in_check) -score_mod.MATE_SCORE + @as(types.Score, @intCast(ply)) else ctx.drawScore(pos.side_to_move);
        }
        attacked = attacks.attackedSquares(pos, pos.side_to_move.other());
        scoreGeneratedMoves(ctx, pos, &moves, tt_move, stack_entry, countermove, resources.history, &cont, attacked, &scores, &capture_see_scores, &staged_counts);
        list_ready = true;
        const singular_attempt = if (!in_check or sing_knobs.knob("sweep_sing_in_check") != 0)
            trySingularPlan(ctx, resources, pos, search_depth, ply, node_ctx, tt_entry, tt_move, excluded_move, &moves, &capture_see_scores, stack_entry, countermove, alpha, beta, attacked, in_check)
        else
            SingularAttempt{};
        singular_test_applied = singular_attempt.applied;
        singular_plan = singular_attempt.plan;
        if (singular_plan) |plan| {
            if (plan.multicut) |mc_bound| {
                if (excluded_move == null) {
                    tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(singularVerificationDepth(search_depth)), mc_bound, tt_move, tt_store.evalToTt(raw_static_eval), node_ttpv, ply, pos.halfmove_clock);
                }
                ctx.noteSingularMulticut();
                return mc_bound;
            }
        }
    }

    var best_move: ?move_mod.Move = null;
    var best_score: types.Score = -qsearch.INF;
    var alpha_raises: i32 = 0;
    const child_entry = ctx.stack.entry(ply + 1);
    // Per-ply slot in the thread's context instead of two MAX_MOVES arrays in
    // this frame (see SearchContext.tried_quiets for why no other frame can
    // write this slot while the loop below is running).
    const tried_quiets = ctx.claimTriedQuiets(ply);
    defer ctx.releaseTriedQuiets(ply);
    var quiet_count: usize = 0;
    var searched_quiet_count: usize = 0;
    var moves_searched: usize = 0;

    // Per-node gives-check context, built lazily on the first move that asks
    // (legal.CheckInfo): O(1) per move afterwards, exact.
    var check_info = legal.CheckInfo{};
    // The node's pins for quiet-move SEE, taken on first use.
    var see_pins: ?see.Pins = null;
    var move_picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    var index: usize = 0;
    var tt_stage = tt_first_move != null;
    // True when `moves.moves[index]` already holds the pick for `index`: the
    // pick order is fixed once the list is scored (nothing rewrites moves or
    // scores in the loop), so picking one slot ahead returns the same move
    // and leaves the same list as picking it on its own iteration.
    var lookahead_ready = false;
    while (true) : ({
        if (tt_stage) tt_stage = false else index += 1;
    }) {
        var mv: move_mod.Move = undefined;
        var capture_see_score: i32 = 0;
        if (tt_stage) {
            mv = tt_first_move.?;
        } else {
            if (!list_ready) {
                // The hash move did not cut off: generate + score exactly as
                // the eager path does, replay the first pick (the TT move,
                // by construction the unique 1e6 score) and continue at slot 1.
                legal.generateHinted(pos, &moves, in_check);
                attacked = attacks.attackedSquares(pos, pos.side_to_move.other());
                scoreGeneratedMoves(ctx, pos, &moves, tt_move, stack_entry, countermove, resources.history, &cont, attacked, &scores, &capture_see_scores, &staged_counts);
                const first = move_picker.next(0);
                std.debug.assert(first == tt_first_move.?);
                list_ready = true;
                index = 1;
            }
            if (index >= moves.count) break;
            mv = if (lookahead_ready) moves.moves[index] else move_picker.next(index);
            lookahead_ready = false;
            capture_see_score = move_picker.captureSee(index);
        }
        if (excluded_move) |excluded| {
            if (mv == excluded) continue;
        }
        const move_index = moves_searched;
        const move_number = move_index + 1;
        // No move is pruned on a static rule while the best score so far is
        // a mate score: with its other moves dropped the node would return
        // and store a mate it has not proved (11 such bounds in 21M nodes,
        // none of them confirmed by a search of all moves: first-principles
        // review, fp-selectivity D1). The exchange-evaluation rules below
        // carried this guard already.
        const can_prune_move = moves_searched >= 1 and !score_mod.isMateLike(best_score);
        const is_capture = mv.isCapture();
        const is_promotion = mv.isPromotion();
        const is_quiet = !is_capture and !is_promotion;
        const moving_piece = pos.pieceAt(mv.from);
        const cont_piece = moving_piece.pieceType();
        const moved_piece_type = if (is_quiet) cont_piece else null;
        // LMR history evidence = main history + CONTINUATION history (rung 2 of the
        // EBF ladder): the ordering already ranks by the combined signal, but LMR only
        // saw main history — cont-hist is the stronger of the two for "this quiet is
        // known-good in this line" and lets reductions track evidence, not blindness.
        // TT-stage diagnostics and cutoff writes share the two-query key.
        const history_bucket: u2 = if (is_quiet or build_options.tuning or basin.defaults.lmr_noisy_history_coeff != 423)
            (if (tt_stage) history_mod.ttQuietBucket(pos, mv) else history_mod.quietBucket(attacked, mv))
        else
            0;
        const quiet_history_score: i32 = if (is_quiet) blk: {
            // Explicit row pointer: a runtime piece index through the returned
            // pointer materialises a 128-byte stack copy of the row first (the
            // store-to-load-forwarding defect class HistoryTable.score documents).
            const quiet_row: *const [64]i16 = &resources.history.quietPlane(pos.side_to_move)[history_bucket][@intFromEnum(cont_piece)];
            break :blk @as(i32, quiet_row[@intFromEnum(mv.to)]) +
                cont_rows.total(history_mod.contKeyOfPiece(moving_piece, mv.to));
        } else 0;
        const basin_history_score: i32 = if (comptime build_options.tuning or basin.defaults.lmr_noisy_history_coeff != 423) blk: {
            if (is_quiet) break :blk quiet_history_score;
            const noisy_row: *const [64]i16 = &resources.history.quietPlane(pos.side_to_move)[history_bucket][@intFromEnum(cont_piece)];
            break :blk @as(i32, noisy_row[@intFromEnum(mv.to)]) +
                cont_rows.total(history_mod.contKeyOfPiece(moving_piece, mv.to));
        } else quiet_history_score;
        const move_order_sample: ?stats_mod.MoveOrderSample = if (ctx.recordMoveOrder()) .{
            .bucket = classifyMoveOrderBucket(mv, tt_move, stack_entry.killer_a, stack_entry.killer_b, countermove, capture_see_score, quiet_history_score),
            .node_type = stats_mod.moveOrderNodeType(node_ctx.pv_node, node_ctx.cut_node),
            .depth_band = stats_mod.moveOrderDepthBand(search_depth),
            .history_score = quiet_history_score,
        } else null;
        var gives_check_hint: ?bool = null;
        const basin_lmr_depth = if (basin.ENABLED)
            (if (comptime build_options.tuning) basin_config.lmrDepth(search_depth, move_number, node_ttpv) else basin.lmrDepth(search_depth, move_number, node_ttpv))
        else
            0;
        // Use the basin effective depth for the parked substrate's SEE family.
        if (basin.ENABLED and can_prune_move and !in_check and !isKillerMove(stack_entry, mv) and
            !score_mod.isMateLike(best_score) and best_score > -qsearch.INF + 1024)
        {
            if (is_capture) {
                const threshold = if (comptime build_options.tuning) basin_config.params.seePruneThresholdNoisy(search_depth) else basin.seePruneThresholdNoisy(search_depth);
                if (capture_see_score < 0 and capture_see_score < threshold) {
                    ctx.noteQuietFutilityPrune();
                    continue;
                }
            }
        }
        // The futility estimate of a quiet move (eval + margin + history term);
        // null when the move is not a futility candidate.
        const basin_futility_value: ?types.Score = if (basin.ENABLED) blk: {
            if (!can_prune_move) break :blk null;
            if (!is_quiet or in_check or isKillerMove(stack_entry, mv)) break :blk null;
            const max_lmr_depth = if (comptime build_options.tuning) basin_config.params.futility_lmr_depth_max else basin.FUTILITY_LMRDEPTH_MAX;
            const alpha_cap = if (comptime build_options.tuning) basin_config.params.futility_alpha_cap else basin.FUTILITY_ALPHA_CAP;
            if (basin_lmr_depth > max_lmr_depth) break :blk null;
            if (@abs(alpha) >= alpha_cap) break :blk null;
            const evaluated = (if (tt_eval.enabled(.futility)) table_eval else static_eval) orelse break :blk null;
            const margin = if (comptime build_options.tuning) basin_config.params.futilityMargin(search_depth) else basin.futilityMargin(search_depth);
            const unc_futility = if (comptime build_options.tuning) basin_config.params.unc_futility else basin.defaults.unc_futility;
            break :blk evaluated + margin + @divTrunc(complexity_cp * unc_futility, 16) + @divTrunc(quiet_history_score, 404);
        } else null;
        const basin_futility_fires = if (basin_futility_value) |value| value <= alpha else false;
        if (basin_futility_fires) {
            const gives_check = gives_check_hint orelse nodeGivesCheck(&check_info, pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteQuietFutilityPrune();
                outcome_flags.quiet_futility_prune = true;
                // Fail-soft: the skipped move may be worth up to its estimate, so
                // a fail low may not report less than that.
                if (comptime fail_soft.ENABLED) {
                    const value = basin_futility_value.?;
                    if (value > best_score and !score_mod.isDecisive(best_score)) best_score = value;
                }
                continue;
            }
        }
        if (!basin.ENABLED and can_prune_move and pruning.shouldPruneQuietMove(search_depth, move_index, mv, alpha, beta, in_check, static_eval, improving, stack_entry.killer_a, stack_entry.killer_b)) {
            const gives_check = nodeGivesCheck(&check_info, pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteQuietFutilityPrune();
                outcome_flags.quiet_futility_prune = true;
                continue;
            }
        }
        const lmp_fires = if (basin.ENABLED)
            (can_prune_move and is_quiet and !in_check and beta - alpha <= 1 and move_index >= (if (comptime build_options.tuning) basin_config.params.lmpThreshold(search_depth, improving) else basin.lmpThreshold(search_depth, improving)) and
                !isKillerMove(stack_entry, mv))
        else
            (can_prune_move and pruning.shouldLatePrune(search_depth, move_index, mv, alpha, beta, in_check, improving, stack_entry.killer_a, stack_entry.killer_b));
        if (lmp_fires) {
            const gives_check = gives_check_hint orelse nodeGivesCheck(&check_info, pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteLatePrune();
                outcome_flags.late_move_prune = true;
                continue;
            }
        }
        const history_prune_fires = if (basin.ENABLED)
            (can_prune_move and is_quiet and !in_check and beta - alpha <= 1 and move_index >= 3 and !isKillerMove(stack_entry, mv) and
                basin_lmr_depth <= (if (comptime build_options.tuning) basin_config.params.history_prune_lmr_depth_max else basin.HISTORY_PRUNE_LMRDEPTH_MAX) and
                quiet_history_score < (if (comptime build_options.tuning) basin_config.params.historyPruneThreshold(search_depth) else basin.historyPruneThreshold(search_depth)))
        else
            (can_prune_move and pruning.shouldHistoryPruneQuiet(search_depth, move_index, mv, alpha, beta, in_check, quiet_history_score, stack_entry.killer_a, stack_entry.killer_b));
        if (is_quiet and history_prune_fires) {
            const gives_check = gives_check_hint orelse nodeGivesCheck(&check_info, pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteLatePrune();
                outcome_flags.late_move_prune = true;
                continue;
            }
        }
        if (can_prune_move and is_quiet and !isKillerMove(stack_entry, mv) and !(gives_check_hint orelse false)) {
            const basin_see_gate = basin.ENABLED and basin.SEE_PRUNE_QUIETS and !in_check and
                !score_mod.isMateLike(best_score) and best_score > -qsearch.INF + 1024 and basin_lmr_depth <= 6;
            const legacy_see_gate = pruning.seeQuietPruneGate(search_depth, move_index, alpha, beta, in_check);
            if (basin_see_gate or legacy_see_gate) {
                // The outer SEE fold is max(0, mover_value - reply), so a
                // quiet move cannot score below minus its material value, or
                // minus that and the promotion gain when an enemy pawn can
                // recapture onto its last rank (see.quietFloor).
                const floor = see.quietFloor(pos, mv);
                const basin_threshold = if (basin_see_gate)
                    (if (comptime build_options.tuning) basin_config.params.seePruneThresholdQuiet(basin_lmr_depth) else basin.seePruneThresholdQuiet(basin_lmr_depth))
                else
                    floor;
                const legacy_threshold = if (legacy_see_gate) pruning.seeQuietPruneMargin(search_depth) else floor;
                if (basin_threshold > floor or legacy_threshold > floor) {
                    const union_threshold = @max(basin_threshold, legacy_threshold);
                    if (see.quietBelowWith(pos, mv, union_threshold, see.lazyPins(&see_pins, pos))) {
                        const gives_check = gives_check_hint orelse nodeGivesCheck(&check_info, pos, mv);
                        gives_check_hint = gives_check;
                        if (!gives_check) {
                            if (comptime context_mod.stats_enabled) {
                                const basin_see_prune = basin_see_gate and
                                    (basin_threshold >= legacy_threshold or see.quietBelowWith(pos, mv, basin_threshold, see.lazyPins(&see_pins, pos)));
                                if (basin_see_prune) {
                                    ctx.noteQuietFutilityPrune();
                                } else {
                                    ctx.noteLatePrune();
                                    outcome_flags.late_move_prune = true;
                                }
                            }
                            continue;
                        }
                    }
                }
            }
        }
        if (can_prune_move and is_capture and !is_promotion) {
            if (pruning.shouldPruneBadCaptureMove(search_depth, move_index, mv, alpha, beta, in_check, if (tt_eval.enabled(.bad_capture)) table_eval else static_eval, improving, capture_see_score)) {
                ctx.noteBadCapturePrune();
                outcome_flags.bad_capture_prune = true;
                continue;
            }
        }

        if (move_order_sample) |sample| ctx.noteMoveOrderSearched(sample);
        if (ctx.recordMoveOrder() and is_quiet) searched_quiet_count += 1;
        // The returned key keeps the prefetch/push chain on the register value
        // instead of a load waiting on makeMove's own zobrist store.
        // gives_check (= the child's in_check) from the per-node context: the
        // post-make isInCheck this replaced was the same predicate, one attack
        // query per searched move; the context answers in two bitboard tests.
        const gives_check = gives_check_hint orelse nodeGivesCheck(&check_info, pos, mv);
        // From the second searched move on (the node did not cut on its first),
        // or from the first at a node not expected to cut, pick the next move
        // now and start its child's TT and eval-cache misses, so they overlap
        // this move's whole subtree. Hint key only.
        if (!tt_stage and (moves_searched >= 1 or !node_ctx.cut_node) and index + 1 < moves.count) {
            const upcoming = move_picker.next(index + 1);
            lookahead_ready = true;
            const hinted_key = make_unmake.prefetchKeyAfter(pos, upcoming);
            resources.tt.prefetch(hinted_key ^ ctx.tableKey(progress.clockAfter(pos, upcoming)));
            resources.eval_cache.prefetch(hinted_key);
        }
        const child_key = make_unmake.makeMove(pos, mv, &stack_entry.state);
        resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock)); // overlap the child's TT miss with the work below
        // The eval-cache set only for a child not in check (an in-check node
        // takes no static eval). A hint only.
        if (!gives_check) resources.eval_cache.prefetch(child_key);
        ctx.repetition.push(child_key);
        child_entry.prev_move = mv;
        child_entry.prev_piece_type = moved_piece_type;
        child_entry.prev_cont_piece = cont_piece;

        // Check-extension policy (EBF v2 forensics 2026-07-10/11): unconditional
        // +1 made EBF position-blind (290k extensions at d20 in a K+R+P endgame;
        // we plateaued at d20 where SF hits d47). Full removal converted weak-tier
        // endgames but collapsed our defensive holds vs stronger opponents — the
        // extension's defensive value (perpetual/fortress hunting) lives on the
        // side that is FAILING, while the bloat is checks given comfortably ahead.
        // So: extend at shallow depth always (tactical net) and at ANY depth when
        // the checker is failing low (this line needs a rescue); never otherwise.
        // Fix 2026-09-29: at a mate-bound alpha every centipawn static eval is below
        // alpha, so the test called the WINNING side desperate and extended its checks
        // at every depth (audit position 227: depth 15 past 100M nodes). The desperate
        // test only means something against a centipawn alpha.
        const checker_desperate = ((if (tt_eval.enabled(.check_ext)) table_eval else static_eval) orelse alpha) <= alpha and !score_mod.isMateLike(alpha);
        const unverified_allowed = extension_bound.unverifiedAllowed(alpha);
        const check_extension: i16 = if (shallow_arms.checkExtensionEnabled() and gives_check and unverified_allowed and search_depth <= extension_bound.checkExtMaxDepth() and (search_depth <= CHECK_EXTENSION_MAX_DEPTH or checker_desperate)) 1 else 0;
        var extension = check_extension;
        var check_extension_selected = check_extension > 0;
        var extension_rule: context_mod.SearchContext.ExtensionRule = .check;
        if (singular_plan) |plan| {
            if (plan.mv == mv and (plan.extension < 0 or extension == 0)) {
                extension = plan.extension;
                check_extension_selected = false;
                extension_rule = .verified;
                if (extension > 0) ctx.noteSingularExtension();
                if (extension > 1) ctx.noteSingularDoubleExtension();
            }
        }
        if (singular_plan == null) {
            if (tt_move) |candidate| {
                if (candidate == mv) {
                    if (tt_entry) |entry| {
                        if (static_eval) |evaluated| {
                            const ldse_extension = if (search_depth > extension_bound.ldseMaxDepth() or !unverified_allowed) 0 else shallow_arms.ldseExtension(
                                singular_test_applied,
                                search_depth,
                                in_check,
                                evaluated,
                                alpha,
                                entry.bound == .lower,
                                node_ctx.pv_node,
                                // Any quiescence entry counts as depth 0 here, as before
                                // the two quiescence depths were told apart (tt.zig).
                                @max(entry.depth, tt_mod.QS_FIRST_PLY_DEPTH),
                            );
                            if (ldse_extension > extension) {
                                extension = ldse_extension;
                                check_extension_selected = false;
                                extension_rule = .ldse;
                            }
                        }
                    }
                }
            }
        }
        // No line accumulates more positive extension than the cap allows.
        if (extension > 0) {
            const wanted = extension;
            extension = extension_bound.bounded(extension, stack_entry.ext_sum, extension_bound.cap(ctx.root_depth));
            if (extension > 0) ctx.noteExtensionGranted(extension_rule, extension < wanted) else ctx.noteExtensionCapped();
            if (extension == 0) check_extension_selected = false;
        }
        child_entry.ext_sum = extension_bound.nextSum(stack_entry.ext_sum, extension);
        if (check_extension_selected) ctx.noteCheckExtension();
        const negative_extension = extension < 0;
        const child_base_depth = shallow_arms.childDepth(search_depth, extension);
        const negative_child_ctx = node_context.NodeContext{ .pv_node = false, .cut_node = true };
        // A child searched at depth >= 1 takes a corrected static eval. A move
        // leaves most correction classes untouched (a pawn push changes only the
        // pawn key, a piece move the mover's non-pawn key and one of minor/major),
        // so the child's entries for those classes sit at THIS node's keys in the
        // child's side-to-move row: prefetch all five now, while the child is
        // made and probes the TT. The changed classes' lines are wasted hints.
        if (corr_keys) |keys| {
            if (child_base_depth > 0) resources.history.prefetchCorrection(pos.side_to_move, keys);
        }

        // Lazy accumulator: record the move only (a couple of byte stores). The
        // old ~210B Position snapshot — the store-forward-stall family in the
        // endgame annotate (~12% of negamax samples pre-R4) — is gone: boards are
        // reconstructed at materialization time from the live position, and the
        // undo-state is `stack_entry.state`, live until this make's own unmake.
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);

        var reduction: u16 = 0;
        var score: types.Score = undefined;
        if (move_index == 0) {
            shallow_arms.setParentLmrReduction(child_entry, 0);
            score = -negamax(ctx, resources, pos, child_base_depth, -beta, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_ctx.firstChild(), null, gives_check);
        } else {
            if (basin.ENABLED) {
                const ttpv_fail_low = node_ttpv and (if (tt_entry) |entry| entry.score <= alpha else false);
                const lmr_inputs = basin.LmrInputs{
                    .depth = search_depth,
                    .move_number = move_number,
                    .is_noisy = !is_quiet,
                    .pv_node = node_ctx.pv_node,
                    .cut_node = node_ctx.cut_node,
                    .improving = improving,
                    .gives_check = gives_check,
                    .tt_move_is_noisy = if (tt_move) |move| move.isCapture() else false,
                    .alpha_raises = alpha_raises,
                    .history = basin_history_score,
                    .ttpv = node_ttpv,
                    .ttpv_fail_low = ttpv_fail_low,
                    .complexity = complexity_cp,
                };
                const r1024 = if (comptime build_options.tuning) basin_config.lmrReduction1024(lmr_inputs) else basin.lmrReduction1024(lmr_inputs);
                const reduction_plies = @divTrunc(r1024, 1024);
                const reduced: u16 = if (child_base_depth == 0) 0 else blk: {
                    var target = std.math.clamp(@as(i32, child_base_depth) - reduction_plies, 1, @as(i32, child_base_depth));
                    if (node_ctx.pv_node) target += 1;
                    const tt_pv_brake = if (comptime build_options.tuning) basin_config.params.lmr_tt_pv_brake else basin.defaults.lmr_tt_pv_brake;
                    if (node_ttpv and r1024 < tt_pv_brake) target += 1;
                    break :blk @intCast(std.math.clamp(target, 1, @as(i32, child_base_depth)));
                };
                reduction = child_base_depth - reduced;
                if (reduction > 0) {
                    ctx.noteLmrReduction(reduction, move_index, node_ctx.pv_node, node_ctx.cut_node);
                    if (move_order_sample) |sample| ctx.noteMoveOrderLmrReduction(sample);
                }
                ctx.notePvsScout();
                shallow_arms.setParentLmrReduction(child_entry, reduction);
                score = -negamax(ctx, resources, pos, reduced, -alpha - 1, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_ctx.reducedChild(reduction), null, gives_check);
                if (!ctx.stopped and reduction > 0 and score > alpha) {
                    // A reduction implies child_base_depth >= 2 (`reduced` is at least 1).
                    std.debug.assert(child_base_depth >= 2);
                    const verified_depth: u16 = if (comptime fail_soft.ENABLED) verified: {
                        // One ply short of the full depth (see lmrVerificationDepthFailHard), or
                        // the full depth by the node's role (LmrVerifyFull).
                        std.debug.assert(best_score <= alpha);
                        break :verified child_base_depth - shallow_arms.lmrVerifyShort(node_ctx.pv_node, node_ctx.cut_node);
                    } else lmrVerificationDepthFailHard(
                        score,
                        best_score,
                        child_base_depth,
                        if (comptime build_options.tuning) basin_config.params.deeperThreshold(child_base_depth) else basin.deeperThreshold(child_base_depth),
                    );
                    ctx.noteLmrResearch(move_index, reduction, score, alpha, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                    if (move_order_sample) |sample| ctx.noteMoveOrderLmrResearch(sample);
                    outcome_flags.lmr_research = true;
                    if (verified_depth > reduced) {
                        shallow_arms.setParentLmrReduction(child_entry, reduction);
                        score = -negamax(ctx, resources, pos, verified_depth, -alpha - 1, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_ctx.scoutChild(), null, gives_check);
                    }
                    if (!ctx.stopped) {
                        if (score <= alpha) {
                            outcome_flags.lmr_verification_fail_low = true;
                            if (move_order_sample) |sample| ctx.noteMoveOrderLmrFailLow(sample);
                        }
                        ctx.noteLmrVerificationOutcome(move_index, reduction, score, alpha, beta, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                    }
                }
            } else {
                reduction = reductions.lateMoveReduction(search_depth, move_index, mv, in_check, improving, node_ctx.cut_node, tt_move != null, quiet_history_score, stack_entry.killer_a, stack_entry.killer_b);
                if (reduction > 0) {
                    ctx.noteLmrReduction(reduction, move_index, node_ctx.pv_node, node_ctx.cut_node);
                    if (move_order_sample) |sample| ctx.noteMoveOrderLmrReduction(sample);
                }
                ctx.notePvsScout();
                const reduced = if (reduction >= child_base_depth) 0 else child_base_depth - reduction;
                shallow_arms.setParentLmrReduction(child_entry, reduction);
                score = -negamax(ctx, resources, pos, reduced, -alpha - 1, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_ctx.scoutChild(), null, gives_check);
                if (!ctx.stopped and reduction > 0 and score > alpha) {
                    ctx.noteLmrResearch(move_index, reduction, score, alpha, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                    if (move_order_sample) |sample| ctx.noteMoveOrderLmrResearch(sample);
                    outcome_flags.lmr_research = true;
                    shallow_arms.setParentLmrReduction(child_entry, reduction);
                    score = -negamax(ctx, resources, pos, child_base_depth, -alpha - 1, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_ctx.scoutChild(), null, gives_check);
                    if (!ctx.stopped) {
                        if (score <= alpha) {
                            outcome_flags.lmr_verification_fail_low = true;
                            if (move_order_sample) |sample| ctx.noteMoveOrderLmrFailLow(sample);
                        }
                        ctx.noteLmrVerificationOutcome(move_index, reduction, score, alpha, beta, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                    }
                }
            }
            if (!ctx.stopped and score > alpha and score < beta) {
                ctx.notePvsResearch();
                shallow_arms.setParentLmrReduction(child_entry, reduction);
                score = -negamax(ctx, resources, pos, child_base_depth, -beta, -alpha, ply + 1, true, if (negative_extension) negative_child_ctx else node_context.NodeContext.fromWindow(-beta, -alpha, false), null, gives_check);
            }
        }

        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &stack_entry.state);

        if (ctx.stopped) return 0;
        moves_searched += 1;

        if (score > best_score) {
            best_score = score;
            best_move = mv;
        }
        if (score > alpha) {
            alpha = score;
            alpha_raises += 1;
        }

        if (alpha >= beta) {
            ctx.noteBetaCutoff(move_index);
            if (move_order_sample) |sample| ctx.noteMoveOrderCutoff(sample, move_index == 0);
            if (is_capture and !is_promotion) {
                ctx.noteCaptureCutoff(move_index, capture_see_score, false);
            } else if (!is_promotion) {
                ctx.noteQuietCutoff(move_index, mv, tt_move, stack_entry.killer_a, stack_entry.killer_b, countermove, quiet_history_score);
            }
            if (reduction > 0 and node_ctx.cut_node) {
                ctx.noteCutLmrCutoff(move_index);
                if (move_order_sample) |sample| ctx.noteMoveOrderLmrCutoff(sample);
            }
            if (excluded_move == null) {
                if (moved_piece_type) |quiet_piece_type| {
                    applyQuietCutoffLearning(resources.history, if (comptime build_options.tuning) &basin_config.params else {}, stack_entry, &cont, pos.side_to_move, mv, quiet_piece_type, tried_quiets.moves[0..quiet_count], tried_quiets.pieces[0..quiet_count], search_depth, history_bucket, if (list_ready) attacked else null, counter_after_capture);
                }
            }
            break;
        }

        if (moved_piece_type) |quiet_piece_type| {
            recordTriedQuiet(&tried_quiets.moves, &tried_quiets.pieces, &quiet_count, mv, quiet_piece_type);
        }
    }

    if (ctx.recordMoveOrder() and searched_quiet_count == 0) ctx.noteStagedMainNoQuietSearched(staged_counts.quiet);

    if (ctx.recordStaticOutcomes()) {
        if (static_eval) |evaluated| {
            ctx.noteStaticSearchOutcome(evaluated, best_score, alpha_orig, beta, outcome_flags);
        }
    }
    // A window the table narrowed (a PV node and a decided table score:
    // tt_probe), and a search that contradicts the bound it started from:
    // every move fell short of the table's lower bound, or a move cut above
    // its upper bound. The search's score then lies inside the caller's
    // window, where it would be returned and stored as an exact value, over
    // the deeper entry, although it is only a bound and the entry says
    // otherwise. The node keeps the bound it trusted when it narrowed the
    // window, and neither the table nor the correction history learn from
    // this search. (A search that ends exactly on the bound agrees with it
    // and is exact; nothing changes there.) Counted in won positions: 22
    // such nodes per million; first-principles review, fp-leaves D3 and
    // fp-selectivity D2.
    if (excluded_move == null) {
        if (probe.alpha > alpha_orig and best_score < probe.alpha) return probe.alpha;
        if (beta < beta_in and best_score > beta) return beta;
        // Correction history learning: teach the tables the gap between the raw
        // static eval and the search result (history_mod.correctionLearns: the
        // build's event rule against the caller's window). Mate and tablebase
        // scores and capture best-moves are tactics or oracle values, not eval
        // error.
        if (raw_static_eval) |raw| {
            const best_is_capture = if (best_move) |bm| bm.isCapture() else false;
            const corr_params: *const basin.Params = if (comptime build_options.tuning) &basin_config.params else &basin.defaults;
            const estimate: i32 = static_eval.? + resources.history.correctionMean(pos);
            if (!score_mod.isDecisive(best_score) and !best_is_capture and
                history_mod.correctionLearns(best_score, alpha_orig, beta_in, estimate))
            {
                // The search result carries the progress term: the residual is
                // taken against the raw eval with it, so it is not learned as
                // an eval error.
                const adjusted_raw = progress.searchEval(corr_params, raw, pos, ctx.root_color, ctx.progress_pressure);
                if (corr_keys) |keys| {
                    resources.history.updateCorrectionKeyed(pos, keys, corr_cont, best_score - adjusted_raw, @intCast(search_depth), corr_params);
                } else {
                    resources.history.updateCorrection(pos, corr_cont, best_score - adjusted_raw, @intCast(search_depth), corr_params);
                }
            }
        }
        const stored_move = tt_store.windowResultMove(tt_store.failLowNoMove(), node_ctx.pv_node, alpha_orig, best_score, best_move);
        tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), alpha_orig, beta_in, best_score, stored_move, tt_store.evalToTt(raw_static_eval), node_ttpv, ply, pos.halfmove_clock);
    }
    return best_score;
}

/// A node whose position occurred once before, in the game's history, with
/// the root side's opponent to move: the opponent may take the draw or play
/// on, so the node is worth the better of the two for it. Searched with alpha
/// raised to the draw score; the table keeps the search's own result, which
/// holds on any path.
noinline fn searchTwofold(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    depth: u16,
    alpha: types.Score,
    beta: types.Score,
    ply: usize,
    allow_null: bool,
    node_ctx: node_context.NodeContext,
    excluded_move: ?move_mod.Move,
    in_check_hint: ?bool,
    draw: types.Score,
) types.Score {
    @branchHint(.cold);
    ctx.twofold_resume = true;
    const score = negamax(ctx, resources, pos, depth, @max(alpha, draw), beta, ply, allow_null, node_ctx, excluded_move, in_check_hint);
    return @max(score, draw);
}

/// The eager path's scoring block, shared with the lazy (hash-move-first)
/// path so both produce byte-identical scores and statistics.
fn scoreGeneratedMoves(
    ctx: *context_mod.SearchContext,
    pos: *const position.Position,
    moves: *const move_mod.MoveList,
    tt_move: ?move_mod.Move,
    stack_entry: anytype,
    countermove: ?move_mod.Move,
    history: *const @import("history.zig").HistoryTable,
    cont: *const @import("history.zig").ContContext,
    attacked: u64,
    scores: *[move_mod.MAX_MOVES]i32,
    capture_see_scores: *[move_mod.MAX_MOVES]i32,
    staged_counts: *StagedMoveCounts,
) void {
    if (ctx.recordMoveOrder()) {
        staged_counts.* = stagedMoveCounts(moves);
        ctx.noteStagedMainMoveList(moves.count, staged_counts.quiet, staged_counts.tactical, containsMove(moves, tt_move));
        if (hasPreviousQuietMove(stack_entry)) {
            ctx.noteCountermoveTableProbe(countermove, containsMove(moves, countermove));
        }
    }
    ordering.scoreMoves(
        pos,
        moves,
        tt_move,
        .{ .a = stack_entry.killer_a, .b = stack_entry.killer_b },
        countermove,
        history,
        cont,
        attacked,
        ordering.QuietBonuses.init(if (comptime build_options.tuning) &ctx.basin_config.params else &basin.defaults),
        scores,
        capture_see_scores,
    );
}

inline fn nodeGivesCheck(info: *legal.CheckInfo, pos: *const position.Position, mv: move_mod.Move) bool {
    // Replaces the per-move predicate / make-unmake round trip (R7's density
    // dispatch): one lazily built per-node context, exact (see legal.CheckInfo).
    info.ensure(pos);
    return info.givesCheck(pos, mv);
}

fn stagedMoveCounts(moves: *const move_mod.MoveList) StagedMoveCounts {
    var counts = StagedMoveCounts{};
    for (moves.slice()) |mv| {
        if (mv.isCapture() or mv.isPromotion()) {
            counts.tactical += 1;
        } else {
            counts.quiet += 1;
        }
    }
    return counts;
}

fn containsMove(moves: *const move_mod.MoveList, needle: ?move_mod.Move) bool {
    const target = needle orelse return false;
    for (moves.slice()) |mv| {
        if (mv == target) return true;
    }
    return false;
}

/// LMR verification depth after a reduced scout failed high, as tuned under
/// fail-hard returns: one ply deeper when the scout beat the best score by
/// `deeper_threshold`, one ply shallower when it beat it by less than the
/// depth. Only the fail-hard flavour (`-Dfail-soft=false`) still runs it.
///
/// The fail-soft build kept the rule but fed it the clamped values it was
/// tuned on (A3b: raw fail-soft magnitudes stopped the shortening, cold depth
/// 13 +16.8% nodes). Those values are fixed there: the scout failed high, so
/// min(score, alpha + 1) is alpha + 1, and max(best_score, alpha) is alpha,
/// because a searched score above alpha raises alpha and a fail-soft
/// futility value is at most alpha. "Deeper" then needs deeper_threshold < 1,
/// but the threshold is at least 2 even at the tuning minimums (13 or more at
/// the defaults); "shallower" needs child_base_depth > 1, which every
/// reduction implies. So the fail-soft verification depth is always
/// child_base_depth - 1, and negamax uses that directly (audit A finding 7;
/// judge A, item A10). The research_base and research_per_depth tunables
/// only act in the fail-hard flavour.
fn lmrVerificationDepthFailHard(score: types.Score, best_score: types.Score, child_base_depth: u16, deeper_threshold: i32) u16 {
    var research_depth: i32 = child_base_depth;
    if (score > best_score + deeper_threshold) research_depth += 1;
    if (score < best_score + child_base_depth) research_depth -= 1;
    return @intCast(std.math.clamp(research_depth, 1, @as(i32, child_base_depth) + 1));
}

test "the fail-soft LMR verification depth is the clamped rule's only outcome" {
    // Every reachable input of the clamped rule (scout alpha + 1 against best
    // alpha) over the depths and thresholds the release and tuning builds can
    // produce gives child_base_depth - 1.
    var child_base_depth: u16 = 2;
    while (child_base_depth <= 128) : (child_base_depth += 1) {
        try std.testing.expect(basin.deeperThreshold(child_base_depth) >= 2);
        var threshold: i32 = 2;
        while (threshold <= 64) : (threshold += 1) {
            for ([_]types.Score{ -27_000, -100, 0, 35, 2_000 }) |alpha| {
                try std.testing.expectEqual(child_base_depth - 1, lmrVerificationDepthFailHard(alpha + 1, alpha, child_base_depth, threshold));
            }
        }
    }
    // The tuning ranges' smallest threshold, at the smallest reduced depth.
    var smallest = basin.defaults;
    smallest.research_base = 22;
    smallest.research_per_depth = 2;
    smallest.unit_percent = 10;
    try std.testing.expect(smallest.deeperThreshold(2) >= 2);
}

fn canTrySingular(
    search_depth: u16,
    node_ctx: node_context.NodeContext,
    tt_entry: ?*const tt_mod.Entry,
    tt_move: ?move_mod.Move,
    excluded_move: ?move_mod.Move,
) bool {
    if (excluded_move != null) return false;
    // Expected cut nodes always; PV nodes and expected all nodes by switch.
    const pv_try = node_ctx.pv_node and sing_knobs.knob("sweep_sing_pv") != 0;
    if (node_ctx.pv_node and !pv_try) return false;
    if (!node_ctx.pv_node and !node_ctx.cut_node and sing_knobs.knob("sweep_sing_all") == 0) return false;
    const min_depth = @as(i32, shallow_arms.singularMinDepth()) + (if (node_ctx.pv_node) sing_knobs.knob("sweep_sing_pv_min_extra") else 0);
    if (@as(i32, search_depth) < min_depth or search_depth > shallow_arms.singularMaxDepth()) return false;

    const entry = tt_entry orelse return false;
    const mv = tt_move orelse return false;
    // A lower bound; an exact score counts too at a PV node under its switch, and everywhere under sweep_sing_exact.
    if (entry.bound != .lower and !((pv_try or sing_knobs.knob("sweep_sing_exact") != 0) and entry.bound == .exact)) return false;
    if (mv.isPromotion()) return false;
    if (score_mod.isMateLike(entry.score)) return false;
    const required_depth = @as(i16, @intCast(search_depth)) - shallow_arms.singularTtDepthSlack();
    return entry.depth >= @max(required_depth, 0);
}

/// ProbCut: at a non-PV node, if a good capture's REDUCED-depth search already beats
/// beta by a solid margin, the full-depth search will almost surely beat beta too ->
/// cut now. Distilled from the SF scheme: qsearch pre-verification, then a depth-4
/// zero-window verification; candidates are tactical moves whose SEE can plausibly
/// bridge (probcut_beta - static_eval).
fn tryProbCut(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    search_depth: u16,
    beta: types.Score,
    ply: usize,
    node_ctx: node_context.NodeContext,
    tt_entry: ?*const tt_mod.Entry,
    tt_move: ?move_mod.Move,
    corrected_eval: types.Score,
    raw_static_eval: types.Score,
) ?types.Score {
    if (search_depth < PROBCUT_MIN_DEPTH) return null;
    if (score_mod.isMateLike(beta)) return null;
    const probcut_beta: types.Score = beta + PROBCUT_MARGIN;
    // The TT already bounds this node BELOW probcut_beta at (near-)verification depth:
    // the reduced search is unlikely to clear it — skip the work.
    if (tt_entry) |entry| {
        if (entry.depth >= @as(i16, @intCast(search_depth - PROBCUT_DEPTH_REDUCTION)) and entry.score < probcut_beta) return null;
    }

    var moves = move_mod.MoveList.init();
    // ProbCut only runs at !in_check nodes (gated at the call site).
    legal.generateCapturesAndPromotionsHinted(pos, &moves, false);
    if (moves.count == 0) return null;
    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    var capture_see_scores: [move_mod.MAX_MOVES]i32 = undefined;
    ordering.scoreTacticalMoves(pos, &moves, tt_move, &scores, &capture_see_scores);

    const required_gain: i32 = @as(i32, probcut_beta) - @as(i32, corrected_eval);
    var picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    for (0..moves.count) |index| {
        const mv = picker.next(index);
        // Only candidates whose material swing can plausibly bridge the gap.
        if (mv.isCapture() and !mv.isPromotion() and picker.captureSee(index) < required_gain) continue;

        const entry = ctx.stack.entry(ply);
        const child_entry = ctx.stack.entry(ply + 1);
        const moving_piece = pos.pieceAt(mv.from);
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key ^ ctx.tableKey(pos.halfmove_clock));
        resources.eval_cache.prefetch(child_key);
        ctx.repetition.push(child_key);
        child_entry.prev_move = mv;
        child_entry.prev_piece_type = null;
        child_entry.prev_cont_piece = moving_piece.pieceType();
        child_entry.ext_sum = entry.ext_sum;
        shallow_arms.setParentLmrReduction(child_entry, 0);
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        // cheap qsearch pre-verification, then the reduced-depth confirmation
        var score = -qsearch.search(ctx, resources, pos, -probcut_beta, -probcut_beta + 1, ply + 1, null);
        if (!ctx.stopped and score >= probcut_beta) {
            const verify_ctx = node_ctx.probCutChild();
            score = -negamax(ctx, resources, pos, search_depth - PROBCUT_DEPTH_REDUCTION, -probcut_beta, -probcut_beta + 1, ply + 1, true, verify_ctx, null, null);
        }
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);
        if (ctx.stopped) return null;
        if (score >= probcut_beta) {
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth - PROBCUT_DEPTH_REDUCTION + 1), score, mv, tt_store.evalToTt(raw_static_eval), false, ply, pos.halfmove_clock);
            return score;
        }
    }
    return null;
}

fn trySingularPlan(
    ctx: *context_mod.SearchContext,
    resources: anytype,
    pos: *position.Position,
    search_depth: u16,
    ply: usize,
    node_ctx: node_context.NodeContext,
    tt_entry: ?*const tt_mod.Entry,
    tt_move: ?move_mod.Move,
    excluded_move: ?move_mod.Move,
    moves: *const move_mod.MoveList,
    capture_see_scores: *const [move_mod.MAX_MOVES]i32,
    stack_entry: anytype,
    countermove: ?move_mod.Move,
    alpha: types.Score,
    beta: types.Score,
    attacked: u64,
    in_check: bool,
) SingularAttempt {
    if (!canTrySingular(search_depth, node_ctx, tt_entry, tt_move, excluded_move)) return .{};

    const entry = tt_entry orelse return .{};
    const candidate = tt_move orelse return .{};

    const required_depth = @as(i16, @intCast(search_depth)) - shallow_arms.singularTtDepthSlack();
    if (entry.depth < @max(required_depth, 0)) return .{};

    const alternative_quality = classifySingularAlternatives(
        pos,
        moves,
        capture_see_scores,
        candidate,
        stack_entry,
        countermove,
        resources.history,
        attacked,
    );
    if (shallow_arms.singularWeakGateEnabled()) {
        if (!alternative_quality.isWeak()) return .{};
        ctx.noteSingularWeakAlternativeCandidate();
    }

    const margin = singularMargin(search_depth);
    const singular_beta = std.math.clamp(entry.score - margin, -qsearch.INF, qsearch.INF);
    const verification_alpha = singular_beta - 1;
    const verification_depth = singularVerificationDepth(search_depth);
    if (verification_depth == 0) return .{};

    ctx.noteSingularVerification();
    ctx.noteSingularVerificationAt(node_ctx.pv_node, node_ctx.cut_node);
    // The table move is the node's only legal move: no other move exists that
    // could reach the bound, so the verification fails low by everything, as
    // its move loop returns when it has nothing to search. It is not searched:
    // inside it reverse futility cuts on the static value before any move is
    // generated, and that fail high would be read as "a second move also
    // reaches the bound" (a multicut or a shallower table move at a node with
    // one move; first-principles review of the form, 0.1 per million nodes).
    const only_move = moves.count == 1 and moves.moves[0] == candidate;
    const verification_score = if (only_move) -qsearch.INF else negamax(
        ctx,
        resources,
        pos,
        verification_depth,
        verification_alpha,
        singular_beta,
        ply,
        true,
        // The node's own expected role (sweep_sing_verify_inherit, on since round 3); an all node otherwise.
        node_context.NodeContext.fromWindow(verification_alpha, singular_beta, sing_knobs.knob("sweep_sing_verify_inherit") != 0 and node_ctx.cut_node),
        candidate,
        in_check,
    );
    if (ctx.stopped) return .{ .applied = true };
    if (verification_score < singular_beta) {
        ctx.noteSingularVerified();
        const extension_margin = sing_knobs.knob("sweep_sing_ext_margin");
        if (verification_score <= singular_beta - extension_margin) {
            // A second ply when it fails low by a second margin as well (off by default).
            const double_margin = sing_knobs.knob("sweep_sing_double_margin");
            const double_here = !node_ctx.pv_node or sing_knobs.knob("sweep_sing_double_pv") != 0;
            const plies: i16 = if (double_here and double_margin > 0 and verification_score <= singular_beta - extension_margin - double_margin) 2 else 1;
            return .{ .applied = true, .plan = .{ .mv = candidate, .extension = plies } };
        }
        return .{ .applied = true };
    }
    // Verification failed high WITHOUT the TT move: a second refutation exists. If the
    // verification bound already clears beta, cut the node (multicut). Mate-band scores
    // are excluded — bounds near mate don't compose across the reduced-depth verify.
    //
    // With a table-depth slack of 0 (the default before round 3) this branch
    // is reached only from the rule-50 gate clock on (audit A, S-MULTICUT;
    // review round, judge A F7): a singular candidate is then a lower bound at
    // least as deep as this node (IIR, which lowers the depth, needs a missing
    // TT move) with a non-mate score. Below halfmove clock 90 the main TT probe
    // has already cut on any such bound >= beta, so entry.score < beta here and
    // singular_beta = entry.score - singularMargin(d) < beta. From clock 90 on
    // (shallow_arms.rule50TrustsTtScore) the probe takes no cutoff and does not
    // narrow the window, but keeps the entry for ordering: the candidate can
    // arrive with entry.score >= beta + margin, and the node cuts on
    // singular_beta, which the reduced-depth verification search (TT move
    // excluded) has just reached at the current clock (review round: 74 fires
    // at clock 90, 0 at clock 0, normal21 at depth 16). With a positive slack
    // (3 since round 3's full form) the candidate may be an entry shallower
    // than the node, which the probe did not cut on, so the branch is reached
    // at every clock; likewise with a TT cutoff gate (tt_cutoff_node_role, or
    // tt_cutoff_halfmove_max below its default 90).
    if (MULTICUT_ENABLED and sing_knobs.knob("sweep_sing_multicut") != 0 and !node_ctx.pv_node and singular_beta >= beta and !score_mod.isMateLike(singular_beta)) {
        return .{ .applied = true, .plan = .{ .mv = candidate, .extension = 0, .multicut = singular_beta } };
    }
    const negative_extension = shallow_arms.singularNegativeExtension(entry.score, alpha, beta, node_ctx.cut_node);
    if (negative_extension < 0) {
        return .{ .applied = true, .plan = .{ .mv = candidate, .extension = negative_extension } };
    }
    return .{ .applied = true };
}

fn classifySingularAlternatives(
    pos: *const position.Position,
    moves: *const move_mod.MoveList,
    capture_see_scores: *const [move_mod.MAX_MOVES]i32,
    tt_move: move_mod.Move,
    stack_entry: anytype,
    countermove: ?move_mod.Move,
    history: *const @import("history.zig").HistoryTable,
    attacked: u64,
) SingularAlternativeQuality {
    var quality = SingularAlternativeQuality{};
    for (moves.slice(), 0..) |mv, idx| {
        if (mv == tt_move) continue;
        quality.alternative_count += 1;

        if (mv.isPromotion()) {
            quality.has_good_capture = true;
            continue;
        }
        if (mv.isCapture()) {
            if (capture_see_scores[idx] >= SINGULAR_CAPTURE_SEE_THRESHOLD) quality.has_good_capture = true;
            continue;
        }
        if (stack_entry.killer_a) |killer| {
            if (killer == mv) quality.has_killer_or_countermove = true;
        }
        if (stack_entry.killer_b) |killer| {
            if (killer == mv) quality.has_killer_or_countermove = true;
        }
        if (countermove) |candidate| {
            if (candidate == mv) quality.has_killer_or_countermove = true;
        }

        const history_score = lmrHistoryScore(history, pos, mv, attacked);
        if (history_score > quality.strongest_history) quality.strongest_history = history_score;
        if (history_score > 0) quality.positive_history_count += 1;
    }
    return quality;
}

fn singularMargin(search_depth: u16) i32 {
    return sing_knobs.knob("sweep_sing_margin_base") + @as(i32, search_depth) * sing_knobs.knob("sweep_sing_margin_per_ply");
}

fn singularVerificationDepth(search_depth: u16) u16 {
    const base = @max(0, @as(i32, search_depth) - sing_knobs.knob("sweep_sing_verify_sub"));
    return @intCast(@max(1, @divTrunc(base * sing_knobs.knob("sweep_sing_verify_pct"), 100)));
}

fn lmrHistoryScore(history: *const @import("history.zig").HistoryTable, pos: *const position.Position, mv: move_mod.Move, attacked: u64) i32 {
    if (mv.isCapture() or mv.isPromotion()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    const color = moving_piece.color() orelse return 0;
    return history.score(color, moving_piece.pieceType(), mv.to, history_mod.quietBucket(attacked, mv));
}

fn classifyMoveOrderBucket(
    mv: move_mod.Move,
    tt_move: ?move_mod.Move,
    killer_a: ?move_mod.Move,
    killer_b: ?move_mod.Move,
    countermove: ?move_mod.Move,
    capture_see_score: i32,
    quiet_history_score: i32,
) stats_mod.MoveOrderBucket {
    if (tt_move) |candidate| {
        if (candidate == mv) return .tt;
    }
    if (mv.isPromotion()) return .promotion;
    if (mv.isCapture()) return if (capture_see_score >= 0) .good_capture else .bad_capture;
    if (killer_a) |candidate| {
        if (candidate == mv) return .killer_a;
    }
    if (killer_b) |candidate| {
        if (candidate == mv) return .killer_b;
    }
    if (countermove) |candidate| {
        if (candidate == mv) return .countermove;
    }
    if (quiet_history_score > 0) return .positive_history_quiet;
    if (quiet_history_score < 0) return .negative_history_quiet;
    return .zero_history_quiet;
}

// Inline: called once per node from the negamax hot path; as an out-of-line
// call it showed up as its own symbol in the endgame profile (call/spill
// overhead on top of the single countermove-table load it performs).
inline fn previousQuietCountermove(
    history: *const @import("history.zig").HistoryTable,
    stack_entry: anytype,
    side_to_move: types.Color,
    after_capture: bool,
) ?move_mod.Move {
    const previous_move = stack_entry.prev_move orelse return null;
    if (after_capture) {
        // Any predecessor: keyed by the piece that moved and its square.
        const any_piece = stack_entry.prev_cont_piece orelse return null;
        return history.counterMove(side_to_move.other(), any_piece, previous_move.to);
    }
    const previous_piece_type = stack_entry.prev_piece_type orelse return null;
    if (previous_move.isCapture() or previous_move.isPromotion()) return null;
    return history.counterMove(side_to_move.other(), previous_piece_type, previous_move.to);
}

fn hasPreviousQuietMove(stack_entry: anytype) bool {
    const previous_move = stack_entry.prev_move orelse return false;
    _ = stack_entry.prev_piece_type orelse return false;
    return !previous_move.isCapture() and !previous_move.isPromotion();
}

fn applyQuietCutoffLearning(
    history: *history_mod.HistoryTable,
    basin_policy: if (build_options.tuning) *const basin.Params else void,
    stack_entry: anytype,
    cont: *const history_mod.ContContext,
    side: types.Color,
    mv: move_mod.Move,
    moved_piece_type: piece.PieceType,
    quiets: []const move_mod.Move,
    quiet_pieces: []const piece.PieceType,
    depth: u16,
    bucket: u2,
    attacked: ?u64,
    counter_after_capture: bool,
) void {
    rememberKiller(stack_entry, mv);
    if (comptime build_options.tuning) {
        history.bonusWithPolicy(basin_policy, side, moved_piece_type, mv.to, depth, bucket);
        history.contBonusWithPolicy(basin_policy, cont, history_mod.contKey(side, moved_piece_type, mv.to), depth);
    } else {
        history.bonus(side, moved_piece_type, mv.to, depth, bucket);
        history.contBonus(cont, history_mod.contKey(side, moved_piece_type, mv.to), depth);
    }
    penalizeFailedQuiets(history, basin_policy, side, quiets, quiet_pieces, depth, attacked);
    for (quiets, quiet_pieces) |quiet, quiet_piece| {
        if (comptime build_options.tuning)
            history.contPenalizeWithPolicy(basin_policy, cont, history_mod.contKey(side, quiet_piece, quiet.to), depth)
        else
            history.contPenalize(cont, history_mod.contKey(side, quiet_piece, quiet.to), depth);
    }

    const previous_move = stack_entry.prev_move orelse return;
    if (counter_after_capture) {
        const any_piece = stack_entry.prev_cont_piece orelse return;
        history.rememberCounterMove(side.other(), any_piece, previous_move.to, mv);
        return;
    }
    const previous_piece_type = stack_entry.prev_piece_type orelse return;
    if (previous_move.isCapture() or previous_move.isPromotion()) return;
    history.rememberCounterMove(side.other(), previous_piece_type, previous_move.to, mv);
}

/// Continuation-history keys for the node at `ply`: the 1-ply predecessor (the
/// opponent's last move) and the 2-ply predecessor (our own last move). Each is
/// `CONT_NONE` when that offset has no usable move (null move or root).
// Inline for the same reason as previousQuietCountermove (once per node; the
// out-of-line call's sret store/reload showed as a skid sample at its call
// site in the endgame annotate).
inline fn continuationContext(ctx: *context_mod.SearchContext, ply: usize, side: types.Color) history_mod.ContContext {
    var cont = history_mod.ContContext{};
    const e1 = ctx.stack.entry(ply);
    if (e1.prev_move) |pm| {
        if (e1.prev_cont_piece) |pc| cont.prev[0] = history_mod.contKey(side.other(), pc, pm.to);
    }
    if (ply >= 1) {
        const e2 = ctx.stack.entry(ply - 1);
        if (e2.prev_move) |pm| {
            if (e2.prev_cont_piece) |pc| cont.prev[1] = history_mod.contKey(side, pc, pm.to);
        }
    }
    return cont;
}

fn recordTriedQuiet(
    quiets: *[move_mod.MAX_MOVES]move_mod.Move,
    quiet_pieces: *[move_mod.MAX_MOVES]piece.PieceType,
    quiet_count: *usize,
    mv: move_mod.Move,
    moved_piece_type: piece.PieceType,
) void {
    quiets[quiet_count.*] = mv;
    quiet_pieces[quiet_count.*] = moved_piece_type;
    quiet_count.* += 1;
}

/// Continuation-correction keys of a node: the continuation-history keys of
/// its 1-ply and 2-ply predecessors (`continuationContext`); CONT_NONE where
/// that has none (null move, root).
inline fn corrContFor(ctx: *context_mod.SearchContext, ply: usize, stm: types.Color) history_mod.CorrCont {
    const cont = continuationContext(ctx, ply, stm);
    return .{ .k1 = cont.prev[0], .k2 = cont.prev[1] };
}

fn isImproving(ctx: *context_mod.SearchContext, ply: usize, static_eval: types.Score) bool {
    if (ply < 2) return false;
    const previous = ctx.stack.entry(ply - 2).static_eval orelse return false;
    return static_eval > previous;
}

fn rememberKiller(entry: anytype, mv: move_mod.Move) void {
    if (entry.killer_a) |killer| {
        if (killer == mv) return;
    }
    entry.killer_b = entry.killer_a;
    entry.killer_a = mv;
}

fn penalizeFailedQuiets(
    history: anytype,
    basin_policy: if (build_options.tuning) *const basin.Params else void,
    side: types.Color,
    quiets: []const move_mod.Move,
    quiet_pieces: []const piece.PieceType,
    depth: u16,
    attacked: ?u64,
) void {
    std.debug.assert(quiets.len == quiet_pieces.len);
    const map = attacked orelse {
        std.debug.assert(quiets.len == 0); // TT-stage cutoff: no failed quiets, no map.
        return;
    };
    for (quiets, quiet_pieces) |quiet, quiet_piece| {
        if (comptime build_options.tuning)
            history.penalizeWithPolicy(basin_policy, side, quiet_piece, quiet.to, depth, history_mod.quietBucket(map, quiet))
        else
            history.penalize(side, quiet_piece, quiet.to, depth, history_mod.quietBucket(map, quiet));
    }
}

test "penalize failed quiets updates only the provided piece-to entries" {
    const history = @import("history.zig");

    var history_table = history.HistoryTable{};
    const quiets = [_]move_mod.Move{
        move_mod.Move.init(.a2, .a3, .quiet),
        move_mod.Move.init(.g1, .f3, .quiet),
    };
    const quiet_pieces = [_]piece.PieceType{ .pawn, .knight };

    penalizeFailedQuiets(&history_table, if (comptime build_options.tuning) &default_basin_policy else {}, .white, &quiets, &quiet_pieces, 5, 0);

    try std.testing.expect(history_table.score(.white, .pawn, .a3, 0) < 0);
    try std.testing.expect(history_table.score(.white, .knight, .f3, 0) < 0);
    try std.testing.expectEqual(@as(i32, 0), history_table.score(.white, .pawn, .e4, 0));
}

test "root hint bonuses prefer previously expensive promising moves" {
    var moves = move_mod.MoveList.init();
    const quiet_a = move_mod.Move.init(.a2, .a3, .quiet);
    const quiet_b = move_mod.Move.init(.h2, .h3, .quiet);
    moves.add(quiet_a);
    moves.add(quiet_b);

    var scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    var hints = RootMoveHints{};
    var bonuses: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    hints.record(quiet_b, 80, 20_000);
    hints.record(quiet_a, -10, 200);
    applyRootHintBonuses(&moves, &scores, &hints, &bonuses);

    const first = ordering.pickNext(&moves, &scores, null, 0);
    try std.testing.expectEqual(quiet_b, first);
}

test "depth-zero negamax counts one honest horizon node" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    ctx.stack.entry(1).acc.refresh(evaluator.net.?, &pos);

    _ = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 0, -qsearch.INF, -qsearch.INF + 1, 1, true, node_context.NodeContext.fromWindow(-qsearch.INF, -qsearch.INF + 1, false), null, null);

    try std.testing.expectEqual(@as(u64, 1), ctx.nodes);
    try std.testing.expectEqual(@as(u64, 1), ctx.stats.horizon_transitions);
    try std.testing.expectEqual(@as(u64, 2), ctx.rootEffortNodes());
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.qnodes);

    // A node limit still polls on the one honest qsearch visit. The stopped
    // entry never reached the legacy duplicate, so it records no transition.
    ctx.nodes = 0;
    ctx.stats.horizon_transitions = 0;
    ctx.stopped = false;
    ctx.control = time.Controller.init(&stop_flag, .{ .node_limit = 1 });
    _ = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 0, -qsearch.INF, -qsearch.INF + 1, 1, true, node_context.NodeContext.fromWindow(-qsearch.INF, -qsearch.INF + 1, false), null, null);
    try std.testing.expect(ctx.stopped);
    try std.testing.expectEqual(@as(u64, 1), ctx.nodes);
    try std.testing.expectEqual(@as(u64, 0), ctx.stats.horizon_transitions);
    try std.testing.expectEqual(@as(u64, 1), ctx.rootEffortNodes());
}

test "reverse futility does not publish a heuristic tt bound" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    ctx.stack.entry(1).acc.refresh(evaluator.net.?, &pos);

    const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 2, 49, 50, 1, true, node_context.NodeContext.fromWindow(49, 50, false), null, null);
    // Fail-soft returns beta moved toward the eval (fail_soft.evalCutoff); a
    // fail-hard build returns beta itself.
    if (comptime fail_soft.ENABLED) {
        try std.testing.expect(score > 50 and !score_mod.isDecisive(score));
    } else {
        try std.testing.expectEqual(@as(types.Score, 50), score);
    }
    try std.testing.expect(table.lookup(pos.zobrist_key) == null);
}

test "a second occurrence of a game-history position is searched only with the root side's opponent to move" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // White to move mates with Qg7. The position stands at ply 2 of a search
    // whose root is the third key; its first occurrence is the first key, in
    // the game's history.
    for ([_]types.Color{ .black, .white }) |root_color| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        ecache.clear();
        // The node is searched at ply 2, so the evaluator and the stack get
        // the history a ply-2 node has: the root two plies earlier, then
        // Qg6+ Kh8 made the way the search makes moves.
        var pos = try fen.parse("6k1/8/5K2/6Q1/8/8/8/8 w - - 6 4");
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        for ([_][]const u8{ "g5g6", "g8h8" }, 0..) |text, made_ply| {
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            var played = false;
            for (moves.slice()) |mv| {
                var buffer: [5]u8 = undefined;
                if (!std.mem.eql(u8, mv.toUci(&buffer), text)) continue;
                const moved = pos.pieceAt(mv.from).pieceType();
                _ = make_unmake.makeMove(&pos, mv, &ctx.stack.entry(made_ply).state);
                const child = ctx.stack.entry(made_ply + 1);
                child.prev_move = mv;
                child.prev_piece_type = moved;
                child.prev_cont_piece = moved;
                shallow_arms.setParentLmrReduction(child, 0);
                evaluator.onMakeMove(&ctx.stack, mv, made_ply);
                played = true;
                break;
            }
            try std.testing.expect(played);
        }
        try std.testing.expectEqual((try fen.parse("7k/8/5KQ1/8/8/8/8/8 w - - 8 5")).zobrist_key, pos.zobrist_key);
        for ([_]u64{ pos.zobrist_key, 0x1111, 0x2222, 0x3333, pos.zobrist_key }) |key| ctx.repetition.push(key);
        ctx.repetition.root = 2;
        ctx.root_color = root_color;
        const resources = .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator };
        const score = negamax(&ctx, resources, &pos, 3, -qsearch.INF, qsearch.INF, 2, true, node_context.NodeContext.fromWindow(-qsearch.INF, qsearch.INF, false), null, null);
        if (root_color == .black) {
            // The root side's opponent is to move: it plays on and mates.
            try std.testing.expectEqual(score_mod.MATE_SCORE - 3, score);
        } else {
            // The root side is to move: a draw, without a search.
            try std.testing.expect(basin.isDrawAtDefault(score));
            try std.testing.expectEqual(@as(u64, 1), ctx.nodes);
        }
    }
}

test "reverse futility respects the rule-50 gate clock" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Code-read finding 6 (2026-11-10): White is a queen up at clock 99, no
    // move resets the clock or mates, so every move reaches clock 100, a draw.
    // The scout at [0, 1] must come back with a draw's value, not the static
    // one. Cold it returned 146 (reverse futility), although the table probe
    // distrusts scores from clock 90 on; a search of the same board at clock 0
    // first must not change that. A draw in the tree is worth at most the
    // dither (basin.Params.draw_dither, 1 by default), so that is the bound;
    // with the dither at 0 it is the old "must fail low".
    const Case = struct { clock0_first: bool };
    for ([_]Case{ .{ .clock0_first = false }, .{ .clock0_first = true } }) |case| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        ecache.clear();
        const resources = .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator };
        if (case.clock0_first) {
            var fresh = try fen.parse("7k/8/8/8/8/8/8/3QK3 w - - 0 1");
            ctx.repetition.clear();
            ctx.repetition.push(fresh.zobrist_key);
            evaluator.prepareRoot(&ctx.stack, &fresh, &ctx.finny, &ctx.ft);
            const warm = negamax(&ctx, resources, &fresh, 1, 0, 1, 0, true, node_context.NodeContext.fromWindow(0, 1, false), null, null);
            try std.testing.expect(warm >= 1);
            table.clear();
        }
        var pos = try fen.parse("7k/8/8/8/8/8/8/3QK3 w - - 99 1");
        ctx.repetition.clear();
        ctx.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        const score = negamax(&ctx, resources, &pos, 1, 0, 1, 0, true, node_context.NodeContext.fromWindow(0, 1, false), null, null);
        try std.testing.expect(score <= basin.defaults.draw_dither);
    }
}

const SeededSearchResult = struct {
    score: types.Score,
    nodes: u64,
};

/// Test helper: one negamax call at ply 0 on fresh tables, after `seed`
/// (a struct with `fn apply(*TranspositionTable, key)`) has written entries
/// for the searched position.
fn searchSeededForTest(fen_text: []const u8, depth: u16, alpha: types.Score, beta: types.Score, seed: anytype) !SeededSearchResult {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history_mod.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse(fen_text);
    ctx.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
    seed.apply(&table, pos.zobrist_key);

    const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, depth, alpha, beta, 0, true, node_context.NodeContext.fromWindow(alpha, beta, false), null, null);
    try std.testing.expect(!ctx.stopped);
    return .{ .score = score, .nodes = ctx.nodes };
}

const NoSeed = struct {
    fn apply(_: NoSeed, _: *tt_mod.TranspositionTable, _: u64) void {}
};

const ExactTtSeed = struct {
    score: types.Score,
    fn apply(self: ExactTtSeed, table: *tt_mod.TranspositionTable, key: u64) void {
        table.store(key, 10 + tt_mod.STORED_DEPTH_OFFSET, self.score, .exact, null);
    }
};

test "a TT score stored far from the 50-move boundary does not cut at clock 99" {
    // Judge A repro (S-RULE50-TT) one ply down: after Qg5 at clock 98 Black's
    // only move Kh7 reaches clock 100, a draw. A deep exact entry for the
    // same board, stored at a low clock, used to answer instead (warm 165
    // against cold 0 at the root).
    // The node is searched with a full window, so it is a PV node: only a
    // decided score may cut there (shallow_arms.pvTtDecidedScore). The seed
    // is decided and differs from every value the search finds itself, so
    // the low-clock result can only be the table's.
    const seeded: types.Score = -(shallow_arms.PV_TT_DECIDED_SCORE_DEFAULT + 165);
    const low_clock = try searchSeededForTest("7k/8/5K2/6Q1/8/8/8/8 b - - 0 1", 1, -qsearch.INF, qsearch.INF, ExactTtSeed{ .score = seeded });
    try std.testing.expectEqual(seeded, low_clock.score);
    const high_clock = try searchSeededForTest("7k/8/5K2/6Q1/8/8/8/8 b - - 99 1", 1, -qsearch.INF, qsearch.INF, ExactTtSeed{ .score = seeded });
    try std.testing.expect(basin.isDrawAtDefault(high_clock.score));
}

const UpperTtSeed = struct {
    score: types.Score,
    fn apply(self: UpperTtSeed, table: *tt_mod.TranspositionTable, key: u64) void {
        // Depth 1 as the search counts it (tt.STORED_DEPTH_OFFSET).
        table.store(key, 1 + tt_mod.STORED_DEPTH_OFFSET, self.score, .upper, null);
    }
};

test "a TT upper bound stored far from the 50-move boundary does not narrow the window at clock 99" {
    // Review-round witness (S-RULE50-TT): an upper bound one above alpha
    // turned the window [alpha, INF] into a scout window at clock 99 without
    // closing it, and razoring returned a lost score; Kh7, the only move,
    // reaches clock 100, a draw.
    // The node is a PV node, so the bound is a decided score, the only kind
    // the PV rule would let narrow (shallow_arms.pvTtDecidedScore), stored at
    // the node's depth: nothing but the rule-50 gate keeps it out.
    const fen_text = "7k/8/5K2/6Q1/8/8/8/8 b - - 99 1";
    const upper: types.Score = -(shallow_arms.PV_TT_DECIDED_SCORE_DEFAULT + 136);
    const alpha = upper - 1;
    const cold = try searchSeededForTest(fen_text, 1, alpha, qsearch.INF, NoSeed{});
    try std.testing.expect(basin.isDrawAtDefault(cold.score));
    const seeded = try searchSeededForTest(fen_text, 1, alpha, qsearch.INF, UpperTtSeed{ .score = upper });
    try std.testing.expect(basin.isDrawAtDefault(seeded.score));

    // Tuning flavour: with the gate switched off the same entry does narrow
    // the window and the result is no longer the draw, so the assertion above
    // rests on the gate.
    if (build_options.tuning) {
        const tunables = @import("tunables.zig");
        tunables.reset();
        defer tunables.reset();
        try std.testing.expect(tunables.set("TtCutoffHalfmoveMax", 100));
        const ungated = try searchSeededForTest(fen_text, 1, alpha, qsearch.INF, UpperTtSeed{ .score = upper });
        try std.testing.expect(!basin.isDrawAtDefault(ungated.score));
    }
}

const ForeignDecisiveSeed = struct {
    narrow_tag: bool,
    fn apply(self: ForeignDecisiveSeed, table: *tt_mod.TranspositionTable, key: u64) void {
        // Another position of the searched position's cluster: its key
        // differs only in the top bit, so the two share the cluster and the
        // low 31 tag bits. Its entry is as tempting as an entry can be: a
        // mate, exact, far deeper than the search.
        const foreign = key ^ (@as(u64, 1) << 63);
        if (self.narrow_tag) table.policy.tag_bits = 16;
        table.store(foreign, 60 + tt_mod.STORED_DEPTH_OFFSET, score_mod.MATE_SCORE - 3, .exact, null);
    }
};

test "a decisive entry of another position in the same cluster never reaches the search" {
    const fen_text = "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4";
    const cold = try searchSeededForTest(fen_text, 3, -qsearch.INF, qsearch.INF, NoSeed{});
    try std.testing.expect(!score_mod.isDecisive(cold.score));
    const planted = try searchSeededForTest(fen_text, 3, -qsearch.INF, qsearch.INF, ForeignDecisiveSeed{ .narrow_tag = false });
    try std.testing.expectEqual(cold.score, planted.score);
    try std.testing.expectEqual(cold.nodes, planted.nodes);
    // The same entry under a 16-bit tag (the stress knob of the tuning
    // flavour) is taken for the searched position's own and returned: what
    // the whole tag prevents.
    if (build_options.tuning) {
        const narrow = try searchSeededForTest(fen_text, 3, -qsearch.INF, qsearch.INF, ForeignDecisiveSeed{ .narrow_tag = true });
        try std.testing.expectEqual(score_mod.MATE_SCORE - 3, narrow.score);
        try std.testing.expectEqual(@as(u64, 1), narrow.nodes);
    }
}

test "basin futility searches a first quiet move before pruning" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Only quiet moves are legal, and the deliberately high alpha makes basin
    // futility eligible for every one. The first must still complete so the
    // node cannot publish -INF as a false mate score.
    var pos = try fen.parse("8/8/8/8/8/8/4k3/6K1 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);

    const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 3, 499, 500, 0, true, node_context.NodeContext.fromWindow(499, 500, false), null, false);
    try std.testing.expect(score > -qsearch.INF + 1024);
    try std.testing.expect(!score_mod.isMateLike(score));
    const stored = table.lookup(pos.zobrist_key).?;
    // The node fails low: its entry is an upper bound, and carries the
    // searched move only where a fail low stores one (tt_store.failLowNoMove).
    try std.testing.expectEqual(tt_mod.Bound.upper, stored.bound);
    try std.testing.expectEqual(tt_store.failLowNoMove() == 0, tt_mod.moveFromEntry(stored) != null);
    try std.testing.expect(!score_mod.isMateLike(stored.score));
}

test "a node whose searched moves are all mated prunes none of the others" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();

    // First-principles review, fp-selectivity D1. The knight on f6 holds h7
    // against Qxh7 mate. The history puts two knight moves that give h7 up
    // first; both are mated at once. At depth 1 the late-move rule then
    // dropped every other quiet move, most of which hold, and the node
    // returned and stored "mated". (Clock 90: reverse futility is off there,
    // so the window can sit well below the static eval and the replies'
    // stand-pat does not cut before the mate is seen.)
    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    for (0..4) |bucket| {
        history_table.adjustMain(.black, .knight, .e8, 8000, @intCast(bucket));
        history_table.adjustMain(.black, .knight, .d7, 8000, @intCast(bucket));
    }
    var pos = try fen.parse("5rk1/5ppp/5n2/8/8/3Q4/2B2PPP/6K1 b - - 90 1");
    ctx.repetition.push(pos.zobrist_key);
    ctx.root_color = .black;
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
    const static_value = evaluator.evaluate(&ctx.stack, 0, &pos, &ctx.finny, &ctx.ft);
    const alpha: types.Score = static_value - 300;
    const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 1, alpha, alpha + 1, 0, true, node_context.NodeContext.fromWindow(alpha, alpha + 1, false), null, false);
    // The two knight moves were searched and are mated.
    try std.testing.expect(ctx.nodes >= 3);
    std.testing.expect(!score_mod.isMateLike(score)) catch |err| {
        std.debug.print("mated at {d} with the window at {d}\n", .{ score, alpha });
        return err;
    };
    const stored = table.lookup(pos.zobrist_key).?;
    try std.testing.expect(!score_mod.isMateLike(stored.score));
}

test "a search that contradicts the table bound that narrowed its window returns the bound and stores nothing" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();

    // First-principles review, fp-leaves D3 and fp-selectivity D2. At a PV
    // node a decided table bound (400 or more) narrows the window without
    // closing it. A level position, a deep entry of an earlier search that
    // says "at least 500" or "at most -500", and a depth-2 search that finds
    // neither: every move fails low against the raised alpha, or the first
    // move cuts against the lowered beta. The node used to return the
    // search's own score, inside the caller's window and so as an exact
    // value, and to store it as exact over the deep entry.
    const Case = struct { bound: tt_mod.Bound, score: types.Score };
    for ([_]Case{ .{ .bound = .lower, .score = 500 }, .{ .bound = .upper, .score = -500 } }) |case| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history_table = history.HistoryTable{};
        table.clear();
        ecache.clear();
        var pos = try fen.parse("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
        ctx.repetition.push(pos.zobrist_key);
        ctx.root_color = .white;
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        const seeded_move = move_mod.Move.init(.e2, .e4, .double_push);
        table.store(pos.zobrist_key, 10 + tt_mod.STORED_DEPTH_OFFSET, case.score, case.bound, seeded_move);
        // The entry is an earlier search's: this search may write over it.
        table.newSearch();
        const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 2, -1000, 1000, 0, true, node_context.NodeContext.fromWindow(-1000, 1000, false), null, false);
        std.testing.expectEqual(case.score, score) catch |err| {
            std.debug.print("returned {d} against the table's {s} bound {d}\n", .{ score, @tagName(case.bound), case.score });
            return err;
        };
        const entry = table.lookup(pos.zobrist_key).?;
        try std.testing.expectEqual(case.bound, entry.bound);
        try std.testing.expectEqual(@as(i32, case.score), entry.score);
        try std.testing.expectEqual(seeded_move, tt_mod.moveFromEntry(entry).?);
    }
}

test "ProbCut stores raw rather than corrected static eval" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const time = @import("time.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/3q4/4P3/8/4K3/8 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);

    const raw: types.Score = -321;
    const corrected: types.Score = 1000;
    const cutoff = tryProbCut(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, PROBCUT_MIN_DEPTH, -10_000, 0, node_context.NodeContext.fromWindow(-10_001, -10_000, true), null, null, corrected, raw);
    try std.testing.expect(cutoff != null);
    try std.testing.expectEqual(@as(i16, @intCast(raw)), table.lookup(pos.zobrist_key).?.static_eval);
}

test "previous quiet countermove ignores tactical previous moves" {
    const history = @import("history.zig");
    const stack = @import("stack.zig");

    var history_table = history.HistoryTable{};
    const response = move_mod.Move.init(.g8, .f6, .quiet);
    history_table.rememberCounterMove(.white, .pawn, .e4, response);

    var quiet_entry = stack.StackEntry{
        .prev_move = move_mod.Move.init(.e2, .e4, .double_push),
        .prev_piece_type = .pawn,
    };
    try std.testing.expectEqual(response, previousQuietCountermove(&history_table, &quiet_entry, .black, false).?);

    var tactical_entry = stack.StackEntry{
        .prev_move = move_mod.Move.init(.e4, .d5, .capture),
        .prev_piece_type = .pawn,
    };
    try std.testing.expect(previousQuietCountermove(&history_table, &tactical_entry, .black, false) == null);
}

test "quiet cutoff learning updates killer history and countermove" {
    const history = @import("history.zig");
    const stack = @import("stack.zig");

    var history_table = history.HistoryTable{};
    var stack_entry = stack.StackEntry{
        .prev_move = move_mod.Move.init(.e2, .e4, .double_push),
        .prev_piece_type = .pawn,
    };
    const cutoff_move = move_mod.Move.init(.g8, .f6, .quiet);
    const tried_quiets = [_]move_mod.Move{move_mod.Move.init(.b8, .c6, .quiet)};
    const tried_pieces = [_]piece.PieceType{.knight};
    const cont = history.ContContext{};

    applyQuietCutoffLearning(&history_table, if (comptime build_options.tuning) &default_basin_policy else {}, &stack_entry, &cont, .black, cutoff_move, .knight, &tried_quiets, &tried_pieces, 4, 0, 0, false);

    try std.testing.expectEqual(cutoff_move, stack_entry.killer_a.?);
    try std.testing.expect(history_table.score(.black, .knight, .f6, 0) > 0);
    try std.testing.expect(history_table.score(.black, .knight, .c6, 0) < 0);
    try std.testing.expectEqual(cutoff_move, history_table.counterMove(.white, .pawn, .e4).?);
}

test "singular alternative quality treats cold quiet alternatives as weak" {
    const fen = @import("../core/fen.zig");
    const stack = @import("stack.zig");
    const history = @import("history.zig");

    const pos = try fen.startpos();
    var moves = move_mod.MoveList.init();
    const tt_move = move_mod.Move.init(.e2, .e4, .double_push);
    moves.add(tt_move);
    moves.add(move_mod.Move.init(.a2, .a3, .quiet));

    const stack_entry = stack.StackEntry{};
    const history_table = history.HistoryTable{};
    const see_scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    const quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table, 0);

    try std.testing.expect(quality.isWeak());
    try std.testing.expectEqual(@as(usize, 1), quality.alternative_count);
    try std.testing.expectEqual(@as(usize, 0), quality.positive_history_count);
}

test "singular alternative quality rejects strong tactical alternatives and records killer context" {
    const fen = @import("../core/fen.zig");
    const stack = @import("stack.zig");
    const history = @import("history.zig");

    const pos = try fen.parse("4k3/8/8/4q3/2N5/8/8/4K3 w - - 0 1");
    const tt_move = move_mod.Move.init(.e1, .f2, .quiet);
    const capture = move_mod.Move.init(.c4, .e5, .capture);
    var moves = move_mod.MoveList.init();
    moves.add(tt_move);
    moves.add(capture);

    var stack_entry = stack.StackEntry{};
    var history_table = history.HistoryTable{};
    var see_scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    see_scores[1] = 900;

    const tactical_quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table, 0);
    try std.testing.expect(!tactical_quality.isWeak());

    const killer_alt = move_mod.Move.init(.e1, .d2, .quiet);
    stack_entry.killer_a = killer_alt;
    moves = move_mod.MoveList.init();
    moves.add(tt_move);
    moves.add(killer_alt);
    see_scores = [_]i32{0} ** move_mod.MAX_MOVES;
    const killer_quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table, 0);
    try std.testing.expect(killer_quality.has_killer_or_countermove);
}

test "null move is not tried inside a singular verification search" {
    @import("startup.zig").ensure();
    if (comptime !context_mod.stats_enabled) return error.SkipZigTest;
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Queen up, beta far below the eval, depth above the RFP range: the plain
    // node tries null move first. Node limit 2 stops at the first child.
    const excluded = move_mod.Move.init(.e2, .e4, .quiet);
    for ([_]?move_mod.Move{ null, excluded }) |excluded_move| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{ .node_limit = 2 }),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        var pos = try fen.parse("4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1");
        ctx.repetition.push(pos.zobrist_key);
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        _ = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator }, &pos, 20, -201, -200, 0, true, node_context.NodeContext.fromWindow(-201, -200, false), excluded_move, false);
        try std.testing.expectEqual(@as(u64, if (excluded_move == null) 1 else 0), ctx.stats.null_tries);
    }
}

test "a table move that is the only legal move is singular whatever the static value says" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{ .node_limit = 200_000 }),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history = history_mod.HistoryTable{};
    // White is not in check and has one legal move, Ka2 (the review's witness).
    var pos = try fen.parse("8/8/8/8/8/1r6/1Pk5/K7 w - - 1 2");
    {
        var legal_moves = move_mod.MoveList.init();
        legal.generateHinted(&pos, &legal_moves, false);
        try std.testing.expectEqual(@as(usize, 1), legal_moves.count);
    }
    ctx.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
    const resources = .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator };
    const static_value = qsearch.search(&ctx, resources, &pos, -qsearch.INF, qsearch.INF, 0, false);
    try std.testing.expect(!score_mod.isMateLike(static_value - 141));
    // A lower bound three plies shallower than the node, 100 below the static
    // value, with the only move as its move; a zero window 140 below the
    // static value. The node's own reverse futility refuses (its margin at
    // depth 6 is larger than 140); a verification search at depth 2 against
    // the bound less the singular margin would be cut by reverse futility
    // without a move, and the node would be multicut on a second move that
    // does not exist.
    table.clear();
    const only = move_mod.Move.init(.a1, .a2, .quiet);
    tt_store.storeLowerBound(&ctx, &table, pos.zobrist_key, 3, static_value - 100, only, tt_store.evalToTt(null), false, 0, pos.halfmove_clock);
    const beta = static_value - 140;
    const nodes_before = ctx.nodes;
    const score = negamax(&ctx, resources, &pos, 6, beta - 1, beta, 0, true, node_context.NodeContext.fromWindow(beta - 1, beta, true), null, false);
    // Without the guard the node returns the verification's bound, the
    // table score less the singular margin (12 at depth 6), after two nodes.
    try std.testing.expect(score != static_value - 112);
    try std.testing.expect(ctx.nodes - nodes_before > 2);
    if (comptime context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 0), ctx.stats.singular_multicuts);
}

test "null-move boundary: the pass child searches as if history began at the pass" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();

    // Judge A repro: Black's king walks a 3-cycle, White's a 2-cycle, so after
    // the pass the board and side to move equal the start position.
    const Mode = enum { no_boundary, boundary, fresh_history };
    var results: [3]types.Score = undefined;
    for ([_]Mode{ .no_boundary, .boundary, .fresh_history }, 0..) |mode, slot| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        ecache.clear();
        var pos = try fen.parse("q6k/8/8/8/8/8/8/R3K3 b - - 0 1");
        ctx.repetition.push(pos.zobrist_key);
        for ([_][]const u8{ "h8g8", "e1f1", "g8g7", "f1e1", "g7h8" }) |text| {
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            var found: ?move_mod.Move = null;
            for (moves.slice()) |mv| {
                var buffer: [5]u8 = undefined;
                if (std.mem.eql(u8, mv.toUci(&buffer), text)) found = mv;
            }
            var state = make_unmake.StateInfo{};
            ctx.repetition.push(make_unmake.makeMove(&pos, found.?, &state));
        }
        var null_state = make_unmake.StateInfo{};
        make_unmake.makeNullMove(&pos, &null_state);
        switch (mode) {
            .no_boundary => {},
            .boundary => _ = ctx.repetition.pushNullBoundary(pos.zobrist_key),
            .fresh_history => {
                ctx.repetition.clear();
                ctx.repetition.push(pos.zobrist_key);
            },
        }
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        results[slot] = qsearch.search(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator }, &pos, -qsearch.INF, qsearch.INF, 0, null);
    }
    // Without the boundary the pass child is a false repetition draw.
    try std.testing.expect(basin.isDrawAtDefault(results[0]));
    try std.testing.expect(results[1] != 0);
    try std.testing.expectEqual(results[2], results[1]);
}

test "null-move boundary is restored on normal returns and on stops" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    // Queen up with beta far below the eval: the node tries null move first,
    // and node limits from 1 up stop the search at every stage of the pass
    // subtree (including nested passes) as well as after normal returns.
    var limit: u64 = 1;
    while (limit <= 3000) : (limit = limit * 3 / 2 + 1) {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{ .node_limit = limit }),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        var pos = try fen.parse("4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1");
        const root_key = pos.zobrist_key;
        ctx.repetition.push(root_key);
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        _ = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator }, &pos, 12, -201, -200, 0, true, node_context.NodeContext.fromWindow(-201, -200, false), null, null);
        try std.testing.expectEqual(@as(usize, 1), ctx.repetition.count);
        try std.testing.expectEqual(@as(usize, 0), ctx.repetition.floor);
        try std.testing.expectEqual(root_key, pos.zobrist_key);
    }
}

test "null-move boundary in negamax: an odd cycle before the node does not reach the pass child" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();

    // The real null branch (review round, judges A F10 / finding 10): Black's
    // king walks a 3-cycle and White's a 2-cycle, so White's pass at the node
    // recreates the start position with Black to move. Without the boundary
    // that pass child is a repetition draw, the null move fails low and the
    // node searches its moves. With it, the node searches exactly as with no
    // earlier history: the queen side's null move cuts at once.
    const Mode = enum { cycle_history, fresh_history };
    var results: [2]SeededSearchResult = undefined;
    for ([_]Mode{ .cycle_history, .fresh_history }, 0..) |mode, slot| {
        var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
        var stop_flag = std.atomic.Value(bool).init(false);
        var ctx = context_mod.SearchContext{
            .repetition = .{},
            .control = time.Controller.init(&stop_flag, .{}),
            .basin_config = if (build_options.tuning) &test_basin_config else {},
        };
        var history = history_mod.HistoryTable{};
        table.clear();
        ecache.clear();
        var pos = try fen.parse("r6k/8/8/8/8/8/8/1Q2K3 b - - 0 1");
        ctx.repetition.push(pos.zobrist_key);
        for ([_][]const u8{ "h8g8", "e1f1", "g8g7", "f1e1", "g7h8" }) |text| {
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            var found: ?move_mod.Move = null;
            for (moves.slice()) |mv| {
                var buffer: [5]u8 = undefined;
                if (std.mem.eql(u8, mv.toUci(&buffer), text)) found = mv;
            }
            var state = make_unmake.StateInfo{};
            ctx.repetition.push(make_unmake.makeMove(&pos, found.?, &state));
        }
        if (mode == .fresh_history) {
            ctx.repetition.clear();
            ctx.repetition.push(pos.zobrist_key);
        }
        const node_key = pos.zobrist_key;
        evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
        // Zero window above the draw, depth above the reverse-futility range
        // and below null-move verification.
        const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator }, &pos, 13, 0, 1, 0, true, node_context.NodeContext.fromWindow(0, 1, false), null, null);
        try std.testing.expect(!ctx.stopped);
        results[slot] = .{ .score = score, .nodes = ctx.nodes };
        // The node took the null-move cut: a lower bound without a move.
        const entry = table.lookup(node_key).?;
        try std.testing.expectEqual(tt_mod.Bound.lower, entry.bound);
        try std.testing.expect(tt_mod.moveFromEntry(entry) == null);
        if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.null_cutoffs);
    }
    try std.testing.expect(results[0].score >= 1);
    try std.testing.expectEqual(results[1].score, results[0].score);
    try std.testing.expectEqual(results[1].nodes, results[0].nodes);
}

test "root LMR starts with the third quiet move and preserves tactical guards" {
    @import("startup.zig").ensure();
    const quiet = move_mod.Move.init(.a2, .a3, .quiet);
    const capture = move_mod.Move.init(.a2, .b3, .capture);
    const promotion = move_mod.Move.init(.a7, .a8, .promo_queen);

    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(2, 2, quiet, false, true, 0));
    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(8, 0, quiet, false, true, 0));
    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(8, 1, quiet, false, true, 0));
    try std.testing.expect(rootLateMoveReduction(8, 2, quiet, false, true, 0) > 0);
    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(8, 2, quiet, true, true, 0));
    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(8, 2, capture, false, true, 0));
    try std.testing.expectEqual(@as(u16, 0), rootLateMoveReduction(8, 2, promotion, false, true, 0));
}

test "root search depth one returns a move in start position" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const tt = @import("tt.zig");

    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = .{ .stop_flag = &stop_flag, .limits = .{ .depth = 1 } },
        .basin_config = if (build_options.tuning) &test_basin_config else {},
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.startpos();
    ctx.repetition.push(pos.zobrist_key);

    const result = searchDepth(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 1);
    try std.testing.expect(result.best_move != null);
}

test "TT-stage quiet cutoff learns without a map and failed TT quiet uses the later map" {
    const fen = @import("../core/fen.zig");
    const stack = @import("stack.zig");
    const pos = try fen.parse("4k3/8/8/8/8/r7/8/N3K3 w - - 0 1");
    const tt_move = move_mod.Move.init(.a1, .c2, .quiet);
    const tt_bucket = history_mod.ttQuietBucket(&pos, tt_move);
    try std.testing.expectEqual(@as(u2, 2), tt_bucket);
    var history = history_mod.HistoryTable{};
    var entry = stack.StackEntry{};
    const cont = history_mod.ContContext{};
    applyQuietCutoffLearning(&history, if (comptime build_options.tuning) &default_basin_policy else {}, &entry, &cont, .white, tt_move, .knight, &.{}, &.{}, 4, tt_bucket, null, false);
    try std.testing.expectEqual(if (basin.ENABLED) basin.historyBonus(4) else 24, history.score(.white, .knight, .c2, tt_bucket));
    try std.testing.expectEqual(@as(i32, 0), history.score(.white, .knight, .c2, 0));
    try std.testing.expectEqual(tt_move, entry.killer_a.?);
    try std.testing.expectEqual(@as(u16, 1), history.snapshot().positive_entries);

    history.clear();
    const map = attacks.attackedSquares(&pos, .black);
    const cutoff = move_mod.Move.init(.e1, .f1, .quiet);
    const bucket = history_mod.quietBucket(map, cutoff);
    applyQuietCutoffLearning(&history, if (comptime build_options.tuning) &default_basin_policy else {}, &entry, &cont, .white, cutoff, .king, &.{tt_move}, &.{.knight}, 4, bucket, map, false);
    try std.testing.expectEqual(-(if (basin.ENABLED) basin.historyMalus(4) else 24), history.score(.white, .knight, .c2, tt_bucket));
    try std.testing.expectEqual(@as(i32, 0), history.score(.white, .knight, .c2, 0));
    try std.testing.expect(history.score(.white, .king, .f1, bucket) > 0);
    try std.testing.expectEqual(history.score(.white, .knight, .c2, tt_bucket), lmrHistoryScore(&history, &pos, tt_move, map));
}

test "negamax quiet TT cutoff bypasses generation and rewards the queried bucket" {
    @import("startup.zig").ensure();
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");
    var test_basin_config = if (build_options.tuning) basin.Config.init(.{}) else {};
    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
        .basin_config = if (build_options.tuning) &test_basin_config else {},
        .record_move_order_outcomes = true,
    };
    var history = history_mod.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_KB);
    defer ecache.deinit();
    var pos = try fen.parse("k7/8/8/8/8/8/4r3/4K3 w - - 0 1");
    const tt_move = move_mod.Move.init(.e1, .f1, .quiet);
    try std.testing.expect(legal.isLegalMoveHinted(&pos, tt_move, true));
    // Depths 1 and 2 have zero bonus under the frozen policy. At depth 3,
    // a seeded child TT cutoff isolates this node from descendant generation.
    const child_key = make_unmake.makeMove(&pos, tt_move, &ctx.stack.entry(0).state);
    make_unmake.unmakeMove(&pos, tt_move, &ctx.stack.entry(0).state);
    table.store(child_key, 8 + tt_mod.STORED_DEPTH_OFFSET, 0, .exact, null);
    table.store(pos.zobrist_key, 0 + tt_mod.STORED_DEPTH_OFFSET, 0, .upper, tt_move);
    ctx.repetition.push(pos.zobrist_key);
    evaluator.prepareRoot(&ctx.stack, &pos, &ctx.finny, &ctx.ft);
    const score = negamax(&ctx, .{ .tt = &table, .eval_cache = &ecache, .history = &history, .evaluator = &evaluator }, &pos, 3, -10001, -10000, 0, true, node_context.NodeContext.fromWindow(-10001, -10000, false), null, true);
    try std.testing.expect(score >= -10000);
    try std.testing.expectEqual(tt_move, ctx.stack.entry(0).killer_a.?);
    try std.testing.expectEqual(if (basin.ENABLED) basin.historyBonus(3) else 17, history.score(.white, .king, .f1, 2));
    try std.testing.expectEqual(@as(i32, 0), history.score(.white, .king, .f1, 0));
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 0), ctx.stats.staged_main_movegen_nodes);
}

test "the countermove after a capture is kept and read only with the switch" {
    var history_table = history_mod.HistoryTable{};
    const stack = @import("stack.zig");
    var entry = stack.StackEntry{};
    entry.prev_move = move_mod.Move.init(.d4, .e5, .capture);
    entry.prev_piece_type = null; // a capture is no quiet predecessor
    entry.prev_cont_piece = .pawn;
    const cont = history_mod.ContContext{};
    const reply = move_mod.Move.init(.g8, .f6, .quiet);
    applyQuietCutoffLearning(&history_table, if (comptime build_options.tuning) &default_basin_policy else {}, &entry, &cont, .black, reply, .knight, &.{}, &.{}, 4, 0, null, false);
    try std.testing.expect(previousQuietCountermove(&history_table, &entry, .black, true) == null);
    applyQuietCutoffLearning(&history_table, if (comptime build_options.tuning) &default_basin_policy else {}, &entry, &cont, .black, reply, .knight, &.{}, &.{}, 4, 0, null, true);
    try std.testing.expectEqual(reply, previousQuietCountermove(&history_table, &entry, .black, true).?);
    try std.testing.expect(previousQuietCountermove(&history_table, &entry, .black, false) == null);
}
