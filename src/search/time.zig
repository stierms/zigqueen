const std = @import("std");
const types = @import("../core/types.zig");

pub const DEFAULT_MOVE_OVERHEAD_MS: u64 = 20;
const LOW_TIME_THRESHOLD_MS: u64 = 1_000;
const SUDDEN_DEATH_DIVISOR: u64 = 24;
const SUDDEN_DEATH_NO_INCREMENT_DIVISOR: u64 = 28;
const LOW_TIME_DIVISOR: u64 = 32;

/// TM arc r1 (2026-08-06): every mechanism below is env-gated and DEFAULT OFF.
/// With no ZQ_TM_* variables set, budgets are bit-identical to the legacy
/// planner. Knob reference lives in docs/TIME_MANAGEMENT.md.
///
/// Gates (booleans, set =1 to enable):
///   ZQ_TM_CLAMP  — audit fix: clamp optimum (and thus returned maximum) to the
///                  remaining-clock hard cap. Without it, the increment/4 term
///                  can push the budget past the clock at increment-heavy low
///                  clocks (e.g. 100ms left + 1s inc plans a 252ms maximum).
///   ZQ_TM_PHASE  — game-phase soft-budget ramp keyed on the full-move clock.
///   ZQ_TM_NF     — soft-limit scaling by node-fraction of the best root move.
///   ZQ_TM_BM     — soft-limit scaling by best-move stability streak.
///   ZQ_TM_SC     — soft-limit scaling by score-trend stability.
///
/// Spend-level knob (r2): ZQ_TM_OPT_PCT — uniform percent scale on the soft
/// (optimum) budget; DEFAULT 130 (shipped); 100 = legacy v5.8.3 spend.
///
/// Hard-budget shape (r6 lane 1): ZQ_TM_MAX_GROWTH_PCT / ZQ_TM_MAX_FRAC_DIV —
/// instability-armed burst headroom on the sudden-death maximum; DEFAULT
/// 300 / 6 (was 50 / 8). Set 50 / 8 to recover the pre-r6 1.5x ceiling
/// bit-for-bit.
pub const TmConfig = struct {
    /// ZQ_TM_CLAMP: fix the budget-exceeds-clock defect (see above).
    clamp_fix: bool = false,

    /// ZQ_TM_OPT_PCT (r2 spend-level knob): uniform percent scale on the soft
    /// (optimum) budget, applied with the phase ramp BEFORE the low-time
    /// emergency caps (safety clamps always win); the maximum budget inherits
    /// the raise through its optimum-derived formula but stays under the
    /// remaining/8 fraction cap and the hard cap. 100 = bit-identical legacy.
    /// Motivation: v5.8.3 anchor games spend 82.7% of the available clock vs
    /// the field's 89.4%, gap concentrated in the opening.
    /// DEFAULT 130 (SHIPPED 2026-08-07, user call): +9.9/+7.3/+9.0 vs v5.8.3
    /// at 8s/20s/60s — significant at both ends, no negative tendency
    /// anywhere; the only surviving mechanism of TM arc r1/r2. Set
    /// ZQ_TM_OPT_PCT=100 to recover legacy spend exactly.
    opt_pct: u32 = 130,

    /// ZQ_TM_MAX_GROWTH_PCT / ZQ_TM_MAX_FRAC_DIV (r6 lane 1, burst headroom):
    /// the HARD (maximum) sudden-death budget as a percentage of the soft one
    /// and as a fraction of the remaining clock:
    ///   maximum = min(optimum + max(optimum*growth/100, inc/2),
    ///                 remaining/frac_div + inc/2,
    ///                 hard_cap)
    /// The head shipped 50 / 8, i.e. a hard budget of exactly 1.5x the soft one:
    /// the binary instability gate (best move changed OR |dscore| >= 80cp) makes
    /// the search keep going, and it then hits that ceiling. Measured on 178
    /// replayed r3 gauntlet games (12,973 of our moves, warm TT, simulated
    /// 20+0.2 clock, r6 lane 1): the 1.5x ceiling BINDS on 14.3% of moves, and
    /// on 11.4% the last completed iteration had just changed its best move or
    /// lost >= 30cp — the search wanted more depth exactly where the position
    /// was moving. Field reference (r3 gauntlet, 121,100 of our moves at 180+1,
    /// past the book): burst capacity t/(remaining/20 + inc) p99 1.42x, max
    /// 1.65x, 0.000% of moves above 2x, while every top-5 opponent bursts to
    /// p99 3-4x on 3-5% of moves.
    /// 300 / 6 gives an effective ceiling of ~2.5-3.1x the soft budget (the
    /// clock fraction binds first, and it tightens as the clock runs down, so
    /// the burst shrinks in time trouble). The Controller starts at the legacy
    /// 50 / 8 ceiling and the ID loop arms this value only for the iteration
    /// after a completed best-move change or >=30cp score drop. Set 50 / 8 to
    /// recover the head's budgets bit-for-bit.
    max_growth_pct: u32 = 300,
    max_fraction_divisor: u32 = 6,

    /// ZQ_TM_PHASE: enable the game-phase ramp. The soft (optimum) budget is
    /// multiplied by a hyperbolic decay over the full-move clock m:
    ///   pct(m) = min + (max - min) * H / (H + (m - 1))
    /// so move 1 gets max%, the factor passes halfway to min at move H+1, and
    /// decays toward min% in long games. Applied BEFORE the low-time emergency
    /// caps, so the safety clamps always win.
    phase: bool = false,
    /// ZQ_TM_PHASE_MAX_PCT: ramp value at move 1 (percent of base optimum).
    phase_max_pct: u32 = 140,
    /// ZQ_TM_PHASE_MIN_PCT: asymptotic late-game floor (percent).
    phase_min_pct: u32 = 80,
    /// ZQ_TM_PHASE_HALF: full-move count after move 1 at which the ramp has
    /// decayed halfway from max to min.
    phase_half_moves: u32 = 24,

    /// ZQ_TM_NF: node-fraction signal. Higher fraction of the last iteration's
    /// root nodes under the best move = easier decision = spend less:
    ///   pct = nf_base_pct - nf_slope_pct * fraction   (fraction in [0,1])
    nf: bool = false,
    /// ZQ_TM_NF_BASE_PCT: factor at fraction 0 (all nodes elsewhere).
    nf_base_pct: u32 = 145,
    /// ZQ_TM_NF_SLOPE_PCT: linear cut across the full [0,1] fraction range.
    nf_slope_pct: u32 = 65,

    /// ZQ_TM_BM: best-move stability signal. streak = consecutive completed
    /// iterations with the same best move (1 = it just changed):
    ///   pct = max(bm_min_pct, bm_max_pct - bm_step_pct * (streak - 1))
    /// While enabled it REPLACES the binary same-best-move stability gate.
    bm: bool = false,
    /// ZQ_TM_BM_MAX_PCT: factor right after a best-move change.
    bm_max_pct: u32 = 130,
    /// ZQ_TM_BM_MIN_PCT: floor for long-stable best moves.
    bm_min_pct: u32 = 85,
    /// ZQ_TM_BM_STEP_PCT: cut per additional stable iteration.
    bm_step_pct: u32 = 6,

    /// ZQ_TM_SC: score-trend signal. A falling score vs the previous iteration
    /// extends the budget; a flat/rising score uses sc_stable_pct:
    ///   drop > 0:  pct = 100 + min(drop_cp * sc_drop_pct / 10, sc_max_pct)
    ///   otherwise: pct = sc_stable_pct
    /// While enabled it REPLACES the binary +/-80cp stability window.
    sc: bool = false,
    /// ZQ_TM_SC_DROP_PCT: extra percent per 10cp of score drop.
    sc_drop_pct_per_10cp: u32 = 4,
    /// ZQ_TM_SC_MAX_PCT: cap on the score-drop extension (extra percent).
    sc_max_extra_pct: u32 = 60,
    /// ZQ_TM_SC_STABLE_PCT: factor when the score held or rose (100 = neutral;
    /// below 100 converts confirmed stability into saved time).
    sc_stable_pct: u32 = 100,

    /// ZQ_TM_SIG_MIN_PCT / ZQ_TM_SIG_MAX_PCT: clamp on the combined
    /// (multiplicative) signal factor.
    sig_min_pct: u32 = 40,
    sig_max_pct: u32 = 250,

    pub fn signalsEnabled(self: TmConfig) bool {
        return self.nf or self.bm or self.sc;
    }
};

