const std = @import("std");
const context_mod = @import("context.zig");
const move_mod = @import("../core/move.zig");
const score_mod = @import("score.zig");
const shallow_arms = @import("shallow_arms.zig");
const tt = @import("tt.zig");
const types = @import("../core/types.zig");

pub const Result = struct {
    entry: ?tt.Entry = null,
    alpha: types.Score,
    beta: types.Score,
    cutoff: ?types.Score = null,
};

/// Out-pointer form, inlined into negamax/qsearch. History of this hot spot:
/// round 1 inlined the sret-returning `probe` (kept cutoff/alpha/beta out of a
/// caller reload). But the inline body still materialized each `return .{...}`
/// as a stack temp that LLVM then copied to the caller's `probe` slot with two
/// overlapping 32-byte vmovdqu loads — wide loads spanning the narrow stores
/// that had just built the temp, a failed store-to-load forward (15.0% of
/// negamax samples in the endgame profile, instruction 0x30dce64). Writing the
/// fields directly through the caller's pointer removes the temp and the wide
/// copy entirely; every later read (cutoff tag, alpha, beta, entry fields) is
/// a narrow load fully contained in one narrow store, which forwards cleanly.
/// Behavior is identical.
pub inline fn probeInto(
    result: *Result,
    ctx: *context_mod.SearchContext,
    table: anytype,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
    halfmove_clock: u16,
    ply: usize,
) void {
    probeIntoImpl(result, ctx, table, key, required_depth, alpha_in, beta_in, excluded_move, false, false, halfmove_clock, ply, false);
}

/// Main-search probe with the rule-50 trust gate, the PV-node trust gate
/// (shallow_arms.pvTtScoreTrusted) and the tuning-only node-role gate
/// (quiescence applies the rule-50 gate alone).
/// From the rule-50 gate clock on the entry orders moves only: no cutoff and
/// no bound tightening. Below it, bound tightening remains active even when
/// the node-role gate declines a would-be cutoff.
pub inline fn probeMainInto(
    result: *Result,
    ctx: *context_mod.SearchContext,
    table: anytype,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
    pv_node: bool,
    cut_node: bool,
    halfmove_clock: u16,
    ply: usize,
) void {
    probeIntoImpl(result, ctx, table, key, required_depth, alpha_in, beta_in, excluded_move, pv_node, cut_node, halfmove_clock, ply, true);
}

