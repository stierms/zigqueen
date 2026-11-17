const std = @import("std");
const build_options = @import("build_options");
const context_mod = @import("context.zig");
const move_mod = @import("../core/move.zig");
const score_mod = @import("score.zig");
const tt = @import("tt.zig");
const tunables = @import("tunables.zig");
const types = @import("../core/types.zig");

pub inline fn boundForWindow(alpha_orig: types.Score, beta: types.Score, score: types.Score) tt.Bound {
    if (score <= alpha_orig) return .upper;
    if (score >= beta) return .lower;
    return .exact;
}

/// The move of a fail low (round 3, 2026-11-13). A main-search node that
/// fails low has a "best move" all the same: the one with the highest
/// fail-soft score among moves that were all refuted. Stored with the upper
/// bound it is the next visit's table move: searched first, never reduced or
/// pruned, and it keeps internal iterative reduction off.
///   0: it is stored (6.5.0 and before).
///   1: a fail low stores no move. With tt.Policy.keep_move the entry then
///      keeps the move an earlier search stored; without it the entry has none.
///   2: as 1 at non-PV nodes only. A PV node that fails low (a re-search
///      after the window moved) still stores its move.
/// The root's own store (root.zig searchRoot) is not under the rule.
/// Quiescence needs none: its `best` starts at alpha, so a move is recorded
/// only once it beat alpha, and its final store never has a fail low's move.
/// 1 in the round-3 integration branch, with tt.KEEP_MOVE_DEFAULT: the cell
/// that is tested as one.
pub const FAIL_LOW_NO_MOVE_DEFAULT: types.Score = 1;

pub inline fn failLowNoMove() types.Score {
    if (comptime build_options.tuning) return tunables.active.fail_low_no_move;
    return FAIL_LOW_NO_MOVE_DEFAULT;
}

/// The move a node's final store records for `score` against the window's
/// `alpha_orig` under `mode` (failLowNoMove); `pv_node` is the node's role.
pub inline fn windowResultMove(mode: types.Score, pv_node: bool, alpha_orig: types.Score, score: types.Score, mv: ?move_mod.Move) ?move_mod.Move {
    if (mode != 0 and score <= alpha_orig and !(mode == 2 and pv_node)) return null;
    return mv;
}

inline fn noteStore(ctx: ?*context_mod.SearchContext, outcome: tt.StoreOutcome) void {
    if (ctx) |search_ctx| search_ctx.noteTtStore(outcome);
}

/// The table key of `key` in the storing search's context (context.tableKey);
/// `halfmove_clock` is the clock of the position stored.
inline fn contextKey(ctx: ?*context_mod.SearchContext, key: u64, halfmove_clock: u16) u64 {
    return if (ctx) |search_ctx| key ^ search_ctx.tableKey(halfmove_clock) else key;
}

/// Convert an optional raw static eval to the TT's i16 slot (null -> NONE).
pub inline fn evalToTt(raw: ?types.Score) i16 {
    const value = raw orelse return tt.STATIC_EVAL_NONE;
    return @intCast(std.math.clamp(value, -32700, 32700));
}

pub inline fn storeWindowResult(
    ctx: ?*context_mod.SearchContext,
    table: anytype,
    key: u64,
    depth: i16,
    alpha_orig: types.Score,
    beta: types.Score,
    score: types.Score,
    mv: ?move_mod.Move,
    static_eval: i16,
    was_pv: bool,
    ply: usize,
    halfmove_clock: u16,
) void {
    // The bound is decided in the caller's frame; the stored score is the TT's (score.toTt).
    noteStore(ctx, table.storeWithOutcome(contextKey(ctx, key, halfmove_clock), depth + tt.STORED_DEPTH_OFFSET, score_mod.toTt(score, ply), boundForWindow(alpha_orig, beta, score), mv, static_eval, was_pv));
}