pub fn loadTmConfigFromEnv() TmConfig {
    const a = std.heap.page_allocator;
    var cfg = TmConfig{};
    cfg.clamp_fix = envFlag(a, "ZQ_TM_CLAMP") orelse cfg.clamp_fix;
    cfg.opt_pct = envU32(a, "ZQ_TM_OPT_PCT") orelse cfg.opt_pct;
    cfg.max_growth_pct = envU32(a, "ZQ_TM_MAX_GROWTH_PCT") orelse cfg.max_growth_pct;
    cfg.max_fraction_divisor = envU32(a, "ZQ_TM_MAX_FRAC_DIV") orelse cfg.max_fraction_divisor;
    cfg.phase = envFlag(a, "ZQ_TM_PHASE") orelse cfg.phase;
    cfg.phase_max_pct = envU32(a, "ZQ_TM_PHASE_MAX_PCT") orelse cfg.phase_max_pct;
    cfg.phase_min_pct = envU32(a, "ZQ_TM_PHASE_MIN_PCT") orelse cfg.phase_min_pct;
    cfg.phase_half_moves = envU32(a, "ZQ_TM_PHASE_HALF") orelse cfg.phase_half_moves;
    cfg.nf = envFlag(a, "ZQ_TM_NF") orelse cfg.nf;
    cfg.nf_base_pct = envU32(a, "ZQ_TM_NF_BASE_PCT") orelse cfg.nf_base_pct;
    cfg.nf_slope_pct = envU32(a, "ZQ_TM_NF_SLOPE_PCT") orelse cfg.nf_slope_pct;
    cfg.bm = envFlag(a, "ZQ_TM_BM") orelse cfg.bm;
    cfg.bm_max_pct = envU32(a, "ZQ_TM_BM_MAX_PCT") orelse cfg.bm_max_pct;
    cfg.bm_min_pct = envU32(a, "ZQ_TM_BM_MIN_PCT") orelse cfg.bm_min_pct;
    cfg.bm_step_pct = envU32(a, "ZQ_TM_BM_STEP_PCT") orelse cfg.bm_step_pct;
    cfg.sc = envFlag(a, "ZQ_TM_SC") orelse cfg.sc;
    cfg.sc_drop_pct_per_10cp = envU32(a, "ZQ_TM_SC_DROP_PCT") orelse cfg.sc_drop_pct_per_10cp;
    cfg.sc_max_extra_pct = envU32(a, "ZQ_TM_SC_MAX_PCT") orelse cfg.sc_max_extra_pct;
    cfg.sc_stable_pct = envU32(a, "ZQ_TM_SC_STABLE_PCT") orelse cfg.sc_stable_pct;
    cfg.sig_min_pct = envU32(a, "ZQ_TM_SIG_MIN_PCT") orelse cfg.sig_min_pct;
    cfg.sig_max_pct = envU32(a, "ZQ_TM_SIG_MAX_PCT") orelse cfg.sig_max_pct;
    return cfg;
}

