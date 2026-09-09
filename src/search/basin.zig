//! Basin-hop search-shaping configuration.
//!
//! Provenance: the fractional LMR formula, the pruning families below and
//! their initial default constants were taken from Stormphrax 8.0.0's published
//! parameter set (Ciekce, GPL-3.0; https://github.com/Ciekce/Stormphrax),
//! with eval-denominated margins scaled by `UNIT_PERCENT` and dimensionless
//! terms taken as-is. The implementation, its integration, guards and
//! score-unit calibration are zigqueen's; no source text was transcribed.
//! In 6.2.0, a local 12-coordinate pruning SPSA retune changed 11 defaults.
//! Remaining inherited values and the original formulas retain that provenance.
//! See docs/PROVENANCE.md, section 1, for the before/after values.
//!
//! Release and tuning builds share Params as the policy source of truth.
//! Release defaults and its LMR table are compile-time constants; tuning uses
//! an engine-owned Config and rebuilds its table only between searches.

const std = @import("std");

pub const ENABLED = true;
pub const defaults: Params = .{};
pub const UNIT_PERCENT: i32 = defaults.unit_percent;
pub const RFP_MAX_DEPTH: u16 = @intCast(defaults.rfp_max_depth);
pub const HISTORY_PRUNE_LMRDEPTH_MAX: i32 = defaults.history_prune_lmr_depth_max;
pub const FUTILITY_LMRDEPTH_MAX: i32 = defaults.futility_lmr_depth_max;
pub const FUTILITY_ALPHA_CAP: i32 = defaults.futility_alpha_cap;
pub const SEE_PRUNE_QUIETS = true;
pub const ASPIRATION_INITIAL_CP: i32 = 8;

const LMR_MAX_D: usize = 64;
const LMR_MAX_M: usize = 64;

