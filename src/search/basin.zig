//! Basin-hop search-shaping configuration, rebased from the parked
//! `basin-hop` branch's `UNIT_PERCENT=25` state.
//!
//! Provenance: the fractional LMR formula, the pruning families below and
//! their default constants were taken from Stormphrax 8.0.0's published
//! parameter set (Ciekce, GPL-3.0; https://github.com/Ciekce/Stormphrax),
//! with eval-denominated margins scaled by `UNIT_PERCENT` and dimensionless
//! terms taken as-is. The implementation, its integration, guards and
//! score-unit calibration are zigqueen's; no source text was transcribed.
//! See docs/PROVENANCE.md, section 1.
//!
//! Score units: `u(x) = x * 25 / 100` is the parked branch's empirically chosen
//! mapping from the published internal-margin constants into zigqueen search
//! score units. The active ZQB9 net is keyed to NNUE scale 48. That scale is a
//! calibration of a different net-native output distribution, not a linear cp
//! conversion from the older net family's scale 66, so this substrate re-test
//! deliberately preserves the requested UNIT_PERCENT=25 configuration rather
//! than introducing an unmeasured 48/66 margin experiment.

const std = @import("std");

pub const ENABLED = true;

pub const UNIT_PERCENT: i32 = 25;
inline fn u(published_internal: i32) i32 {
    return @divTrunc(published_internal * UNIT_PERCENT, 100);
}

// Dual 1024-scale fractional LMR tables:
//   quiet = 1024 * (0.78 + ln(depth) * ln(move) / 2.36)
//   noisy = 1024 * (-0.10 + ln(depth) * ln(move) / 2.49)
const LMR_MAX_D: usize = 64;
const LMR_MAX_M: usize = 64;
const lmr_table: [2][LMR_MAX_D][LMR_MAX_M]i32 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [2][LMR_MAX_D][LMR_MAX_M]i32 = undefined;
    const cfg = [2][2]f64{ .{ 0.78, 2.36 }, .{ -0.10, 2.49 } };
    for (0..2) |n| {
        for (0..LMR_MAX_D) |d| {
            for (0..LMR_MAX_M) |m| {
                if (d < 1 or m < 1) {
                    table[n][d][m] = 0;
                    continue;
                }
                const ln_d = @log(@as(f64, @floatFromInt(d)));
                const ln_m = @log(@as(f64, @floatFromInt(m)));
                table[n][d][m] = @intFromFloat(1024.0 * (cfg[n][0] + ln_d * ln_m / cfg[n][1]));
            }
        }
    }
    break :blk table;
};

pub const LmrInputs = struct {
    depth: u16,
    move_number: usize,
    is_noisy: bool,
    pv_node: bool,
    cut_node: bool,
    improving: bool,
    gives_check: bool,
    tt_move_is_noisy: bool,
    alpha_raises: i32,
    history: i32,
    ttpv: bool,
    ttpv_fail_low: bool,
    complexity: i32,
};

/// Fractional reduction in 1/1024 ply units. The caller converts it to the
/// reduced scout depth and applies the PV/TT-PV brakes.
pub fn lmrReduction1024(in: LmrInputs) i32 {
    const d = @min(@as(usize, in.depth), LMR_MAX_D - 1);
    const m = @min(in.move_number, LMR_MAX_M - 1);
    var r: i32 = lmr_table[@intFromBool(in.is_noisy)][d][m] - 37;
    if (!in.pv_node) r += 1069;
    r -= @divTrunc(in.history * @as(i32, if (in.is_noisy) 423 else 447), 4096);
    if (in.improving) r -= 1242;
    if (in.gives_check) r -= 852;
    if (in.cut_node) r += 1945;
    if (in.tt_move_is_noisy) r += 1081;
    r += in.alpha_raises * 597;
    r -= @as(i32, @intCast(m)) * 42;
    if (in.ttpv) r -= 1146;
    if (in.ttpv_fail_low) r += 1054;
    // The parked UNIT_PERCENT=25 calibration maps the published corrhist term
    // to 15 fractional-reduction units per zigqueen correction-score unit.
    r -= in.complexity * 15;
    return r;
}

