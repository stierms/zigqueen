//! Runtime-tunable search parameters (SPSA scaffold).
//!
//! These default to the shipped values, so the engine plays IDENTICALLY out of
//! the box (verified by an exact-output bench signature) -- they only diverge
//! when set via `setoption`, and only -Dtunables builds expose them as UCI
//! options. This exists so an external SPSA tuning driver
//! can perturb the search calibration without recompiling. Once a campaign
//! finds a better point, the winning values are baked back as the defaults
//! here and the engine ships with them (no hot-path cost beyond a cached
//! global read).
//!
//! Single-threaded only (Threads=1), so a process-global `active` is safe.

const std = @import("std");
const types = @import("../core/types.zig");

pub const Tunables = struct {
    // Pruning margins (centipawns); defaults = the shipped calibration.
    null_static_margin: types.Score = 10,
    rfp_margin_per_ply: types.Score = 30,
    rfp_non_improving_bonus: types.Score = 28,
    quiet_futility_base: types.Score = 96,
    quiet_futility_per_ply: types.Score = 94,
    quiet_futility_non_improving_bonus: types.Score = 64,
    bad_capture_base: types.Score = 119,
    bad_capture_per_ply: types.Score = 140,
    bad_capture_non_improving_bonus: types.Score = 37,
    razor_base: types.Score = 5,
    razor_per_ply: types.Score = 80,
    // Late-move pruning.
    lmp_base: types.Score = 6, // late-move-prune onset base (threshold = lmp_base + d*d)

    // Mid-tree forward-pruning depths/margins.
    rfp_max_depth: types.Score = 6, // reverse-futility extends to this depth
    rfp_deep_margin_per_ply: types.Score = 75, // per-ply margin in the deepened RFP range (depths 4-6)
    quiet_futility_max_depth: types.Score = 4, // quiet futility extends to this depth
    history_prune_max_depth: types.Score = 6, // history-prune late quiets up to this depth
    history_prune_margin_per_ply: types.Score = -2048, // history threshold per ply (negative)
    see_quiet_max_depth: types.Score = 7, // SEE-prune late quiets up to this depth
    see_quiet_margin_per_ply: types.Score = -50, // SEE-quiet margin per ply (negative)

    // LMR shape in fixed-point centi-units (0.50 / 2.28).
    lmr_base_100: types.Score = @import("reductions.zig").LMR_BASE_100_DEFAULT,
    lmr_divisor_100: types.Score = @import("reductions.zig").LMR_DIVISOR_100_DEFAULT,
};

/// The live parameters read by the search. Mutated only by UCI `setoption`.
pub var active: Tunables = .{};

pub const Spec = struct {
    uci_name: []const u8,
    field: []const u8,
    default: types.Score,
    min: types.Score,
    max: types.Score,
};