pub const Params = struct {
    // Decimal LMR coefficients in integer 1/1000 units.
    lmr_quiet_base_1000: i32 = 780,
    lmr_quiet_divisor_1000: i32 = 2360,
    lmr_noisy_base_1000: i32 = -100,
    lmr_noisy_divisor_1000: i32 = 2490,

    // Fractional reduction adjustments in 1/1024-ply units.
    lmr_base_adjust: i32 = -37,
    lmr_non_pv_adjust: i32 = 1069,
    lmr_noisy_history_coeff: i32 = 423,
    lmr_quiet_history_coeff: i32 = 447,
    lmr_improving_adjust: i32 = -1242,
    lmr_check_adjust: i32 = -852,
    lmr_cut_adjust: i32 = 1945,
    lmr_noisy_tt_move_adjust: i32 = 1081,
    lmr_alpha_raise_adjust: i32 = 597,
    lmr_move_number_adjust: i32 = -42,
    lmr_tt_pv_adjust: i32 = -1146,
    lmr_tt_pv_fail_low_adjust: i32 = 1054,
    lmr_depth_tt_pv_offset: i32 = 726,

    // Published-margin units; scaled once by unit_percent at use.
    nmp_margin_base: i32 = 219,
    nmp_margin_depth_coeff: i32 = 1327,
    nmp_margin_improving_coeff: i32 = 39,
    nmp_reduction_base: i32 = 6,
    nmp_reduction_depth_divisor: i32 = 5,

    lmp_base: i32 = 3,
    lmp_quadratic: i32 = 1,
    lmp_non_improving_divisor: i32 = 2,

    rfp_linear: i32 = 84,
    rfp_quadratic: i32 = 7,
    rfp_improving_coeff: i32 = 70,
    rfp_max_depth: i32 = 12,

    history_prune_linear: i32 = -2482,
    history_prune_base: i32 = -1313,
    history_prune_lmr_depth_max: i32 = 5,

    futility_base: i32 = 237,
    futility_per_depth: i32 = 71,
    futility_lmr_depth_max: i32 = 8,
    futility_alpha_cap: i32 = 500,

    see_quiet_coeff: i32 = -21,
    see_noisy_per_depth: i32 = -116,

    history_bonus_per_depth: i32 = 277,
    history_bonus_offset: i32 = -575,
    history_bonus_cap: i32 = 2723,
    history_malus_per_depth: i32 = 307,
    history_malus_offset: i32 = -245,
    history_malus_cap: i32 = 1027,

    research_base: i32 = 44,
    research_per_depth: i32 = 4,
    lmr_tt_pv_brake: i32 = -886,
    unit_percent: i32 = 25,

    inline fn scalePublished(self: *const Params, value: i32) i32 {
        return @divTrunc(value * self.unit_percent, 100);
    }

    pub inline fn nmpMargin(self: *const Params, depth: u16, improving: bool) i32 {
        const margin = self.scalePublished(self.nmp_margin_base -
            @divTrunc(@as(i32, depth) * self.nmp_margin_depth_coeff, 128) -
            @as(i32, if (improving) self.nmp_margin_improving_coeff else 0));
        return @max(margin, 0);
    }

    pub inline fn nmpReduction(self: *const Params, depth: u16) u16 {
        const reduction = self.nmp_reduction_base + @divTrunc(@as(i32, depth), self.nmp_reduction_depth_divisor);
        return @intCast(@min(reduction, @as(i32, depth)));
    }

    pub inline fn lmpThreshold(self: *const Params, depth: u16, improving: bool) usize {
        const d: i32 = @min(@as(i32, depth), 15);
        const divisor: i32 = if (improving) 1 else self.lmp_non_improving_divisor;
        return @intCast(@divTrunc(self.lmp_base + self.lmp_quadratic * d * d, divisor));
    }

    pub inline fn rfpMargin(self: *const Params, depth: u16, improving: bool) i32 {
        const d: i32 = depth;
        return self.scalePublished(d * self.rfp_linear + d * d * self.rfp_quadratic -
            @as(i32, if (improving) self.rfp_improving_coeff else 0));
    }

    pub inline fn historyPruneThreshold(self: *const Params, depth: u16) i32 {
        return self.history_prune_linear * @as(i32, depth) + self.history_prune_base;
    }

    pub inline fn futilityMargin(self: *const Params, depth: u16) i32 {
        return self.scalePublished(self.futility_base + self.futility_per_depth * @as(i32, depth));
    }

    pub inline fn seePruneThresholdQuiet(self: *const Params, lmr_depth: i32) i32 {
        return self.see_quiet_coeff * lmr_depth * lmr_depth;
    }

    pub inline fn seePruneThresholdNoisy(self: *const Params, depth: u16) i32 {
        return self.see_noisy_per_depth * @as(i32, depth);
    }

    pub inline fn historyBonus(self: *const Params, depth: u16) i32 {
        return std.math.clamp(@as(i32, depth) * self.history_bonus_per_depth + self.history_bonus_offset, 0, self.history_bonus_cap);
    }

    pub inline fn historyMalus(self: *const Params, depth: u16) i32 {
        return std.math.clamp(@as(i32, depth) * self.history_malus_per_depth + self.history_malus_offset, 0, self.history_malus_cap);
    }

    pub inline fn adjustLmrReduction(self: *const Params, table_value: i32, in: LmrInputs) i32 {
        const m = @min(in.move_number, LMR_MAX_M - 1);
        var r = table_value + self.lmr_base_adjust;
        if (!in.pv_node) r += self.lmr_non_pv_adjust;
        // The original tuning coordinate used 423 as its zero point. Keep that
        // coordinate compatible with existing checkpoints; both flavours now
        // apply the same effective coefficient to the same history input.
        const history_coeff = if (in.is_noisy) self.lmr_noisy_history_coeff - 423 else self.lmr_quiet_history_coeff;
        r -= @divTrunc(in.history * history_coeff, 4096);
        if (in.improving) r += self.lmr_improving_adjust;
        if (in.gives_check) r += self.lmr_check_adjust;
        if (in.cut_node) r += self.lmr_cut_adjust;
        if (in.tt_move_is_noisy) r += self.lmr_noisy_tt_move_adjust;
        r += in.alpha_raises * self.lmr_alpha_raise_adjust;
        r += @as(i32, @intCast(m)) * self.lmr_move_number_adjust;
        if (in.ttpv) r += self.lmr_tt_pv_adjust;
        if (in.ttpv_fail_low) r += self.lmr_tt_pv_fail_low_adjust;
        r -= in.complexity * 15;
        return r;
    }

    pub inline fn deeperThreshold(self: *const Params, depth: u16) i32 {
        return self.scalePublished(self.research_base + self.research_per_depth * @as(i32, depth));
    }
};

