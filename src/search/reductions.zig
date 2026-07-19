const std = @import("std");
const move_mod = @import("../core/move.zig");

const MAX_LMR_DEPTH: usize = 64;
const MAX_LMR_MOVES: usize = 64;
// SPSA-tuned values, kept runtime-tunable: the LMR shape is the most
// eval-coupled reduction parameter (a new net changes the eval's error
// distribution the reductions were fit to), so it must stay re-tunable
// without recompiling. Fixed-point centi-units so the SPSA driver perturbs
// integers.
pub const LMR_BASE_100_DEFAULT: i32 = 50; // 0.50 base offset
pub const LMR_DIVISOR_100_DEFAULT: i32 = 228; // 2.28 log-product divisor
const LMR_NON_IMPROVING: i32 = 0; // extra LMR reduction when not improving

// Built at runtime (startup + on setoption) so the default table and any SPSA
// perturbation go through the SAME libm — a comptime-built default could differ
// by an ulp in @log and flip a rounded cell vs the runtime rebuild.
var lmr_table: [MAX_LMR_DEPTH][MAX_LMR_MOVES]u8 = undefined;
var lmr_table_ready = false;

/// (Re)build the LMR table for the given shape (centi-units). Called at engine
/// startup with the defaults and by the tunables layer on setoption. Cheap
/// (64x64 doubles), never on the search hot path.
pub fn applyLmrShape(base_100: i32, divisor_100: i32) void {
    const base = @as(f64, @floatFromInt(base_100)) / 100.0;
    const divisor = @as(f64, @floatFromInt(divisor_100)) / 100.0;
    for (&lmr_table, 0..) |*row, d| {
        for (row, 0..) |*cell, m| {
            if (d <= 1 or m <= 1) {
                cell.* = 0;
                continue;
            }
            const ln_d = @log(@as(f64, @floatFromInt(d)));
            const ln_m = @log(@as(f64, @floatFromInt(m)));
            // Shape: BASE OFFSET + log-product, ROUNDED. An offset-free,
            // truncated formula reduces 1-2 plies less across the mid-tree and
            // inflates the effective branching factor well above SF-class
            // engines.
            const r = base + ln_d * ln_m / divisor;
            if (r <= 0.0) {
                cell.* = 0;
            } else {
                cell.* = @intFromFloat(r + 0.5);
            }
        }
    }
    lmr_table_ready = true;
}

fn ensureLmrTable() void {
    if (!lmr_table_ready) applyLmrShape(LMR_BASE_100_DEFAULT, LMR_DIVISOR_100_DEFAULT);
}

pub fn lateMoveReduction(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    in_check: bool,
    improving: bool,
    cut_node: bool,
    has_tt_move: bool,
    history_score: i32,
    killer_a: ?move_mod.Move,
    killer_b: ?move_mod.Move,
) u16 {
    ensureLmrTable();
    if (depth < 3) return 0;
    if (in_check) return 0;
    if (move_index < 2) return 0;
    if (mv.isPromotion()) return 0;
    if (mv.isCapture()) return 0;
    if (killer_a) |killer| {
        if (killer == mv) return 0;
    }
    if (killer_b) |killer| {
        if (killer == mv) return 0;
    }

    const depth_idx = @min(@as(usize, depth), MAX_LMR_DEPTH - 1);
    const move_idx = @min(move_index, MAX_LMR_MOVES - 1);
    var reduction_signed: i32 = lmr_table[depth_idx][move_idx];
    // No TT move at this node = never resolved by prior search; its late quiets are
    // the least-vetted moves in the tree — reduce them more (TT-quality rung).
    if (!has_tt_move) reduction_signed += 1;
    if (!improving) reduction_signed += LMR_NON_IMPROVING;
    // History-conditioned scaling over the summed (main + continuation) history
    // signal: hot-evidence quiets reduce up to 3 less, cold ones up to 3 more.
    // Conditioning the aggression on move-quality evidence is what lets the base
    // reductions stay large without tactical blind spots.
    const history_shift = std.math.clamp(@divTrunc(history_score, 5461), -3, 3);
    reduction_signed -= history_shift;
    // Deep, late, cold quiets at expected-ALL nodes get one extra reduction.
    if (!cut_node and depth >= 8 and move_index >= 8 and !improving and history_score <= 0 and reduction_signed > 1) {
        reduction_signed += 1;
    }
    if (reduction_signed < 0) return 0;
    var reduction: u16 = @intCast(reduction_signed);
    if (reduction >= depth) reduction = depth - 1;
    return reduction;
}