/// Process-wide cached config. Read once on first use; the UCI worker, the
/// engine and the tools all see the same snapshot, so a search is internally
/// consistent even if the environment mutates mid-process.
var tm_config_cache: ?TmConfig = null;

pub fn tmConfig() TmConfig {
    if (tm_config_cache == null) tm_config_cache = loadTmConfigFromEnv();
    return tm_config_cache.?;
}

fn envU32(allocator: std.mem.Allocator, name: []const u8) ?u32 {
    const text = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(text);
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn envFlag(allocator: std.mem.Allocator, name: []const u8) ?bool {
    const parsed = envU32(allocator, name) orelse return null;
    return parsed != 0;
}

pub const Plan = struct {
    optimum_ms: u64,
    maximum_ms: u64,
};

pub const Limits = struct {
    depth: ?u16 = null,
    node_limit: ?u64 = null,
    optimum_budget_ns: ?u64 = null,
    /// Live Controller deadline. Sudden-death clock searches start with the
    /// legacy 50/8 ceiling; the engine may replace it with the stored wider
    /// ceiling only after a completed unstable iteration.
    maximum_budget_ns: ?u64 = null,
    wider_maximum_budget_ns: ?u64 = null,
    /// Preserve the UCI `go infinite` intent after GoLimits is converted so
    /// search policy cannot treat the request like a finite depth-64 search.
    infinite: bool = false,

    pub fn hasFiniteLimit(self: Limits) bool {
        return !self.infinite and (self.depth != null or
            self.node_limit != null or
            self.optimum_budget_ns != null or
            self.maximum_budget_ns != null);
    }
};

pub const GoLimits = struct {
    depth: ?u16 = null,
    movetime_ms: ?u64 = null,
    node_limit: ?u64 = null,
    wtime_ms: ?u64 = null,
    btime_ms: ?u64 = null,
    winc_ms: u64 = 0,
    binc_ms: u64 = 0,
    movestogo: ?u32 = null,
    infinite: bool = false,

    pub fn hasExplicitLimit(self: GoLimits) bool {
        return self.depth != null or
            self.movetime_ms != null or
            self.node_limit != null or
            self.wtime_ms != null or
            self.btime_ms != null or
            self.infinite;
    }

    pub fn plan(self: GoLimits, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) ?Plan {
        return self.planWithConfig(tmConfig(), side, move_overhead_ms, fullmove_number);
    }

    pub fn planWithConfig(self: GoLimits, cfg: TmConfig, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) ?Plan {
        if (self.infinite) return null;

        if (self.movetime_ms) |ms| {
            // Exact per-move budget: neither the phase ramp nor the clamp fix
            // applies (there is no clock to protect or redistribute).
            const maximum_ms = @max(@as(u64, 1), ms);
            const optimum_ms = @max(@as(u64, 1), (maximum_ms * 17) / 20);
            return .{ .optimum_ms = optimum_ms, .maximum_ms = maximum_ms };
        }

        const remaining = switch (side) {
            .white => self.wtime_ms,
            .black => self.btime_ms,
        } orelse return null;
        const increment = switch (side) {
            .white => self.winc_ms,
            .black => self.binc_ms,
        };
        const hard_cap = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
        const phase_pct: u64 = if (cfg.phase) phaseFactorPct(cfg, fullmove_number) else 100;
        // r2 spend-level scale composes with the phase ramp; 100 * 100 / 100
        // keeps the legacy value exactly (bit-identity at defaults).
        const spend_pct: u64 = phase_pct * @max(@as(u64, 1), cfg.opt_pct) / 100;

        if (self.movestogo) |moves_to_go| {
            return planMovesToGo(cfg, remaining, increment, move_overhead_ms, moves_to_go, hard_cap, spend_pct);
        }

        return planSuddenDeath(cfg, remaining, increment, move_overhead_ms, hard_cap, spend_pct);
    }

    pub fn toControllerLimits(self: GoLimits, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) Limits {
        var limits = Limits{
            .depth = self.depth,
            .node_limit = self.node_limit,
            .infinite = self.infinite,
        };

        const cfg = tmConfig();
        if (self.planWithConfig(cfg, side, move_overhead_ms, fullmove_number)) |timing| {
            limits.optimum_budget_ns = timing.optimum_ms * std.time.ns_per_ms;
            limits.maximum_budget_ns = timing.maximum_ms * std.time.ns_per_ms;

            // Fixed movetime and moves-to-go retain their single deadline.
            // Only sudden-death clock searches store a second, instability-
            // armed ceiling; their live Controller deadline starts at 50/8.
            if (self.movetime_ms == null and self.movestogo == null) {
                var legacy_cfg = cfg;
                legacy_cfg.max_growth_pct = 50;
                legacy_cfg.max_fraction_divisor = 8;
                const legacy = self.planWithConfig(legacy_cfg, side, move_overhead_ms, fullmove_number).?;
                limits.maximum_budget_ns = legacy.maximum_ms * std.time.ns_per_ms;
                limits.wider_maximum_budget_ns = timing.maximum_ms * std.time.ns_per_ms;
            }
        }

        return limits;
    }
};

/// Game-phase ramp factor (percent) for full-move number m:
///   pct(m) = min + (max - min) * H / (H + (m - 1))
/// Move 1 gets max%, the halfway point sits at move H+1, late game decays
/// toward min%. The clock naturally re-normalizes overspend/underspend (each
/// move re-divides the REMAINING time), so this redistributes thinking time
/// toward the opening/early middlegame rather than spending extra overall.
pub fn phaseFactorPct(cfg: TmConfig, fullmove_number: u16) u64 {
    const m: u64 = @max(1, fullmove_number);
    const h: u64 = @max(1, cfg.phase_half_moves);
    const max_pct: u64 = cfg.phase_max_pct;
    const min_pct: u64 = @min(cfg.phase_min_pct, max_pct);
    const span = max_pct - min_pct;
    return min_pct + span * h / (h + (m - 1));
}

/// Legacy return path vs the ZQ_TM_CLAMP fix. Legacy raises maximum up to
/// optimum even when optimum overshot the remaining-clock hard cap (the
/// documented flag-risk defect); the fix clamps optimum down instead so no
/// budget ever exceeds hard_cap.
fn finishPlan(cfg: TmConfig, optimum_ms: u64, maximum_ms: u64, hard_cap: u64) Plan {
    if (cfg.clamp_fix) {
        const capped_maximum = @max(@as(u64, 1), @min(maximum_ms, hard_cap));
        const capped_optimum = @max(@as(u64, 1), @min(optimum_ms, capped_maximum));
        return .{ .optimum_ms = capped_optimum, .maximum_ms = capped_maximum };
    }
    return .{ .optimum_ms = optimum_ms, .maximum_ms = @max(optimum_ms, maximum_ms) };
}

fn planMovesToGo(cfg: TmConfig, remaining: u64, increment: u64, move_overhead_ms: u64, moves_to_go: u32, hard_cap: u64, spend_pct: u64) Plan {
    const mtg = std.math.clamp(moves_to_go, 1, 50);
    const reserve = move_overhead_ms * (@as(u64, mtg) + 2);
    const future_increment = increment * (@as(u64, mtg) - 1);
    const time_pool = if (remaining + future_increment > reserve)
        remaining + future_increment - reserve
    else
        1;

    var optimum_ms = @max(@as(u64, 1), time_pool / mtg);
    // Phase/spend scale on the raw optimum; the low-time emergency cap below
    // still applies afterwards, so safety clamps always win.
    optimum_ms = @max(@as(u64, 1), optimum_ms * spend_pct / 100);
    if (remaining <= LOW_TIME_THRESHOLD_MS) {
        const safe_remaining = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
        const emergency_cap = @max(@as(u64, 1), safe_remaining / 16 + increment / 4);
        optimum_ms = @min(optimum_ms, emergency_cap);
    }

    var maximum_ms = optimum_ms + @max(@as(u64, 1), optimum_ms / 2);
    maximum_ms = @min(maximum_ms, hard_cap);
    return finishPlan(cfg, optimum_ms, maximum_ms, hard_cap);
}

fn planSuddenDeath(cfg: TmConfig, remaining: u64, increment: u64, move_overhead_ms: u64, hard_cap: u64, spend_pct: u64) Plan {
    const safe_remaining = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
    const divisor: u64 = if (remaining <= LOW_TIME_THRESHOLD_MS)
        LOW_TIME_DIVISOR
    else if (increment == 0)
        SUDDEN_DEATH_NO_INCREMENT_DIVISOR
    else
        SUDDEN_DEATH_DIVISOR;

    var optimum_ms = safe_remaining / divisor;
    optimum_ms += increment / 4;
    // Phase/spend scale on the raw optimum; the low-time emergency cap below
    // still applies afterwards, so safety clamps always win.
    optimum_ms = optimum_ms * spend_pct / 100;
    optimum_ms = @max(@as(u64, 1), optimum_ms);

    if (remaining <= LOW_TIME_THRESHOLD_MS) {
        const emergency_cap = @max(@as(u64, 1), safe_remaining / 16 + increment / 4);
        optimum_ms = @min(optimum_ms, emergency_cap);
    }

    // Burst headroom applies only while there is a clock to burst from; inside
    // the low-time regime the legacy 1.5x ceiling stands (safety clamps win).
    const growth_pct: u64 = if (remaining <= LOW_TIME_THRESHOLD_MS) 50 else cfg.max_growth_pct;
    const fraction_divisor: u64 = if (remaining <= LOW_TIME_THRESHOLD_MS) 8 else @max(@as(u64, 1), cfg.max_fraction_divisor);
    const growth_margin = @max(@as(u64, 1), @max(optimum_ms * growth_pct / 100, increment / 2));
    const fraction_cap = @max(@as(u64, 1), safe_remaining / fraction_divisor + increment / 2);
    var maximum_ms = optimum_ms + growth_margin;
    maximum_ms = @min(maximum_ms, fraction_cap);
    maximum_ms = @min(maximum_ms, hard_cap);

    return finishPlan(cfg, optimum_ms, maximum_ms, hard_cap);
}

/// Per-iteration inputs for the three-signal soft-limit scaler. All values are
/// deterministic functions of the completed iteration (no wall clock), so the
/// scaler is unit-testable and fixed-depth searches remain bit-identical.
pub const SignalInputs = struct {
    /// Permille of the last iteration's root nodes spent under the current
    /// best move. null = unavailable (no hints recorded).
    best_move_node_permille: ?u32 = null,
    /// Consecutive completed iterations (including this one) with the same
    /// best move; 1 means the best move just changed (or first iteration).
    best_move_streak: u32 = 1,
    /// Score drop vs the previous iteration in cp (positive = current score is
    /// LOWER, i.e. the position is deteriorating). null = no previous iteration.
    score_drop_cp: ?i32 = null,
};

/// Combined multiplicative soft-limit factor in percent (100 = neutral).
/// Each enabled signal contributes one factor; the product is clamped to
/// [sig_min_pct, sig_max_pct]. With no signal enabled this returns 100.
pub fn signalScalePct(cfg: TmConfig, sig: SignalInputs) u32 {
    var total: u64 = 100;

    // Node-fraction: concentrated root effort = easy decision = spend less.
    if (cfg.nf) {
        if (sig.best_move_node_permille) |permille| {
            const p: u64 = @min(permille, 1000);
            const cut = @as(u64, cfg.nf_slope_pct) * p / 1000;
            const nf_pct = if (cfg.nf_base_pct > cut) @as(u64, cfg.nf_base_pct) - cut else 1;
            total = total * nf_pct / 100;
        }
    }

    // Best-move stability: a fresh change extends, a long streak shrinks.
    if (cfg.bm) {
        const streak: u64 = @max(1, sig.best_move_streak);
        const cut = @as(u64, cfg.bm_step_pct) * (streak - 1);
        const floor: u64 = cfg.bm_min_pct;
        const bm_pct = if (@as(u64, cfg.bm_max_pct) > cut + floor)
            @as(u64, cfg.bm_max_pct) - cut
        else
            floor;
        total = total * bm_pct / 100;
    }

    // Score trend: a falling score extends; flat/rising uses the stable knob.
    if (cfg.sc) {
        if (sig.score_drop_cp) |drop_raw| {
            const sc_pct: u64 = if (drop_raw > 0) blk: {
                const drop: u64 = @intCast(@min(drop_raw, 10_000));
                break :blk 100 + @min(drop * cfg.sc_drop_pct_per_10cp / 10, cfg.sc_max_extra_pct);
            } else cfg.sc_stable_pct;
            total = total * sc_pct / 100;
        }
    }

    const lo: u64 = @max(1, cfg.sig_min_pct);
    const hi: u64 = @max(lo, cfg.sig_max_pct);
    return @intCast(std.math.clamp(total, lo, hi));
}

pub const StopNowReason = enum {
    external,
    node_limit,
    maximum_budget,
};

pub const Controller = struct {
    stop_flag: *const std.atomic.Value(bool),
    limits: Limits,
    legacy_maximum_budget_ns: ?u64 = null,
    timer: ?std.time.Timer = null,

    pub fn init(stop_flag: *const std.atomic.Value(bool), limits: Limits) Controller {
        return .{
            .stop_flag = stop_flag,
            .limits = limits,
            .legacy_maximum_budget_ns = limits.maximum_budget_ns,
            .timer = std.time.Timer.start() catch null,
        };
    }

    /// Select the deadline for the next iteration. The engine calls this only
    /// after a completed iteration, so an unfinished iteration can never arm
    /// its own extra headroom.
    pub fn setWiderMaximumArmed(self: *Controller, armed: bool) void {
        self.limits.maximum_budget_ns = if (armed)
            self.limits.wider_maximum_budget_ns orelse self.legacy_maximum_budget_ns
        else
            self.legacy_maximum_budget_ns;
    }

    pub fn elapsedNs(self: *Controller) u64 {
        if (self.timer) |*timer| return timer.read();
        return 0;
    }

    pub fn stopReasonNow(self: *Controller, nodes: u64) ?StopNowReason {
        if (self.stop_flag.load(.acquire)) return .external;
        if (self.limits.node_limit) |limit| {
            if (nodes >= limit) return .node_limit;
        }
        // The wall-clock read (clock_gettime) is ~4% of search time when done every
        // node; throttle it to every 1024 nodes. node_limit + external stop stay exact
        // every node; the time deadline can overshoot by <=1023 nodes (<~1ms at our
        // nps), which is negligible vs any move budget. Fixed-nodes search is unaffected.
        if (self.limits.maximum_budget_ns) |budget_ns| {
            if (nodes & 1023 == 0 and self.elapsedNs() >= budget_ns) return .maximum_budget;
        }
        return null;
    }

    pub fn shouldStopNow(self: *Controller, nodes: u64) bool {
        return self.stopReasonNow(nodes) != null;
    }
};

test "controller stops at node limit" {
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .node_limit = 8 });

    try std.testing.expect(!controller.shouldStopNow(7));
    try std.testing.expect(controller.shouldStopNow(8));
}