pub const Config = struct {
    params: Params,
    lmr_table: [2][LMR_MAX_D][LMR_MAX_M]i32,
    lmr_rebuild_count: u32 = 0,

    pub fn init(params: Params) Config {
        var result = Config{ .params = params, .lmr_table = undefined };
        result.rebuildLmrTable();
        return result;
    }

    /// Apply a complete snapshot between searches. Only the four logarithmic
    /// table inputs trigger the 2x64x64 rebuild.
    pub fn applyParams(self: *Config, params: Params) bool {
        if (std.meta.eql(self.params, params)) return false;
        const rebuild = self.params.lmr_quiet_base_1000 != params.lmr_quiet_base_1000 or
            self.params.lmr_quiet_divisor_1000 != params.lmr_quiet_divisor_1000 or
            self.params.lmr_noisy_base_1000 != params.lmr_noisy_base_1000 or
            self.params.lmr_noisy_divisor_1000 != params.lmr_noisy_divisor_1000;
        self.params = params;
        if (rebuild) self.rebuildLmrTable();
        return true;
    }

    fn rebuildLmrTable(self: *Config) void {
        const shape = [2][2]i32{
            .{ self.params.lmr_quiet_base_1000, self.params.lmr_quiet_divisor_1000 },
            .{ self.params.lmr_noisy_base_1000, self.params.lmr_noisy_divisor_1000 },
        };
        for (0..2) |noisy| {
            const base = @as(f64, @floatFromInt(shape[noisy][0])) / 1000.0;
            const divisor = @as(f64, @floatFromInt(shape[noisy][1])) / 1000.0;
            for (0..LMR_MAX_D) |d| {
                for (0..LMR_MAX_M) |m| {
                    if (d < 1 or m < 1) {
                        self.lmr_table[noisy][d][m] = 0;
                    } else {
                        const ln_d = @log(@as(f64, @floatFromInt(d)));
                        const ln_m = @log(@as(f64, @floatFromInt(m)));
                        self.lmr_table[noisy][d][m] = @intFromFloat(1024.0 * (base + ln_d * ln_m / divisor));
                    }
                }
            }
        }
        self.lmr_rebuild_count +%= 1;
    }

    pub inline fn lmrReduction1024(self: *const Config, in: LmrInputs) i32 {
        const d = @min(@as(usize, in.depth), LMR_MAX_D - 1);
        const m = @min(in.move_number, LMR_MAX_M - 1);
        const p = &self.params;
        return p.adjustLmrReduction(self.lmr_table[@intFromBool(in.is_noisy)][d][m], in);
    }

    pub inline fn lmrDepth(self: *const Config, depth: u16, move_number: usize, ttpv: bool) i32 {
        const d = @min(@as(usize, depth), LMR_MAX_D - 1);
        const m = @min(move_number, LMR_MAX_M - 1);
        const base = self.lmr_table[0][d][m] + @as(i32, if (ttpv) self.params.lmr_depth_tt_pv_offset else 0);
        return @max(@as(i32, depth) - @divTrunc(base, 1024), 0);
    }
};

