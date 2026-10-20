const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const types = @import("../core/types.zig");

pub const DEFAULT_MOVE_OVERHEAD_MS: u64 = 20;
const LOW_TIME_THRESHOLD_MS: u64 = 1_000;
const SUDDEN_DEATH_DIVISOR: u64 = 24;
const SUDDEN_DEATH_NO_INCREMENT_DIVISOR: u64 = 28;
const LOW_TIME_DIVISOR: u64 = 32;

/// TM arc r1 (2026-08-06): the phase and signal mechanisms below are env-gated
/// and DEFAULT OFF. Knob reference lives in docs/archive/TIME_MANAGEMENT.md.
///
/// Gates (booleans, set =1 to enable, =0 to disable):
///   ZQ_TM_CLAMP  — DEFAULT ON since 2026-09-30: clamp optimum (and thus the
///                  returned maximum) to the remaining-clock hard cap. Without
///                  it a plan can exceed the clock in two regimes: the last
///                  move before a time control (movestogo 1 plans 130% of the
///                  remaining clock at the shipped spend level) and
///                  increment-heavy low clocks (100ms left + 1s inc plans
///                  255ms). ZQ_TM_CLAMP=0 recovers the 6.0.0–6.3.0 plans.
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
    /// ZQ_TM_CLAMP: no plan may exceed the remaining clock (see above).
    clamp_fix: bool = true,

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

    /// ZQ_TM_V2: TM v2 clock model and soft stop (docs/research/
    /// TM_V2_DESIGN_2026-10-13.md, step 2). Struct default off; the engine
    /// process turns it on (`loadTmConfigFromEnv`), and ZQ_TM_V2=0 restores
    /// exactly the 6.4.0 plans and stops. Clock searches only; movetime, depth and
    /// node limits are unchanged. With an increment the target is
    ///   T = inc + (R - reserve) / horizon - overhead   (>= floor% of inc)
    /// so the full increment is spent and the clock settles at an explicit
    /// reserve instead of the ~20 increments the legacy plan strands. The
    /// hard budget lets one move draw on that reserve:
    ///   M = min(T * burst%, T + share% * (R - inc - 4*overhead - T)).
    /// Without increment T = (R - overhead) / horizon0 and the share is
    /// share0%. With movestogo the horizon is min(movestogo, horizon) and the
    /// period's safety margin replaces the reserve.
    v2: bool = false,
    /// ZQ_TM_V2_H / ZQ_TM_V2_H0: planning horizon in moves with / without an
    /// increment (our T1 gauntlet front-loads like the field at ~24; the
    /// log-return optimum on our game lengths is 21-31 after move 60).
    v2_horizon_inc: u32 = 24,
    v2_horizon_noinc: u32 = 28,
    /// ZQ_TM_V2_RES: reserve target in percent of the increment (1000 = 10
    /// increments; the 6.4.0 T1 games end with a median 28).
    v2_reserve_inc_pct: u32 = 1000,
    /// ZQ_TM_V2_FLOOR: lower bound on T while the clock is under the reserve,
    /// percent of the increment.
    v2_floor_inc_pct: u32 = 40,
    /// ZQ_TM_V2_BURST: hard budget at most this percent of T.
    v2_burst_pct: u32 = 500,
    /// ZQ_TM_V2_SHARE / ZQ_TM_V2_SHARE0: percent of the clock above the
    /// target one move may draw, with / without an increment.
    v2_share_inc_pct: u32 = 40,
    v2_share_noinc_pct: u32 = 15,
    /// ZQ_TM_V2_FORCED: target percent when the root has one legal move.
    v2_forced_pct: u32 = 25,
    /// ZQ_TM_V2_C3: TM v2 step 3, graded stop urgency (design doc, "Step 3
    /// spec"). Struct default off; the engine process turns it on, and
    /// ZQ_TM_V2_C3=0 restores step 2's yes/no soft arm exactly. On a v2 clock
    /// search every completed iteration re-arms the soft deadline at
    ///   T * clamp(K * u(streak), 0.5, burst / T)
    /// where streak counts the completed iterations since the best move last
    /// changed or the score jumped >= 80 cp, and u is the fitted relative
    /// chance that one more doubling changes the move (`c3UrgencyPermille`).
    /// The root's fail-low/challenger disarm and the forced-move 25 % target
    /// (with step 2's arm) are unchanged. Low-clock guard (`c3LowClock`):
    /// when a move that ran to the burst cap would leave less than the
    /// reserve target, the multiplier is capped at 1.0 for that move.
    v2_c3: bool = false,
    /// ZQ_TM_V2_C3_K: the budget constant K in percent. 120 matches step 2's
    /// spend near 1M nodes per move (about 20+0.2 on a Zen 3 core) in the warm-hash
    /// policy simulation (vot/FIT-WARM.md). Multipliers: streak 0 -> the
    /// burst cap, 1-3 -> 3.4 T, 4-11 -> 1.7 T, 12-19 -> 0.77 T, 20+ -> 0.5 T.
    v2_c3_k_pct: u32 = 120,
    /// ZQ_TM_TRACE: emit `info string tm ...` lines (plan, each completed
    /// iteration, stop) for clock audits and the value-of-time dataset.
    trace: bool = false,

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
    // Process default since the 6.5 merge (2026-10-15): the engine runs TM v2
    // unless ZQ_TM_V2=0 (6.4.0 plans). The struct default stays legacy so the
    // planner tests keep their explicit configurations.
    cfg.v2 = envFlag(a, "ZQ_TM_V2") orelse true;
    cfg.v2_horizon_inc = @max(1, envU32(a, "ZQ_TM_V2_H") orelse cfg.v2_horizon_inc);
    cfg.v2_horizon_noinc = @max(1, envU32(a, "ZQ_TM_V2_H0") orelse cfg.v2_horizon_noinc);
    cfg.v2_reserve_inc_pct = envU32(a, "ZQ_TM_V2_RES") orelse cfg.v2_reserve_inc_pct;
    cfg.v2_floor_inc_pct = envU32(a, "ZQ_TM_V2_FLOOR") orelse cfg.v2_floor_inc_pct;
    cfg.v2_burst_pct = @max(100, envU32(a, "ZQ_TM_V2_BURST") orelse cfg.v2_burst_pct);
    cfg.v2_share_inc_pct = @min(100, envU32(a, "ZQ_TM_V2_SHARE") orelse cfg.v2_share_inc_pct);
    cfg.v2_share_noinc_pct = @min(100, envU32(a, "ZQ_TM_V2_SHARE0") orelse cfg.v2_share_noinc_pct);
    cfg.v2_forced_pct = @min(100, envU32(a, "ZQ_TM_V2_FORCED") orelse cfg.v2_forced_pct);
    // Process default since the 6.5 merge (2026-10-15): TM v2 runs with C3
    // unless ZQ_TM_V2_C3=0 (step 2) or ZQ_TM_V2=0 (legacy). The struct
    // default stays off so the planner tests keep their configurations.
    cfg.v2_c3 = envFlag(a, "ZQ_TM_V2_C3") orelse true;
    cfg.v2_c3_k_pct = envU32(a, "ZQ_TM_V2_C3_K") orelse cfg.v2_c3_k_pct;
    cfg.trace = envFlag(a, "ZQ_TM_TRACE") orelse cfg.trace;
    return cfg;
}