test "opt_pct: default ships 130, 100 recovers legacy exactly" {
    const base = GoLimits{ .wtime_ms = 60_000, .winc_ms = 600 };
    const legacy = base.planWithConfig(.{ .opt_pct = 100 }, .white, 20, 10).?;
    const at130 = base.planWithConfig(.{ .opt_pct = 130 }, .white, 20, 10).?;
    try std.testing.expectEqual(legacy.optimum_ms * 130 / 100, at130.optimum_ms);
    // r6 lane 1: at a comfortable clock the hard budget is the clock fraction,
    // not an optimum multiple, so the spend level no longer moves the ceiling.
    try std.testing.expect(at130.maximum_ms >= legacy.maximum_ms);
    try std.testing.expect(at130.maximum_ms >= at130.optimum_ms * 5 / 2);

    // The shipped default IS 130.
    const default_plan = base.planWithConfig(.{}, .white, 20, 10).?;
    try std.testing.expectEqual(at130.optimum_ms, default_plan.optimum_ms);
    try std.testing.expectEqual(at130.maximum_ms, default_plan.maximum_ms);

    // Low-clock emergency cap still wins over a raised spend level:
    // optimum may never exceed safe_remaining/16 + inc/4 in the low-time regime.
    const scramble = GoLimits{ .wtime_ms = 800, .winc_ms = 100 };
    const hot = scramble.planWithConfig(.{ .opt_pct = 200 }, .white, 20, 60).?;
    const emergency_cap: u64 = (800 - 20) / 16 + 100 / 4;
    try std.testing.expect(hot.optimum_ms <= emergency_cap);
}

