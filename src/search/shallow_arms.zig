//! Shallow-hole mechanisms from the September 2026 screen.
//!
//! LDSE is enabled in the release flavour; the other arms resolve to their
//! pre-screen constants. Parameterised helpers keep the arithmetic and gates
//! independently testable without making the unit tests depend on a particular
//! build flavour.

const std = @import("std");
const build_options = @import("build_options");
const tunables = @import("tunables.zig");
const types = @import("../core/types.zig");

pub inline fn setParentLmrReduction(entry: anytype, reduction: u16) void {
    if (comptime build_options.tuning) {
        entry.parent_lmr_reduction = reduction;
    }
}

pub inline fn parentLmrReduction(entry: anytype) u16 {
    if (comptime build_options.tuning) return entry.parent_lmr_reduction;
    return 0;
}

pub inline fn hindsightEnabled() bool {
    if (comptime build_options.tuning) return tunables.active.hindsight_repair != 0;
    return false;
}

pub inline fn hindsightMargin() types.Score {
    if (comptime build_options.tuning) return tunables.active.hindsight_margin;
    return tunables.HINDSIGHT_MARGIN_DEFAULT;
}

pub fn hindsightAdjustmentWith(enabled: bool, depth: u16, reduction: u16, eval_sum: i32, margin: i32) i8 {
    if (!enabled) return 0;
    if (reduction >= 3 and eval_sum <= 0) return 1;
    if (depth >= 2 and reduction >= 2 and eval_sum >= margin) return -1;
    return 0;
}

pub inline fn evalPolicyEnabled() bool {
    if (comptime build_options.tuning) return tunables.active.eval_policy_history != 0;
    return false;
}

pub inline fn evalPolicyBonus(gain: i32) i32 {
    if (comptime build_options.tuning) {
        return evalPolicyBonusWith(gain, tunables.active.eval_policy_scale, tunables.active.eval_policy_clamp, tunables.active.eval_policy_offset);
    }
    return 0;
}

pub fn evalPolicyBonusWith(gain: i32, scale: i32, clamp: i32, offset: i32) i32 {
    const scaled: i64 = @as(i64, gain) * @as(i64, scale);
    const limit: i64 = @max(clamp, 0);
    const bounded = std.math.clamp(scaled, -limit, limit);
    return @intCast(bounded + offset);
}

pub inline fn allowMainTtCutoff(entry_score: types.Score, alpha: types.Score, pv_node: bool, cut_node: bool, halfmove_clock: u16) bool {
    if (comptime build_options.tuning) {
        return allowMainTtCutoffWith(
            entry_score,
            alpha,
            pv_node,
            cut_node,
            halfmove_clock,
            tunables.active.tt_cutoff_node_role != 0,
            @intCast(tunables.active.tt_cutoff_halfmove_max),
        );
    }
    return true;
}

pub fn allowMainTtCutoffWith(
    entry_score: types.Score,
    alpha: types.Score,
    pv_node: bool,
    cut_node: bool,
    halfmove_clock: u16,
    node_role_enabled: bool,
    halfmove_max: u16,
) bool {
    if (halfmove_max < 100 and halfmove_clock >= halfmove_max) return false;
    if (!node_role_enabled) return true;
    return !pv_node and (entry_score <= alpha or cut_node);
}

pub inline fn singularMinDepth() u16 {
    if (comptime build_options.tuning) return @intCast(tunables.active.singular_min_depth);
    return 6;
}

pub inline fn singularMaxDepth() u16 {
    if (comptime build_options.tuning) return @intCast(tunables.active.singular_max_depth);
    return 8;
}

pub inline fn singularTtDepthSlack() i16 {
    if (comptime build_options.tuning) return @intCast(tunables.active.singular_tt_depth_slack);
    return 0;
}

pub inline fn singularWeakGateEnabled() bool {
    if (comptime build_options.tuning) return tunables.active.singular_weak_gate != 0;
    return true;
}

pub inline fn singularNegativeExtension(entry_score: types.Score, beta: types.Score, cut_node: bool) i16 {
    if (comptime build_options.tuning) {
        return singularNegativeExtensionWith(tunables.active.singular_neg_ext != 0, entry_score, beta, cut_node);
    }
    return 0;
}

pub fn singularNegativeExtensionWith(enabled: bool, entry_score: types.Score, beta: types.Score, cut_node: bool) i16 {
    if (!enabled) return 0;
    if (entry_score >= beta) return -3;
    if (cut_node) return -2;
    return 0;
}

pub fn childDepth(search_depth: u16, extension: i16) u16 {
    const adjusted = @as(i32, search_depth) - 1 + @as(i32, extension);
    const minimum: i32 = if (extension < 0) 1 else 0;
    return @intCast(std.math.clamp(adjusted, minimum, std.math.maxInt(u16)));
}

pub inline fn ldseExtension(
    singular_test_applied: bool,
    search_depth: u16,
    in_check: bool,
    static_eval: types.Score,
    alpha: types.Score,
    lower_bound: bool,
    pv_node: bool,
    tt_depth: i16,
) i16 {
    if (comptime build_options.tuning) {
        return ldseExtensionWith(
            tunables.active.ldse != 0,
            singular_test_applied,
            search_depth,
            in_check,
            static_eval,
            alpha,
            lower_bound,
            pv_node,
            tt_depth,
            tunables.active.ldse_margin,
            tunables.active.ldse_double_margin,
        );
    }
    return ldseExtensionWith(
        true,
        singular_test_applied,
        search_depth,
        in_check,
        static_eval,
        alpha,
        lower_bound,
        pv_node,
        tt_depth,
        tunables.LDSE_MARGIN_DEFAULT,
        tunables.LDSE_DOUBLE_MARGIN_DEFAULT,
    );
}

