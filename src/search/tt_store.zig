const std = @import("std");
const context_mod = @import("context.zig");
const move_mod = @import("../core/move.zig");
const tt = @import("tt.zig");
const types = @import("../core/types.zig");

pub inline fn boundForWindow(alpha_orig: types.Score, beta: types.Score, score: types.Score) tt.Bound {
    if (score <= alpha_orig) return .upper;
    if (score >= beta) return .lower;
    return .exact;
}

inline fn noteStore(ctx: ?*context_mod.SearchContext, outcome: tt.StoreOutcome) void {
    if (ctx) |search_ctx| search_ctx.noteTtStore(outcome);
}

/// Convert an optional raw static eval to the TT's i16 slot (null -> NONE).
pub inline fn evalToTt(raw: ?types.Score) i16 {
    const value = raw orelse return tt.STATIC_EVAL_NONE;
    return @intCast(std.math.clamp(value, -32700, 32700));
}

pub inline fn storeWindowResult(
    ctx: ?*context_mod.SearchContext,
    table: *tt.TranspositionTable,
    key: u64,
    depth: i16,
    alpha_orig: types.Score,
    beta: types.Score,
    score: types.Score,
    mv: ?move_mod.Move,
    static_eval: i16,
) void {
    noteStore(ctx, table.storeWithOutcome(key, depth, score, boundForWindow(alpha_orig, beta, score), mv, static_eval));
}

pub inline fn storeLowerBound(
    ctx: ?*context_mod.SearchContext,
    table: *tt.TranspositionTable,
    key: u64,
    depth: i16,
    beta: types.Score,
    mv: ?move_mod.Move,
    static_eval: i16,
) void {
    noteStore(ctx, table.storeWithOutcome(key, depth, beta, .lower, mv, static_eval));
}

test "boundForWindow classifies upper exact and lower results" {
    try std.testing.expectEqual(tt.Bound.upper, boundForWindow(20, 40, 20));
    try std.testing.expectEqual(tt.Bound.upper, boundForWindow(20, 40, -10));
    try std.testing.expectEqual(tt.Bound.exact, boundForWindow(20, 40, 30));
    try std.testing.expectEqual(tt.Bound.lower, boundForWindow(20, 40, 40));
    try std.testing.expectEqual(tt.Bound.lower, boundForWindow(20, 40, 80));
}

test "storeLowerBound publishes the proven beta score" {
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const key: u64 = 0x1234;
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    storeLowerBound(null, &table, key, 3, 51, mv, tt.STATIC_EVAL_NONE);

    const entry = table.lookup(key).?;
    try std.testing.expectEqual(tt.Bound.lower, entry.bound);
    try std.testing.expectEqual(@as(i32, 51), entry.score);
    try std.testing.expectEqual(mv, tt.moveFromEntry(entry).?);
}

test "storeWindowResult stores the searched score with the matching bound" {
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const exact_key: u64 = 0x2000;
    const upper_key: u64 = 0x2001;
    const lower_key: u64 = 0x2002;

    storeWindowResult(null, &table, exact_key, 4, 20, 40, 30, null, tt.STATIC_EVAL_NONE);
    storeWindowResult(null, &table, upper_key, 4, 20, 40, 10, null, tt.STATIC_EVAL_NONE);
    storeWindowResult(null, &table, lower_key, 4, 20, 40, 45, null, tt.STATIC_EVAL_NONE);

    try std.testing.expectEqual(tt.Bound.exact, table.lookup(exact_key).?.bound);
    try std.testing.expectEqual(@as(i32, 30), table.lookup(exact_key).?.score);
    try std.testing.expectEqual(tt.Bound.upper, table.lookup(upper_key).?.bound);
    try std.testing.expectEqual(@as(i32, 10), table.lookup(upper_key).?.score);
    try std.testing.expectEqual(tt.Bound.lower, table.lookup(lower_key).?.bound);
    try std.testing.expectEqual(@as(i32, 45), table.lookup(lower_key).?.score);
}