// Release-only compile-time dual LMR table.
const default_lmr_table: [2][LMR_MAX_D][LMR_MAX_M]i32 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [2][LMR_MAX_D][LMR_MAX_M]i32 = undefined;
    const shape = [2][2]f64{
        .{ @as(f64, @floatFromInt(defaults.lmr_quiet_base_1000)) / 1000.0, @as(f64, @floatFromInt(defaults.lmr_quiet_divisor_1000)) / 1000.0 },
        .{ @as(f64, @floatFromInt(defaults.lmr_noisy_base_1000)) / 1000.0, @as(f64, @floatFromInt(defaults.lmr_noisy_divisor_1000)) / 1000.0 },
    };
    for (0..2) |noisy| {
        for (0..LMR_MAX_D) |d| {
            for (0..LMR_MAX_M) |m| {
                if (d < 1 or m < 1) {
                    table[noisy][d][m] = 0;
                } else {
                    table[noisy][d][m] = @intFromFloat(1024.0 * (shape[noisy][0] +
                        @log(@as(f64, @floatFromInt(d))) * @log(@as(f64, @floatFromInt(m))) / shape[noisy][1]));
                }
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

pub inline fn u(published_internal: i32) i32 {
    return @divTrunc(published_internal * UNIT_PERCENT, 100);
}

pub fn uWithPercent(published_internal: i32, unit_percent: i32) i32 {
    return @divTrunc(published_internal * unit_percent, 100);
}

pub fn lmrReduction1024(in: LmrInputs) i32 {
    const d = @min(@as(usize, in.depth), LMR_MAX_D - 1);
    const m = @min(in.move_number, LMR_MAX_M - 1);
    return defaults.adjustLmrReduction(default_lmr_table[@intFromBool(in.is_noisy)][d][m], in);
}

pub fn lmrDepth(depth: u16, move_number: usize, ttpv: bool) i32 {
    const d = @min(@as(usize, depth), LMR_MAX_D - 1);
    const m = @min(move_number, LMR_MAX_M - 1);
    const base = default_lmr_table[0][d][m] + @as(i32, if (ttpv) defaults.lmr_depth_tt_pv_offset else 0);
    return @max(@as(i32, depth) - @divTrunc(base, 1024), 0);
}

pub fn nmpMargin(depth: u16, improving: bool) i32 {
    return defaults.nmpMargin(depth, improving);
}

pub fn nmpReduction(depth: u16) u16 {
    return defaults.nmpReduction(depth);
}

pub fn lmpThreshold(depth: u16, improving: bool) usize {
    return defaults.lmpThreshold(depth, improving);
}

pub fn rfpMargin(depth: u16, improving: bool) i32 {
    return defaults.rfpMargin(depth, improving);
}

pub fn historyPruneThreshold(depth: u16) i32 {
    return defaults.historyPruneThreshold(depth);
}

pub fn futilityMargin(depth: u16) i32 {
    return defaults.futilityMargin(depth);
}

pub fn seePruneThresholdQuiet(lmr_depth: i32) i32 {
    return defaults.seePruneThresholdQuiet(lmr_depth);
}

pub fn seePruneThresholdNoisy(depth: u16) i32 {
    return defaults.seePruneThresholdNoisy(depth);
}

pub fn historyBonus(depth: u16) i32 {
    return defaults.historyBonus(depth);
}

pub fn historyMalus(depth: u16) i32 {
    return defaults.historyMalus(depth);
}

pub fn deeperThreshold(depth: u16) i32 {
    return defaults.deeperThreshold(depth);
}

pub const Spec = struct {
    uci_name: []const u8,
    field: []const u8,
    default: i32,
    min: i32,
    max: i32,
    unit: []const u8,
};

pub const specs = [_]Spec{
    .{ .uci_name = "BasinLmrQuietBase", .field = "lmr_quiet_base_1000", .default = defaults.lmr_quiet_base_1000, .min = 390, .max = 1170, .unit = "1/1000" },
    .{ .uci_name = "BasinLmrQuietDivisor", .field = "lmr_quiet_divisor_1000", .default = defaults.lmr_quiet_divisor_1000, .min = 1180, .max = 3540, .unit = "1/1000" },
    .{ .uci_name = "BasinLmrNoisyBase", .field = "lmr_noisy_base_1000", .default = defaults.lmr_noisy_base_1000, .min = -300, .max = 100, .unit = "1/1000" },
    .{ .uci_name = "BasinLmrNoisyDivisor", .field = "lmr_noisy_divisor_1000", .default = defaults.lmr_noisy_divisor_1000, .min = 1245, .max = 3735, .unit = "1/1000" },
    .{ .uci_name = "BasinLmrBaseAdjust", .field = "lmr_base_adjust", .default = defaults.lmr_base_adjust, .min = -111, .max = 37, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrNonPvAdjust", .field = "lmr_non_pv_adjust", .default = defaults.lmr_non_pv_adjust, .min = 535, .max = 1604, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrNoisyHistoryCoeff", .field = "lmr_noisy_history_coeff", .default = defaults.lmr_noisy_history_coeff, .min = 212, .max = 635, .unit = "numerator" },
    .{ .uci_name = "BasinLmrQuietHistoryCoeff", .field = "lmr_quiet_history_coeff", .default = defaults.lmr_quiet_history_coeff, .min = 224, .max = 671, .unit = "numerator" },
    .{ .uci_name = "BasinLmrImprovingAdjust", .field = "lmr_improving_adjust", .default = defaults.lmr_improving_adjust, .min = -1863, .max = -621, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrCheckAdjust", .field = "lmr_check_adjust", .default = defaults.lmr_check_adjust, .min = -1278, .max = -426, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrCutAdjust", .field = "lmr_cut_adjust", .default = defaults.lmr_cut_adjust, .min = 973, .max = 2918, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrNoisyTtMoveAdjust", .field = "lmr_noisy_tt_move_adjust", .default = defaults.lmr_noisy_tt_move_adjust, .min = 541, .max = 1622, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrAlphaRaiseAdjust", .field = "lmr_alpha_raise_adjust", .default = defaults.lmr_alpha_raise_adjust, .min = 299, .max = 896, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrMoveNumberAdjust", .field = "lmr_move_number_adjust", .default = defaults.lmr_move_number_adjust, .min = -126, .max = 42, .unit = "1/1024 ply per move" },
    .{ .uci_name = "BasinLmrTtPvAdjust", .field = "lmr_tt_pv_adjust", .default = defaults.lmr_tt_pv_adjust, .min = -1719, .max = -573, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrTtPvFailLowAdjust", .field = "lmr_tt_pv_fail_low_adjust", .default = defaults.lmr_tt_pv_fail_low_adjust, .min = 527, .max = 1581, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinLmrDepthTtPvOffset", .field = "lmr_depth_tt_pv_offset", .default = defaults.lmr_depth_tt_pv_offset, .min = 363, .max = 1089, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinNmpMarginBase", .field = "nmp_margin_base", .default = defaults.nmp_margin_base, .min = 107, .max = 320, .unit = "published margin" },
    .{ .uci_name = "BasinNmpMarginDepthCoeff", .field = "nmp_margin_depth_coeff", .default = defaults.nmp_margin_depth_coeff, .min = 641, .max = 1922, .unit = "published numerator" },
    .{ .uci_name = "BasinNmpMarginImprovingCoeff", .field = "nmp_margin_improving_coeff", .default = defaults.nmp_margin_improving_coeff, .min = 0, .max = 82, .unit = "published margin" },
    .{ .uci_name = "BasinNmpReductionBase", .field = "nmp_reduction_base", .default = defaults.nmp_reduction_base, .min = 3, .max = 9, .unit = "plies" },
    .{ .uci_name = "BasinNmpReductionDepthDivisor", .field = "nmp_reduction_depth_divisor", .default = defaults.nmp_reduction_depth_divisor, .min = 2, .max = 8, .unit = "depth divisor" },
    .{ .uci_name = "BasinLmpBase", .field = "lmp_base", .default = defaults.lmp_base, .min = 0, .max = 6, .unit = "moves" },
    .{ .uci_name = "BasinLmpQuadratic", .field = "lmp_quadratic", .default = defaults.lmp_quadratic, .min = 0, .max = 3, .unit = "moves/depth^2" },
    .{ .uci_name = "BasinLmpNonImprovingDivisor", .field = "lmp_non_improving_divisor", .default = defaults.lmp_non_improving_divisor, .min = 1, .max = 4, .unit = "divisor" },
    .{ .uci_name = "BasinRfpLinear", .field = "rfp_linear", .default = defaults.rfp_linear, .min = 43, .max = 128, .unit = "published margin/depth" },
    .{ .uci_name = "BasinRfpQuadratic", .field = "rfp_quadratic", .default = defaults.rfp_quadratic, .min = 3, .max = 11, .unit = "published margin/depth^2" },
    .{ .uci_name = "BasinRfpImprovingCoeff", .field = "rfp_improving_coeff", .default = defaults.rfp_improving_coeff, .min = 0, .max = 150, .unit = "published margin" },
    .{ .uci_name = "BasinRfpMaxDepth", .field = "rfp_max_depth", .default = defaults.rfp_max_depth, .min = 6, .max = 18, .unit = "plies" },
    .{ .uci_name = "BasinHistoryPruneLinear", .field = "history_prune_linear", .default = defaults.history_prune_linear, .min = -3363, .max = -1121, .unit = "history points/depth" },
    .{ .uci_name = "BasinHistoryPruneBase", .field = "history_prune_base", .default = defaults.history_prune_base, .min = -2630, .max = 0, .unit = "history points" },
    .{ .uci_name = "BasinHistoryPruneLmrDepthMax", .field = "history_prune_lmr_depth_max", .default = defaults.history_prune_lmr_depth_max, .min = 2, .max = 8, .unit = "plies" },
    .{ .uci_name = "BasinFutilityBase", .field = "futility_base", .default = defaults.futility_base, .min = 137, .max = 411, .unit = "published margin" },
    .{ .uci_name = "BasinFutilityPerDepth", .field = "futility_per_depth", .default = defaults.futility_per_depth, .min = 34, .max = 102, .unit = "published margin/depth" },
    .{ .uci_name = "BasinFutilityLmrDepthMax", .field = "futility_lmr_depth_max", .default = defaults.futility_lmr_depth_max, .min = 4, .max = 12, .unit = "plies" },
    .{ .uci_name = "BasinFutilityAlphaCap", .field = "futility_alpha_cap", .default = defaults.futility_alpha_cap, .min = 250, .max = 750, .unit = "cp" },
    .{ .uci_name = "BasinSeeQuietCoeff", .field = "see_quiet_coeff", .default = defaults.see_quiet_coeff, .min = -40, .max = -4, .unit = "cp/lmr_depth^2" },
    .{ .uci_name = "BasinSeeNoisyPerDepth", .field = "see_noisy_per_depth", .default = defaults.see_noisy_per_depth, .min = -222, .max = -25, .unit = "cp/depth" },
    .{ .uci_name = "BasinHistoryBonusPerDepth", .field = "history_bonus_per_depth", .default = defaults.history_bonus_per_depth, .min = 139, .max = 416, .unit = "history points/depth" },
    .{ .uci_name = "BasinHistoryBonusOffset", .field = "history_bonus_offset", .default = defaults.history_bonus_offset, .min = -1150, .max = 0, .unit = "history points" },
    .{ .uci_name = "BasinHistoryBonusCap", .field = "history_bonus_cap", .default = defaults.history_bonus_cap, .min = 1362, .max = 4085, .unit = "history points" },
    .{ .uci_name = "BasinHistoryMalusPerDepth", .field = "history_malus_per_depth", .default = defaults.history_malus_per_depth, .min = 154, .max = 461, .unit = "history points/depth" },
    .{ .uci_name = "BasinHistoryMalusOffset", .field = "history_malus_offset", .default = defaults.history_malus_offset, .min = -490, .max = 0, .unit = "history points" },
    .{ .uci_name = "BasinHistoryMalusCap", .field = "history_malus_cap", .default = defaults.history_malus_cap, .min = 514, .max = 1541, .unit = "history points" },
    .{ .uci_name = "BasinResearchBase", .field = "research_base", .default = defaults.research_base, .min = 22, .max = 66, .unit = "published margin" },
    .{ .uci_name = "BasinResearchPerDepth", .field = "research_per_depth", .default = defaults.research_per_depth, .min = 2, .max = 6, .unit = "published margin/depth" },
    .{ .uci_name = "BasinLmrTtPvBrake", .field = "lmr_tt_pv_brake", .default = defaults.lmr_tt_pv_brake, .min = -4096, .max = 4096, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinUnitPercent", .field = "unit_percent", .default = defaults.unit_percent, .min = 10, .max = 60, .unit = "percent" },
};

pub fn setParam(params: *Params, uci_name: []const u8, value: i32) bool {
    inline for (specs) |spec| {
        if (std.mem.eql(u8, uci_name, spec.uci_name)) {
            @field(params, spec.field) = std.math.clamp(value, spec.min, spec.max);
            return true;
        }
    }
    return false;
}

test "basin specs match Params defaults" {
    const initial = Params{};
    inline for (specs) |spec| try std.testing.expectEqual(@field(initial, spec.field), spec.default);
}

test "release and runtime LMR tables agree over the entire lookup domain" {
    const config = Config.init(defaults);
    for (0..2) |noisy| {
        for (0..LMR_MAX_D) |d| {
            try std.testing.expectEqualSlices(i32, &default_lmr_table[noisy][d], &config.lmr_table[noisy][d]);
        }
    }
}

test "noisy history calibration has the same effective coefficient when baked" {
    const input = LmrInputs{
        .depth = 20,
        .move_number = 12,
        .is_noisy = true,
        .pv_node = false,
        .cut_node = true,
        .improving = true,
        .gives_check = false,
        .tt_move_is_noisy = true,
        .alpha_raises = 1,
        .history = 4096,
        .ttpv = false,
        .ttpv_fail_low = false,
        .complexity = 7,
    };
    const base = Config.init(defaults);
    var tuned_params = defaults;
    tuned_params.lmr_noisy_history_coeff += 41;
    const tuned = Config.init(tuned_params);
    try std.testing.expectEqual(base.lmrReduction1024(input) - 41, tuned.lmrReduction1024(input));
    try std.testing.expectEqual(lmrReduction1024(input), base.lmrReduction1024(input));
}

test "basin defaults preserve formulas and LMR rebuild is setoption-only" {
    var config = Config.init(.{});
    try std.testing.expectEqual(@as(u32, 1), config.lmr_rebuild_count);
    try std.testing.expectEqual(lmrDepth(20, 20, true), config.lmrDepth(20, 20, true));
    try std.testing.expectEqual(nmpMargin(4, false), config.params.nmpMargin(4, false));
    try std.testing.expectEqual(lmpThreshold(6, false), config.params.lmpThreshold(6, false));
    try std.testing.expectEqual(rfpMargin(6, true), config.params.rfpMargin(6, true));
    try std.testing.expectEqual(historyBonus(14), config.params.historyBonus(14));
    var params = config.params;
    params.rfp_linear += 1;
    try std.testing.expect(config.applyParams(params));
    try std.testing.expectEqual(@as(u32, 1), config.lmr_rebuild_count);
    params.lmr_quiet_base_1000 += 1;
    try std.testing.expect(config.applyParams(params));
    try std.testing.expectEqual(@as(u32, 2), config.lmr_rebuild_count);
}

test "basin parameter setters clamp" {
    var params = Params{};
    try std.testing.expect(setParam(&params, "BasinLmrQuietBase", 99999));
    try std.testing.expectEqual(@as(i32, 1170), params.lmr_quiet_base_1000);
    try std.testing.expect(!setParam(&params, "BasinNoSuchOption", 1));
}

test "BasinUnitPercent preserves 25 percent and remaps published eval margins" {
    try std.testing.expectEqual(@as(i32, 50), uWithPercent(202, 25));
    try std.testing.expectEqual(@as(i32, 80), uWithPercent(202, 40));
}