pub inline fn storeLowerBound(
    ctx: ?*context_mod.SearchContext,
    table: anytype,
    key: u64,
    depth: i16,
    beta: types.Score,
    mv: ?move_mod.Move,
    static_eval: i16,
    was_pv: bool,
    ply: usize,
    halfmove_clock: u16,
) void {
    noteStore(ctx, table.storeWithOutcome(contextKey(ctx, key, halfmove_clock), depth + tt.STORED_DEPTH_OFFSET, score_mod.toTt(beta, ply), .lower, mv, static_eval, was_pv));
}

// The tests' keys differ in their tag bits (key bits 32..47, tt.tagOf): the
// table tells positions apart by cluster and tag, not by the whole key.

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

    const key: u64 = 0x1234 << 32;
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    storeLowerBound(null, &table, key, 3, 51, mv, tt.STATIC_EVAL_NONE, false, 5, 0);

    const entry = table.lookup(key).?;
    try std.testing.expectEqual(tt.Bound.lower, entry.bound);
    try std.testing.expectEqual(@as(i32, 51), entry.score);
    try std.testing.expectEqual(mv, tt.moveFromEntry(entry).?);
}

test "storeWindowResult stores the searched score with the matching bound" {
    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const exact_key: u64 = 0x2000 << 32;
    const upper_key: u64 = 0x2001 << 32;
    const lower_key: u64 = 0x2002 << 32;

    storeWindowResult(null, &table, exact_key, 4, 20, 40, 30, null, tt.STATIC_EVAL_NONE, true, 3, 0);
    storeWindowResult(null, &table, upper_key, 4, 20, 40, 10, null, tt.STATIC_EVAL_NONE, false, 3, 0);
    storeWindowResult(null, &table, lower_key, 4, 20, 40, 45, null, tt.STATIC_EVAL_NONE, false, 3, 0);

    try std.testing.expectEqual(tt.Bound.exact, table.lookup(exact_key).?.bound);
    try std.testing.expectEqual(@as(i32, 30), table.lookup(exact_key).?.score);
    try std.testing.expect(table.lookup(exact_key).?.was_pv);
    try std.testing.expectEqual(tt.Bound.upper, table.lookup(upper_key).?.bound);
    try std.testing.expectEqual(@as(i32, 10), table.lookup(upper_key).?.score);
    try std.testing.expectEqual(tt.Bound.lower, table.lookup(lower_key).?.bound);
    try std.testing.expectEqual(@as(i32, 45), table.lookup(lower_key).?.score);
}

test "a fail low's move is stored unless the switch says otherwise" {
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    inline for (.{ false, true }) |pv_node| {
        // Off: every result keeps its move.
        try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(0, pv_node, 20, 20, mv));
        try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(0, pv_node, 20, -5, mv));
        // 1: exactly the results boundForWindow calls an upper bound lose it.
        try std.testing.expectEqual(@as(?move_mod.Move, null), windowResultMove(1, pv_node, 20, 20, mv));
        try std.testing.expectEqual(@as(?move_mod.Move, null), windowResultMove(1, pv_node, 20, -5, mv));
        // A result above alpha keeps it in every mode.
        inline for (.{ 1, 2 }) |mode| {
            try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(mode, pv_node, 20, 21, mv));
            try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(mode, pv_node, 20, 400, mv));
        }
    }
    // 2: the rule of 1 at non-PV nodes; a PV node's fail low keeps its move.
    try std.testing.expectEqual(@as(?move_mod.Move, null), windowResultMove(2, false, 20, 20, mv));
    try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(2, true, 20, 20, mv));
    try std.testing.expectEqual(@as(?move_mod.Move, mv), windowResultMove(2, true, 20, -5, mv));
    // The tunable's default is the release flavour's rule.
    try std.testing.expectEqual(FAIL_LOW_NO_MOVE_DEFAULT, (tunables.Tunables{}).fail_low_no_move);
}
