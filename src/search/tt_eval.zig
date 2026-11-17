//! The table's searched score as a node's value for the static decisions.
//!
//! A table entry that does not cut the node (too shallow, a PV node, a bound
//! on the wrong side of the window) still holds the result of a search of
//! this position. The static decisions (reverse futility, razoring, the
//! null-move gates, quiet futility, the check-extension test, ProbCut's
//! required gain, the depth-1 bad-capture rule, quiescence's stand-pat) read the unsearched static value; where the entry's bound
//! contradicts that value, the entry knows more: an exact score, a lower
//! bound above the static value, an upper bound below it.
//!
//! `refined` is the value those decisions read where their switch is on
//! (`enabled`, one tunable per consumer; on by default for reverse futility,
//! razoring, the null-move gates, quiet futility and ProbCut's gap, off for
//! the check-extension test, the bad-capture rule and the stand-pat, where
//! the release flavour folds the site back to the static value). The stack's static
//! eval, `improving`, the correction's size and its learning keep the static
//! value: they compare evals with evals.

const std = @import("std");
const score_mod = @import("score.zig");
const tt = @import("tt.zig");
const tunables = @import("tunables.zig");
const types = @import("../core/types.zig");

/// The decisions that can read the table's score, each with its own switch
/// (tunables.tt_eval_<name>).
pub const Consumer = enum { rfp, razor, null_move, futility, check_ext, probcut, bad_capture, stand_pat };

pub inline fn enabled(comptime consumer: Consumer) bool {
    return tunables.knob("tt_eval_" ++ @tagName(consumer)) != 0;
}

/// Whether any main-search consumer is on (the value is computed once per node).
pub inline fn anyMain() bool {
    return enabled(.rfp) or enabled(.razor) or enabled(.null_move) or enabled(.futility) or enabled(.check_ext) or enabled(.probcut) or enabled(.bad_capture);
}

/// Reverse futility's cut returns its fail-soft value from the table's score
/// too (tunables.tt_eval_rfp_return); otherwise from the static value.
pub inline fn rfpReturn() bool {
    return tunables.knob("tt_eval_rfp_return") != 0;
}

/// The node's value for a static decision: the entry's score where its bound
/// says the static value is on the wrong side of it, the static value
/// otherwise. `trusted`: the node may read a table score at all (the rule-50
/// gate; no excluded move). Decisive scores are distances, not values, and
/// are never taken; entries shallower than tunables.tt_eval_min_depth are
/// not taken either (quiescence entries are depth 0 and -1).
pub inline fn refined(entry: ?*const tt.Entry, static_value: types.Score, trusted: bool) types.Score {
    return refinedWith(entry, static_value, trusted, @intCast(tunables.knob("tt_eval_min_depth")));
}

pub inline fn refinedWith(entry: ?*const tt.Entry, static_value: types.Score, trusted: bool, min_depth: i16) types.Score {
    const e = entry orelse return static_value;
    if (!trusted) return static_value;
    if (score_mod.isDecisive(e.score)) return static_value;
    if (e.depth < min_depth) return static_value;
    return switch (e.bound) {
        .exact => e.score,
        .lower => @max(static_value, e.score),
        .upper => @min(static_value, e.score),
    };
}

test "the table's score replaces the static value only where its bound contradicts it" {
    var entry = tt.Entry{};
    entry.depth = 3;
    entry.score = 80;
    entry.bound = .lower;
    // A lower bound above the static value is the better statement; below it, it says nothing new.
    try std.testing.expectEqual(@as(types.Score, 80), refinedWith(&entry, 20, true, -1));
    try std.testing.expectEqual(@as(types.Score, 120), refinedWith(&entry, 120, true, -1));
    entry.bound = .upper;
    try std.testing.expectEqual(@as(types.Score, 80), refinedWith(&entry, 120, true, -1));
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(&entry, 20, true, -1));
    entry.bound = .exact;
    try std.testing.expectEqual(@as(types.Score, 80), refinedWith(&entry, 120, true, -1));
    try std.testing.expectEqual(@as(types.Score, 80), refinedWith(&entry, 20, true, -1));
    // No entry, an untrusted node, a decisive score, an entry below the depth floor: the static value.
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(null, 20, true, -1));
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(&entry, 20, false, -1));
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(&entry, 20, true, 4));
    try std.testing.expectEqual(@as(types.Score, 80), refinedWith(&entry, 20, true, 3));
    entry.score = score_mod.MATE_SCORE - 9;
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(&entry, 20, true, -1));
    entry.score = -score_mod.TB_WIN_SCORE + 4;
    entry.bound = .upper;
    try std.testing.expectEqual(@as(types.Score, 20), refinedWith(&entry, 20, true, -1));
    // The defaults: reverse futility, razoring, the null-move gates, quiet
    // futility and ProbCut's gap read the table's score, and reverse
    // futility's cut returns from it; the check-extension test, the
    // bad-capture rule and quiescence's stand-pat stay on the static value.
    // The release flavour has exactly these compiled in; in the tuning
    // flavour `enabled` follows the options, so only the defaults are pinned.
    const defaults = tunables.Tunables{};
    inline for (std.meta.fields(Consumer)) |field| {
        const consumer = @field(Consumer, field.name);
        const expected = switch (consumer) {
            .rfp, .razor, .null_move, .futility, .probcut => true,
            .check_ext, .bad_capture, .stand_pat => false,
        };
        try std.testing.expectEqual(expected, @field(defaults, "tt_eval_" ++ field.name) != 0);
        if (!@import("build_options").tuning) try std.testing.expectEqual(expected, enabled(consumer));
    }
    try std.testing.expectEqual(@as(types.Score, 1), defaults.tt_eval_rfp_return);
    try std.testing.expectEqual(@as(types.Score, -1), defaults.tt_eval_min_depth);
}