pub fn nullMoveReduction(depth: u16) u16 {
    // Dynamic R = 4 + depth/6: a moderate depth-scaled dose. More aggressive
    // scaling (e.g. 3 + depth/3) destabilized deep scout trees for this
    // engine's move-ordering quality.
    const r = 4 + depth / 6;
    return @min(r, depth -| 1);
}

test "lmr shape rebuild changes reductions and restores defaults exactly" {
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    ensureLmrTable();
    const default_r = lateMoveReduction(12, 20, q, false, true, false, true, 0, null, null);
    // Flatter divisor -> larger reductions at deep/late cells.
    applyLmrShape(LMR_BASE_100_DEFAULT, 150);
    const aggressive_r = lateMoveReduction(12, 20, q, false, true, false, true, 0, null, null);
    try std.testing.expect(aggressive_r > default_r);
    // Restoring the default shape restores the exact default table values.
    applyLmrShape(LMR_BASE_100_DEFAULT, LMR_DIVISOR_100_DEFAULT);
    try std.testing.expectEqual(default_r, lateMoveReduction(12, 20, q, false, true, false, true, 0, null, null));
}

test "late move reduction stays off for early tactical moves and grows with depth and move index" {
    try std.testing.expectEqual(@as(u16, 0), lateMoveReduction(4, 0, move_mod.Move.init(.e2, .e4, .double_push), false, true, false, true, 0, null, null));
    try std.testing.expectEqual(@as(u16, 0), lateMoveReduction(4, 4, move_mod.Move.init(.e2, .d3, .capture), false, true, false, true, 0, null, null));
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    try std.testing.expect(lateMoveReduction(8, 10, q, false, true, false, true, 0, null, null) >= lateMoveReduction(4, 4, q, false, true, false, true, 0, null, null));
    try std.testing.expect(lateMoveReduction(12, 20, q, false, true, false, true, 0, null, null) >= 2);
}

test "late move reduction respects in-check and killer guards" {
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    try std.testing.expectEqual(@as(u16, 0), lateMoveReduction(8, 10, q, true, true, false, true, 0, null, null));
    try std.testing.expectEqual(@as(u16, 0), lateMoveReduction(8, 10, q, false, true, false, true, 0, q, null));
    try std.testing.expectEqual(@as(u16, 0), lateMoveReduction(8, 10, q, false, true, false, true, 0, null, q));
}

test "late move reduction never reduces less when not improving" {
    // The improving-asymmetry lives in LMR_NON_IMPROVING (currently 0).
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    const improving = lateMoveReduction(8, 10, q, false, true, false, true, 0, null, null);
    const not_improving = lateMoveReduction(8, 10, q, false, false, false, true, 0, null, null);
    try std.testing.expect(not_improving >= improving);
}

test "late move reduction shrinks when quiet history is strongly positive" {
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    const unknown = lateMoveReduction(8, 10, q, false, false, false, true, 0, null, null);
    const hot_quiet = lateMoveReduction(8, 10, q, false, false, false, true, 30_000, null, null);
    try std.testing.expect(hot_quiet < unknown);
}

test "all-node cold-quiet bonus and hot history shape reductions" {
    const q = move_mod.Move.init(.a2, .a3, .quiet);
    const all_node = lateMoveReduction(8, 20, q, false, false, false, true, 0, null, null);
    const cut_node = lateMoveReduction(8, 20, q, false, false, true, true, 0, null, null);
    const positive_history = lateMoveReduction(8, 20, q, false, false, false, true, 20_000, null, null);
    // Deep late cold quiets at ALL-nodes get the +1, so cut nodes never reduce more.
    try std.testing.expect(all_node >= cut_node);
    try std.testing.expect(positive_history < all_node);
}