inline fn probeIntoImpl(
    result: *Result,
    ctx: *context_mod.SearchContext,
    table: anytype,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
    pv_node: bool,
    cut_node: bool,
    halfmove_clock: u16,
    ply: usize,
    comptime main_search: bool,
) void {
    result.entry = null;
    result.alpha = alpha_in;
    result.beta = beta_in;
    result.cutoff = null;

    var alpha = alpha_in;
    var beta = beta_in;

    ctx.noteTtProbe();
    // The key of this search's table context (context.tableKey): an entry
    // of another context is not found at all.
    var entry = table.probe(key ^ ctx.tableKey(halfmove_clock)) orelse return;
    if (comptime context_mod.stats_enabled) {
        if (entry.foreign) ctx.stats.tt_foreign_hits += 1;
    }
    // Back to this node's frame before any consumer sees it (score.fromTt):
    // cutoffs, bound tightening, singular, ProbCut and LMR all read entry.score.
    // A stored mate score is a distance to mate from this node (score.toTt).
    // It holds here when that mate still comes before the fifty-move boundary
    // on this node's clock (a mating move at clock 100 mates, rule50.zig) and
    // lies inside the mate band seen from the root. Otherwise the entry
    // orders moves only, and its score stays a mate score for every reader.
    const stored_mate_plies: ?i32 = if (score_mod.isMateLike(entry.score)) score_mod.matePlies(entry.score, 0) else null;
    entry.score = score_mod.fromTt(entry.score, ply);
    var mate_out_of_reach = false;
    if (stored_mate_plies) |plies| {
        if (!score_mod.isMateLike(entry.score)) {
            entry.score = if (entry.score > 0) score_mod.MATE_THRESHOLD else -score_mod.MATE_THRESHOLD;
            mate_out_of_reach = true;
        } else if (@as(i32, halfmove_clock) + plies > 100) {
            mate_out_of_reach = true;
        }
    }
    // And back to the search's depths (tt.STORED_DEPTH_OFFSET).
    entry.depth -= tt.STORED_DEPTH_OFFSET;
    ctx.noteTtHit();
    ctx.noteTtHitDetails(&entry, table.generation);
    const current_generation = entry.generation == table.generation;

    if (excluded_move) |excluded| {
        if (tt.moveFromEntry(entry)) |entry_move| {
            if (entry_move == excluded) return;
        }
    }

    result.entry = entry;
    if (entry.depth < required_depth or mate_out_of_reach) {
        ctx.noteTtShallowHit();
        ctx.noteTtOrderingOnlyHit();
        ctx.noteTtOrderingOnlyGeneration(current_generation);
        return;
    }

    // From the rule-50 gate clock on the score may be stale (a draw by the
    // clock is near): it neither cuts nor narrows the window, which would
    // otherwise pass a stale bound to a PV node as its result. The entry
    // still orders moves and supplies the static eval.
    if (!shallow_arms.rule50TrustsTtScore(halfmove_clock)) {
        ctx.noteTtOrderingOnlyHit();
        ctx.noteTtOrderingOnlyGeneration(current_generation);
        return;
    }

    // A main-search PV node searches its own window (shallow_arms
    // .pvTtScoreTrusted): the entry orders moves and supplies the static
    // eval; its score neither cuts nor narrows the window. Exception: a
    // decided score (shallow_arms.pvTtDecidedScore) is used as 6.5.0 did.
    if (main_search and pv_node and !shallow_arms.pvTtScoreTrusted() and
        @abs(entry.score) < shallow_arms.pvTtDecidedScore())
    {
        ctx.noteTtOrderingOnlyHit();
        ctx.noteTtOrderingOnlyGeneration(current_generation);
        return;
    }

    switch (entry.bound) {
        .exact => {
            if (!cutoffAllowed(main_search, entry.score, alpha_in, pv_node, cut_node, halfmove_clock)) {
                ctx.noteTtOrderingOnlyHit();
                ctx.noteTtOrderingOnlyGeneration(current_generation);
                return;
            }
            ctx.noteTtExactCutoff();
            ctx.noteTtCutoffGeneration(current_generation);
            result.cutoff = entry.score;
            return;
        },
        .lower => {
            if (entry.score > alpha) alpha = entry.score;
        },
        .upper => {
            if (entry.score < beta) beta = entry.score;
        },
    }

    result.alpha = alpha;
    result.beta = beta;
    if (alpha < beta) {
        if (alpha != alpha_in or beta != beta_in) {
            ctx.noteTtBoundNoCutoffHit();
        } else {
            ctx.noteTtOrderingOnlyHit();
            ctx.noteTtOrderingOnlyGeneration(current_generation);
        }
        return;
    }

    if (!cutoffAllowed(main_search, entry.score, alpha_in, pv_node, cut_node, halfmove_clock)) {
        // A rejected would-be cutoff cannot pass a closed window to negamax.
        // Preserve ordinary non-cutting tightening, but restore the caller's
        // window when this entry alone would otherwise close it.
        result.alpha = alpha_in;
        result.beta = beta_in;
        ctx.noteTtBoundNoCutoffHit();
        return;
    }

    switch (entry.bound) {
        .lower => ctx.noteTtLowerCutoff(),
        .upper => ctx.noteTtUpperCutoff(),
        .exact => unreachable,
    }
    ctx.noteTtCutoffGeneration(current_generation);
    result.cutoff = entry.score;
}

inline fn cutoffAllowed(comptime main_search: bool, entry_score: types.Score, alpha_in: types.Score, pv_node: bool, cut_node: bool, halfmove_clock: u16) bool {
    if (main_search) return shallow_arms.allowMainTtCutoff(entry_score, alpha_in, pv_node, cut_node, halfmove_clock);
    return shallow_arms.rule50TrustsTtScore(halfmove_clock);
}

/// By-value convenience wrapper (tests and any cold caller), probing at the root (ply 0) with clock 0.
pub inline fn probe(
    ctx: *context_mod.SearchContext,
    table: anytype,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
) Result {
    var result: Result = undefined;
    probeInto(&result, ctx, table, key, required_depth, alpha_in, beta_in, excluded_move, 0, 0);
    return result;
}

// The tests' keys differ in their tag bits (key bits 32..47, tt.tagOf): the
// table tells positions apart by cluster and tag, not by the whole key.