test "go limits compute sudden-death plan with wider hard headroom" {
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100 }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 1_499), plan.optimum_ms);
    // 29_980/6 + 500: the clock fraction binds before the 4x optimum multiple.
    try std.testing.expectEqual(@as(u64, 5_496), plan.maximum_ms);

    // 50 / 8 recovers the pre-r6 ceiling (optimum + optimum/2) exactly.
    const legacy_ceiling = TmConfig{ .opt_pct = 100, .max_growth_pct = 50, .max_fraction_divisor = 8 };
    const legacy = limits.planWithConfig(legacy_ceiling, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 1_499), legacy.optimum_ms);
    try std.testing.expectEqual(@as(u64, 2_248), legacy.maximum_ms);
}

test "burst headroom stays inside the clock and stands down in time trouble" {
    // Comfortable clock: the hard budget is 2-4x the soft one, never more than
    // the remaining/6 fraction and never past the remaining-clock hard cap.
    const cases = [_]GoLimits{
        .{ .wtime_ms = 180_000, .winc_ms = 1_000 },
        .{ .wtime_ms = 60_000, .winc_ms = 600 },
        .{ .wtime_ms = 20_000, .winc_ms = 200 },
        .{ .wtime_ms = 8_000, .winc_ms = 80 },
        .{ .wtime_ms = 3_000, .winc_ms = 100 },
        .{ .wtime_ms = 30_000, .winc_ms = 0 },
    };
    for (cases) |limits| {
        const plan = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 20).?;
        const remaining = limits.wtime_ms.?;
        const safe = remaining - DEFAULT_MOVE_OVERHEAD_MS;
        try std.testing.expect(plan.maximum_ms >= plan.optimum_ms * 2);
        try std.testing.expect(plan.maximum_ms <= plan.optimum_ms * 4);
        try std.testing.expect(plan.maximum_ms <= safe / 6 + limits.winc_ms / 2);
        try std.testing.expect(plan.maximum_ms <= safe);
    }

    // Low-time regime (<= 1s left): the legacy 1.5x ceiling still applies, so
    // the scramble behaviour is bit-identical to the head (values pinned).
    const scramble = [_]struct { limits: GoLimits, optimum: u64, maximum: u64 }{
        .{ .limits = .{ .wtime_ms = 1_000, .winc_ms = 100 }, .optimum = 71, .maximum = 121 },
        .{ .limits = .{ .wtime_ms = 500, .winc_ms = 50 }, .optimum = 35, .maximum = 60 },
        .{ .limits = .{ .wtime_ms = 100, .winc_ms = 1_000 }, .optimum = 255, .maximum = 255 },
    };
    for (scramble) |case| {
        const plan = case.limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 60).?;
        try std.testing.expectEqual(case.optimum, plan.optimum_ms);
        try std.testing.expectEqual(case.maximum, plan.maximum_ms);
    }
}