/// Process-wide snapshot frozen at first Engine construction or cold getter.
/// Engine-less tools/tests use the same acquire/release initialization boundary.
pub fn tmConfig() TmConfig {
    return @import("startup.zig").tmConfig();
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

/// Largest clock, increment or movetime the planner works with (about 34
/// years). UCI accepts any u64; larger values saturate here so the pool,
/// percentage and nanosecond arithmetic below cannot wrap.
pub const MAX_PLAN_INPUT_MS: u64 = 1 << 40;

pub const Plan = struct {
    optimum_ms: u64,
    maximum_ms: u64,
};

/// `low_clock` is a TM v2 C3 start state only: disarmed, and this move's C3
/// deadline may not stretch past the target (`c3LowClock`). The first
/// completed iteration replaces it with `armed`; until then it acts exactly
/// like `disarmed`.
pub const SoftStop = enum(u8) { off, armed, disarmed, low_clock };

pub const Limits = struct {
    depth: ?u16 = null,
    node_limit: ?u64 = null,
    optimum_budget_ns: ?u64 = null,
    /// Live Controller deadline. Sudden-death clock searches start with the
    /// legacy 50/8 ceiling; the engine may replace it with the stored wider
    /// ceiling only after a completed unstable iteration.
    maximum_budget_ns: ?u64 = null,
    wider_maximum_budget_ns: ?u64 = null,
    /// UCI `go mate N`: stop once a completed iteration proves a mate in N
    /// moves or fewer; 0 = not requested. Other limits still apply; alone it
    /// searches to the depth ceiling. A plain u16 on purpose: it sits in this
    /// struct's existing padding, so the search context keeps its layout.
    mate_in_moves: u16 = 0,
    /// Preserve the UCI `go infinite` intent after GoLimits is converted so
    /// search policy cannot treat the request like a finite depth-64 search.
    infinite: bool = false,
    /// TM v2 soft stop. `off` keeps the legacy controller exactly. In TM v2
    /// clock searches the optimum becomes an in-search deadline that only
    /// applies while `armed` (after a stable completed iteration, or any
    /// completed iteration under C3, and until the root reports a fail-low
    /// or a challenger). One byte in the
    /// existing padding: the search context keeps its layout.
    soft: SoftStop = .off,

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
    /// `go mate N`; 0 = not requested.
    mate_in_moves: u16 = 0,
    infinite: bool = false,

    pub fn hasExplicitLimit(self: GoLimits) bool {
        return self.depth != null or
            self.movetime_ms != null or
            self.node_limit != null or
            self.wtime_ms != null or
            self.btime_ms != null or
            self.mate_in_moves != 0 or
            self.infinite;
    }

    pub fn plan(self: GoLimits, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) ?Plan {
        return self.planWithConfig(tmConfig(), side, move_overhead_ms, fullmove_number);
    }

    pub fn planWithConfig(self: GoLimits, cfg: TmConfig, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) ?Plan {
        if (self.infinite) return null;

        if (self.movetime_ms) |raw_ms| {
            // Exact per-move budget: neither the phase ramp nor the clamp fix
            // applies (there is no clock to protect or redistribute).
            // Typed: @min with a comptime-known bound narrows to u41, and the
            // optimum's ×17 below would then overflow for clamped values.
            const ms: u64 = @min(raw_ms, MAX_PLAN_INPUT_MS);
            const maximum_ms = @max(@as(u64, 1), ms);
            const optimum_ms = @max(@as(u64, 1), (maximum_ms * 17) / 20);
            return .{ .optimum_ms = optimum_ms, .maximum_ms = maximum_ms };
        }

        const remaining: u64 = @min(switch (side) {
            .white => self.wtime_ms,
            .black => self.btime_ms,
        } orelse return null, MAX_PLAN_INPUT_MS);
        const increment: u64 = @min(switch (side) {
            .white => self.winc_ms,
            .black => self.binc_ms,
        }, MAX_PLAN_INPUT_MS);
        const hard_cap = @max(@as(u64, 1), if (remaining > move_overhead_ms) remaining - move_overhead_ms else 1);
        const phase_pct: u64 = if (cfg.phase) phaseFactorPct(cfg, fullmove_number) else 100;
        // r2 spend-level scale composes with the phase ramp; 100 * 100 / 100
        // keeps the legacy value exactly (bit-identity at defaults).
        const spend_pct: u64 = phase_pct * @max(@as(u64, 1), cfg.opt_pct) / 100;

        if (cfg.v2 and remaining > LOW_TIME_THRESHOLD_MS) {
            return planV2(cfg, remaining, increment, move_overhead_ms, self.movestogo, hard_cap);
        }

        if (self.movestogo) |moves_to_go| {
            return planMovesToGo(cfg, remaining, increment, move_overhead_ms, moves_to_go, hard_cap, spend_pct);
        }

        return planSuddenDeath(cfg, remaining, increment, move_overhead_ms, hard_cap, spend_pct);
    }

    /// True when planWithConfig took the TM v2 path for this side's clock
    /// (above the shared low-time threshold, where legacy safety planning
    /// still applies).
    fn usesV2Plan(self: GoLimits, side: types.Color) bool {
        const remaining = switch (side) {
            .white => self.wtime_ms,
            .black => self.btime_ms,
        } orelse return false;
        return remaining > LOW_TIME_THRESHOLD_MS;
    }

    pub fn toControllerLimits(self: GoLimits, side: types.Color, move_overhead_ms: u64, fullmove_number: u16) Limits {
        var limits = Limits{
            .depth = self.depth,
            .node_limit = self.node_limit,
            .mate_in_moves = self.mate_in_moves,
            .infinite = self.infinite,
        };

        const cfg = tmConfig();
        if (self.planWithConfig(cfg, side, move_overhead_ms, fullmove_number)) |timing| {
            limits.optimum_budget_ns = timing.optimum_ms * std.time.ns_per_ms;
            limits.maximum_budget_ns = timing.maximum_ms * std.time.ns_per_ms;

            // TM v2 clock searches have one hard budget (the reserve-funded
            // burst cap) and a soft deadline armed by the search itself.
            if (cfg.v2 and self.movetime_ms == null and self.usesV2Plan(side)) {
                limits.wider_maximum_budget_ns = limits.maximum_budget_ns;
                limits.soft = .disarmed;
                if (cfg.v2_c3) {
                    const remaining: u64 = @min((if (side == .white) self.wtime_ms else self.btime_ms).?, MAX_PLAN_INPUT_MS);
                    const increment: u64 = @min(if (side == .white) self.winc_ms else self.binc_ms, MAX_PLAN_INPUT_MS);
                    limits.soft = v2InitialSoft(cfg, remaining, increment, self.movestogo, timing.maximum_ms);
                }
                return limits;
            }

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

/// Default (clamped) return path vs ZQ_TM_CLAMP=0. The unclamped form raises
/// maximum up to optimum even when optimum overshot the remaining-clock hard
/// cap (the 6.0.0–6.3.0 flag-risk defect); the clamp lowers optimum instead so
/// no budget ever exceeds hard_cap.
fn finishPlan(cfg: TmConfig, optimum_ms: u64, maximum_ms: u64, hard_cap: u64) Plan {
    if (cfg.clamp_fix) {
        const capped_maximum = @max(@as(u64, 1), @min(maximum_ms, hard_cap));
        const capped_optimum = @max(@as(u64, 1), @min(optimum_ms, capped_maximum));
        return .{ .optimum_ms = capped_optimum, .maximum_ms = capped_maximum };
    }
    return .{ .optimum_ms = optimum_ms, .maximum_ms = @max(optimum_ms, maximum_ms) };
}

/// TM v2 step 2 clock model; see `TmConfig.v2`. All terms saturate at zero;
/// the shared `finishPlan` clamp keeps both budgets under the hard cap.
fn planV2(cfg: TmConfig, remaining: u64, increment: u64, move_overhead_ms: u64, movestogo: ?u32, hard_cap: u64) Plan {
    var target: u64 = undefined;
    var bank: u64 = undefined;
    var share_pct: u64 = undefined;
    if (movestogo) |raw_mtg| {
        const mtg: u64 = std.math.clamp(raw_mtg, 1, 50);
        const horizon: u64 = @min(mtg, if (increment > 0) cfg.v2_horizon_inc else cfg.v2_horizon_noinc);
        const safety = move_overhead_ms * (mtg + 2);
        const pool = (remaining + increment * (horizon - 1)) -| safety;
        target = pool / horizon;
        // Future increments are not on the clock yet: before the last move of
        // the period, never plan more than half of what is (review finding).
        if (mtg >= 2) target = @min(target, (remaining -| safety) / 2);
        bank = (remaining -| safety) -| target;
        share_pct = @max(cfg.v2_share_inc_pct, 100 / horizon);
    } else if (increment > 0) {
        const reserve = increment * cfg.v2_reserve_inc_pct / 100;
        const horizon: u64 = cfg.v2_horizon_inc;
        const above = remaining -| reserve;
        const below = reserve -| remaining;
        target = ((increment + above / horizon) -| (below / horizon)) -| move_overhead_ms;
        target = @max(target, increment * cfg.v2_floor_inc_pct / 100);
        // The increment arrives after the move: never plan more than half of
        // what is on the clock now (inc >> remaining would otherwise plan the
        // whole clock).
        target = @min(target, (remaining -| move_overhead_ms) / 2);
        bank = (remaining -| (increment + 4 * move_overhead_ms)) -| target;
        share_pct = cfg.v2_share_inc_pct;
    } else {
        target = (remaining -| move_overhead_ms) / cfg.v2_horizon_noinc;
        bank = remaining -| target;
        share_pct = cfg.v2_share_noinc_pct;
    }
    target = @max(@as(u64, 1), target);
    const maximum = @min(target * cfg.v2_burst_pct / 100, target + bank * share_pct / 100);
    return finishPlan(cfg, target, @max(target, maximum), hard_cap);
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

/// TM v2 C3 urgency u, in permille, for `streak` completed iterations since
/// the best move last changed or the score jumped >= 80 cp: the relative
/// chance that one more doubling of the search changes the move, fitted on
/// our own warm-hash value-of-time traces (artifacts/research/
/// tm-v2-2026-10-13/vot/FIT-WARM.md). Warm hash stretches the streak, so
/// the long-streak range keeps three classes.
pub fn c3UrgencyPermille(streak: u32) u32 {
    if (streak == 0) return 5540;
    if (streak <= 3) return 2870;
    if (streak <= 11) return 1410;
    if (streak <= 19) return 640;
    if (streak <= 29) return 360;
    return 80;
}

/// TM v2 C3 low-clock guard. C3 may stretch its deadline past the target T
/// only while even a move that runs to the hard budget M leaves at least
/// step 2's reserve target on the clock once the increment arrives:
///   guarded  <=>  remaining + increment - M < reserve target.
/// A guarded move keeps C3's classes but caps the multiplier at 1.0, so it
/// never plans past T (the root's fail-low/challenger disarm can still run
/// to M, as in step 2). Only increment controls without movestogo have a
/// reserve target; the others are never guarded.
pub fn c3LowClock(cfg: TmConfig, remaining_ms: u64, increment_ms: u64, movestogo: ?u32, maximum_ms: u64) bool {
    if (movestogo != null or increment_ms == 0) return false;
    const reserve = increment_ms * cfg.v2_reserve_inc_pct / 100;
    return remaining_ms + increment_ms < reserve + maximum_ms;
}

/// Start state of a TM v2 clock search's soft deadline: step 2's `disarmed`,
/// or C3's `low_clock` when the guard applies.
pub fn v2InitialSoft(cfg: TmConfig, remaining_ms: u64, increment_ms: u64, movestogo: ?u32, maximum_ms: u64) SoftStop {
    if (cfg.v2_c3 and c3LowClock(cfg, remaining_ms, increment_ms, movestogo, maximum_ms)) return .low_clock;
    return .disarmed;
}

/// TM v2 C3 soft deadline: target * clamp(K * u, 0.5, burst / target), in ns.
/// Wide arithmetic: the planner saturates inputs at MAX_PLAN_INPUT_MS.
pub fn c3SoftDeadlineNs(target_ns: u64, burst_ns: u64, k_pct: u32, u_permille: u32) u64 {
    const scaled = @as(u128, target_ns) * k_pct * u_permille / 100_000;
    const floored = @max(scaled, target_ns / 2);
    return @intCast(@min(floored, burst_ns));
}

pub const StopNowReason = enum {
    external,
    node_limit,
    maximum_budget,
    soft_budget,
};

/// Audit D (U-STOP-D1) backstop: the first iteration's clock hold ends after
/// this many nodes, a multiple of the 1024-node clock-check interval. Depth 1
/// of an ordinary position costs far fewer (at most 1,281 nodes in a census of
/// 71,975 opening and game positions). An impossible dense-queen board can
/// need millions or never finish; it then answers at the later of its planned
/// deadline and this many nodes (some milliseconds). The planned deadline
/// stays inside the remaining clock less the move overhead, or the movetime.
pub const FIRST_ITERATION_CLOCK_HOLD_NODES: u64 = 4096;

pub const Controller = struct {
    stop_flag: *const std.atomic.Value(bool),
    limits: Limits,
    legacy_maximum_budget_ns: ?u64 = null,
    timer: ?runtime.Timer = null,
    /// U-STOP-D1: the clock may not stop the search (holdClockUntilFirstIteration).
    /// Kept out of Limits, whose size is pinned.
    clock_held: bool = false,

    pub fn init(stop_flag: *const std.atomic.Value(bool), limits: Limits) Controller {
        return .{
            .stop_flag = stop_flag,
            .limits = limits,
            .legacy_maximum_budget_ns = limits.maximum_budget_ns,
            .timer = runtime.Timer.start() catch null,
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

    /// Audit D (U-STOP-D1): the clock does not stop the search before the
    /// first iteration completes, so the move played is a searched one and not
    /// the first generated move (a 1 ms cap, a zero or negative clock, or the
    /// first `go` of a process used to stop at node 0). Depth 1 costs up to
    /// about 200 nodes on ordinary positions. The hold is bounded: from
    /// FIRST_ITERATION_CLOCK_HOLD_NODES nodes on, the planned hard deadline
    /// applies again. `stop`, `quit` and node limits end the search at once
    /// throughout; the soft deadline is never armed before a completed
    /// iteration. The limits, the hard deadline included, are not touched.
    pub fn holdClockUntilFirstIteration(self: *Controller) void {
        self.clock_held = true;
    }

    /// The engine ends the hold at every completed iteration, before any
    /// iteration-end stop decision.
    pub fn releaseClockHold(self: *Controller) void {
        self.clock_held = false;
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
        if (nodes & 1023 != 0) return null;
        if (self.clock_held and nodes < FIRST_ITERATION_CLOCK_HOLD_NODES) return null;
        if (self.limits.maximum_budget_ns) |budget_ns| {
            if (self.elapsedNs() >= budget_ns) return .maximum_budget;
        }
        // TM v2: the soft deadline, only while the search is stable.
        if (self.limits.soft == .armed) {
            if (self.limits.optimum_budget_ns) |soft_ns| {
                if (self.elapsedNs() >= soft_ns) return .soft_budget;
            }
        }
        return null;
    }

    /// TM v2: the soft deadline is live only while the search is stable.
    pub fn softMode(self: *const Controller) bool {
        return self.limits.soft != .off;
    }

    pub fn setSoftArmed(self: *Controller, armed: bool) void {
        if (self.limits.soft == .off) return;
        self.limits.soft = if (armed) .armed else .disarmed;
    }

    /// Root evidence of trouble (the incumbent failed low, or another move
    /// beat it): keep searching until a completed iteration is stable again
    /// or the hard budget runs out. No-op outside TM v2.
    pub fn disarmSoft(self: *Controller) void {
        if (self.limits.soft == .armed) self.limits.soft = .disarmed;
    }

    /// TM v2: scale the soft target (one legal root move).
    pub fn scaleSoftTarget(self: *Controller, pct: u32) void {
        if (self.limits.soft == .off) return;
        if (self.limits.optimum_budget_ns) |soft_ns| {
            self.limits.optimum_budget_ns = @max(@as(u64, 1), soft_ns / 100 * pct + (soft_ns % 100) * pct / 100);
        }
    }

    /// TM v2 C3, at a completed iteration: arm the soft deadline of this
    /// iteration's urgency class against the plan's target. The root may
    /// disarm it again (fail-low, challenger) until the next completed
    /// iteration. `capped` (low-clock guard) limits the deadline to the
    /// target instead of the hard budget. Returns u in permille; no-op
    /// outside TM v2.
    pub fn armUrgency(self: *Controller, target_ns: u64, k_pct: u32, streak: u32, capped: bool) u32 {
        const u = c3UrgencyPermille(streak);
        if (self.limits.soft == .off) return u;
        const ceiling_ns = if (capped) target_ns else (self.limits.maximum_budget_ns orelse std.math.maxInt(u64));
        self.limits.optimum_budget_ns = c3SoftDeadlineNs(target_ns, ceiling_ns, k_pct, u);
        self.limits.soft = .armed;
        return u;
    }

    pub fn shouldStopNow(self: *Controller, nodes: u64) bool {
        return self.stopReasonNow(nodes) != null;
    }
};

// Limits is embedded in the search context. Its size is part of that context's
// layout, which hot-path timing has proved sensitive to.
test "TM v2 spends the full increment and settles at the explicit reserve" {
    const cfg = TmConfig{ .v2 = true };
    const inc: u64 = 8_000;
    const overhead: u64 = DEFAULT_MOVE_OVERHEAD_MS;
    const reserve = inc * cfg.v2_reserve_inc_pct / 100;

    // At the reserve the target is the increment (less the overhead).
    const at_reserve = (GoLimits{ .btime_ms = reserve, .binc_ms = inc }).planWithConfig(cfg, .black, overhead, 90).?;
    try std.testing.expectEqual(inc - overhead, at_reserve.optimum_ms);
    // Above it the surplus is spread over the horizon.
    const r: u64 = 163_800;
    const above = (GoLimits{ .btime_ms = r, .binc_ms = inc }).planWithConfig(cfg, .black, overhead, 93).?;
    try std.testing.expectEqual(inc + (r - reserve) / cfg.v2_horizon_inc - overhead, above.optimum_ms);
    // Near the reserve the legacy plan banks three quarters of the increment
    // and spends less (higher up the two plans cross: legacy front-loads).
    const legacy_at_reserve = (GoLimits{ .btime_ms = reserve, .binc_ms = inc }).planWithConfig(.{}, .black, overhead, 90).?;
    try std.testing.expect(at_reserve.optimum_ms > legacy_at_reserve.optimum_ms);
    // The hard budget may draw on the reserve: well above the legacy ceiling.
    const legacy = (GoLimits{ .btime_ms = r, .binc_ms = inc }).planWithConfig(.{}, .black, overhead, 93).?;
    try std.testing.expect(above.maximum_ms > legacy.maximum_ms);
    try std.testing.expect(above.maximum_ms <= above.optimum_ms * cfg.v2_burst_pct / 100);
    // Under the reserve the target shrinks but keeps its floor.
    const low = (GoLimits{ .btime_ms = 2 * inc, .binc_ms = inc }).planWithConfig(cfg, .black, overhead, 120).?;
    try std.testing.expect(low.optimum_ms < inc - overhead);
    try std.testing.expect(low.optimum_ms >= inc * cfg.v2_floor_inc_pct / 100);
}

test "TM v2 budgets never invert or exceed the clock" {
    const cfg = TmConfig{ .v2 = true };
    const incs = [_]u64{ 0, 80, 600, 1_000, 8_000 };
    const mtgs = [_]?u32{ null, 1, 2, 5, 40 };
    for (incs) |inc| {
        for (mtgs) |mtg| {
            var remaining: u64 = 1_001;
            while (remaining < 20_000_000) : (remaining = remaining * 5 / 4 + 7) {
                const limits = GoLimits{ .wtime_ms = remaining, .winc_ms = inc, .movestogo = mtg };
                const plan = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 40).?;
                try std.testing.expect(plan.optimum_ms >= 1);
                try std.testing.expect(plan.optimum_ms <= plan.maximum_ms);
                try std.testing.expect(plan.maximum_ms <= remaining - DEFAULT_MOVE_OVERHEAD_MS);
            }
        }
    }
}

test "TM v2 never plans an increment that has not arrived" {
    const cfg = TmConfig{ .v2 = true };
    // Review findings (step 2): inc >> remaining made T equal the hard cap,
    // with and without movestogo (the last move of a period may use it all).
    for ([_]u64{ 1_100, 1_500, 3_000, 10_000 }) |remaining| {
        for ([_]?u32{ null, 2, 5, 40 }) |mtg| {
            const plan = (GoLimits{ .wtime_ms = remaining, .winc_ms = 2 * remaining, .movestogo = mtg }).planWithConfig(cfg, .white, 20, 50).?;
            try std.testing.expect(plan.optimum_ms <= (remaining - 20) / 2);
            try std.testing.expect(plan.maximum_ms <= remaining - 20);
        }
    }
}

test "TM v2 leaves low clocks, movetime and the default to the legacy planner" {
    const v2 = TmConfig{ .v2 = true };
    const legacy = TmConfig{};
    const scramble = GoLimits{ .wtime_ms = 900, .winc_ms = 100 };
    try std.testing.expectEqual(scramble.planWithConfig(legacy, .white, 20, 60).?, scramble.planWithConfig(v2, .white, 20, 60).?);
    const fixed = GoLimits{ .movetime_ms = 5_000 };
    try std.testing.expectEqual(fixed.planWithConfig(legacy, .white, 20, 1).?, fixed.planWithConfig(v2, .white, 20, 1).?);
    // ZQ_TM_V2 unset: the default config is the legacy planner.
    try std.testing.expect(!(TmConfig{}).v2);
}

test "TM v2 soft deadline fires only while armed" {
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .optimum_budget_ns = 1, .maximum_budget_ns = std.math.maxInt(u64), .soft = .disarmed });
    try std.testing.expect(controller.softMode());
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(1024));
    controller.setSoftArmed(true);
    try std.testing.expectEqual(@as(?StopNowReason, .soft_budget), controller.stopReasonNow(1024));
    controller.disarmSoft();
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(1024));
    controller.setSoftArmed(true);
    controller.scaleSoftTarget(25);
    try std.testing.expectEqual(@as(?u64, 1), controller.limits.optimum_budget_ns);

    // Legacy controllers never arm.
    var legacy = Controller.init(&stop_flag, .{ .optimum_budget_ns = 1, .maximum_budget_ns = std.math.maxInt(u64) });
    try std.testing.expect(!legacy.softMode());
    legacy.setSoftArmed(true);
    legacy.scaleSoftTarget(25);
    try std.testing.expectEqual(@as(?StopNowReason, null), legacy.stopReasonNow(1024));
    try std.testing.expectEqual(@as(?u64, 1), legacy.limits.optimum_budget_ns);
}

test "TM v2 C3 urgency follows the fitted streak classes" {
    // vot/FIT-WARM.md: relative P(the move changes on doubling) under warm
    // hash 5.54 / 2.87 / 1.41 / 0.64 / 0.36 / 0.08 for streak 0 / 1-3 /
    // 4-11 / 12-19 / 20-29 / >= 30.
    const expected = [_]struct { streak: u32, u: u32 }{
        .{ .streak = 0, .u = 5540 }, .{ .streak = 1, .u = 2870 },  .{ .streak = 3, .u = 2870 },
        .{ .streak = 4, .u = 1410 }, .{ .streak = 11, .u = 1410 }, .{ .streak = 12, .u = 640 },
        .{ .streak = 19, .u = 640 }, .{ .streak = 20, .u = 360 },  .{ .streak = 29, .u = 360 },
        .{ .streak = 30, .u = 80 },  .{ .streak = 254, .u = 80 },
    };
    for (expected) |case| try std.testing.expectEqual(case.u, c3UrgencyPermille(case.streak));
    // ZQ_TM_V2_C3 unset: step 2's yes/no arm.
    try std.testing.expect(!(TmConfig{}).v2_c3);
}

test "TM v2 C3 deadline is the target times K u, clamped to half the target and the burst" {
    const t: u64 = 4_000 * std.time.ns_per_ms;
    const burst = 5 * t;
    // K 120 %: streak 1-3 gives 3.444 T, 4-11 1.692 T, 12-19 0.768 T.
    try std.testing.expectEqual(t * 3444 / 1000, c3SoftDeadlineNs(t, burst, 120, 2870));
    try std.testing.expectEqual(t * 1692 / 1000, c3SoftDeadlineNs(t, burst, 120, 1410));
    try std.testing.expectEqual(t * 768 / 1000, c3SoftDeadlineNs(t, burst, 120, 640));
    // Streaks of 20 and more are floored at half the target.
    try std.testing.expectEqual(t / 2, c3SoftDeadlineNs(t, burst, 120, 360));
    try std.testing.expectEqual(t / 2, c3SoftDeadlineNs(t, burst, 120, 80));
    // Never past the burst cap (streak 0 asks for 6.648 T).
    try std.testing.expectEqual(burst, c3SoftDeadlineNs(t, burst, 120, 5540));
    try std.testing.expectEqual(2 * t, c3SoftDeadlineNs(t, 2 * t, 120, 2870));
    // Saturated planner inputs cannot wrap.
    const huge = MAX_PLAN_INPUT_MS * std.time.ns_per_ms;
    try std.testing.expectEqual(huge, c3SoftDeadlineNs(huge, huge, 1_000, 5540));
    try std.testing.expectEqual(huge / 2, c3SoftDeadlineNs(huge, 5 * huge, 120, 80));
}

test "TM v2 C3 re-arms the graded deadline at every completed iteration" {
    var stop_flag = std.atomic.Value(bool).init(false);
    const t: u64 = 2;
    var controller = Controller.init(&stop_flag, .{ .optimum_budget_ns = t, .maximum_budget_ns = std.math.maxInt(u64), .soft = .disarmed });
    // A completed iteration arms its class's deadline, whatever the legacy gate said.
    try std.testing.expectEqual(@as(u32, 80), controller.armUrgency(t, 120, 30, false));
    try std.testing.expectEqual(SoftStop.armed, controller.limits.soft);
    try std.testing.expectEqual(@as(?u64, t / 2), controller.limits.optimum_budget_ns);
    try std.testing.expectEqual(@as(?StopNowReason, .soft_budget), controller.stopReasonNow(1024));
    // Root trouble disarms it until the next completed iteration ...
    controller.disarmSoft();
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(1024));
    // ... which re-arms at its own class (streak 0 after a change): 2 ns * 6.648.
    try std.testing.expectEqual(@as(u32, 5540), controller.armUrgency(t, 120, 0, false));
    try std.testing.expectEqual(SoftStop.armed, controller.limits.soft);
    try std.testing.expectEqual(@as(?u64, 13), controller.limits.optimum_budget_ns);
    // A far deadline does not fire.
    _ = controller.armUrgency(std.math.maxInt(u64) / 8, 120, 0, false);
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(1024));

    // Legacy controllers never arm.
    var legacy = Controller.init(&stop_flag, .{ .optimum_budget_ns = t, .maximum_budget_ns = std.math.maxInt(u64) });
    _ = legacy.armUrgency(t, 120, 30, false);
    try std.testing.expectEqual(SoftStop.off, legacy.limits.soft);
    try std.testing.expectEqual(@as(?u64, t), legacy.limits.optimum_budget_ns);
    try std.testing.expectEqual(@as(?StopNowReason, null), legacy.stopReasonNow(1024));
}