/// UCI option metadata, driving both the option advertisement and `setoption`
/// dispatch. `default` mirrors the struct defaults above (kept in sync by a test).
pub const specs = [_]Spec{
    .{ .uci_name = "NullStaticMargin", .field = "null_static_margin", .default = 10, .min = 0, .max = 400 },
    .{ .uci_name = "RfpMarginPerPly", .field = "rfp_margin_per_ply", .default = 30, .min = 10, .max = 300 },
    .{ .uci_name = "RfpNonImprovingBonus", .field = "rfp_non_improving_bonus", .default = 28, .min = 0, .max = 300 },
    .{ .uci_name = "QuietFutilityBase", .field = "quiet_futility_base", .default = 96, .min = 0, .max = 500 },
    .{ .uci_name = "QuietFutilityPerPly", .field = "quiet_futility_per_ply", .default = 94, .min = 10, .max = 500 },
    .{ .uci_name = "QuietFutilityNonImprovingBonus", .field = "quiet_futility_non_improving_bonus", .default = 64, .min = 0, .max = 300 },
    .{ .uci_name = "BadCaptureBase", .field = "bad_capture_base", .default = 119, .min = 0, .max = 500 },
    .{ .uci_name = "BadCapturePerPly", .field = "bad_capture_per_ply", .default = 140, .min = 10, .max = 500 },
    .{ .uci_name = "BadCaptureNonImprovingBonus", .field = "bad_capture_non_improving_bonus", .default = 37, .min = 0, .max = 300 },
    .{ .uci_name = "RazorBase", .field = "razor_base", .default = 5, .min = 0, .max = 500 },
    .{ .uci_name = "RazorPerPly", .field = "razor_per_ply", .default = 80, .min = 10, .max = 500 },
    .{ .uci_name = "LmpBase", .field = "lmp_base", .default = 6, .min = 0, .max = 12 },
    // Mid-tree forward-pruning depths/margins.
    .{ .uci_name = "RfpMaxDepth", .field = "rfp_max_depth", .default = 6, .min = 3, .max = 10 },
    .{ .uci_name = "RfpDeepMarginPerPly", .field = "rfp_deep_margin_per_ply", .default = 75, .min = 30, .max = 160 },
    .{ .uci_name = "QuietFutilityMaxDepth", .field = "quiet_futility_max_depth", .default = 4, .min = 1, .max = 8 },
    .{ .uci_name = "HistoryPruneMaxDepth", .field = "history_prune_max_depth", .default = 6, .min = 2, .max = 10 },
    .{ .uci_name = "HistoryPruneMarginPerPly", .field = "history_prune_margin_per_ply", .default = -2048, .min = -8192, .max = -256 },
    .{ .uci_name = "SeeQuietMaxDepth", .field = "see_quiet_max_depth", .default = 7, .min = 3, .max = 12 },
    .{ .uci_name = "SeeQuietMarginPerPly", .field = "see_quiet_margin_per_ply", .default = -50, .min = -200, .max = -10 },
    // LMR shape (centi-units; rebuilds the reduction table on set).
    .{ .uci_name = "LmrBase100", .field = "lmr_base_100", .default = 50, .min = 0, .max = 150 },
    .{ .uci_name = "LmrDivisor100", .field = "lmr_divisor_100", .default = 228, .min = 120, .max = 400 },
};

/// Set a tunable by its UCI name (clamped to [min,max]). Returns true when the
/// name matched a tunable. Out-of-range values clamp rather than error, so an
/// SPSA driver never stalls on a boundary perturbation.
pub fn set(uci_name: []const u8, value: types.Score) bool {
    inline for (specs) |s| {
        if (std.mem.eql(u8, uci_name, s.uci_name)) {
            @field(active, s.field) = std.math.clamp(value, s.min, s.max);
            // The LMR shape lives in a precomputed table: rebuild it whenever
            // either shape knob changes (cheap, never on the search hot path).
            if (comptime std.mem.eql(u8, s.field, "lmr_base_100") or std.mem.eql(u8, s.field, "lmr_divisor_100")) {
                @import("reductions.zig").applyLmrShape(active.lmr_base_100, active.lmr_divisor_100);
            }
            return true;
        }
    }
    return false;
}

/// Reset all tunables to their shipped defaults (used by tests).
pub fn reset() void {
    active = .{};
    @import("reductions.zig").applyLmrShape(active.lmr_base_100, active.lmr_divisor_100);
}

test "specs defaults match the struct defaults (manifest stays in sync)" {
    const defaults = Tunables{};
    inline for (specs) |s| {
        try std.testing.expectEqual(@field(defaults, s.field), s.default);
    }
}

test "set clamps and matches by uci name" {
    reset();
    defer reset();
    try std.testing.expect(set("RazorBase", 200));
    try std.testing.expectEqual(@as(types.Score, 200), active.razor_base);
    try std.testing.expect(set("RazorBase", 99999)); // clamps to max
    try std.testing.expectEqual(@as(types.Score, 500), active.razor_base);
    try std.testing.expect(set("SeeQuietMarginPerPly", -500)); // clamps to min
    try std.testing.expectEqual(@as(types.Score, -200), active.see_quiet_margin_per_ply);
    try std.testing.expect(!set("NoSuchOption", 1));
}