test "tt probe returns exact cutoffs at sufficient depth" {
    const history = @import("history.zig");
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var history_table = history.HistoryTable{};
    _ = &history_table;

    table.store(0x1234 << 32, 4 + tt.STORED_DEPTH_OFFSET, 17, .exact, null);
    const result = probe(&ctx, &table, 0x1234 << 32, 4, -20, 20, null);

    try std.testing.expect(result.entry != null);
    try std.testing.expectEqual(@as(?types.Score, 17), result.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_probes);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_hits);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_exact_cutoffs);
}

test "tt probe trusts a mate score while the mate fits before the fifty-move boundary" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    // Stored form: mate 5 plies below the node (score.toTt).
    table.store(0x5000 << 32, 6 + tt.STORED_DEPTH_OFFSET, score_mod.MATE_SCORE - 5, .exact, null);
    table.store(0x5001 << 32, 6 + tt.STORED_DEPTH_OFFSET, -(score_mod.MATE_SCORE - 4), .exact, null);

    // Read at ply 3 with clock 20: mate at ply 8, a cutoff.
    var result: Result = undefined;
    probeMainInto(&result, &ctx, &table, 0x5000 << 32, 6, -50, 50, null, false, false, 20, 3);
    try std.testing.expectEqual(@as(?types.Score, score_mod.MATE_SCORE - 8), result.cutoff);
    // A mate 30 plies away: at clock 70 the mating move is played at clock
    // 100 and mates; at clock 71 the draw comes first, so the entry only
    // orders moves.
    table.store(0x5002 << 32, 6 + tt.STORED_DEPTH_OFFSET, score_mod.MATE_SCORE - 30, .exact, null);
    probeMainInto(&result, &ctx, &table, 0x5002 << 32, 6, -50, 50, null, false, false, 70, 3);
    try std.testing.expectEqual(@as(?types.Score, score_mod.MATE_SCORE - 33), result.cutoff);
    probeMainInto(&result, &ctx, &table, 0x5002 << 32, 6, -50, 50, null, false, false, 71, 3);
    try std.testing.expect(result.cutoff == null and result.entry != null);
    // Read so deep that the mate leaves the mate band (30 + 110 plies from
    // the root): ordering only, and still a mate score to its readers.
    probeMainInto(&result, &ctx, &table, 0x5002 << 32, 6, -50, 50, null, false, false, 20, 110);
    try std.testing.expect(result.cutoff == null);
    try std.testing.expect(score_mod.isMateLike(result.entry.?.score));
    // Being mated in 4 plies, read at ply 2 with clock 80: holds.
    probeMainInto(&result, &ctx, &table, 0x5001 << 32, 6, -50, 50, null, false, false, 80, 2);
    try std.testing.expectEqual(@as(?types.Score, -(score_mod.MATE_SCORE - 6)), result.cutoff);
    // A shallower entry still orders only.
    probeMainInto(&result, &ctx, &table, 0x5000 << 32, 7, -50, 50, null, false, false, 20, 3);
    try std.testing.expect(result.cutoff == null and result.entry != null);
}

test "tt probe keeps hit entry for move ordering when depth is insufficient" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    table.store(0x2222 << 32, 1 + tt.STORED_DEPTH_OFFSET, 30, .lower, null);
    const result = probe(&ctx, &table, 0x2222 << 32, 3, 10, 11, null);

    try std.testing.expect(result.entry != null);
    try std.testing.expect(result.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 10), result.alpha);
    try std.testing.expectEqual(@as(types.Score, 11), result.beta);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_shallow_hits);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_ordering_only_hits);
}

test "tt probe counts non-cutoff bound tightening before a later cutoff" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    table.store(0x2fff << 32, 4 + tt.STORED_DEPTH_OFFSET, 42, .lower, null);
    const partial = probe(&ctx, &table, 0x2fff << 32, 4, 40, 45, null);
    try std.testing.expect(partial.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 42), partial.alpha);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_bound_no_cutoff_hits);
}

