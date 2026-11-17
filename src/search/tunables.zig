//! Runtime-tunable search parameters (SPSA scaffold).
//!
//! These default to the shipped (v3.1.0) values, so the engine plays IDENTICALLY
//! out of the box (verified by an exact-output bench signature) -- they only
//! diverge when set via `setoption`. This exists so an external SPSA driver
//! (`scripts/spsa-tune.py`) can perturb the search calibration without recompiling.
//! Once a campaign finds a better point, the winning values are baked back as the
//! defaults here and the engine ships with them (no hot-path cost beyond a cached
//! global read).
//!
//! Mutation requires process-wide quiescence: no search or constructor may
//! overlap any set/reset, and there is one writer. UCI stops its sole worker;
//! multi-engine tools must join every reader before tuning.
//!
//! Restored + extended 2026-06-06: the original 19 margins/reductions + the 7
//! v3.1.0 depth-efficiency knobs (the +44 bundle), which had never been SPSA'd.

const std = @import("std");
const tt = @import("tt.zig");
const types = @import("../core/types.zig");

pub const BASIN_UNIT_PERCENT_DEFAULT: types.Score = 25;
pub const HINDSIGHT_MARGIN_DEFAULT: types.Score = @divTrunc(202 * BASIN_UNIT_PERCENT_DEFAULT, 100);
pub const LDSE_MARGIN_DEFAULT: types.Score = @divTrunc(22 * BASIN_UNIT_PERCENT_DEFAULT, 100);
pub const LDSE_DOUBLE_MARGIN_DEFAULT: types.Score = @divTrunc(39 * BASIN_UNIT_PERCENT_DEFAULT, 100);

