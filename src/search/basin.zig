//! Basin-hop search-shaping configuration.
//!
//! Provenance: the fractional LMR formula, the pruning families below and
//! their initial default constants were taken from Stormphrax 8.0.0's published
//! parameter set (Ciekce, GPL-3.0; https://github.com/Ciekce/Stormphrax),
//! with eval-denominated margins scaled by `UNIT_PERCENT` and dimensionless
//! terms taken as-is. The implementation, its integration, guards and
//! score-unit calibration are zigqueen's; no source text was transcribed.
//! In 6.2.0, a local 12-coordinate pruning SPSA retune changed 11 defaults.
//! A2 candidate (2026-10): a local 17-coordinate SPSA retune for the BT4 net
//! changed 15 defaults (artifacts/research/a2-spsa-20261001/).
//! Correction-history bundle (2026-10): a joint 26-coordinate SPSA (margins,
//! reductions, correction, uncertainty, fail-soft softness) on top of A2
//! changed 21 defaults (artifacts/research/cbundle-20261003/).
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
/// `progress_floor` at this value switches the clock pressure off exactly: no
/// ordinary eval lies beyond it (score.ORDINARY_SCORE_LIMIT is below).
pub const PROGRESS_FLOOR_OFF: i32 = 30_000;
pub const ASPIRATION_INITIAL_CP: i32 = 8;

const LMR_MAX_D: usize = 64;
const LMR_MAX_M: usize = 64;