test "tt probe applies lower and upper bounds before reporting cutoffs" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    table.store(0x3000 << 32, 4 + tt.STORED_DEPTH_OFFSET, 50, .lower, null);
    const lower = probe(&ctx, &table, 0x3000 << 32, 4, 40, 45, null);
    try std.testing.expectEqual(@as(?types.Score, 50), lower.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_lower_cutoffs);

    ctx.stats = .{};
    table.clear();
    table.store(0x3001 << 32, 4 + tt.STORED_DEPTH_OFFSET, 30, .upper, null);
    const upper = probe(&ctx, &table, 0x3001 << 32, 4, 35, 40, null);
    try std.testing.expectEqual(@as(?types.Score, 30), upper.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_upper_cutoffs);
}

test "node-role trust rejects a lower cutoff without leaking a closed window" {
    const build_options = @import("build_options");
    if (!build_options.tuning) return;

    const time = @import("time.zig");
    const tunables = @import("tunables.zig");
    tunables.reset();
    defer tunables.reset();
    try std.testing.expect(tunables.set("TtCutoffNodeRole", 1));

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    table.store(0x3500 << 32, 4 + tt.STORED_DEPTH_OFFSET, 50, .lower, null);
    var result: Result = undefined;
    probeMainInto(&result, &ctx, &table, 0x3500 << 32, 4, 40, 45, null, false, false, 0, 0);

    try std.testing.expect(result.entry != null);
    try std.testing.expect(result.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 40), result.alpha);
    try std.testing.expectEqual(@as(types.Score, 45), result.beta);
}

test "tt probe ignores entries whose stored move is the excluded move" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const excluded = move_mod.Move.init(.e2, .e4, .double_push);
    table.store(0x4000 << 32, 5 + tt.STORED_DEPTH_OFFSET, 88, .lower, excluded);
    const result = probe(&ctx, &table, 0x4000 << 32, 5, 40, 45, excluded);

    try std.testing.expect(result.entry == null);
    try std.testing.expect(result.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 40), result.alpha);
    try std.testing.expectEqual(@as(types.Score, 45), result.beta);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_hits);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 0), ctx.stats.tt_lower_cutoffs);
}

test "tablebase scores keep their distance from the probing node across plies" {
    // Audit A (S-TB-PLY), Report 2's ply-8 / ply-2 case: a TB win found at ply 8
    // and stored by its ply-2 ancestor read back as 28000 - 8 at every ply.
    const time = @import("time.zig");
    const tt_store = @import("tt_store.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const win = score_mod.TB_WIN_SCORE - 8;
    tt_store.storeWindowResult(null, &table, 0x5000 << 32, 6, -30_000, 30_000, win, null, tt.STATIC_EVAL_NONE, false, 2, 0);
    tt_store.storeLowerBound(null, &table, 0x5001 << 32, 6, -win, null, tt.STATIC_EVAL_NONE, false, 2, 0);
    tt_store.storeWindowResult(null, &table, 0x5002 << 32, 6, -30_000, 30_000, 345, null, tt.STATIC_EVAL_NONE, false, 2, 0);

    var result: Result = undefined;
    // The same node reached two plies deeper: the win is two plies further away.
    probeInto(&result, &ctx, &table, 0x5000 << 32, 6, -30_000, 30_000, null, 0, 4);
    try std.testing.expectEqual(@as(?types.Score, score_mod.TB_WIN_SCORE - 10), result.cutoff);
    try std.testing.expectEqual(score_mod.TB_WIN_SCORE - 10, result.entry.?.score);
    // Read back at the storing ply: unchanged; at the root: six plies nearer.
    probeInto(&result, &ctx, &table, 0x5000 << 32, 6, -30_000, 30_000, null, 0, 2);
    try std.testing.expectEqual(@as(?types.Score, win), result.cutoff);
    probeMainInto(&result, &ctx, &table, 0x5000 << 32, 6, -30_000, 30_000, null, false, false, 0, 0);
    try std.testing.expectEqual(@as(?types.Score, score_mod.TB_WIN_SCORE - 6), result.cutoff);
    // A loss bound mirrors it (the bound is decided before conversion).
    probeInto(&result, &ctx, &table, 0x5001 << 32, 6, -30_000, -27_000, null, 0, 5);
    try std.testing.expectEqual(tt.Bound.lower, result.entry.?.bound);
    try std.testing.expectEqual(-score_mod.TB_WIN_SCORE + 11, result.entry.?.score);
    // Ordinary scores read back as stored at any ply.
    probeInto(&result, &ctx, &table, 0x5002 << 32, 6, -30_000, 30_000, null, 0, 9);
    try std.testing.expectEqual(@as(?types.Score, 345), result.cutoff);
}

test "tt probe takes no score cutoff from the rule-50 gate clock on, main search and qsearch" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const gate = shallow_arms.ttCutoffHalfmoveMax();
    try std.testing.expect(gate < 100);

    table.store(0x4000 << 32, 4 + tt.STORED_DEPTH_OFFSET, 17, .exact, null);
    table.store(0x4001 << 32, 4 + tt.STORED_DEPTH_OFFSET, 50, .lower, null);
    table.store(0x4002 << 32, 4 + tt.STORED_DEPTH_OFFSET, 30, .upper, null);
    for ([_]bool{ false, true }) |main_search| {
        for ([_]u16{ 0, gate - 1, gate, 99 }) |clock| {
            const allowed = clock < gate;
            var exact: Result = undefined;
            var lower: Result = undefined;
            var upper: Result = undefined;
            if (main_search) {
                probeMainInto(&exact, &ctx, &table, 0x4000 << 32, 4, -20, 20, null, false, false, clock, 0);
                probeMainInto(&lower, &ctx, &table, 0x4001 << 32, 4, 40, 45, null, false, false, clock, 0);
                probeMainInto(&upper, &ctx, &table, 0x4002 << 32, 4, 35, 40, null, false, false, clock, 0);
            } else {
                probeInto(&exact, &ctx, &table, 0x4000 << 32, 4, -20, 20, null, clock, 0);
                probeInto(&lower, &ctx, &table, 0x4001 << 32, 4, 40, 45, null, clock, 0);
                probeInto(&upper, &ctx, &table, 0x4002 << 32, 4, 35, 40, null, clock, 0);
            }
            try std.testing.expectEqual(if (allowed) @as(?types.Score, 17) else null, exact.cutoff);
            try std.testing.expectEqual(if (allowed) @as(?types.Score, 50) else null, lower.cutoff);
            try std.testing.expectEqual(if (allowed) @as(?types.Score, 30) else null, upper.cutoff);
            // A declined cutoff keeps the entry for ordering and the window open.
            try std.testing.expect(exact.entry != null);
            if (!allowed) {
                try std.testing.expectEqual(@as(types.Score, -20), exact.alpha);
                try std.testing.expectEqual(@as(types.Score, 20), exact.beta);
                try std.testing.expectEqual(@as(types.Score, 40), lower.alpha);
                try std.testing.expectEqual(@as(types.Score, 45), lower.beta);
            }
        }
    }
}