pub const Tunables = struct {
    // --- original 19 (SPSA campaigns #1-#3); defaults = current shipped consts ---
    // Pruning margins (centipawns).
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
    // Reductions + LMP. (LMR divisor feeds a comptime table -> left const for now.)
    lmp_base: types.Score = 6, // late-move-prune onset base (threshold = lmp_base + d*d)

    // --- v3.1.0 depth-efficiency knobs (the +44 bundle), never tuned ---
    rfp_deep_margin_per_ply: types.Score = 75, // per-ply margin in the deepened RFP range (depths 4-6)
    quiet_futility_max_depth: types.Score = 4, // quiet futility extends to this depth (was 2)
    history_prune_max_depth: types.Score = 6, // history-prune late quiets up to this depth
    history_prune_margin_per_ply: types.Score = -2048, // history threshold per ply (negative)
    see_quiet_max_depth: types.Score = 7, // SEE-prune late quiets up to this depth
    see_quiet_margin_per_ply: types.Score = -50, // SEE-quiet margin per ply (negative)

    // --- lever 5 (2026-07-16): LMR shape, centi-units (0.50 / 2.28) ---
    lmr_base_100: types.Score = @import("reductions.zig").LMR_BASE_100_DEFAULT,
    lmr_divisor_100: types.Score = @import("reductions.zig").LMR_DIVISOR_100_DEFAULT,

    // --- shallow-hole mechanism arms (2026-09-02) ---
    // Every switch defaults to shipped behaviour. Score margins are already
    // mapped into zigqueen eval units at the default 25% basin unit factor.
    hindsight_repair: types.Score = 0,
    hindsight_margin: types.Score = HINDSIGHT_MARGIN_DEFAULT,
    eval_policy_history: types.Score = 0,
    eval_policy_scale: types.Score = 40,
    eval_policy_clamp: types.Score = 1841,
    eval_policy_offset: types.Score = 503,
    tt_cutoff_node_role: types.Score = 0,
    tt_cutoff_halfmove_max: types.Score = 90, // = shallow_arms.TT_CUTOFF_HALFMOVE_MAX_DEFAULT (release)
    pv_tt_score_trust: types.Score = 0, // = shallow_arms.PV_TT_SCORE_TRUST_DEFAULT (release)
    pv_tt_decided_score: types.Score = 400, // = shallow_arms.PV_TT_DECIDED_SCORE_DEFAULT (release)
    // The singular test (root.zig trySingularPlan) as round 3's full form
    // (first-principles review, fp-whole P1): no depth ceiling, a table
    // entry up to three plies shallower than the node, no weak-alternatives
    // gate, and the table move searched shallower when it is not singular.
    // Before round 3: neg_ext 0, max_depth 8, tt_depth_slack 0, weak_gate 1.
    singular_neg_ext: types.Score = 1,
    singular_min_depth: types.Score = 6,
    singular_max_depth: types.Score = 64,
    singular_tt_depth_slack: types.Score = 3,
    singular_weak_gate: types.Score = 0,
    ldse: types.Score = 1,
    ldse_margin: types.Score = LDSE_MARGIN_DEFAULT,
    ldse_double_margin: types.Score = LDSE_DOUBLE_MARGIN_DEFAULT,
    qsearch_tt_quiet: types.Score = 0,
    check_extension: types.Score = 1,

    // --- roadmap #2 (2026-11-10): extension rules.
    // Bound on the positive extension accumulated along one line, in plies
    // (extension_bound.zig): ext_cap_base + root depth * ext_cap_pct / 100.
    // 0 / 0 = no bound (6.5.0). On: a line may gain as many plies as the
    // iteration is deep.
    ext_cap_base: types.Score = 0,
    ext_cap_pct: types.Score = 100,
    // Unverified extensions: where they may still act.
    ldse_max_depth: types.Score = 7, // LDSE acts up to this depth
    check_ext_max_depth: types.Score = 127, // check extension acts up to this depth
    // Both unverified rules read "static eval below alpha" as trouble. Where
    // alpha itself is already a won score for the mover that is true at every
    // node of the winning line, so they act only below this alpha (32000 = always).
    uext_alpha_max: types.Score = 300,

    // --- roadmap round 2 (2026-11-11): the transposition table (tt.Policy).
    tt_refresh_on_hit: types.Score = @intFromBool(tt.REFRESH_ON_HIT_DEFAULT),
    // Round 3 (2026-11-13): a store without a move keeps the entry's move.
    tt_keep_move: types.Score = @intFromBool(tt.KEEP_MOVE_DEFAULT),
    // The move of a fail low in a node's final store (tt_store.failLowNoMove).
    fail_low_no_move: types.Score = 1, // = tt_store.FAIL_LOW_NO_MOVE_DEFAULT (release)
    // Instruments: the key bits kept in an entry's tag, and (stats flavour)
    // whether a hit under another position's key counts as a miss.
    tt_tag_bits: types.Score = tt.TAG_BITS,
    tt_verify_keys: types.Score = 0,

    // --- round 3 (2026-11-13): quiescence move rules (qs_rules.zig).
    // Integration defaults (roadmap/r3-integration): the cell R123 is on, so
    // that the survivors of the 100k readings can be played together. The
    // proposal's start values were off / 300 / 850 / 950 / 1100 / 0 / 0 / 0.
    // Per-move futility of captures; the gains are in evaluation units.
    qs_move_futility: types.Score = 1,
    qs_gain_pawn: types.Score = 350,
    qs_gain_minor: types.Score = 1000,
    qs_gain_rook: types.Score = 1200,
    qs_gain_queen: types.Score = 1400,
    qs_futility_keep_checks: types.Score = 1, // 1: a capture with check is exempt
    // An exchange that nets exactly nothing is skipped this far below alpha (0 = off).
    qs_equal_exchange_margin: types.Score = 450,
    // 1: rook and bishop promotions are not searched in quiescence outside check.
    qs_no_underpromotion: types.Score = 1,
    // Quiet checks of the first quiescence ply (qs_rules.checkGateOpen):
    // 0 all (as before); 1 only near alpha or against a boxed-in king;
    // 2 as 1, by piece, ending after qs_check_fail_lows that raise nothing;
    // 3 none where a capture or promotion exists (the control).
    qs_check_gate: types.Score = 0,
    qs_check_margin: types.Score = 200,
    qs_check_fail_lows: types.Score = 2,

    // The singular test's choices (root.zig trySingularPlan). The defaults
    // are the full form of round 3 as its reviewer wrote it, no number
    // tuned; the values before round 3 were pv 0, all 0, double_margin 0,
    // ext_margin 16, margin_base 8, margin_per_ply 4. multicut: a
    // verification that fails high at or above beta cuts the node. pv / all:
    // the test is also tried at PV
    // nodes (where an exact table entry counts as well) / at expected all
    // nodes; expected cut nodes are always tried. double_margin: a second ply
    // of extension when the verification fails low by this much more than the
    // extension needs (0 = never). ext_margin: what the verification has to
    // fail low by, beyond the singular margin, for the extension. margin_base,
    // margin_per_ply: the singular margin below the table score. verify_pct:
    // the verification's depth as a percentage of the node's.
    sweep_sing_multicut: types.Score = 1,
    sweep_sing_pv: types.Score = 1,
    sweep_sing_all: types.Score = 1,
    sweep_sing_double_margin: types.Score = 20,
    sweep_sing_ext_margin: types.Score = 0,
    sweep_sing_margin_base: types.Score = 0,
    sweep_sing_margin_per_ply: types.Score = 2,
    sweep_sing_verify_pct: types.Score = 50,
    // The rest of the form (before round 3: exact 0, in_check 0,
    // pv_min_extra 0, verify_sub 0, verify_inherit 0, double_pv 1,
    // neg_beta 3, neg_cut 2, neg_alpha 0). exact: an exact table
    // entry is a candidate like a lower bound at every node the test runs at.
    // in_check: the test also runs at nodes in check. pv_min_extra: a PV node
    // needs this much more depth. verify_sub: plies taken off the node's
    // depth before the verification's percentage ((d - 1) / 2 is sub 1 at
    // 50). verify_inherit: the verification search keeps the node's expected
    // role instead of an all node's. double_pv: the second ply also at PV
    // nodes. neg_beta / neg_cut / neg_alpha: with SingularNegExt on, the
    // plies the table move is searched shallower when the verification fails
    // high without a multicut and the table score is at or above beta / the
    // node is an expected cut node / the table score is at or below alpha.
    sweep_sing_exact: types.Score = 1,
    sweep_sing_in_check: types.Score = 0,
    sweep_sing_pv_min_extra: types.Score = 1,
    sweep_sing_verify_sub: types.Score = 1,
    sweep_sing_verify_inherit: types.Score = 1,
    sweep_sing_double_pv: types.Score = 0,
    sweep_sing_neg_beta: types.Score = 2,
    sweep_sing_neg_cut: types.Score = 2,
    sweep_sing_neg_alpha: types.Score = 1,
    // The table's searched score as the node's value for a static decision
    // (tt_eval.zig), one switch per consumer: reverse futility, razoring,
    // the null-move gates, quiet futility, the check-extension test,
    // ProbCut's required gain (probcut_beta minus the value), the depth-1
    // bad-capture rule, quiescence's stand-pat. rfp_return: reverse futility's cut also takes
    // its fail-soft value from the table's score. min_depth: the shallowest
    // entry whose score is taken (-1: any, quiescence entries included).
    tt_eval_rfp: types.Score = 1,
    tt_eval_razor: types.Score = 1,
    tt_eval_null_move: types.Score = 1,
    tt_eval_futility: types.Score = 1,
    tt_eval_check_ext: types.Score = 0,
    tt_eval_probcut: types.Score = 1,
    tt_eval_bad_capture: types.Score = 0,
    tt_eval_stand_pat: types.Score = 0,
    tt_eval_rfp_return: types.Score = 1,
    tt_eval_min_depth: types.Score = -1,
    // The verification of a reduced scout that beat alpha runs at the full
    // child depth instead of one ply short: 0 nowhere (the rule before
    // 2026-11-16), 1 at expected all nodes, 2 at PV and expected all
    // nodes, 3 everywhere.
    lmr_verify_full: types.Score = 2,

    // root_node_order 1: the root's moves ordered by the previous
    // iteration's subtree nodes, the table move first (fp-root P3's measured
    // simple form, vol-frame 4's code). 0 = the order before (interior
    // scores plus the root hint bonus).
    root_node_order: types.Score = 1,
};