pub const Params = struct {
    // Decimal LMR coefficients in integer 1/1000 units.
    lmr_quiet_base_1000: i32 = 832,
    lmr_quiet_divisor_1000: i32 = 1686,
    lmr_noisy_base_1000: i32 = -100,
    lmr_noisy_divisor_1000: i32 = 2490,

    // Fractional reduction adjustments in 1/1024-ply units.
    lmr_base_adjust: i32 = -37,
    lmr_non_pv_adjust: i32 = 1307,
    lmr_noisy_history_coeff: i32 = 423,
    lmr_quiet_history_coeff: i32 = 447,
    lmr_improving_adjust: i32 = -1195,
    lmr_check_adjust: i32 = -852,
    lmr_cut_adjust: i32 = 1945,
    lmr_noisy_tt_move_adjust: i32 = 1081,
    lmr_alpha_raise_adjust: i32 = 597,
    lmr_move_number_adjust: i32 = -42,
    lmr_tt_pv_adjust: i32 = -1146,
    lmr_tt_pv_fail_low_adjust: i32 = 1054,
    lmr_depth_tt_pv_offset: i32 = 726,

    // Published-margin units; scaled once by unit_percent at use.
    nmp_margin_base: i32 = 207,
    nmp_margin_depth_coeff: i32 = 1357,
    nmp_margin_improving_coeff: i32 = 38,
    nmp_reduction_base: i32 = 8,
    nmp_reduction_depth_divisor: i32 = 5,

    lmp_base: i32 = 3,
    lmp_quadratic: i32 = 1,
    lmp_non_improving_divisor: i32 = 2,

    rfp_linear: i32 = 79,
    rfp_quadratic: i32 = 7,
    rfp_improving_coeff: i32 = 72,
    rfp_max_depth: i32 = 12,

    history_prune_linear: i32 = -2653,
    history_prune_base: i32 = -1345,
    history_prune_lmr_depth_max: i32 = 5,

    futility_base: i32 = 240,
    futility_per_depth: i32 = 75,
    futility_lmr_depth_max: i32 = 8,
    futility_alpha_cap: i32 = 500,

    see_quiet_coeff: i32 = -20,
    see_noisy_per_depth: i32 = -126,

    history_bonus_per_depth: i32 = 277,
    history_bonus_offset: i32 = -575,
    history_bonus_cap: i32 = 2723,
    history_malus_per_depth: i32 = 307,
    history_malus_offset: i32 = -245,
    history_malus_cap: i32 = 1027,

    // Killers and countermove as bonuses in one quiet score. With
    // order_unified at 1 a quiet's order score is its history sum plus these
    // bonuses for being killer A, killer B or the countermove (they add up
    // for a move that is two of them), so a quiet with strong history can
    // pass a stale killer and the countermove is no longer tried behind both
    // killers; at 0 the three are fixed tiers above every other quiet. The
    // bonuses follow the measured cut rate per try (countermove 28 to 30%,
    // killer A 23%, killer B 8%, a plain quiet 2%) on the scale of one
    // table's range of 32,000. One score needs a level for losing captures,
    // which the tiers put between the countermove and the other quiets:
    // order_losing_capture_base plus the exchange value, behind a killer or
    // countermove without bad history and ahead of a quiet whose history sum
    // is below it. The pruning exemptions of killers are unchanged. On by
    // default since its direct test (cell `ord-one`).
    order_unified: i32 = 1,
    order_killer_a_bonus: i32 = 40000,
    order_killer_b_bonus: i32 = 16000,
    order_counter_bonus: i32 = 48000,
    order_losing_capture_base: i32 = 12000,
    /// The countermove is also kept and read after a capture or promotion,
    /// keyed by the piece that moved and its square (at 0 it exists only
    /// after a quiet move): the reply to a capture is the most forced reply
    /// there is. On by default since its direct test (cell `counter-capt`).
    counter_after_capture: i32 = 1,

    research_base: i32 = 44,
    research_per_depth: i32 = 4,
    lmr_tt_pv_brake: i32 = -886,
    unit_percent: i32 = 25,

    // Fail-soft returns (A3b): an RFP or stand-pat cutoff returns beta moved
    // toward the eval by this many sixteenths of the gap (fail_soft.zig).
    rfp_softness: i32 = 6,
    standpat_softness: i32 = 9,
    // Correction history (A3c, history.zig): relative class weights of the
    // applied average, applied scale (64 = 1.0), learning steps and the cap
    // on a learning target.
    corr_weight_pawn: i32 = 16,
    corr_weight_nonpawn: i32 = 16,
    corr_weight_minor: i32 = 17,
    corr_weight_major: i32 = 16,
    corr_apply_scale: i32 = 77,
    /// Class entries move min(depth, 16) * corr_step / 1024 of the gap.
    corr_step: i32 = 16,
    /// The bucket mean moves corr_mean_step / 4096 of the gap.
    corr_mean_step: i32 = 15,
    corr_target_cap: i32 = 128,
    /// Continuation classes (previous move, move before that).
    corr_weight_cont1: i32 = 14,
    corr_weight_cont2: i32 = 16,

    // Uncertainty (bundle step 2): |correction| makes pruning and reduction
    // less aggressive. RFP and quiet futility margins grow by |c| * unc / 16;
    // LMR loses lmr_complexity_coeff / 1024 ply per cp of |c|.
    unc_rfp: i32 = 8,
    unc_futility: i32 = 7,
    lmr_complexity_coeff: i32 = 10,

    // A bare king against pawnless mating material: centipawns per step the
    // bare king is from the centre (twice) and per step the kings are closer
    // (progress.bareKingBonus). Elementary endings at 5k nodes against SF19:
    // 55 of 80 won without, 66 with 5, 74 with 10.
    bare_king_unit: i32 = 10,

    // Clock pressure on the side that is ahead (round 2, item 3). While a
    // pawn is on the board, the part of the eval beyond progress_floor that
    // favours the root side loses halfmove clock / progress_clock_span of
    // itself: a pawn move or capture, which resets the clock, is worth more
    // to the side that has to win than waiting. The network's eval ignores
    // the clock, so a won position was worth the same after 40 moves of
    // shuffling as after progress. Evals that favour the root side's opponent
    // lose progress_defender_pct percent of that amount: 0 keeps the root
    // side's view of its own bad positions exactly as the network gives it
    // (damping both sides alike made the engine defend worse, round 1);
    // 100 is the symmetric form. PROGRESS_FLOOR_OFF switches the term off.
    // The term acts only in a search whose root is ahead for the root side by
    // progress_root_gate: the game's last search, of which this one is the
    // successor (predecessor.zig), ended at or above it. Decided before the
    // search, so the term is on for a whole search or not at all. A search
    // of a game that has not been ahead is exactly the search without the
    // term. Without the
    // gate the term also touched won lines deep in the trees of level
    // positions; that changed nothing measurable in play but made nearly
    // half of all games differ from the base's, so its effect could not be
    // told from noise. A gate of -30000 opens after any completed search.
    // progress_root_leave: once on, the term stays on until the game's last
    // search ended below this. With one line for both, a score that moves
    // 2.90, 3.10, 2.95, 3.05 changes the search's table context
    // (progress.TableContext) at every move, and a search that starts in
    // another context than the last finds none of its entries: x1.6 to x1.7
    // nodes to the same depth, 0.8 to 1.1 plies less at 100k nodes, four
    // fifths of the cost of an empty table. In the stack's pool games at 100k
    // 0.32% of all searches started that way and 44% of those changes were
    // undone within two searches; a leave line of 200 removes those. Equal
    // to the gate (or above it) it is the single line again.
    progress_clock_span: i32 = 150,
    progress_floor: i32 = 300,
    progress_defender_pct: i32 = 0,
    progress_root_gate: i32 = 300,
    progress_root_leave: i32 = 200,
    // A searched score under the pressure also depends on the halfmove clock
    // of its node, which the position key does not hold: the same position
    // reached by a longer manoeuvre has a higher clock. The table keeps
    // pressure-on entries apart by clock in buckets of this many plies
    // (progress.TableContext), so a bound is reused only at a clock of the
    // same bucket: one reuse is then off by about (bucket - 1) /
    // progress_clock_span of what exceeds the floor at most (an estimate of
    // size, not a guarantee). 128 is one bucket for every clock (no
    // separation).
    progress_clock_bucket: i32 = 16,

    // draw_dither (vol-frame 15): with Contempt 0 an in-tree draw
    // (context.drawScore: repetition, fifty moves, stalemate) scores +D or -D
    // by bit 1 of the thread's node counter instead of exactly 0, from the
    // side to move's view. The root's cycle tie-break then takes |score| <= D
    // for a draw (root.cycleTieAsked). 0 = exact 0 (the engine before
    // 2026-11-16); 1 since.
    draw_dither: i32 = 1,

    /// The eval (side to move's view) under the clock pressure; `mover_is_root`
    /// says whether the side to move is the root side.
    pub inline fn clockPressure(self: *const Params, eval: i32, halfmove_clock: u16, mover_is_root: bool) i32 {
        const magnitude: i32 = @intCast(@abs(eval));
        if (magnitude <= self.progress_floor) return eval;
        const ahead_is_root = (eval > 0) == mover_is_root;
        const pct: i32 = if (ahead_is_root) 100 else self.progress_defender_pct;
        if (pct == 0) return eval;
        const clock: i32 = @min(@as(i32, halfmove_clock), 100);
        const cut = @divTrunc((magnitude - self.progress_floor) * clock * pct, self.progress_clock_span * 100);
        const damped = magnitude - cut;
        return if (eval > 0) damped else -damped;
    }

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
        r -= in.complexity * self.lmr_complexity_coeff;
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
    .{ .uci_name = "OrderUnified", .field = "order_unified", .default = defaults.order_unified, .min = 0, .max = 1, .unit = "switch" },
    .{ .uci_name = "OrderKillerABonus", .field = "order_killer_a_bonus", .default = defaults.order_killer_a_bonus, .min = 0, .max = 150000, .unit = "history points" },
    .{ .uci_name = "OrderKillerBBonus", .field = "order_killer_b_bonus", .default = defaults.order_killer_b_bonus, .min = 0, .max = 150000, .unit = "history points" },
    .{ .uci_name = "OrderCounterBonus", .field = "order_counter_bonus", .default = defaults.order_counter_bonus, .min = 0, .max = 150000, .unit = "history points" },
    .{ .uci_name = "OrderLosingCaptureBase", .field = "order_losing_capture_base", .default = defaults.order_losing_capture_base, .min = -100000, .max = 200000, .unit = "history points" },
    .{ .uci_name = "CounterAfterCapture", .field = "counter_after_capture", .default = defaults.counter_after_capture, .min = 0, .max = 1, .unit = "switch" },
    .{ .uci_name = "BasinResearchBase", .field = "research_base", .default = defaults.research_base, .min = 22, .max = 66, .unit = "published margin" },
    .{ .uci_name = "BasinResearchPerDepth", .field = "research_per_depth", .default = defaults.research_per_depth, .min = 2, .max = 6, .unit = "published margin/depth" },
    .{ .uci_name = "BasinLmrTtPvBrake", .field = "lmr_tt_pv_brake", .default = defaults.lmr_tt_pv_brake, .min = -4096, .max = 4096, .unit = "1/1024 ply" },
    .{ .uci_name = "BasinUnitPercent", .field = "unit_percent", .default = defaults.unit_percent, .min = 10, .max = 60, .unit = "percent" },
    .{ .uci_name = "BasinRfpSoftness", .field = "rfp_softness", .default = defaults.rfp_softness, .min = 0, .max = 16, .unit = "1/16 of eval - beta" },
    .{ .uci_name = "BasinStandPatSoftness", .field = "standpat_softness", .default = defaults.standpat_softness, .min = 0, .max = 16, .unit = "1/16 of eval - beta" },
    .{ .uci_name = "CorrWeightPawn", .field = "corr_weight_pawn", .default = defaults.corr_weight_pawn, .min = 0, .max = 64, .unit = "relative weight" },
    .{ .uci_name = "CorrWeightNonPawn", .field = "corr_weight_nonpawn", .default = defaults.corr_weight_nonpawn, .min = 0, .max = 64, .unit = "relative weight (each colour)" },
    .{ .uci_name = "CorrWeightMinor", .field = "corr_weight_minor", .default = defaults.corr_weight_minor, .min = 0, .max = 64, .unit = "relative weight" },
    .{ .uci_name = "CorrWeightMajor", .field = "corr_weight_major", .default = defaults.corr_weight_major, .min = 0, .max = 64, .unit = "relative weight" },
    .{ .uci_name = "CorrApplyScale", .field = "corr_apply_scale", .default = defaults.corr_apply_scale, .min = 0, .max = 128, .unit = "1/64" },
    .{ .uci_name = "CorrStep", .field = "corr_step", .default = defaults.corr_step, .min = 4, .max = 48, .unit = "1/1024 per depth" },
    .{ .uci_name = "CorrMeanStep", .field = "corr_mean_step", .default = defaults.corr_mean_step, .min = 4, .max = 64, .unit = "1/4096" },
    .{ .uci_name = "CorrTargetCap", .field = "corr_target_cap", .default = defaults.corr_target_cap, .min = 32, .max = 256, .unit = "cp" },
    .{ .uci_name = "CorrWeightCont1", .field = "corr_weight_cont1", .default = defaults.corr_weight_cont1, .min = 0, .max = 64, .unit = "relative weight" },
    .{ .uci_name = "CorrWeightCont2", .field = "corr_weight_cont2", .default = defaults.corr_weight_cont2, .min = 0, .max = 64, .unit = "relative weight" },
    .{ .uci_name = "UncRfp", .field = "unc_rfp", .default = defaults.unc_rfp, .min = 0, .max = 32, .unit = "1/16 of |correction|" },
    .{ .uci_name = "UncFutility", .field = "unc_futility", .default = defaults.unc_futility, .min = 0, .max = 32, .unit = "1/16 of |correction|" },
    .{ .uci_name = "UncLmr", .field = "lmr_complexity_coeff", .default = defaults.lmr_complexity_coeff, .min = 0, .max = 48, .unit = "1/1024 ply per cp" },
    .{ .uci_name = "BareKingUnit", .field = "bare_king_unit", .default = defaults.bare_king_unit, .min = 0, .max = 40, .unit = "cp/step" },
    .{ .uci_name = "ProgressClockSpan", .field = "progress_clock_span", .default = defaults.progress_clock_span, .min = 100, .max = 100000, .unit = "plies" },
    .{ .uci_name = "ProgressFloor", .field = "progress_floor", .default = defaults.progress_floor, .min = 0, .max = PROGRESS_FLOOR_OFF, .unit = "cp" },
    .{ .uci_name = "ProgressDefenderPct", .field = "progress_defender_pct", .default = defaults.progress_defender_pct, .min = 0, .max = 100, .unit = "percent" },
    .{ .uci_name = "ProgressRootGate", .field = "progress_root_gate", .default = defaults.progress_root_gate, .min = -30000, .max = 30000, .unit = "cp" },
    .{ .uci_name = "ProgressRootLeave", .field = "progress_root_leave", .default = defaults.progress_root_leave, .min = -30000, .max = 30000, .unit = "cp" },
    .{ .uci_name = "ProgressClockBucket", .field = "progress_clock_bucket", .default = defaults.progress_clock_bucket, .min = 1, .max = 128, .unit = "plies" },
    .{ .uci_name = "DrawDither", .field = "draw_dither", .default = defaults.draw_dither, .min = 0, .max = 8, .unit = "cp" },
};