test "tt probe bounds do not narrow the window from the rule-50 gate clock on" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const gate = shallow_arms.ttCutoffHalfmoveMax();
    try std.testing.expectEqual(@as(u16, 90), gate);

    // Bounds inside the window [40, 45]: they tighten it without closing it,
    // so no cutoff gate ever sees them (a node would return the bound). Main
    // search probes as a non-PV node: a PV node never narrows (the PV gate).
    table.store(0x4100 << 32, 4 + tt.STORED_DEPTH_OFFSET, 42, .lower, null);
    table.store(0x4101 << 32, 4 + tt.STORED_DEPTH_OFFSET, 43, .upper, null);
    for ([_]bool{ false, true }) |main_search| {
        for ([_]u16{ 0, 89, 90, 99 }) |clock| {
            const trusted = clock < gate;
            var lower: Result = undefined;
            var upper: Result = undefined;
            if (main_search) {
                probeMainInto(&lower, &ctx, &table, 0x4100 << 32, 4, 40, 45, null, false, false, clock, 0);
                probeMainInto(&upper, &ctx, &table, 0x4101 << 32, 4, 40, 45, null, false, false, clock, 0);
            } else {
                probeInto(&lower, &ctx, &table, 0x4100 << 32, 4, 40, 45, null, clock, 0);
                probeInto(&upper, &ctx, &table, 0x4101 << 32, 4, 40, 45, null, clock, 0);
            }
            try std.testing.expect(lower.entry != null);
            try std.testing.expect(upper.entry != null);
            try std.testing.expect(lower.cutoff == null);
            try std.testing.expect(upper.cutoff == null);
            try std.testing.expectEqual(@as(types.Score, if (trusted) 42 else 40), lower.alpha);
            try std.testing.expectEqual(@as(types.Score, 45), lower.beta);
            try std.testing.expectEqual(@as(types.Score, 40), upper.alpha);
            try std.testing.expectEqual(@as(types.Score, if (trusted) 43 else 45), upper.beta);
        }
    }
}