test "go limits compute moves-to-go plan with wider hard headroom" {
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
        .movestogo = 40,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100 }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 1_704), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 2_556), plan.maximum_ms);
}

test "go limits keep some safety margin under short time controls" {
    const limits = GoLimits{
        .wtime_ms = 500,
        .winc_ms = 50,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100 }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 27), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 52), plan.maximum_ms);
}

test "go limits keep short moves-to-go plans on low time" {
    const limits = GoLimits{
        .wtime_ms = 500,
        .winc_ms = 50,
        .movestogo = 10,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100 }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 42), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 63), plan.maximum_ms);
}

// PINNED DEFECT (default-off documents it; ZQ_TM_CLAMP fixes it): with 100ms
// on the clock and a 1s increment, the legacy sudden-death plan lets the
// unclamped increment/4 optimum term drag `maximum` to 252ms — past the 80ms
// remaining-clock hard cap. Spending it forfeits on time; the increment lands
// only AFTER the move is played.
test "legacy sudden-death budget exceeds the clock at increment-heavy low time" {
    const limits = GoLimits{
        .wtime_ms = 100,
        .winc_ms = 1_000,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100 }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 252), plan.optimum_ms);
    try std.testing.expectEqual(@as(u64, 252), plan.maximum_ms); // > 80ms hard cap
}