test "TM v2 C3 low-clock guard keeps step 2's reserve after a full burst" {
    const cfg = TmConfig{ .v2 = true, .v2_c3 = true };
    const inc: u64 = 200;
    const reserve = inc * cfg.v2_reserve_inc_pct / 100;
    // 20+0.2 at the default overhead: R 2800 plans T 213 / burst 1065, so a
    // full burst would leave 1935 < 2000 after the increment; R 2900 plans
    // 217 / 1085 and leaves 2015.
    const low = (GoLimits{ .wtime_ms = 2_800, .winc_ms = inc }).planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 60).?;
    try std.testing.expectEqual(@as(u64, 1065), low.maximum_ms);
    try std.testing.expect(c3LowClock(cfg, 2_800, inc, null, low.maximum_ms));
    const ok = (GoLimits{ .wtime_ms = 2_900, .winc_ms = inc }).planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 60).?;
    try std.testing.expectEqual(@as(u64, 1085), ok.maximum_ms);
    try std.testing.expect(!c3LowClock(cfg, 2_900, inc, null, ok.maximum_ms));
    // Exactly at the reserve after a full burst is not guarded.
    try std.testing.expect(!c3LowClock(cfg, reserve + 1_000 - inc, inc, null, 1_000));
    try std.testing.expect(c3LowClock(cfg, reserve + 999 - inc, inc, null, 1_000));
    // Over the v2 range the guard switches off exactly once as the clock grows.
    var flips: u32 = 0;
    var previous = true;
    var remaining: u64 = 1_001;
    while (remaining < 60_000) : (remaining += 1) {
        const plan = (GoLimits{ .wtime_ms = remaining, .winc_ms = inc }).planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 60).?;
        const guarded = c3LowClock(cfg, remaining, inc, null, plan.maximum_ms);
        if (guarded != previous) flips += 1;
        previous = guarded;
    }
    try std.testing.expectEqual(@as(u32, 1), flips);
    try std.testing.expect(!previous);
    // No reserve target without an increment or with movestogo: never guarded.
    try std.testing.expect(!c3LowClock(cfg, 1_001, 0, null, 900));
    try std.testing.expect(!c3LowClock(cfg, 1_001, inc, 2, 900));
}