/// Effective LMR depth used by per-move pruning decisions.
pub fn lmrDepth(depth: u16, move_number: usize, ttpv: bool) i32 {
    const d = @min(@as(usize, depth), LMR_MAX_D - 1);
    const m = @min(move_number, LMR_MAX_M - 1);
    const base = lmr_table[0][d][m] + @as(i32, if (ttpv) 726 else 0);
    return @max(@as(i32, depth) - @divTrunc(base, 1024), 0);
}

// Null-move pruning: decreasing margin and R = 6 + depth / 5.
pub fn nmpMargin(depth: u16, improving: bool) i32 {
    const margin = u(213 - @divTrunc(@as(i32, depth) * 1281, 128) - @as(i32, if (improving) 41 else 0));
    return @max(margin, 0);
}

pub fn nmpReduction(depth: u16) u16 {
    return @intCast(@min(6 + depth / 5, depth));
}

// Late-move pruning.
pub fn lmpThreshold(depth: u16, improving: bool) usize {
    const d: usize = @min(depth, 15);
    const divisor: usize = if (improving) 1 else 2;
    return (3 + d * d) / divisor;
}

// Reverse futility pruning.
pub fn rfpMargin(depth: u16, improving: bool) i32 {
    const d: i32 = depth;
    return u(d * 85 + d * d * 7 - @as(i32, if (improving) 75 else 0));
}
pub const RFP_MAX_DEPTH: u16 = 12;

// Quiet-history pruning.
pub fn historyPruneThreshold(depth: u16) i32 {
    return -2242 * @as(i32, depth) - 1315;
}
pub const HISTORY_PRUNE_LMRDEPTH_MAX: i32 = 5;

// Quiet futility pruning.
pub fn futilityMargin(depth: u16) i32 {
    return u(274 + 68 * @as(i32, depth));
}
pub const FUTILITY_LMRDEPTH_MAX: i32 = 8;
pub const FUTILITY_ALPHA_CAP: i32 = 500;

// SEE pruning. Capture-history is intentionally absent because the base has no
// accepted capture-history table.
pub const SEE_PRUNE_QUIETS = true;
pub fn seePruneThresholdQuiet(lmr_depth: i32) i32 {
    return -20 * lmr_depth * lmr_depth;
}
pub fn seePruneThresholdNoisy(depth: u16) i32 {
    return -111 * @as(i32, depth);
}

// Linear history bonus/malus shape.
pub fn historyBonus(depth: u16) i32 {
    return std.math.clamp(@as(i32, depth) * 277 - 575, 0, 2723);
}
pub fn historyMalus(depth: u16) i32 {
    return std.math.clamp(@as(i32, depth) * 307 - 245, 0, 1027);
}

pub const ASPIRATION_INITIAL_CP: i32 = 8;

pub fn deeperThreshold(new_depth: u16) i32 {
    return u(44 + 4 * @as(i32, new_depth));
}

test "basin tables and formulas produce sane values" {
    try std.testing.expect(lmr_table[0][20][20] > lmr_table[0][6][6]);
    try std.testing.expect(lmr_table[1][20][20] < lmr_table[0][20][20]);
    try std.testing.expect(nmpMargin(4, false) > nmpMargin(10, false));
    try std.testing.expectEqual(@as(i32, 0), nmpMargin(22, false));
    try std.testing.expect(lmpThreshold(6, false) < lmpThreshold(6, true));
    try std.testing.expect(rfpMargin(12, true) > rfpMargin(6, true) * 2);
    try std.testing.expectEqual(@divTrunc(@as(i32, 687) * UNIT_PERCENT, 100), rfpMargin(6, true));
    try std.testing.expectEqual(@as(i32, 2723), historyBonus(14));
}