test "clamp fix keeps sudden-death budgets inside the remaining clock" {
    const cfg = TmConfig{ .clamp_fix = true };
    const limits = GoLimits{
        .wtime_ms = 100,
        .winc_ms = 1_000,
    };

    const plan = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 80), plan.maximum_ms); // hard cap: 100 - 20 overhead
    try std.testing.expectEqual(@as(u64, 80), plan.optimum_ms);
}

test "clamp fix keeps moves-to-go budgets inside the remaining clock" {
    const cfg = TmConfig{ .clamp_fix = true };
    const limits = GoLimits{
        .wtime_ms = 100,
        .winc_ms = 1_000,
        .movestogo = 40,
    };

    const legacy = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 255), legacy.maximum_ms); // pinned defect, > 80ms cap

    const fixed = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 80), fixed.maximum_ms);
    try std.testing.expectEqual(@as(u64, 80), fixed.optimum_ms);
}

test "clamp fix leaves comfortable-clock plans unchanged" {
    const cfg = TmConfig{ .clamp_fix = true };
    const cases = [_]GoLimits{
        .{ .wtime_ms = 30_000, .winc_ms = 1_000 },
        .{ .wtime_ms = 30_000, .winc_ms = 0 },
        .{ .wtime_ms = 30_000, .winc_ms = 1_000, .movestogo = 40 },
        .{ .wtime_ms = 500, .winc_ms = 50 },
        .{ .wtime_ms = 500, .winc_ms = 50, .movestogo = 10 },
        .{ .wtime_ms = 60_000, .winc_ms = 600 },
        .{ .wtime_ms = 8_000, .winc_ms = 80 },
    };
    for (cases) |limits| {
        const legacy = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
        const fixed = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
        try std.testing.expectEqual(legacy.optimum_ms, fixed.optimum_ms);
        try std.testing.expectEqual(legacy.maximum_ms, fixed.maximum_ms);
    }
}

test "phase factor decays hyperbolically from max toward min" {
    const cfg = TmConfig{ .phase = true }; // defaults: max 140, min 80, half 24
    const cases = [_]struct { m: u16, pct: u64 }{
        .{ .m = 1, .pct = 140 },
        .{ .m = 10, .pct = 123 },
        .{ .m = 25, .pct = 110 }, // half+1: halfway from 140 to 80
        .{ .m = 49, .pct = 100 }, // neutral crossing
        .{ .m = 97, .pct = 92 },
        .{ .m = 400, .pct = 83 }, // approaching the 80 floor
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.pct, phaseFactorPct(cfg, case.m));
    }
    // Monotone non-increasing over the whole clock.
    var m: u16 = 2;
    while (m <= 200) : (m += 1) {
        try std.testing.expect(phaseFactorPct(cfg, m) <= phaseFactorPct(cfg, m - 1));
    }
    // Degenerate config (min > max) collapses to max, never traps.
    const inverted = TmConfig{ .phase = true, .phase_max_pct = 90, .phase_min_pct = 120 };
    try std.testing.expectEqual(@as(u64, 90), phaseFactorPct(inverted, 1));
    try std.testing.expectEqual(@as(u64, 90), phaseFactorPct(inverted, 60));
}

test "phase ramp scales sudden-death optimum by game progress" {
    const cfg = TmConfig{ .phase = true, .opt_pct = 100 };
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
    };

    // Move 1: 140% of the base 1499ms optimum. The hard budget is the
    // remaining/6 clock fraction (5_496ms) for every phase here.
    const early = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 2_098), early.optimum_ms);
    try std.testing.expectEqual(@as(u64, 5_496), early.maximum_ms);

    // Move 49: neutral crossing — identical to the un-ramped plan.
    const neutral = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 49).?;
    try std.testing.expectEqual(@as(u64, 1_499), neutral.optimum_ms);
    try std.testing.expectEqual(@as(u64, 5_496), neutral.maximum_ms);

    // Move 200: late game shrinks toward the floor.
    const late = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 200).?;
    try std.testing.expectEqual(@as(u64, 1_289), late.optimum_ms);
    try std.testing.expectEqual(@as(u64, 5_156), late.maximum_ms);
}

test "phase ramp never overrides the low-time emergency cap" {
    const cfg = TmConfig{ .phase = true };
    const limits = GoLimits{
        .wtime_ms = 200,
        .winc_ms = 1_000,
    };

    // Base optimum 255ms would ramp to 357ms at move 1, but the low-time
    // emergency cap (180/16 + 250 = 261ms) still binds.
    const plan = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 261), plan.optimum_ms);
}

test "phase ramp leaves movetime budgets alone" {
    const cfg = TmConfig{ .phase = true };
    const limits = GoLimits{ .movetime_ms = 1_000 };

    const ramped = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    const base = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(base.optimum_ms, ramped.optimum_ms);
    try std.testing.expectEqual(base.maximum_ms, ramped.maximum_ms);
}