pub fn ldseExtensionWith(
    enabled: bool,
    singular_test_applied: bool,
    search_depth: u16,
    in_check: bool,
    static_eval: types.Score,
    alpha: types.Score,
    lower_bound: bool,
    pv_node: bool,
    tt_depth: i16,
    margin: i32,
    double_margin: i32,
) i16 {
    if (!enabled or singular_test_applied or search_depth > 7 or in_check or !lower_bound) return 0;
    if (@as(i32, static_eval) > @as(i32, alpha) - margin) return 0;
    var extension: i16 = 1;
    const double_required_depth: i16 = @intCast(search_depth -| 3);
    if (!pv_node and tt_depth >= double_required_depth and @as(i32, static_eval) <= @as(i32, alpha) - double_margin) {
        extension += 1;
    }
    return extension;
}

pub inline fn qsearchTtQuietEnabled() bool {
    if (comptime build_options.tuning) return tunables.active.qsearch_tt_quiet != 0;
    return false;
}

pub fn qsearchTtQuietAllowedWith(enabled: bool, pv_node: bool, in_check: bool, upper_bound: bool, quiet: bool, legal: bool) bool {
    return enabled and !pv_node and !in_check and !upper_bound and quiet and legal;
}

pub inline fn checkExtensionEnabled() bool {
    if (comptime build_options.tuning) return tunables.active.check_extension != 0;
    return true;
}

pub fn checkExtensionAllowedWith(enabled: bool, gives_check: bool, checker_desperate: bool) bool {
    return enabled and gives_check and checker_desperate;
}

test "HindsightRepair defaults to identity and repairs both depth directions" {
    try std.testing.expectEqual(@as(i8, 0), hindsightAdjustmentWith(false, 5, 3, -1, tunables.HINDSIGHT_MARGIN_DEFAULT));
    try std.testing.expectEqual(@as(i8, 1), hindsightAdjustmentWith(true, 5, 3, 0, tunables.HINDSIGHT_MARGIN_DEFAULT));
    try std.testing.expectEqual(@as(i8, -1), hindsightAdjustmentWith(true, 5, 2, tunables.HINDSIGHT_MARGIN_DEFAULT, tunables.HINDSIGHT_MARGIN_DEFAULT));
}

test "EvalPolicyHistory defaults off and clamps mapped gain before its offset" {
    try std.testing.expect(!evalPolicyEnabled() or build_options.tuning);
    try std.testing.expectEqual(@as(i32, 2344), evalPolicyBonusWith(100, 40, 1841, 503));
    try std.testing.expectEqual(@as(i32, -1338), evalPolicyBonusWith(-100, 40, 1841, 503));
}

test "TtCutoffNodeRole defaults to trust and rejects all-node fail-high plus late-halfmove cutoffs" {
    try std.testing.expect(allowMainTtCutoffWith(30, 20, false, false, 40, false, 100));
    try std.testing.expect(!allowMainTtCutoffWith(30, 20, false, false, 40, true, 100));
    try std.testing.expect(allowMainTtCutoffWith(30, 20, false, true, 40, true, 100));
    try std.testing.expect(!allowMainTtCutoffWith(10, 20, false, false, 90, true, 90));
    try std.testing.expect(allowMainTtCutoffWith(10, 20, false, false, 100, true, 100));
}

test "SingularNegExt defaults to identity and clamps a negative child depth" {
    try std.testing.expectEqual(@as(i16, 0), singularNegativeExtensionWith(false, 80, 50, true));
    try std.testing.expectEqual(@as(i16, -3), singularNegativeExtensionWith(true, 80, 50, true));
    try std.testing.expectEqual(@as(i16, -2), singularNegativeExtensionWith(true, 40, 50, true));
    try std.testing.expectEqual(@as(u16, 1), childDepth(2, -3));
}

test "Ldse defaults on, can restore identity, and doubles only for the strong non-PV lower-bound case" {
    const strong_score = @as(types.Score, 100) - @max(tunables.LDSE_MARGIN_DEFAULT, tunables.LDSE_DOUBLE_MARGIN_DEFAULT) - 1;
    try std.testing.expectEqual(@as(i16, 2), ldseExtension(false, 7, false, strong_score, 100, true, false, 4));
    try std.testing.expectEqual(@as(i16, 0), ldseExtensionWith(false, false, 7, false, 80, 100, true, false, 4, 5, 9));
    try std.testing.expectEqual(@as(i16, 2), ldseExtensionWith(true, false, 7, false, 80, 100, true, false, 4, 5, 9));
    try std.testing.expectEqual(@as(i16, 1), ldseExtensionWith(true, false, 7, false, 94, 100, true, false, 4, 5, 9));
    try std.testing.expectEqual(@as(i16, 0), ldseExtensionWith(true, true, 7, false, 80, 100, true, false, 4, 5, 9));
}

test "QsearchTtQuiet defaults off and requires the exact node move and bound gates" {
    try std.testing.expect(!qsearchTtQuietAllowedWith(false, false, false, false, true, true));
    try std.testing.expect(qsearchTtQuietAllowedWith(true, false, false, false, true, true));
    try std.testing.expect(!qsearchTtQuietAllowedWith(true, false, false, true, true, true));
}

test "CheckExtension defaults on and its tuning switch can disable the policy" {
    try std.testing.expect(checkExtensionAllowedWith(true, true, true));
    try std.testing.expect(!checkExtensionAllowedWith(false, true, true));
}
