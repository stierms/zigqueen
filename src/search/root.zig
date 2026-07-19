const std = @import("std");
const context_mod = @import("context.zig");
const eval_cache_mod = @import("eval_cache.zig");
const history_mod = @import("history.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const node_context = @import("node_context.zig");
const piece = @import("../core/piece.zig");
const ordering = @import("ordering.zig");
const position = @import("../core/position.zig");
const pruning = @import("pruning.zig");
const qsearch = @import("qsearch.zig");
const score_mod = @import("score.zig");
const reductions = @import("reductions.zig");
const see = @import("see.zig");
const syzygy = @import("syzygy.zig");
const stats_mod = @import("stats.zig");
const tt_mod = @import("tt.zig");
const tt_probe = @import("tt_probe.zig");
const tt_store = @import("tt_store.zig");
const types = @import("../core/types.zig");

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
};

// Checks extend only at shallow depth (0 = never). Unconditional extension made
// EBF position-blind; see the policy comment at the extension site.
const CHECK_EXTENSION_MAX_DEPTH: u16 = 0;
const SINGULAR_MIN_DEPTH: u16 = 6;
const SINGULAR_MAX_DEPTH: u16 = 8;
const SINGULAR_REQUIRED_DEPTH_SURPLUS: i16 = 0;
const SINGULAR_MARGIN_BASE: i32 = 8;
const SINGULAR_MARGIN_PER_PLY: i32 = 4;
const SINGULAR_EXTENSION_MARGIN: i32 = 16;
const SINGULAR_CAPTURE_SEE_THRESHOLD: i32 = 96;
// ProbCut: shallow preemptive verification that a good capture beats beta by
// a margin, skipping the full-depth search when it does. Cuts ~10% of nodes at
// fixed depth; its strength value concentrates at deep searches / long time
// controls and is neutral at fast ones. Multicut stays enabled but fires at
// noise level under the narrow singular eligibility (~445 per 1.5M nodes);
// widening that eligibility was tested and washed.
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
    extension: u16 = 1,
    /// Multicut: the singular verification (TT move EXCLUDED) failed high at
    /// singular_beta >= beta — a SECOND move beats beta at reduced depth, so the
    /// node has at least two refutations -> cut immediately with this bound.
    multicut: ?types.Score = null,
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

pub fn searchDepth(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
    pos: *position.Position,
    depth: u16,
) IterationResult {
    return searchDepthWindow(ctx, resources, pos, depth, -qsearch.INF, qsearch.INF, null);
}