test "a tablebase entry from the rule-50 gate clock on orders moves only, its score still rebased" {
    // Integration of S-TB-PLY and the rule-50 gate (both in probeIntoImpl):
    // the ply rebase comes first, so from clock 90 a TB entry neither cuts
    // nor narrows the window, and the entry it hands on for ordering, singular
    // and ProbCut carries the distance from this node.
    const time = @import("time.zig");
    const tt_store = @import("tt_store.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const gate = shallow_arms.ttCutoffHalfmoveMax();

    // A TB win found 8 plies from the root, stored by its ply-2 ancestor:
    // exact, and as a lower bound inside a window near the band.
    const win = score_mod.TB_WIN_SCORE - 8;
    tt_store.storeWindowResult(null, &table, 0x5200 << 32, 6, -30_000, 30_000, win, null, tt.STATIC_EVAL_NONE, false, 2, 0);
    tt_store.storeLowerBound(null, &table, 0x5201 << 32, 6, win, null, tt.STATIC_EVAL_NONE, false, 2, 0);
    const at_ply_4 = score_mod.TB_WIN_SCORE - 10;
    for ([_]bool{ false, true }) |main_search| {
        for ([_]u16{ 0, gate - 1, gate, 99 }) |clock| {
            const trusted = clock < gate;
            var exact: Result = undefined;
            var lower: Result = undefined;
            if (main_search) {
                probeMainInto(&exact, &ctx, &table, 0x5200 << 32, 6, -30_000, 30_000, null, false, false, clock, 4);
                probeMainInto(&lower, &ctx, &table, 0x5201 << 32, 6, 27_000, 29_000, null, false, false, clock, 4);
            } else {
                probeInto(&exact, &ctx, &table, 0x5200 << 32, 6, -30_000, 30_000, null, clock, 4);
                probeInto(&lower, &ctx, &table, 0x5201 << 32, 6, 27_000, 29_000, null, clock, 4);
            }
            try std.testing.expectEqual(at_ply_4, exact.entry.?.score);
            try std.testing.expectEqual(at_ply_4, lower.entry.?.score);
            try std.testing.expectEqual(if (trusted) @as(?types.Score, at_ply_4) else null, exact.cutoff);
            try std.testing.expect(lower.cutoff == null);
            try std.testing.expectEqual(@as(types.Score, if (trusted) at_ply_4 else 27_000), lower.alpha);
            try std.testing.expectEqual(@as(types.Score, 29_000), lower.beta);
            if (!trusted) {
                try std.testing.expectEqual(@as(types.Score, -30_000), exact.alpha);
                try std.testing.expectEqual(@as(types.Score, 30_000), exact.beta);
            }
        }
    }
}

test "a main-search PV node takes neither a cutoff nor a narrower window from the table" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    try std.testing.expect(!shallow_arms.pvTtScoreTrusted());

    const tt_move = move_mod.Move.init(.e2, .e4, .double_push);
    table.store(0x6000 << 32, 4 + tt.STORED_DEPTH_OFFSET, 17, .exact, tt_move);
    table.store(0x6001 << 32, 4 + tt.STORED_DEPTH_OFFSET, 50, .lower, tt_move); // closes [40, 45]
    table.store(0x6002 << 32, 4 + tt.STORED_DEPTH_OFFSET, 42, .lower, tt_move); // narrows [40, 45]
    table.store(0x6003 << 32, 4 + tt.STORED_DEPTH_OFFSET, 30, .upper, tt_move); // closes [35, 40]
    table.store(0x6004 << 32, 4 + tt.STORED_DEPTH_OFFSET, 38, .upper, tt_move); // narrows [35, 40]
    const Case = struct { key: u64, alpha: types.Score, beta: types.Score, cut: ?types.Score, narrowed_alpha: types.Score, narrowed_beta: types.Score };
    const cases = [_]Case{
        .{ .key = 0x6000 << 32, .alpha = -20, .beta = 20, .cut = 17, .narrowed_alpha = -20, .narrowed_beta = 20 },
        .{ .key = 0x6001 << 32, .alpha = 40, .beta = 45, .cut = 50, .narrowed_alpha = 50, .narrowed_beta = 45 },
        .{ .key = 0x6002 << 32, .alpha = 40, .beta = 45, .cut = null, .narrowed_alpha = 42, .narrowed_beta = 45 },
        .{ .key = 0x6003 << 32, .alpha = 35, .beta = 40, .cut = 30, .narrowed_alpha = 35, .narrowed_beta = 30 },
        .{ .key = 0x6004 << 32, .alpha = 35, .beta = 40, .cut = null, .narrowed_alpha = 35, .narrowed_beta = 38 },
    };
    for (cases) |c| {
        // PV node, main search: ordering only, the caller's window untouched.
        var pv: Result = undefined;
        probeMainInto(&pv, &ctx, &table, c.key, 4, c.alpha, c.beta, null, true, false, 0, 0);
        try std.testing.expect(pv.cutoff == null);
        try std.testing.expectEqual(@as(?move_mod.Move, tt_move), tt.moveFromEntry(pv.entry.?));
        try std.testing.expectEqual(c.alpha, pv.alpha);
        try std.testing.expectEqual(c.beta, pv.beta);

        // Non-PV node and quiescence (any window): 6.5.0's cutoffs and narrowing.
        var scout: Result = undefined;
        var quiet: Result = undefined;
        probeMainInto(&scout, &ctx, &table, c.key, 4, c.alpha, c.beta, null, false, false, 0, 0);
        probeInto(&quiet, &ctx, &table, c.key, 4, c.alpha, c.beta, null, 0, 0);
        for ([_]*const Result{ &scout, &quiet }) |r| {
            try std.testing.expectEqual(c.cut, r.cutoff);
            if (c.cut == null) {
                try std.testing.expectEqual(c.narrowed_alpha, r.alpha);
                try std.testing.expectEqual(c.narrowed_beta, r.beta);
            }
        }
    }
}

