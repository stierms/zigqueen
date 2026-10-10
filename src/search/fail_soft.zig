//! Fail-soft cutoff returns (A3b, 2026-10-03).
//!
//! The search used to return the window bound itself at its eval-based and
//! null-move cutoffs (reverse futility, quiescence stand-pat, null move). A
//! score that is the bound says where the window was, not what the position is
//! worth: 95% of correction-history update events sat exactly on the bound (A3
//! diagnosis). With fail-soft returns a cutoff reports how far beyond beta it
//! is, and TT entries carry those values. Quiescence fail lows report below
//! alpha only beyond a quiet-move margin over the stand-pat (qsearch.zig), and
//! the LMR re-search depth rule keeps clamped inputs (root.zig).
//!
//! `-Dfail-soft=false` returns the bounds exactly as before (node-identical).
const build_options = @import("build_options");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

pub const ENABLED: bool = build_options.fail_soft;

/// Value of an eval-based fail high (reverse futility, stand-pat): beta moved
/// toward the eval by `softness`/16 of the gap. A fail-hard build, an eval not
/// above beta or a decisive result returns beta.
pub inline fn evalCutoff(beta: types.Score, eval: types.Score, softness: i32) types.Score {
    if (comptime !ENABLED) return beta;
    if (eval <= beta) return beta;
    const value = beta + @divTrunc((eval - beta) * softness, 16);
    return if (score_mod.isDecisive(value)) beta else value;
}

/// Value of a searched fail high whose score proves only "at least beta" for
/// the real position (null move): the score itself unless it is decisive.
pub inline fn nullCutoff(beta: types.Score, score: types.Score) types.Score {
    if (comptime !ENABLED) return beta;
    if (score_mod.isDecisive(score)) return beta;
    return @max(score, beta);
}

test "eval cutoffs blend toward the eval and never return a decisive score" {
    const std = @import("std");
    if (!ENABLED) {
        try std.testing.expectEqual(@as(types.Score, 10), evalCutoff(10, 90, 8));
        return;
    }
    try std.testing.expectEqual(@as(types.Score, 50), evalCutoff(10, 90, 8));
    try std.testing.expectEqual(@as(types.Score, 10), evalCutoff(10, 90, 0));
    try std.testing.expectEqual(@as(types.Score, 90), evalCutoff(10, 90, 16));
    try std.testing.expectEqual(@as(types.Score, 10), evalCutoff(10, 5, 8));
    try std.testing.expectEqual(@as(types.Score, 10), evalCutoff(10, score_mod.MATE_SCORE, 16));
    try std.testing.expectEqual(@as(types.Score, 40), nullCutoff(10, 40));
    try std.testing.expectEqual(@as(types.Score, 10), nullCutoff(10, score_mod.MATE_SCORE - 3));
}