pub fn searchDepthWindow(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
    pos: *position.Position,
    depth: u16,
    alpha_in: types.Score,
    beta_in: types.Score,
    previous_root_hints: ?*const RootMoveHints,
) IterationResult {
    if (pos.halfmove_clock >= 100 or ctx.repetition.isClaimableCurrentRepetition(pos.halfmove_clock)) {
        return .{
            .score = 0,
            .depth = depth,
        };
    }

    const in_check = legal.isInCheck(pos, pos.side_to_move);
    const entry = ctx.stack.entry(0);
    // The root has no predecessor; clear it so ply-1 children get no stale
    // continuation context from an earlier iteration/search.
    entry.prev_move = null;
    entry.prev_piece_type = null;
    entry.prev_cont_piece = null;
    entry.static_eval = if (in_check) null else resources.history.correctedEval(pos, resources.evaluator.evaluate(&ctx.stack, 0, pos, &ctx.finny));

    var moves = move_mod.MoveList.init();
    legal.generateHinted(pos, &moves, in_check);
    if (moves.count == 0) {
        return .{
            .score = if (in_check) -score_mod.MATE_SCORE else 0,
            .depth = depth,
        };
    }

    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    const tt_move = resources.tt.bestMove(pos.zobrist_key);
    const root_move_counts = if (ctx.recordMoveOrder()) stagedMoveCounts(&moves) else StagedMoveCounts{};
    if (ctx.recordMoveOrder()) ctx.noteStagedMainMoveList(moves.count, root_move_counts.quiet, root_move_counts.tactical, containsMove(&moves, tt_move));
    const root_cont = history_mod.ContContext{}; // root has no predecessor moves
    ordering.scoreMoves(pos, &moves, tt_move, .{}, null, resources.history, &root_cont, &scores, null);
    var previous_hint_bonuses: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    applyRootHintBonuses(&moves, &scores, previous_root_hints, &previous_hint_bonuses);
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
        const nodes_before = ctx.nodes;
        const is_quiet_root = !mv.isCapture() and !mv.isPromotion();
        if (ctx.recordMoveOrder() and is_quiet_root) root_searched_quiets += 1;
        const cont_piece = pos.pieceAt(mv.from).pieceType();
        const moved_piece_type = if (is_quiet_root) cont_piece else null;
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key); // overlap the child's TT miss with the work below
        resources.rfp_hint.prefetch(child_key); // and the RFP-hint cluster (probed per negamax node)
        const repeats_cycle = if (cycle_child_key) |key| child_key == key else false;
        ctx.repetition.push(child_key);
        child_entry.prev_move = mv;
        child_entry.prev_piece_type = moved_piece_type;
        child_entry.prev_cont_piece = cont_piece;
        // Lazy accumulator: record the move only — boards/undo-state are
        // reconstructed at materialization time from the live position.
        resources.evaluator.onMakeMove(&ctx.stack, mv, 0);

        var score: types.Score = undefined;
        if (index == 0) {
            score = -negamax(ctx, resources, pos, depth - 1, -beta, -alpha, 1, true, node_context.NodeContext.fromWindow(-beta, -alpha, false), null);
        } else {
            ctx.notePvsScout();
            score = -negamax(ctx, resources, pos, depth - 1, -alpha - 1, -alpha, 1, true, node_context.NodeContext.fromWindow(-alpha - 1, -alpha, true), null);
            if (!ctx.stopped and score > alpha and score < beta) {
                ctx.notePvsResearch();
                score = -negamax(ctx, resources, pos, depth - 1, -beta, -alpha, 1, true, node_context.NodeContext.fromWindow(-beta, -alpha, false), null);
            }
        }

        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);
        const subtree_nodes = ctx.nodes - nodes_before;
        root_hints.record(mv, score, subtree_nodes);
        recordRootOrderSearch(&root_order, mv, score, subtree_nodes);

        if (ctx.stopped) break;
        if (score > best_score or (score == 0 and score == best_score and repeats_cycle and !best_repeats_cycle)) {
            best_score = score;
            best_move = mv;
            best_repeats_cycle = repeats_cycle;
        }
        if (score > alpha) alpha = score;
        if (alpha >= beta) break;
    }

    if (ctx.recordMoveOrder() and root_searched_quiets == 0) ctx.noteStagedMainNoQuietSearched(root_move_counts.quiet);

    if (!ctx.stopped) {
        const score = if (best_move == null) 0 else best_score;
        tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, @intCast(depth), alpha_orig, beta_in, score, best_move, tt_mod.STATIC_EVAL_NONE);
    }

    return .{
        .best_move = best_move,
        .score = if (best_move == null) 0 else best_score,
        .depth = depth,
        .root_hints = root_hints,
        .root_order = root_order,
    };
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
    resources: context_mod.Resources,
    pos: *position.Position,
    depth: u16,
    alpha_in: types.Score,
    beta_in: types.Score,
    ply: usize,
    allow_null: bool,
    node_ctx: node_context.NodeContext,
    excluded_move: ?move_mod.Move,
) types.Score {
    if (ctx.noteNode()) return 0;
    ctx.observePly(ply);
    if (pos.halfmove_clock >= 100 or ctx.repetition.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock)) return ctx.drawScore(pos.side_to_move);
    if (depth == 0) return qsearch.search(ctx, resources, pos, alpha_in, beta_in, ply);

    const alpha_orig = alpha_in;
    const stack_entry = ctx.stack.entry(ply);
    stack_entry.static_eval = null;
    // Out-pointer probe: fields are written directly into this slot (narrow
    // stores) and read back narrowly — no whole-Result temp + wide copy. See
    // the probeInto doc comment for the store-forward-stall history.
    var probe: tt_probe.Result = undefined;
    tt_probe.probeInto(&probe, ctx, resources.tt, pos.zobrist_key, @intCast(depth), alpha_in, beta_in, excluded_move);

    // Syzygy WDL probe (no-op unless SyzygyPath is set): a table hit is ground
    // truth — return it. probeWdl itself gates on piece count, castling, and a
    // fresh rule-50 clock; singular verification nodes are excluded so the
    // exclusion window still searches.
    if (excluded_move == null) {
        if (syzygy.probeWdl(pos)) |wdl| {
            return syzygy.wdlScore(wdl, ply);
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
    if (excluded_move == null and pruning.isRfpHintApplicable(search_depth, alpha, beta)) {
        ctx.noteRfpHintProbe();
        if (resources.rfp_hint.lookup(pos.zobrist_key, @intCast(search_depth))) |hint_score| {
            if (hint_score >= beta) {
                ctx.noteRfpHintCutoff(search_depth);
                return hint_score;
            }
            if (hint_score > alpha) {
                ctx.noteRfpHintAlphaRaise();
                alpha = hint_score;
            }
        }
    }

    const in_check = legal.isInCheck(pos, pos.side_to_move);
    if (!in_check and canTrySingular(search_depth, node_ctx, tt_entry, tt_move, excluded_move)) {
        ctx.noteSingularCandidate(search_depth, node_ctx.cut_node);
    }
    var static_eval: ?types.Score = null;
    var raw_static_eval: ?types.Score = null;
    var improving = false;
    if (!in_check) {
        ctx.noteMainStaticEval();
        // Reuse the raw static eval cached in the TT entry (position-
        // invariant, so identical to recomputing) — skips the NNUE forward on
        // TT hits that didn't cut; every downstream decision is unchanged.
        // On a TT static-eval miss, try the dedicated raw-eval cache
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
            const fresh = resources.evaluator.evaluate(&ctx.stack, ply, pos, &ctx.finny);
            if (std.math.cast(i16, fresh)) |memo| resources.eval_cache.store(pos.zobrist_key, memo);
            break :blk fresh;
        };
        raw_static_eval = raw;
        // Rule-50 decay applies to the retrieved value (caches hold undecayed
        // evals; the clock is not part of the position key). Corrections and
        // every search decision downstream see the decayed value.
        const decayed = score_mod.rule50Decay(raw, pos.halfmove_clock);
        // Correction history: search decisions (pruning margins, improving,
        // null-move gates) use the corrected eval; the corrhist update at the
        // node's end measures the search result against the decayed eval.
        const evaluated = resources.history.correctedEval(pos, decayed);
        stack_entry.static_eval = evaluated;
        static_eval = evaluated;
        improving = isImproving(ctx, ply, evaluated);
        if (pruning.shouldReverseFutilityPrune(search_depth, alpha, beta, in_check, evaluated, improving)) {
            ctx.noteReverseFutilityPrune(search_depth);
            outcome_flags.rfp_cutoff = true;
            if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, beta, alpha_orig, beta, outcome_flags);
            if (excluded_move == null) resources.rfp_hint.store(pos.zobrist_key, @intCast(search_depth), beta);
            return beta;
        }
        if (pruning.shouldRazor(search_depth, alpha, beta, in_check, evaluated)) {
            const razor_score = qsearch.search(ctx, resources, pos, alpha, beta, ply);
            if (ctx.stopped) return 0;
            if (razor_score <= alpha) {
                if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, razor_score, alpha_orig, beta, outcome_flags);
                return razor_score;
            }
        }
    }
    if (ply >= ctx.nmp_min_ply and pruning.shouldTryNullMove(allow_null, pos, search_depth, alpha, beta, in_check, static_eval)) {
        const reduction = reductions.nullMoveReduction(search_depth);
        ctx.noteNullTry();
        make_unmake.makeNullMove(pos, &stack_entry.state);
        resources.evaluator.onMakeNullMove(&ctx.stack, ply);
        ctx.stack.entry(ply + 1).prev_move = null;
        ctx.stack.entry(ply + 1).prev_piece_type = null;
        ctx.stack.entry(ply + 1).prev_cont_piece = null;
        const null_child_ctx = node_context.NodeContext.fromWindow(-beta, -beta + 1, true);
        const null_score = -negamax(ctx, resources, pos, search_depth - 1 - reduction, -beta, -beta + 1, ply + 1, false, null_child_ctx, null);
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
                const verify_score = negamax(ctx, resources, pos, verify_depth, beta - 1, beta, ply, false, verify_ctx, null);
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
                    if (excluded_move == null) tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), beta, null, tt_store.evalToTt(raw_static_eval));
                    return beta;
                }
            } else {
                ctx.noteNullCutoff();
                if (static_eval) |evaluated| {
                    outcome_flags.null_cutoff = true;
                    if (ctx.recordStaticOutcomes()) ctx.noteStaticSearchOutcome(evaluated, beta, alpha_orig, beta, outcome_flags);
                }
                if (excluded_move == null) tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), beta, null, tt_store.evalToTt(raw_static_eval));
                return beta;
            }
        }
    }

    // ProbCut (non-PV, not in check, not inside a singular-excluded search): a good
    // capture that beats beta+margin at reduced depth cuts the node now.
    if (PROBCUT_ENABLED and !node_ctx.pv_node and !in_check and excluded_move == null) {
        if (static_eval) |evaluated| {
            if (tryProbCut(ctx, resources, pos, search_depth, beta, ply, tt_entry, tt_move, evaluated)) |probcut_score| {
                return probcut_score;
            }
            if (ctx.stopped) return 0;
        }
    }

    var moves = move_mod.MoveList.init();
    // Null-move/razor/probcut all make+unmake in balanced pairs above, so `pos`
    // is unchanged since `in_check` was computed — the hint is exact.
    legal.generateHinted(pos, &moves, in_check);
    if (moves.count == 0) {
        return if (in_check) -score_mod.MATE_SCORE + @as(types.Score, @intCast(ply)) else ctx.drawScore(pos.side_to_move);
    }

    var scores: [move_mod.MAX_MOVES]i32 = undefined;
    var capture_see_scores: [move_mod.MAX_MOVES]i32 = undefined;
    const staged_counts = if (ctx.recordMoveOrder()) stagedMoveCounts(&moves) else StagedMoveCounts{};
    if (ctx.recordMoveOrder()) ctx.noteStagedMainMoveList(moves.count, staged_counts.quiet, staged_counts.tactical, containsMove(&moves, tt_move));
    const countermove = previousQuietCountermove(resources.history, stack_entry, pos.side_to_move);
    if (ctx.recordMoveOrder() and hasPreviousQuietMove(stack_entry)) {
        ctx.noteCountermoveTableProbe(countermove, containsMove(&moves, countermove));
    }
    const cont = continuationContext(ctx, ply, pos.side_to_move);
    // Per-node conthist rows for the loop's LMR history evidence (same hoist
    // as inside scoreMoves — value-identical, reads stay live).
    const cont_rows = resources.history.contRows(&cont);
    ordering.scoreMoves(
        pos,
        &moves,
        tt_move,
        .{ .a = stack_entry.killer_a, .b = stack_entry.killer_b },
        countermove,
        resources.history,
        &cont,
        &scores,
        &capture_see_scores,
    );
    const singular_plan = if (!in_check)
        trySingularPlan(ctx, resources, pos, search_depth, ply, node_ctx, tt_entry, tt_move, excluded_move, &moves, &capture_see_scores, stack_entry, countermove, beta)
    else
        null;
    if (singular_plan) |plan| {
        if (plan.multicut) |mc_bound| {
            if (excluded_move == null) {
                tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(singularVerificationDepth(search_depth)), mc_bound, tt_move, tt_store.evalToTt(raw_static_eval));
            }
            return mc_bound;
        }
    }

    var best_move: ?move_mod.Move = null;
    var best_score: types.Score = -qsearch.INF;
    const child_entry = ctx.stack.entry(ply + 1);
    var quiets_tried: [move_mod.MAX_MOVES]move_mod.Move = undefined;
    var quiet_count: usize = 0;
    var quiet_pieces_tried: [move_mod.MAX_MOVES]piece.PieceType = undefined;
    var searched_quiet_count: usize = 0;

    var move_picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    for (0..moves.count) |index| {
        const mv = move_picker.next(index);
        const capture_see_score = move_picker.captureSee(index);
        if (excluded_move) |excluded| {
            if (mv == excluded) continue;
        }
        const is_capture = mv.isCapture();
        const is_promotion = mv.isPromotion();
        const is_quiet = !is_capture and !is_promotion;
        const cont_piece = pos.pieceAt(mv.from).pieceType();
        const moved_piece_type = if (is_quiet) cont_piece else null;
        // LMR history evidence = main history + CONTINUATION history (rung 2 of the
        // EBF ladder): the ordering already ranks by the combined signal, but LMR only
        // saw main history — cont-hist is the stronger of the two for "this quiet is
        // known-good in this line" and lets reductions track evidence, not blindness.
        const quiet_history_score = if (moved_piece_type) |quiet_piece_type|
            resources.history.score(pos.side_to_move, quiet_piece_type, mv.to) +
                cont_rows.total(history_mod.contKey(pos.side_to_move, quiet_piece_type, mv.to))
        else
            0;
        const move_order_sample: ?stats_mod.MoveOrderSample = if (ctx.recordMoveOrder()) .{
            .bucket = classifyMoveOrderBucket(mv, tt_move, stack_entry.killer_a, stack_entry.killer_b, countermove, capture_see_score, quiet_history_score),
            .node_type = stats_mod.moveOrderNodeType(node_ctx.pv_node, node_ctx.cut_node),
            .depth_band = stats_mod.moveOrderDepthBand(search_depth),
            .history_score = quiet_history_score,
        } else null;
        var gives_check_hint: ?bool = null;
        if (pruning.shouldPruneQuietMove(search_depth, index, mv, alpha, beta, in_check, static_eval, improving, stack_entry.killer_a, stack_entry.killer_b)) {
            const gives_check = quietMoveGivesCheck(pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteQuietFutilityPrune();
                outcome_flags.quiet_futility_prune = true;
                continue;
            }
        }
        if (pruning.shouldLatePrune(search_depth, index, mv, alpha, beta, in_check, improving, stack_entry.killer_a, stack_entry.killer_b)) {
            const gives_check = gives_check_hint orelse quietMoveGivesCheck(pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteLatePrune();
                outcome_flags.late_move_prune = true;
                continue;
            }
        }
        if (is_quiet and pruning.shouldHistoryPruneQuiet(search_depth, index, mv, alpha, beta, in_check, quiet_history_score, stack_entry.killer_a, stack_entry.killer_b)) {
            const gives_check = gives_check_hint orelse quietMoveGivesCheck(pos, mv);
            gives_check_hint = gives_check;
            if (!gives_check) {
                ctx.noteLatePrune();
                outcome_flags.late_move_prune = true;
                continue;
            }
        }
        if (is_quiet and pruning.seeQuietPruneGate(search_depth, index, alpha, beta, in_check) and
            !isKillerMove(stack_entry, mv))
        {
            // SEE is expensive, so it is only computed once the cheap gate passes.
            if (see.quietScore(pos, mv) < pruning.seeQuietPruneMargin(search_depth)) {
                const gives_check = gives_check_hint orelse quietMoveGivesCheck(pos, mv);
                gives_check_hint = gives_check;
                if (!gives_check) {
                    ctx.noteLatePrune();
                    outcome_flags.late_move_prune = true;
                    continue;
                }
            }
        }
        if (is_capture and !is_promotion) {
            if (pruning.shouldPruneBadCaptureMove(search_depth, index, mv, alpha, beta, in_check, static_eval, improving, capture_see_score)) {
                ctx.noteBadCapturePrune();
                outcome_flags.bad_capture_prune = true;
                continue;
            }
        }

        if (move_order_sample) |sample| ctx.noteMoveOrderSearched(sample);
        if (ctx.recordMoveOrder() and is_quiet) searched_quiet_count += 1;
        // The returned key keeps the prefetch/push chain on the register value
        // instead of a load waiting on makeMove's own zobrist store.
        const child_key = make_unmake.makeMove(pos, mv, &stack_entry.state);
        // gives_check: post-make isInCheck when no hint exists — in sparse
        // positions this beats the mask-op predicate (measured ~5% slower
        // endgames with the predicate here); the predicate stays at the
        // PRUNING sites where it eliminates whole make/unmake round trips.
        const gives_check = gives_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
        resources.tt.prefetch(child_key); // overlap the child's TT miss with the work below
        resources.rfp_hint.prefetch(child_key); // and the RFP-hint cluster (probed per negamax node)
        ctx.repetition.push(child_key);
        child_entry.prev_move = mv;
        child_entry.prev_piece_type = moved_piece_type;
        child_entry.prev_cont_piece = cont_piece;

        // Check-extension policy: extend a checking move ONLY when the checker is
        // failing low (static_eval <= alpha) — that is where the extension's value
        // lives (perpetual/fortress rescue lines for the side in trouble), while
        // unconditional check extensions bloat the tree with checks given from
        // comfortable positions and make the branching factor position-blind in
        // check-rich endgames. The shallow-depth "always extend" leg is compiled
        // out (CHECK_EXTENSION_MAX_DEPTH = 0).
        const checker_desperate = (static_eval orelse alpha) <= alpha;
        var extension: u16 = if (gives_check and (search_depth <= CHECK_EXTENSION_MAX_DEPTH or checker_desperate)) 1 else 0;
        if (extension > 0) ctx.noteCheckExtension();
        if (extension == 0) {
            if (singular_plan) |plan| {
                if (plan.mv == mv) {
                    extension = plan.extension;
                    ctx.noteSingularExtension();
                }
            }
        }
        const child_base_depth = search_depth - 1 + extension;

        // Lazy accumulator: record the move only (a couple of byte stores).
        // An eager ~210B Position snapshot here is a store-forward-stall
        // family costing ~12% of endgame negamax samples; instead boards are
        // reconstructed at materialization time from the live position, and the
        // undo-state is `stack_entry.state`, live until this make's own unmake.
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);

        var reduction: u16 = 0;
        var score: types.Score = undefined;
        if (index == 0) {
            score = -negamax(ctx, resources, pos, child_base_depth, -beta, -alpha, ply + 1, true, node_ctx.firstChild(), null);
        } else {
            reduction = reductions.lateMoveReduction(search_depth, index, mv, in_check, improving, node_ctx.cut_node, tt_move != null, quiet_history_score, stack_entry.killer_a, stack_entry.killer_b);
            if (reduction > 0) {
                ctx.noteLmrReduction(reduction, index, node_ctx.pv_node, node_ctx.cut_node);
                if (move_order_sample) |sample| ctx.noteMoveOrderLmrReduction(sample);
            }
            ctx.notePvsScout();
            const reduced = if (reduction >= child_base_depth) 0 else child_base_depth - reduction;
            score = -negamax(ctx, resources, pos, reduced, -alpha - 1, -alpha, ply + 1, true, node_ctx.scoutChild(), null);
            if (!ctx.stopped and reduction > 0 and score > alpha) {
                ctx.noteLmrResearch(index, reduction, score, alpha, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                if (move_order_sample) |sample| ctx.noteMoveOrderLmrResearch(sample);
                outcome_flags.lmr_research = true;
                score = -negamax(ctx, resources, pos, child_base_depth, -alpha - 1, -alpha, ply + 1, true, node_ctx.scoutChild(), null);
                if (!ctx.stopped) {
                    if (score <= alpha) {
                        outcome_flags.lmr_verification_fail_low = true;
                        if (move_order_sample) |sample| ctx.noteMoveOrderLmrFailLow(sample);
                    }
                    ctx.noteLmrVerificationOutcome(index, reduction, score, alpha, beta, quiet_history_score, node_ctx.pv_node, node_ctx.cut_node);
                }
            }
            if (!ctx.stopped and score > alpha and score < beta) {
                ctx.notePvsResearch();
                score = -negamax(ctx, resources, pos, child_base_depth, -beta, -alpha, ply + 1, true, node_context.NodeContext.fromWindow(-beta, -alpha, false), null);
            }
        }

        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &stack_entry.state);

        if (ctx.stopped) return 0;

        if (score > best_score) {
            best_score = score;
            best_move = mv;
        }
        if (score > alpha) alpha = score;

        if (alpha >= beta) {
            ctx.noteBetaCutoff(index);
            if (move_order_sample) |sample| ctx.noteMoveOrderCutoff(sample, index == 0);
            if (is_capture and !is_promotion) {
                ctx.noteCaptureCutoff(index, capture_see_score, false);
            } else if (!is_promotion) {
                ctx.noteQuietCutoff(index, mv, tt_move, stack_entry.killer_a, stack_entry.killer_b, countermove, quiet_history_score);
            }
            if (reduction > 0 and node_ctx.cut_node) {
                ctx.noteCutLmrCutoff(index);
                if (move_order_sample) |sample| ctx.noteMoveOrderLmrCutoff(sample);
            }
            if (excluded_move == null) {
                if (moved_piece_type) |quiet_piece_type| {
                    applyQuietCutoffLearning(resources.history, stack_entry, &cont, pos.side_to_move, mv, quiet_piece_type, quiets_tried[0..quiet_count], quiet_pieces_tried[0..quiet_count], search_depth);
                }
            }
            break;
        }

        if (moved_piece_type) |quiet_piece_type| {
            recordTriedQuiet(&quiets_tried, &quiet_pieces_tried, &quiet_count, mv, quiet_piece_type);
        }
    }

    if (ctx.recordMoveOrder() and searched_quiet_count == 0) ctx.noteStagedMainNoQuietSearched(staged_counts.quiet);

    if (ctx.recordStaticOutcomes()) {
        if (static_eval) |evaluated| {
            ctx.noteStaticSearchOutcome(evaluated, best_score, alpha_orig, beta, outcome_flags);
        }
    }
    if (excluded_move == null) {
        // Correction history learning: teach the tables the gap between the raw
        // static eval and the search result, when the result actually bounds it
        // (skip mate scores, capture best-moves, and bound-inconsistent pairs:
        // a fail-high below raw / fail-low above raw says nothing about eval error).
        if (raw_static_eval) |raw_val| {
            const raw = score_mod.rule50Decay(raw_val, pos.halfmove_clock);
            const best_is_capture = if (best_move) |bm| bm.isCapture() else false;
            if (!score_mod.isMateLike(best_score) and !best_is_capture and
                !(best_score >= beta_in and best_score <= raw) and
                !(best_score <= alpha_orig and best_score >= raw))
            {
                resources.history.updateCorrection(pos, best_score - raw, @intCast(search_depth));
            }
        }
        tt_store.storeWindowResult(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth), alpha_orig, beta_in, best_score, best_move, tt_store.evalToTt(raw_static_eval));
    }
    return best_score;
}