/// Whether a score is a draw at the default dither (draw_dither): exactly 0
/// at the root's own draws, within the dither for a draw found in the tree.
/// For tests.
pub inline fn isDrawAtDefault(score: i32) bool {
    return @abs(score) <= defaults.draw_dither;
}

pub fn setParam(params: *Params, uci_name: []const u8, value: i32) bool {
    inline for (specs) |spec| {
        if (std.ascii.eqlIgnoreCase(uci_name, spec.uci_name)) {
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

test "the clock pressure damps only what favours the root side beyond the floor" {
    var params = Params{};
    params.progress_clock_span = 150;
    params.progress_floor = 300;
    params.progress_defender_pct = 0;
    // The root side to move, 6.00 up at clock 50: a third of the 3.00 beyond the floor goes.
    try std.testing.expectEqual(@as(i32, 500), params.clockPressure(600, 50, true));
    // The same position seen by the opponent to move: -6.00 becomes -5.00.
    try std.testing.expectEqual(@as(i32, -500), params.clockPressure(-600, 50, false));
    // The root side behind, whoever is to move: untouched.
    try std.testing.expectEqual(@as(i32, -600), params.clockPressure(-600, 50, true));
    try std.testing.expectEqual(@as(i32, 600), params.clockPressure(600, 50, false));
    // Within the floor and at clock 0: untouched.
    try std.testing.expectEqual(@as(i32, 300), params.clockPressure(300, 90, true));
    try std.testing.expectEqual(@as(i32, 600), params.clockPressure(600, 0, true));
    // The clock stops counting at the boundary.
    try std.testing.expectEqual(params.clockPressure(600, 100, true), params.clockPressure(600, 140, true));
    // The symmetric form damps the opponent's lead as well; half of it at 50 percent.
    params.progress_defender_pct = 100;
    try std.testing.expectEqual(@as(i32, -500), params.clockPressure(-600, 50, true));
    try std.testing.expectEqual(@as(i32, 500), params.clockPressure(600, 50, false));
    params.progress_defender_pct = 50;
    try std.testing.expectEqual(@as(i32, -550), params.clockPressure(-600, 50, true));
    // The off value of the floor leaves every eval exactly as it is.
    params.progress_floor = PROGRESS_FLOOR_OFF;
    params.progress_defender_pct = 100;
    for ([_]i32{ 0, 299, 301, -4000, 26_975, -26_975 }) |eval| {
        try std.testing.expectEqual(eval, params.clockPressure(eval, 99, true));
        try std.testing.expectEqual(eval, params.clockPressure(eval, 99, false));
    }
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