test "TM v2 C3 low-clock guard starts only C3 searches capped" {
    const on = TmConfig{ .v2 = true, .v2_c3 = true };
    const off = TmConfig{ .v2 = true };
    // C3 off: always step 2's start state, guarded clock or not.
    try std.testing.expectEqual(SoftStop.disarmed, v2InitialSoft(off, 2_800, 200, null, 1_065));
    try std.testing.expectEqual(SoftStop.disarmed, v2InitialSoft(on, 2_900, 200, null, 1_085));
    try std.testing.expectEqual(SoftStop.low_clock, v2InitialSoft(on, 2_800, 200, null, 1_065));
    // The capped start state behaves as disarmed until the first completed iteration.
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .optimum_budget_ns = 1, .maximum_budget_ns = std.math.maxInt(u64), .soft = .low_clock });
    try std.testing.expect(controller.softMode());
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(1024));
    controller.disarmSoft();
    try std.testing.expectEqual(SoftStop.low_clock, controller.limits.soft);
}

test "TM v2 C3 capped deadline never stretches past the target" {
    var stop_flag = std.atomic.Value(bool).init(false);
    const t: u64 = 4_000 * std.time.ns_per_ms;
    var controller = Controller.init(&stop_flag, .{ .optimum_budget_ns = t, .maximum_budget_ns = 5 * t, .soft = .low_clock });
    // Streak 0 asks for 6.648 T: the burst cap uncapped, the target capped.
    _ = controller.armUrgency(t, 120, 0, false);
    try std.testing.expectEqual(@as(?u64, 5 * t), controller.limits.optimum_budget_ns);
    _ = controller.armUrgency(t, 120, 0, true);
    try std.testing.expectEqual(@as(?u64, t), controller.limits.optimum_budget_ns);
    try std.testing.expectEqual(SoftStop.armed, controller.limits.soft);
    // Below 1.0 the class still applies: 12-19 gives 0.768 T, 30+ the floor.
    _ = controller.armUrgency(t, 120, 12, true);
    try std.testing.expectEqual(@as(?u64, t * 768 / 1000), controller.limits.optimum_budget_ns);
    _ = controller.armUrgency(t, 120, 30, true);
    try std.testing.expectEqual(@as(?u64, t / 2), controller.limits.optimum_budget_ns);
}