fn quietMoveGivesCheck(pos: *position.Position, mv: move_mod.Move) bool {
    // Both branches are EXACT (equivalence-tested), so dispatching by board
    // density is behavior-free. Dense boards: the attack-geometry predicate
    // wins (eliminates the make/unmake round trip). Sparse boards: the live
    // make round trip is cheaper than the predicate's mask assembly (measured
    // ~2.5% slower endgames with the predicate everywhere).
    if (@popCount(pos.occupancy()) >= 14) return legal.givesCheck(pos, mv);
    const mover = pos.side_to_move;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(pos, mv, &state);
    const gives_check = legal.isInCheck(pos, mover.other());
    make_unmake.unmakeMove(pos, mv, &state);
    return gives_check;
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

fn canTrySingular(
    search_depth: u16,
    node_ctx: node_context.NodeContext,
    tt_entry: ?*const tt_mod.Entry,
    tt_move: ?move_mod.Move,
    excluded_move: ?move_mod.Move,
) bool {
    if (excluded_move != null) return false;
    if (node_ctx.pv_node or !node_ctx.cut_node) return false;
    if (search_depth < SINGULAR_MIN_DEPTH or search_depth > SINGULAR_MAX_DEPTH) return false;

    const entry = tt_entry orelse return false;
    const mv = tt_move orelse return false;
    if (entry.bound != .lower) return false;
    if (mv.isPromotion()) return false;
    if (score_mod.isMateLike(entry.score)) return false;
    return entry.depth >= @as(i16, @intCast(search_depth));
}

/// ProbCut: at a non-PV node, if a good capture's REDUCED-depth search already beats
/// beta by a solid margin, the full-depth search will almost surely beat beta too ->
/// cut now. Distilled from the SF scheme: qsearch pre-verification, then a depth-4
/// zero-window verification; candidates are tactical moves whose SEE can plausibly
/// bridge (probcut_beta - static_eval).
fn tryProbCut(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
    pos: *position.Position,
    search_depth: u16,
    beta: types.Score,
    ply: usize,
    tt_entry: ?*const tt_mod.Entry,
    tt_move: ?move_mod.Move,
    static_eval: types.Score,
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

    const required_gain: i32 = @as(i32, probcut_beta) - @as(i32, static_eval);
    var picker = ordering.MovePicker.init(&moves, &scores, &capture_see_scores);
    for (0..moves.count) |index| {
        const mv = picker.next(index);
        // Only candidates whose material swing can plausibly bridge the gap.
        if (mv.isCapture() and !mv.isPromotion() and picker.captureSee(index) < required_gain) continue;

        const entry = ctx.stack.entry(ply);
        const child_key = make_unmake.makeMove(pos, mv, &entry.state);
        resources.tt.prefetch(child_key);
        ctx.repetition.push(child_key);
        resources.evaluator.onMakeMove(&ctx.stack, mv, ply);
        // cheap qsearch pre-verification, then the reduced-depth confirmation
        var score = -qsearch.search(ctx, resources, pos, -probcut_beta, -probcut_beta + 1, ply + 1);
        if (!ctx.stopped and score >= probcut_beta) {
            const verify_ctx = node_context.NodeContext.fromWindow(-probcut_beta, -probcut_beta + 1, true);
            score = -negamax(ctx, resources, pos, search_depth - PROBCUT_DEPTH_REDUCTION, -probcut_beta, -probcut_beta + 1, ply + 1, true, verify_ctx, null);
        }
        ctx.repetition.pop();
        make_unmake.unmakeMove(pos, mv, &entry.state);
        if (ctx.stopped) return null;
        if (score >= probcut_beta) {
            tt_store.storeLowerBound(ctx, resources.tt, pos.zobrist_key, @intCast(search_depth - PROBCUT_DEPTH_REDUCTION + 1), score, mv, tt_store.evalToTt(static_eval));
            return score;
        }
    }
    return null;
}

fn trySingularPlan(
    ctx: *context_mod.SearchContext,
    resources: context_mod.Resources,
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
    beta: types.Score,
) ?SingularPlan {
    if (!canTrySingular(search_depth, node_ctx, tt_entry, tt_move, excluded_move)) return null;

    const entry = tt_entry orelse return null;
    const candidate = tt_move orelse return null;

    const required_depth: i16 = @intCast(search_depth);
    if (entry.depth < required_depth + SINGULAR_REQUIRED_DEPTH_SURPLUS) return null;

    const alternative_quality = classifySingularAlternatives(
        pos,
        moves,
        capture_see_scores,
        candidate,
        stack_entry,
        countermove,
        resources.history,
    );
    if (!alternative_quality.isWeak()) return null;
    ctx.noteSingularWeakAlternativeCandidate();

    const margin = singularMargin(search_depth);
    const singular_beta = std.math.clamp(entry.score - margin, -qsearch.INF, qsearch.INF);
    const verification_alpha = singular_beta - 1;
    const verification_depth = singularVerificationDepth(search_depth);
    if (verification_depth == 0) return null;

    ctx.noteSingularVerification();
    const verification_score = negamax(
        ctx,
        resources,
        pos,
        verification_depth,
        verification_alpha,
        singular_beta,
        ply,
        true,
        node_context.NodeContext.fromWindow(verification_alpha, singular_beta, false),
        candidate,
    );
    if (ctx.stopped) return null;
    if (verification_score < singular_beta) {
        ctx.noteSingularVerified();
        if (verification_score <= singular_beta - SINGULAR_EXTENSION_MARGIN) {
            return .{ .mv = candidate };
        }
        return null;
    }
    // Verification failed high WITHOUT the TT move: a second refutation exists. If the
    // verification bound already clears beta, cut the node (multicut). Mate-band scores
    // are excluded — bounds near mate don't compose across the reduced-depth verify.
    if (MULTICUT_ENABLED and singular_beta >= beta and !score_mod.isMateLike(singular_beta)) {
        return .{ .mv = candidate, .extension = 0, .multicut = singular_beta };
    }
    return null;
}

fn classifySingularAlternatives(
    pos: *const position.Position,
    moves: *const move_mod.MoveList,
    capture_see_scores: *const [move_mod.MAX_MOVES]i32,
    tt_move: move_mod.Move,
    stack_entry: anytype,
    countermove: ?move_mod.Move,
    history: *const @import("history.zig").HistoryTable,
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

        const history_score = lmrHistoryScore(history, pos, mv);
        if (history_score > quality.strongest_history) quality.strongest_history = history_score;
        if (history_score > 0) quality.positive_history_count += 1;
    }
    return quality;
}