test "phase ramp off is bit-identical across the full-move clock" {
    const limits = GoLimits{
        .wtime_ms = 30_000,
        .winc_ms = 1_000,
    };
    const base = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    const moves = [_]u16{ 1, 2, 15, 40, 90, 300 };
    for (moves) |m| {
        const p = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, m).?;
        try std.testing.expectEqual(base.optimum_ms, p.optimum_ms);
        try std.testing.expectEqual(base.maximum_ms, p.maximum_ms);
    }
}

test "tm config defaults keep every signal mechanism off" {
    const cfg = TmConfig{};
    try std.testing.expect(!cfg.clamp_fix);
    try std.testing.expect(!cfg.phase);
    try std.testing.expect(!cfg.signalsEnabled());
    // Shipped levels: r2 spend 130, r6 burst headroom 300/6.
    try std.testing.expectEqual(@as(u32, 130), cfg.opt_pct);
    try std.testing.expectEqual(@as(u32, 300), cfg.max_growth_pct);
    try std.testing.expectEqual(@as(u32, 6), cfg.max_fraction_divisor);
}

test "signal scale is neutral with no signal enabled" {
    const sig = SignalInputs{ .best_move_node_permille = 900, .best_move_streak = 9, .score_drop_cp = 300 };
    try std.testing.expectEqual(@as(u32, 100), signalScalePct(.{}, sig));
}

test "node-fraction signal shrinks with concentrated root effort" {
    const cfg = TmConfig{ .nf = true }; // base 145, slope 65
    const cases = [_]struct { permille: ?u32, pct: u32 }{
        .{ .permille = 0, .pct = 145 },
        .{ .permille = 300, .pct = 126 },
        .{ .permille = 700, .pct = 100 },
        .{ .permille = 1000, .pct = 80 },
        .{ .permille = null, .pct = 100 }, // unavailable = neutral
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.pct, signalScalePct(cfg, .{ .best_move_node_permille = case.permille }));
    }
}

test "best-move stability signal decays from fresh-change boost to floor" {
    const cfg = TmConfig{ .bm = true }; // max 130, step 6, min 85
    const cases = [_]struct { streak: u32, pct: u32 }{
        .{ .streak = 1, .pct = 130 },
        .{ .streak = 4, .pct = 112 },
        .{ .streak = 8, .pct = 88 },
        .{ .streak = 10, .pct = 85 },
        .{ .streak = 60, .pct = 85 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.pct, signalScalePct(cfg, .{ .best_move_streak = case.streak }));
    }
}

test "score-trend signal extends on drops and honours the stable knob" {
    const cfg = TmConfig{ .sc = true }; // 4%/10cp, +60 cap, stable 100
    const cases = [_]struct { drop: ?i32, pct: u32 }{
        .{ .drop = null, .pct = 100 }, // first iteration = neutral
        .{ .drop = -30, .pct = 100 }, // rising score = stable knob (default neutral)
        .{ .drop = 0, .pct = 100 },
        .{ .drop = 50, .pct = 120 },
        .{ .drop = 200, .pct = 160 }, // capped at +60
        .{ .drop = 5_000, .pct = 160 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.pct, signalScalePct(cfg, .{ .score_drop_cp = case.drop }));
    }

    const saver = TmConfig{ .sc = true, .sc_stable_pct = 90 };
    try std.testing.expectEqual(@as(u32, 90), signalScalePct(saver, .{ .score_drop_cp = -10 }));
}

test "signals combine multiplicatively and clamp" {
    const cfg = TmConfig{ .nf = true, .bm = true, .sc = true };
    // 80% (frac 1.0) * 85% (streak 10) * 160% (drop 200) = 108%.
    try std.testing.expectEqual(@as(u32, 108), signalScalePct(cfg, .{
        .best_move_node_permille = 1000,
        .best_move_streak = 10,
        .score_drop_cp = 200,
    }));

    // Product below the floor clamps to sig_min_pct.
    const shrinker = TmConfig{ .nf = true, .bm = true, .sc = true, .sc_stable_pct = 50 };
    try std.testing.expectEqual(@as(u32, 40), signalScalePct(shrinker, .{
        .best_move_node_permille = 1000,
        .best_move_streak = 10,
        .score_drop_cp = 0,
    }));

    // Product above the ceiling clamps to sig_max_pct.
    const booster = TmConfig{ .nf = true, .bm = true, .sc = true, .nf_base_pct = 200, .bm_max_pct = 200, .sig_max_pct = 250 };
    try std.testing.expectEqual(@as(u32, 250), signalScalePct(booster, .{
        .best_move_node_permille = 0,
        .best_move_streak = 1,
        .score_drop_cp = 500,
    }));
}

test "go limit conversion carries node limits and deadlines" {
    const limits = GoLimits{ .depth = 4, .node_limit = 128, .movetime_ms = 20 };
    const converted = limits.toControllerLimits(.white, DEFAULT_MOVE_OVERHEAD_MS, 1);
    try std.testing.expectEqual(@as(?u16, 4), converted.depth);
    try std.testing.expectEqual(@as(?u64, 128), converted.node_limit);
    try std.testing.expect(converted.optimum_budget_ns != null);
    try std.testing.expect(converted.maximum_budget_ns != null);
}

test "go infinite remains marked as unlimited after conversion" {
    const converted = (GoLimits{ .infinite = true }).toControllerLimits(.white, DEFAULT_MOVE_OVERHEAD_MS, 1);
    try std.testing.expect(converted.infinite);
    try std.testing.expect(!converted.hasFiniteLimit());
}