/// The transposition table's policy as the tunables have it (tuning flavour;
/// the release flavour's table ignores it and uses its defaults).
pub fn tablePolicy() tt.Policy {
    return .{
        .refresh_on_hit = knob("tt_refresh_on_hit") != 0,
        .keep_move = knob("tt_keep_move") != 0,
        .tag_bits = @intCast(knob("tt_tag_bits")),
        .verify_keys = knob("tt_verify_keys") != 0,
    };
}

/// The live parameters read by the search. Mutated only by UCI `setoption`.
pub var active: Tunables = .{};

/// A parameter as the search reads it: the live value in the tuning flavour,
/// the compiled-in default in the release flavour.
pub inline fn knob(comptime field: []const u8) types.Score {
    if (comptime @import("build_options").tuning) return @field(active, field);
    return @field(Tunables{}, field);
}

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
    // v3.1.0 depth-efficiency knobs.
    .{ .uci_name = "RfpDeepMarginPerPly", .field = "rfp_deep_margin_per_ply", .default = 75, .min = 30, .max = 160 },
    .{ .uci_name = "QuietFutilityMaxDepth", .field = "quiet_futility_max_depth", .default = 4, .min = 1, .max = 8 },
    .{ .uci_name = "HistoryPruneMaxDepth", .field = "history_prune_max_depth", .default = 6, .min = 2, .max = 10 },
    .{ .uci_name = "HistoryPruneMarginPerPly", .field = "history_prune_margin_per_ply", .default = -2048, .min = -8192, .max = -256 },
    .{ .uci_name = "SeeQuietMaxDepth", .field = "see_quiet_max_depth", .default = 7, .min = 3, .max = 12 },
    .{ .uci_name = "SeeQuietMarginPerPly", .field = "see_quiet_margin_per_ply", .default = -50, .min = -200, .max = -10 },
    // lever 5: LMR shape (centi-units; rebuilds the reduction table on set).
    .{ .uci_name = "LmrBase100", .field = "lmr_base_100", .default = 50, .min = 0, .max = 150 },
    .{ .uci_name = "LmrDivisor100", .field = "lmr_divisor_100", .default = 228, .min = 120, .max = 400 },
    // Shallow-hole arms. Boolean switches are represented as 0/1 spin knobs so
    // the existing integer-only SPSA/UCI plumbing remains the single mechanism.
    .{ .uci_name = "HindsightRepair", .field = "hindsight_repair", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "HindsightMargin", .field = "hindsight_margin", .default = HINDSIGHT_MARGIN_DEFAULT, .min = 0, .max = 500 },
    .{ .uci_name = "EvalPolicyHistory", .field = "eval_policy_history", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "EvalPolicyScale", .field = "eval_policy_scale", .default = 40, .min = 0, .max = 200 },
    .{ .uci_name = "EvalPolicyClamp", .field = "eval_policy_clamp", .default = 1841, .min = 0, .max = 32000 },
    .{ .uci_name = "EvalPolicyOffset", .field = "eval_policy_offset", .default = 503, .min = -5000, .max = 5000 },
    .{ .uci_name = "TtCutoffNodeRole", .field = "tt_cutoff_node_role", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "TtCutoffHalfmoveMax", .field = "tt_cutoff_halfmove_max", .default = 90, .min = 0, .max = 100 },
    .{ .uci_name = "PvTtScoreTrust", .field = "pv_tt_score_trust", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "PvTtDecidedScore", .field = "pv_tt_decided_score", .default = 400, .min = 0, .max = 32000 },
    .{ .uci_name = "SingularNegExt", .field = "singular_neg_ext", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SingularMinDepth", .field = "singular_min_depth", .default = 6, .min = 1, .max = 64 },
    .{ .uci_name = "SingularMaxDepth", .field = "singular_max_depth", .default = 64, .min = 1, .max = 64 },
    .{ .uci_name = "SingularTtDepthSlack", .field = "singular_tt_depth_slack", .default = 3, .min = 0, .max = 16 },
    .{ .uci_name = "SingularWeakGate", .field = "singular_weak_gate", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "Ldse", .field = "ldse", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "LdseMargin", .field = "ldse_margin", .default = LDSE_MARGIN_DEFAULT, .min = 0, .max = 20 },
    .{ .uci_name = "LdseDoubleMargin", .field = "ldse_double_margin", .default = LDSE_DOUBLE_MARGIN_DEFAULT, .min = 0, .max = 30 },
    .{ .uci_name = "QsearchTtQuiet", .field = "qsearch_tt_quiet", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "CheckExtension", .field = "check_extension", .default = 1, .min = 0, .max = 1 },
    // Roadmap #2: extension rules.
    .{ .uci_name = "ExtCapBase", .field = "ext_cap_base", .default = 0, .min = 0, .max = 127 },
    .{ .uci_name = "ExtCapPct", .field = "ext_cap_pct", .default = 100, .min = 0, .max = 400 },
    .{ .uci_name = "LdseMaxDepth", .field = "ldse_max_depth", .default = 7, .min = 0, .max = 127 },
    .{ .uci_name = "CheckExtMaxDepth", .field = "check_ext_max_depth", .default = 127, .min = 0, .max = 127 },
    .{ .uci_name = "UextAlphaMax", .field = "uext_alpha_max", .default = 300, .min = -32000, .max = 32000 },
    // Roadmap round 2: the transposition table.
    .{ .uci_name = "TtRefreshOnHit", .field = "tt_refresh_on_hit", .default = @intFromBool(tt.REFRESH_ON_HIT_DEFAULT), .min = 0, .max = 1 },
    .{ .uci_name = "TtKeepMove", .field = "tt_keep_move", .default = @intFromBool(tt.KEEP_MOVE_DEFAULT), .min = 0, .max = 1 },
    .{ .uci_name = "FailLowNoMove", .field = "fail_low_no_move", .default = 1, .min = 0, .max = 2 },
    .{ .uci_name = "TtTagBits", .field = "tt_tag_bits", .default = tt.TAG_BITS, .min = 1, .max = tt.TAG_BITS },
    .{ .uci_name = "TtVerifyKeys", .field = "tt_verify_keys", .default = 0, .min = 0, .max = 1 },
    // Round 3: quiescence move rules.
    .{ .uci_name = "QsMoveFutility", .field = "qs_move_futility", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "QsGainPawn", .field = "qs_gain_pawn", .default = 350, .min = 0, .max = 4000 },
    .{ .uci_name = "QsGainMinor", .field = "qs_gain_minor", .default = 1000, .min = 0, .max = 4000 },
    .{ .uci_name = "QsGainRook", .field = "qs_gain_rook", .default = 1200, .min = 0, .max = 4000 },
    .{ .uci_name = "QsGainQueen", .field = "qs_gain_queen", .default = 1400, .min = 0, .max = 4000 },
    .{ .uci_name = "QsFutilityKeepChecks", .field = "qs_futility_keep_checks", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "QsEqualExchangeMargin", .field = "qs_equal_exchange_margin", .default = 450, .min = 0, .max = 4000 },
    .{ .uci_name = "QsNoUnderpromotion", .field = "qs_no_underpromotion", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "QsCheckGate", .field = "qs_check_gate", .default = 0, .min = 0, .max = 3 },
    .{ .uci_name = "QsCheckMargin", .field = "qs_check_margin", .default = 200, .min = -4000, .max = 4000 },
    .{ .uci_name = "QsCheckFailLows", .field = "qs_check_fail_lows", .default = 2, .min = 1, .max = 64 },
    // Round 3: the singular test's fixed choices.
    .{ .uci_name = "SweepSingMulticut", .field = "sweep_sing_multicut", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingPv", .field = "sweep_sing_pv", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingAll", .field = "sweep_sing_all", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingDoubleMargin", .field = "sweep_sing_double_margin", .default = 20, .min = 0, .max = 1000 },
    .{ .uci_name = "SweepSingExtMargin", .field = "sweep_sing_ext_margin", .default = 0, .min = 0, .max = 1000 },
    .{ .uci_name = "SweepSingMarginBase", .field = "sweep_sing_margin_base", .default = 0, .min = 0, .max = 400 },
    .{ .uci_name = "SweepSingMarginPerPly", .field = "sweep_sing_margin_per_ply", .default = 2, .min = 0, .max = 64 },
    .{ .uci_name = "SweepSingVerifyPct", .field = "sweep_sing_verify_pct", .default = 50, .min = 10, .max = 100 },
    .{ .uci_name = "SweepSingExact", .field = "sweep_sing_exact", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingInCheck", .field = "sweep_sing_in_check", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingPvMinExtra", .field = "sweep_sing_pv_min_extra", .default = 1, .min = 0, .max = 16 },
    .{ .uci_name = "SweepSingVerifySub", .field = "sweep_sing_verify_sub", .default = 1, .min = 0, .max = 8 },
    .{ .uci_name = "SweepSingVerifyInherit", .field = "sweep_sing_verify_inherit", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingDoublePv", .field = "sweep_sing_double_pv", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "SweepSingNegBeta", .field = "sweep_sing_neg_beta", .default = 2, .min = 0, .max = 6 },
    .{ .uci_name = "SweepSingNegCut", .field = "sweep_sing_neg_cut", .default = 2, .min = 0, .max = 6 },
    .{ .uci_name = "SweepSingNegAlpha", .field = "sweep_sing_neg_alpha", .default = 1, .min = 0, .max = 6 },
    .{ .uci_name = "TtEvalRfp", .field = "tt_eval_rfp", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalRazor", .field = "tt_eval_razor", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalNull", .field = "tt_eval_null_move", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalFutility", .field = "tt_eval_futility", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalCheckExt", .field = "tt_eval_check_ext", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalProbCut", .field = "tt_eval_probcut", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalBadCapture", .field = "tt_eval_bad_capture", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalStandPat", .field = "tt_eval_stand_pat", .default = 0, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalRfpReturn", .field = "tt_eval_rfp_return", .default = 1, .min = 0, .max = 1 },
    .{ .uci_name = "TtEvalMinDepth", .field = "tt_eval_min_depth", .default = -1, .min = -1, .max = 32 },
    .{ .uci_name = "LmrVerifyFull", .field = "lmr_verify_full", .default = 2, .min = 0, .max = 3 },
    .{ .uci_name = "RootNodeOrder", .field = "root_node_order", .default = 1, .min = 0, .max = 1 },
};

/// Set a tunable by its UCI name (clamped to [min,max]). Returns true when the
/// name matched a tunable. Out-of-range values clamp rather than error, so an
/// SPSA driver never stalls on a boundary perturbation.
pub fn set(uci_name: []const u8, value: types.Score) bool {
    inline for (specs) |s| {
        if (std.ascii.eqlIgnoreCase(uci_name, s.uci_name)) {
            @import("startup.zig").ensure();
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
    @import("startup.zig").ensure();
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