fn singularMargin(search_depth: u16) i32 {
    return SINGULAR_MARGIN_BASE + @as(i32, search_depth) * SINGULAR_MARGIN_PER_PLY;
}

fn singularVerificationDepth(search_depth: u16) u16 {
    return @max(@as(u16, 1), search_depth / 2);
}

fn lmrHistoryScore(history: *const @import("history.zig").HistoryTable, pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture() or mv.isPromotion()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    const color = moving_piece.color() orelse return 0;
    return history.score(color, moving_piece.pieceType(), mv.to);
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
) ?move_mod.Move {
    const previous_move = stack_entry.prev_move orelse return null;
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
    stack_entry: anytype,
    cont: *const history_mod.ContContext,
    side: types.Color,
    mv: move_mod.Move,
    moved_piece_type: piece.PieceType,
    quiets: []const move_mod.Move,
    quiet_pieces: []const piece.PieceType,
    depth: u16,
) void {
    rememberKiller(stack_entry, mv);
    history.bonus(side, moved_piece_type, mv.to, depth);
    history.contBonus(cont, history_mod.contKey(side, moved_piece_type, mv.to), depth);
    penalizeFailedQuiets(history, side, quiets, quiet_pieces, depth);
    for (quiets, quiet_pieces) |quiet, quiet_piece| {
        history.contPenalize(cont, history_mod.contKey(side, quiet_piece, quiet.to), depth);
    }

    const previous_move = stack_entry.prev_move orelse return;
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
    side: types.Color,
    quiets: []const move_mod.Move,
    quiet_pieces: []const piece.PieceType,
    depth: u16,
) void {
    std.debug.assert(quiets.len == quiet_pieces.len);
    for (quiets, quiet_pieces) |quiet, quiet_piece| {
        history.penalize(side, quiet_piece, quiet.to, depth);
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

    penalizeFailedQuiets(&history_table, .white, &quiets, &quiet_pieces, 5);

    try std.testing.expect(history_table.score(.white, .pawn, .a3) < 0);
    try std.testing.expect(history_table.score(.white, .knight, .f3) < 0);
    try std.testing.expectEqual(@as(i32, 0), history_table.score(.white, .pawn, .e4));
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

test "reverse futility does not publish a heuristic tt bound" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint_mod = @import("rfp_hint.zig");
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint_mod.HintTable.init(std.testing.allocator, rfp_hint_mod.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    ctx.stack.entry(1).acc.refresh(evaluator.net.?, &pos);

    const score = negamax(&ctx, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 2, 49, 50, 1, true, node_context.NodeContext.fromWindow(49, 50, false), null);
    try std.testing.expectEqual(@as(types.Score, 50), score);
    try std.testing.expect(table.lookup(pos.zobrist_key) == null);
    try std.testing.expect(hint_table.lookup(pos.zobrist_key, 2) != null);
}

test "reverse futility hint reuses on second probe without evaluating" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint_mod = @import("rfp_hint.zig");
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt_mod.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint_mod.HintTable.init(std.testing.allocator, rfp_hint_mod.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    var pos = try fen.parse("4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1");
    ctx.repetition.push(pos.zobrist_key);
    ctx.stack.entry(1).acc.refresh(evaluator.net.?, &pos);

    _ = negamax(&ctx, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 2, 49, 50, 1, true, node_context.NodeContext.fromWindow(49, 50, false), null);
    const evals_after_first = ctx.stats.main_static_evals;
    const rf_prunes_after_first = ctx.stats.reverse_futility_prunes;
    table.clear();

    const score = negamax(&ctx, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 2, 49, 50, 1, true, node_context.NodeContext.fromWindow(49, 50, false), null);
    try std.testing.expectEqual(@as(types.Score, 50), score);
    try std.testing.expectEqual(evals_after_first, ctx.stats.main_static_evals);
    try std.testing.expectEqual(rf_prunes_after_first, ctx.stats.reverse_futility_prunes);
    if (context_mod.stats_enabled) try std.testing.expect(ctx.stats.rfp_hint_cutoffs >= 1);
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
    try std.testing.expectEqual(response, previousQuietCountermove(&history_table, &quiet_entry, .black).?);

    var tactical_entry = stack.StackEntry{
        .prev_move = move_mod.Move.init(.e4, .d5, .capture),
        .prev_piece_type = .pawn,
    };
    try std.testing.expect(previousQuietCountermove(&history_table, &tactical_entry, .black) == null);
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

    applyQuietCutoffLearning(&history_table, &stack_entry, &cont, .black, cutoff_move, .knight, &tried_quiets, &tried_pieces, 4);

    try std.testing.expectEqual(cutoff_move, stack_entry.killer_a.?);
    try std.testing.expect(history_table.score(.black, .knight, .f6) > 0);
    try std.testing.expect(history_table.score(.black, .knight, .c6) < 0);
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
    const quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table);

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

    const tactical_quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table);
    try std.testing.expect(!tactical_quality.isWeak());

    const killer_alt = move_mod.Move.init(.e1, .d2, .quiet);
    stack_entry.killer_a = killer_alt;
    moves = move_mod.MoveList.init();
    moves.add(tt_move);
    moves.add(killer_alt);
    see_scores = [_]i32{0} ** move_mod.MAX_MOVES;
    const killer_quality = classifySingularAlternatives(&pos, &moves, &see_scores, tt_move, &stack_entry, null, &history_table);
    try std.testing.expect(killer_quality.has_killer_or_countermove);
}

test "root search depth one returns a move in start position" {
    const fen = @import("../core/fen.zig");
    const history = @import("history.zig");
    const rfp_hint_mod = @import("rfp_hint.zig");
    const tt = @import("tt.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = .{ .stop_flag = &stop_flag, .limits = .{ .depth = 1 } },
    };
    var history_table = history.HistoryTable{};
    var evaluator = try @import("../eval/backend.zig").EngineState.init(std.testing.allocator, .{});
    defer evaluator.deinit();
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var hint_table = try rfp_hint_mod.HintTable.init(std.testing.allocator, rfp_hint_mod.MIN_HINT_MB);
    defer hint_table.deinit();
    var ecache = try eval_cache_mod.EvalCache.init(std.testing.allocator, eval_cache_mod.MIN_CACHE_MB);
    defer ecache.deinit();
    var pos = try fen.startpos();
    ctx.repetition.push(pos.zobrist_key);

    const result = searchDepth(&ctx, .{ .tt = &table, .rfp_hint = &hint_table, .eval_cache = &ecache, .history = &history_table, .evaluator = &evaluator }, &pos, 1);
    try std.testing.expect(result.best_move != null);
}