test "limits keep their size" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Limits));
}

test "controller stops at node limit" {
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .node_limit = 8 });

    try std.testing.expect(!controller.shouldStopNow(7));
    try std.testing.expect(controller.shouldStopNow(8));
}

test "the first-iteration clock hold keeps the hard deadline and ends at its node budget" {
    // Judge D finding A: the hold must not depend on anything restoring the
    // deadline. Soft stopping disarmed and a large optimum: only the hard
    // budget (long expired) can stop this search.
    var stop_flag = std.atomic.Value(bool).init(false);
    var controller = Controller.init(&stop_flag, .{ .optimum_budget_ns = std.time.ns_per_hour, .maximum_budget_ns = 1, .soft = .disarmed });
    controller.holdClockUntilFirstIteration();
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(0));
    try std.testing.expectEqual(@as(?StopNowReason, null), controller.stopReasonNow(FIRST_ITERATION_CLOCK_HOLD_NODES - 1024));
    // The backstop: from the hold's node budget on, the deadline applies.
    try std.testing.expectEqual(@as(?StopNowReason, .maximum_budget), controller.stopReasonNow(FIRST_ITERATION_CLOCK_HOLD_NODES));
    try std.testing.expectEqual(@as(?u64, 1), controller.limits.maximum_budget_ns);
    // A completed iteration ends the hold: the next clock check stops.
    controller.releaseClockHold();
    try std.testing.expectEqual(@as(?StopNowReason, .maximum_budget), controller.stopReasonNow(1024));

    // stop and node limits stay ahead of the hold.
    var limited = Controller.init(&stop_flag, .{ .node_limit = 1, .maximum_budget_ns = 1 });
    limited.holdClockUntilFirstIteration();
    try std.testing.expectEqual(@as(?StopNowReason, .node_limit), limited.stopReasonNow(1));
    stop_flag.store(true, .release);
    try std.testing.expectEqual(@as(?StopNowReason, .external), limited.stopReasonNow(0));
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
    // the scramble behaviour is bit-identical to the head (values pinned). The
    // last case is the increment-heavy one the clamp protects: 100 - 20 = 80.
    const scramble = [_]struct { limits: GoLimits, optimum: u64, maximum: u64 }{
        .{ .limits = .{ .wtime_ms = 1_000, .winc_ms = 100 }, .optimum = 71, .maximum = 121 },
        .{ .limits = .{ .wtime_ms = 500, .winc_ms = 50 }, .optimum = 35, .maximum = 60 },
        .{ .limits = .{ .wtime_ms = 100, .winc_ms = 1_000 }, .optimum = 80, .maximum = 80 },
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

// PINNED DEFECT of the unclamped planner (ZQ_TM_CLAMP=0, the 6.0.0–6.3.0
// default): with 100ms on the clock and a 1s increment, the sudden-death plan
// lets the unclamped increment/4 optimum term drag `maximum` to 252ms — past
// the 80ms remaining-clock hard cap. Spending it forfeits on time; the
// increment lands only AFTER the move is played.
test "unclamped sudden-death budget exceeds the clock at increment-heavy low time" {
    const limits = GoLimits{
        .wtime_ms = 100,
        .winc_ms = 1_000,
    };

    const plan = limits.planWithConfig(.{ .opt_pct = 100, .clamp_fix = false }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
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

    const legacy = limits.planWithConfig(.{ .clamp_fix = false }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
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
        const legacy = limits.planWithConfig(.{ .clamp_fix = false }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
        const fixed = limits.planWithConfig(cfg, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
        try std.testing.expectEqual(legacy.optimum_ms, fixed.optimum_ms);
        try std.testing.expectEqual(legacy.maximum_ms, fixed.maximum_ms);
    }
}

// The last move before a time control. At the shipped 130% spend level the
// unclamped planner budgets (remaining - 3 * overhead) * 1.3 for it, soft and
// hard alike: 12.9s on a 10s clock. The refill arrives only after the move.
test "moves-to-go 1 never plans past the remaining clock" {
    const clocks = [_]u64{ 1_500, 2_000, 10_000, 45_000, 900_000 };
    for (clocks) |remaining| {
        const limits = GoLimits{ .wtime_ms = remaining, .movestogo = 1 };
        const unclamped = limits.planWithConfig(.{ .clamp_fix = false }, .white, DEFAULT_MOVE_OVERHEAD_MS, 40).?;
        try std.testing.expect(unclamped.maximum_ms > remaining); // pinned defect

        const plan = limits.planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 40).?;
        try std.testing.expectEqual(remaining - DEFAULT_MOVE_OVERHEAD_MS, plan.maximum_ms);
        try std.testing.expect(plan.optimum_ms <= plan.maximum_ms);
    }
}

// The clamp acts exactly where the unclamped plan is past the remaining clock,
// and nowhere else. Three regimes reach that: movestogo 1; an increment clock
// below one increment; and moves-to-go with an increment, where the pooled
// future increments can outweigh a short clock. Everywhere else the two
// planners agree, so the default changes no other budget.
test "clamp changes a plan only where the unclamped plan is past the clock" {
    const on = TmConfig{};
    const off = TmConfig{ .clamp_fix = false };
    const increments = [_]u64{ 0, 80, 200, 600, 1_000, 2_000, 8_000, 10_000 };
    const overheads = [_]u64{ 0, 20, 100, 1_000 };
    const moves_to_go = [_]?u32{ null, 1, 2, 3, 10, 40, 60 };
    var changed: usize = 0;
    for (overheads) |overhead| {
        for (increments) |inc| {
            for (moves_to_go) |mtg| {
                var remaining: u64 = 30;
                while (remaining <= 1_000_000) : (remaining += @max(@as(u64, 7), remaining / 9)) {
                    const limits = GoLimits{ .wtime_ms = remaining, .winc_ms = inc, .movestogo = mtg };
                    const hard_cap = @max(@as(u64, 1), if (remaining > overhead) remaining - overhead else 1);
                    const a = limits.planWithConfig(on, .white, overhead, 30).?;
                    const b = limits.planWithConfig(off, .white, overhead, 30).?;
                    try std.testing.expect(a.maximum_ms <= hard_cap);
                    try std.testing.expect(a.optimum_ms <= a.maximum_ms);
                    if (b.maximum_ms <= hard_cap) {
                        try std.testing.expectEqual(b.optimum_ms, a.optimum_ms);
                        try std.testing.expectEqual(b.maximum_ms, a.maximum_ms);
                    } else {
                        changed += 1;
                        // Sudden death: only a clock shorter than its own
                        // increment (plus the overhead) is ever affected.
                        if (mtg == null) try std.testing.expect(remaining < inc + overhead + 2);
                        // Without an increment only the last move before
                        // the control is.
                        if (inc == 0) try std.testing.expectEqual(@as(?u32, 1), mtg);
                    }
                }
            }
        }
    }
    try std.testing.expect(changed != 0);
}

test "absurd clock values saturate instead of wrapping" {
    const huge = std.math.maxInt(u64);
    const movetime = (GoLimits{ .movetime_ms = 18_446_744_073_710 }).planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(MAX_PLAN_INPUT_MS, movetime.maximum_ms);
    const sudden = (GoLimits{ .wtime_ms = huge, .winc_ms = huge }).planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expect(sudden.optimum_ms <= sudden.maximum_ms);
    try std.testing.expect(sudden.maximum_ms <= MAX_PLAN_INPUT_MS);
    const pooled = (GoLimits{ .wtime_ms = huge, .winc_ms = huge, .movestogo = 50 }).planWithConfig(.{}, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expect(pooled.maximum_ms <= MAX_PLAN_INPUT_MS);
    const limits = (GoLimits{ .wtime_ms = huge, .winc_ms = huge }).toControllerLimits(.white, DEFAULT_MOVE_OVERHEAD_MS, 1);
    try std.testing.expect(limits.maximum_budget_ns.? >= limits.optimum_budget_ns.?);
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
    const limits = GoLimits{
        .wtime_ms = 200,
        .winc_ms = 1_000,
    };

    // Base optimum 255ms would ramp to 357ms at move 1, but the low-time
    // emergency cap (180/16 + 250 = 261ms) still binds. Shown unclamped: the
    // cap itself is past this 180ms clock, which the default clamp then cuts.
    const unclamped = limits.planWithConfig(.{ .phase = true, .clamp_fix = false }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 261), unclamped.optimum_ms);
    const plan = limits.planWithConfig(.{ .phase = true }, .white, DEFAULT_MOVE_OVERHEAD_MS, 1).?;
    try std.testing.expectEqual(@as(u64, 180), plan.optimum_ms);
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
    try std.testing.expect(cfg.clamp_fix); // safety clamp, not a signal
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