test "PvTtScoreTrust 1 restores 6.5.0's PV-node cutoffs and narrowing (tuning builds)" {
    const build_options = @import("build_options");
    if (!build_options.tuning) return;

    const time = @import("time.zig");
    const tunables = @import("tunables.zig");
    tunables.reset();
    defer tunables.reset();
    try std.testing.expect(tunables.set("PvTtScoreTrust", 1));
    try std.testing.expect(shallow_arms.pvTtScoreTrusted());

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    table.store(0x6100 << 32, 4 + tt.STORED_DEPTH_OFFSET, 17, .exact, null);
    table.store(0x6101 << 32, 4 + tt.STORED_DEPTH_OFFSET, 42, .lower, null);
    var exact: Result = undefined;
    var lower: Result = undefined;
    probeMainInto(&exact, &ctx, &table, 0x6100 << 32, 4, -20, 20, null, true, false, 0, 0);
    probeMainInto(&lower, &ctx, &table, 0x6101 << 32, 4, 40, 45, null, true, false, 0, 0);
    try std.testing.expectEqual(@as(?types.Score, 17), exact.cutoff);
    try std.testing.expect(lower.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 42), lower.alpha);
}

test "a main-search PV node still cuts and narrows on a decided table score" {
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const decided = shallow_arms.pvTtDecidedScore();
    try std.testing.expectEqual(@as(types.Score, 400), decided);

    table.store(0x6400 << 32, 4 + tt.STORED_DEPTH_OFFSET, decided, .exact, null);
    table.store(0x6401 << 32, 4 + tt.STORED_DEPTH_OFFSET, decided - 1, .exact, null);
    table.store(0x6402 << 32, 4 + tt.STORED_DEPTH_OFFSET, -decided - 10, .lower, null);
    var cut: Result = undefined;
    var level: Result = undefined;
    var narrowed: Result = undefined;
    probeMainInto(&cut, &ctx, &table, 0x6400 << 32, 4, -1000, 1000, null, true, false, 0, 0);
    probeMainInto(&level, &ctx, &table, 0x6401 << 32, 4, -1000, 1000, null, true, false, 0, 0);
    probeMainInto(&narrowed, &ctx, &table, 0x6402 << 32, 4, -1000, 1000, null, true, false, 0, 0);
    try std.testing.expectEqual(@as(?types.Score, decided), cut.cutoff);
    try std.testing.expect(level.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, -1000), level.alpha);
    try std.testing.expect(narrowed.cutoff == null);
    try std.testing.expectEqual(-decided - 10, narrowed.alpha);
}
