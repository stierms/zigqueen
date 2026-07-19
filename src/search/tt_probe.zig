const std = @import("std");
const context_mod = @import("context.zig");
const move_mod = @import("../core/move.zig");
const score_mod = @import("score.zig");
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
    table: *const tt.TranspositionTable,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
) void {
    result.entry = null;
    result.alpha = alpha_in;
    result.beta = beta_in;
    result.cutoff = null;

    var alpha = alpha_in;
    var beta = beta_in;

    ctx.noteTtProbe();
    const entry = table.lookupPtr(key) orelse return;
    ctx.noteTtHit();
    ctx.noteTtHitDetails(entry, table.generation);
    const current_generation = entry.generation == table.generation;

    if (excluded_move) |excluded| {
        if (tt.moveFromEntry(entry.*)) |entry_move| {
            if (entry_move == excluded) return;
        }
    }

    result.entry = entry.*;
    if (entry.depth < required_depth or score_mod.isMateLike(entry.score)) {
        ctx.noteTtShallowHit();
        ctx.noteTtOrderingOnlyHit();
        ctx.noteTtOrderingOnlyGeneration(current_generation);
        return;
    }

    switch (entry.bound) {
        .exact => {
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

    switch (entry.bound) {
        .lower => ctx.noteTtLowerCutoff(),
        .upper => ctx.noteTtUpperCutoff(),
        .exact => unreachable,
    }
    ctx.noteTtCutoffGeneration(current_generation);
    result.cutoff = entry.score;
}

/// By-value convenience wrapper (tests and any cold caller).
pub inline fn probe(
    ctx: *context_mod.SearchContext,
    table: *const tt.TranspositionTable,
    key: u64,
    required_depth: i16,
    alpha_in: types.Score,
    beta_in: types.Score,
    excluded_move: ?move_mod.Move,
) Result {
    var result: Result = undefined;
    probeInto(&result, ctx, table, key, required_depth, alpha_in, beta_in, excluded_move);
    return result;
}

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

    table.store(0x1234, 4, 17, .exact, null);
    const result = probe(&ctx, &table, 0x1234, 4, -20, 20, null);

    try std.testing.expect(result.entry != null);
    try std.testing.expectEqual(@as(?types.Score, 17), result.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_probes);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_hits);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_exact_cutoffs);
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

    table.store(0x2222, 1, 30, .lower, null);
    const result = probe(&ctx, &table, 0x2222, 3, 10, 11, null);

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

    table.store(0x2fff, 4, 42, .lower, null);
    const partial = probe(&ctx, &table, 0x2fff, 4, 40, 45, null);
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

    table.store(0x3000, 4, 50, .lower, null);
    const lower = probe(&ctx, &table, 0x3000, 4, 40, 45, null);
    try std.testing.expectEqual(@as(?types.Score, 50), lower.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_lower_cutoffs);

    ctx.stats = .{};
    table.clear();
    table.store(0x3001, 4, 30, .upper, null);
    const upper = probe(&ctx, &table, 0x3001, 4, 35, 40, null);
    try std.testing.expectEqual(@as(?types.Score, 30), upper.cutoff);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_upper_cutoffs);
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
    table.store(0x4000, 5, 88, .lower, excluded);
    const result = probe(&ctx, &table, 0x4000, 5, 40, 45, excluded);

    try std.testing.expect(result.entry == null);
    try std.testing.expect(result.cutoff == null);
    try std.testing.expectEqual(@as(types.Score, 40), result.alpha);
    try std.testing.expectEqual(@as(types.Score, 45), result.beta);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 1), ctx.stats.tt_hits);
    if (context_mod.stats_enabled) try std.testing.expectEqual(@as(u64, 0), ctx.stats.tt_lower_cutoffs);
}
