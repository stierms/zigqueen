pub const STATIC_SEARCH_RESIDUAL_BUCKET_COUNT: usize = 6;
pub const STATIC_SEARCH_RESIDUAL_BUCKET_NAMES = [_][]const u8{ "0_15", "16_31", "32_63", "64_127", "128_255", "256p" };
pub const StaticSearchResidualCounters = [STATIC_SEARCH_RESIDUAL_BUCKET_COUNT]u64;

pub const MoveOrderBucket = enum(usize) {
    tt,
    promotion,
    good_capture,
    bad_capture,
    killer_a,
    killer_b,
    countermove,
    positive_history_quiet,
    zero_history_quiet,
    negative_history_quiet,
    other,
};

pub const MOVE_ORDER_BUCKET_NAMES = [_][]const u8{
    "tt",
    "promotion",
    "good_capture",
    "bad_capture",
    "killer_a",
    "killer_b",
    "countermove",
    "positive_history_quiet",
    "zero_history_quiet",
    "negative_history_quiet",
    "other",
};
pub const MOVE_ORDER_BUCKET_COUNT: usize = MOVE_ORDER_BUCKET_NAMES.len;
pub const MoveOrderCounters = [MOVE_ORDER_BUCKET_COUNT]u64;

pub const MOVE_ORDER_DEPTH_BAND_NAMES = [_][]const u8{ "d1", "d2_3", "d4_5", "d6_8", "d9p" };
pub const MOVE_ORDER_DEPTH_BAND_COUNT: usize = MOVE_ORDER_DEPTH_BAND_NAMES.len;
pub const MOVE_ORDER_NODE_TYPE_NAMES = [_][]const u8{ "pv", "cut", "all" };
pub const MOVE_ORDER_NODE_TYPE_COUNT: usize = MOVE_ORDER_NODE_TYPE_NAMES.len;
pub const MoveOrderDetailCounters = [MOVE_ORDER_NODE_TYPE_COUNT][MOVE_ORDER_DEPTH_BAND_COUNT][MOVE_ORDER_BUCKET_COUNT]u64;
pub const MoveOrderDetailScoreSums = [MOVE_ORDER_NODE_TYPE_COUNT][MOVE_ORDER_DEPTH_BAND_COUNT][MOVE_ORDER_BUCKET_COUNT]i64;

pub const MoveOrderSample = struct {
    bucket: MoveOrderBucket,
    node_type: usize,
    depth_band: usize,
    history_score: i32,
};

pub fn moveOrderDepthBand(depth: u16) usize {
    if (depth <= 1) return 0;
    if (depth <= 3) return 1;
    if (depth <= 5) return 2;
    if (depth <= 8) return 3;
    return 4;
}

pub fn moveOrderNodeType(pv_node: bool, cut_node: bool) usize {
    if (pv_node) return 0;
    if (cut_node) return 1;
    return 2;
}

pub const zero_move_order_detail_counters: MoveOrderDetailCounters = [_][MOVE_ORDER_DEPTH_BAND_COUNT][MOVE_ORDER_BUCKET_COUNT]u64{
    [_][MOVE_ORDER_BUCKET_COUNT]u64{[_]u64{0} ** MOVE_ORDER_BUCKET_COUNT} ** MOVE_ORDER_DEPTH_BAND_COUNT,
} ** MOVE_ORDER_NODE_TYPE_COUNT;

pub const zero_move_order_detail_score_sums: MoveOrderDetailScoreSums = [_][MOVE_ORDER_DEPTH_BAND_COUNT][MOVE_ORDER_BUCKET_COUNT]i64{
    [_][MOVE_ORDER_BUCKET_COUNT]i64{[_]i64{0} ** MOVE_ORDER_BUCKET_COUNT} ** MOVE_ORDER_DEPTH_BAND_COUNT,
} ** MOVE_ORDER_NODE_TYPE_COUNT;

/// Counters of the extension rules and the switch rules (only_move.zig,
/// extension_bound.zig, switch_confirm.zig); the grids are by node type
/// (pv, cut, all) and node depth band.
pub const ONLY_MOVE_DEPTH_BAND_NAMES = [_][]const u8{ "d2_5", "d6_7", "d8_10", "d11_14", "d15p" };
pub const ONLY_MOVE_DEPTH_BAND_COUNT: usize = ONLY_MOVE_DEPTH_BAND_NAMES.len;
pub const OnlyMoveGrid = [MOVE_ORDER_NODE_TYPE_COUNT][ONLY_MOVE_DEPTH_BAND_COUNT]u64;
pub const zero_only_move_grid: OnlyMoveGrid = [_][ONLY_MOVE_DEPTH_BAND_COUNT]u64{[_]u64{0} ** ONLY_MOVE_DEPTH_BAND_COUNT} ** MOVE_ORDER_NODE_TYPE_COUNT;

pub fn onlyMoveDepthBand(depth: u16) usize {
    if (depth <= 5) return 0;
    if (depth <= 7) return 1;
    if (depth <= 10) return 2;
    if (depth <= 14) return 3;
    return 4;
}

/// Counters of the quiescence move rules (qs_rules.zig). A candidate is a
/// move a rule's test names, counted whether the switch is on (the move is
/// skipped) or off (it is searched, and a raise of the node's best value
/// counts as a miss). The futility grids are by late endgame (0 no, 1 yes;
/// the rule itself stays off there) and victim class.
pub const QsFutilityGrid = [2][4]u64;
pub const zero_qs_futility_grid: QsFutilityGrid = [_][4]u64{[_]u64{0} ** 4} ** 2;
pub const QS_EQUAL_BAND_MARGINS = [_]i32{ 0, 100, 200, 300, 450 };
pub const QS_EQUAL_BAND_COUNT: usize = QS_EQUAL_BAND_MARGINS.len;
pub const QsEqualBands = [QS_EQUAL_BAND_COUNT]u64;
/// A first-ply node's path to its quiet checks: no capture or promotion to
/// try (`empty`), stand-pat within the margin of alpha (`near`), further
/// below with the enemy king boxed in by a side with a queen (`far_boxed`),
/// further below otherwise (`far_open`).
pub const QS_CHECK_PATH_NAMES = [_][]const u8{ "empty", "near", "far_boxed", "far_open" };
pub const QS_CHECK_PATH_COUNT: usize = QS_CHECK_PATH_NAMES.len;
pub const QsCheckPaths = [QS_CHECK_PATH_COUNT]u64;
pub const QsRuleStats = struct {
    /// Captures that are not promotions, outside check, past the exchange test.
    captures: u64 = 0,
    captures_searched: u64 = 0,
    capture_raises: u64 = 0,
    capture_nodes: u64 = 0,
    fut_candidates: QsFutilityGrid = zero_qs_futility_grid,
    fut_searched: QsFutilityGrid = zero_qs_futility_grid,
    fut_misses: QsFutilityGrid = zero_qs_futility_grid,
    fut_nodes: QsFutilityGrid = zero_qs_futility_grid,
    /// The same for the candidates that give check.
    fut_check_candidates: QsFutilityGrid = zero_qs_futility_grid,
    fut_check_searched: QsFutilityGrid = zero_qs_futility_grid,
    fut_check_misses: QsFutilityGrid = zero_qs_futility_grid,
    fut_skipped: u64 = 0,
    /// Captures whose exchange value is exactly 0 (the table move's is not
    /// computed and it is not among them), outside late endgames; `far` by
    /// the distance of the stand-pat below the best value: any, 100, 200,
    /// 300, 450 or more.
    equal_captures: u64 = 0,
    equal_far_searched: QsEqualBands = [_]u64{0} ** QS_EQUAL_BAND_COUNT,
    equal_far_misses: QsEqualBands = [_]u64{0} ** QS_EQUAL_BAND_COUNT,
    equal_far_nodes: QsEqualBands = [_]u64{0} ** QS_EQUAL_BAND_COUNT,
    equal_skipped: u64 = 0,
    /// En passant captures the equal-exchange test would name on their 0,
    /// which is not a computed exchange value: the rule leaves them alone.
    equal_en_passant_kept: u64 = 0,
    /// Promotions outside check: all searched, the knight's, and the rook's
    /// and bishop's (`under`), with raises of the best value and subtree nodes.
    promotions_searched: u64 = 0,
    knight_promotions_searched: u64 = 0,
    knight_promotion_raises: u64 = 0,
    under_searched: u64 = 0,
    under_raises: u64 = 0,
    under_nodes: u64 = 0,
    under_skipped: u64 = 0,
    /// Quiet checks of the first quiescence ply, by the node's path through
    /// the gate (QS_CHECK_PATH_NAMES): searched, raises of the best value,
    /// subtree nodes; and the nodes on each path, gated or not.
    check_stage_nodes: QsCheckPaths = [_]u64{0} ** QS_CHECK_PATH_COUNT,
    checks_searched: QsCheckPaths = [_]u64{0} ** QS_CHECK_PATH_COUNT,
    check_raises: QsCheckPaths = [_]u64{0} ** QS_CHECK_PATH_COUNT,
    check_nodes: QsCheckPaths = [_]u64{0} ** QS_CHECK_PATH_COUNT,
    check_gated_nodes: u64 = 0,
    check_fail_low_stops: u64 = 0,
};

pub const OnlyMoveStats = struct {
    /// Verification searches run.
    verified: OnlyMoveGrid = zero_only_move_grid,
    /// ... that found the hash move to be the only move: +1, +2.
    single: OnlyMoveGrid = zero_only_move_grid,
    double: OnlyMoveGrid = zero_only_move_grid,
    /// ... that ended the node on a second refutation.
    cut: OnlyMoveGrid = zero_only_move_grid,
    /// ... that shortened a hash move which is not the only good one.
    shortened: OnlyMoveGrid = zero_only_move_grid,
    /// Nodes searched inside verification searches.
    verify_nodes: OnlyMoveGrid = zero_only_move_grid,
    verified_in_check: u64 = 0,
    /// Extensions trimmed by the bound on accumulated extension.
    capped: u64 = 0,
    /// Extensions granted, by rule: check, LDSE, verified.
    ext_check: u64 = 0,
    ext_ldse: u64 = 0,
    ext_verified: u64 = 0,
    root_confirms: u64 = 0,
    root_confirms_rejected: u64 = 0,
    root_displaced_scouts: u64 = 0,
    root_displaced_returns: u64 = 0,
    pv_confirms: u64 = 0,
    pv_confirms_rejected: u64 = 0,
};

pub const SearchStats = struct {
    only_move: OnlyMoveStats = .{},
    /// Depth-0 entries that the legacy negamax wrapper and qsearch both counted.
    /// This is a functional exception to the diagnostic-only stats below: root
    /// ordering adds it back to honest nodes to preserve its legacy effort scale.
    horizon_transitions: u64 = 0,
    qnodes: u64 = 0,
    main_static_evals: u64 = 0,
    reverse_futility_prunes: u64 = 0,
    reverse_futility_prunes_depth_1: u64 = 0,
    reverse_futility_prunes_depth_2: u64 = 0,
    reverse_futility_prunes_depth_3: u64 = 0,
    iir_reductions: u64 = 0,
    iir_pv_reductions: u64 = 0,
    iir_cut_reductions: u64 = 0,
    iir_all_reductions: u64 = 0,
    check_extensions: u64 = 0,
    hindsight_depth_extensions: u64 = 0,
    hindsight_depth_reductions: u64 = 0,
    // Raw-eval cache (perf-r11). Probes happen ONLY after a TT static-eval
    // miss, so hits/probes IS the hit-after-TT-miss rate.
    eval_cache_probes: u64 = 0,
    eval_cache_hits: u64 = 0,
    eval_cache_q_probes: u64 = 0,
    eval_cache_q_hits: u64 = 0,
    quiet_futility_prunes: u64 = 0,
    late_move_prunes: u64 = 0,
    bad_capture_prunes: u64 = 0,
    tt_probes: u64 = 0,
    tt_hits: u64 = 0,
    /// Hits on an entry of another position with the same cluster and tag
    /// (stats flavour, serial table: tt.Entry.foreign).
    tt_foreign_hits: u64 = 0,
    tt_hit_current_generation: u64 = 0,
    tt_hit_old_generation: u64 = 0,
    tt_hit_age_1: u64 = 0,
    tt_hit_age_2_3: u64 = 0,
    tt_hit_age_4p: u64 = 0,
    tt_hit_with_move: u64 = 0,
    tt_hit_without_move: u64 = 0,
    tt_hit_exact_bound: u64 = 0,
    tt_hit_lower_bound: u64 = 0,
    tt_hit_upper_bound: u64 = 0,
    tt_shallow_hits: u64 = 0,
    tt_ordering_only_hits: u64 = 0,
    tt_ordering_only_current_generation: u64 = 0,
    tt_ordering_only_old_generation: u64 = 0,
    tt_bound_no_cutoff_hits: u64 = 0,
    tt_cutoffs: u64 = 0,
    tt_cutoffs_current_generation: u64 = 0,
    tt_cutoffs_old_generation: u64 = 0,
    tt_stores: u64 = 0,
    tt_store_skipped_same_generation_deeper: u64 = 0,
    tt_store_skip_new_with_move: u64 = 0,
    tt_store_skip_new_without_move: u64 = 0,
    tt_store_skip_victim_with_move: u64 = 0,
    tt_store_skip_victim_without_move: u64 = 0,
    tt_store_empty: u64 = 0,
    tt_store_same_key: u64 = 0,
    tt_store_replacements: u64 = 0,
    tt_store_replaced_current_generation: u64 = 0,
    tt_store_replaced_old_generation: u64 = 0,
    tt_store_replaced_with_move: u64 = 0,
    tt_store_replaced_without_move: u64 = 0,
    tt_store_replaced_exact_bound: u64 = 0,
    tt_store_replaced_lower_bound: u64 = 0,
    tt_store_replaced_upper_bound: u64 = 0,
    tt_store_new_with_move: u64 = 0,
    tt_store_new_without_move: u64 = 0,
    tt_store_new_exact_bound: u64 = 0,
    tt_store_new_lower_bound: u64 = 0,
    tt_store_new_upper_bound: u64 = 0,
    tt_exact_cutoffs: u64 = 0,
    tt_lower_cutoffs: u64 = 0,
    tt_upper_cutoffs: u64 = 0,
    beta_cutoffs: u64 = 0,
    beta_cutoffs_first: u64 = 0,
    main_capture_cutoffs: u64 = 0,
    main_capture_cutoffs_first: u64 = 0,
    main_capture_cutoffs_1_2: u64 = 0,
    main_capture_cutoffs_3_5: u64 = 0,
    main_capture_cutoffs_6p: u64 = 0,
    main_good_capture_cutoffs: u64 = 0,
    main_bad_capture_cutoffs: u64 = 0,
    main_quiet_cutoffs: u64 = 0,
    main_quiet_cutoffs_first: u64 = 0,
    main_quiet_cutoffs_1_2: u64 = 0,
    main_quiet_cutoffs_3_5: u64 = 0,
    main_quiet_cutoffs_6p: u64 = 0,
    main_quiet_tt_cutoffs: u64 = 0,
    main_quiet_killer_a_cutoffs: u64 = 0,
    main_quiet_killer_b_cutoffs: u64 = 0,
    main_quiet_countermove_cutoffs: u64 = 0,
    countermove_table_probes: u64 = 0,
    countermove_table_misses: u64 = 0,
    countermove_table_hits: u64 = 0,
    countermove_table_legal_hits: u64 = 0,
    countermove_table_stale_hits: u64 = 0,
    main_quiet_positive_history_cutoffs: u64 = 0,
    main_quiet_nonpositive_history_cutoffs: u64 = 0,
    qsearch_capture_cutoffs: u64 = 0,
    qsearch_capture_cutoffs_first: u64 = 0,
    qsearch_capture_cutoffs_1_2: u64 = 0,
    qsearch_capture_cutoffs_3_5: u64 = 0,
    qsearch_capture_cutoffs_6p: u64 = 0,
    qsearch_good_capture_cutoffs: u64 = 0,
    qsearch_bad_capture_cutoffs: u64 = 0,
    null_tries: u64 = 0,
    null_cutoffs: u64 = 0,
    null_verify_rejects: u64 = 0,
    hard_stops_external: u64 = 0,
    hard_stops_node_limit: u64 = 0,
    hard_stops_maximum_budget: u64 = 0,
    /// TM v2: armed soft deadline reached inside an iteration.
    hard_stops_soft_budget: u64 = 0,
    /// TM v2 C1: interrupted iterations that supplied the played move.
    interrupted_challengers: u64 = 0,
    lmr_reductions: u64 = 0,
    lmr_total_reduction: u64 = 0,
    lmr_pv_reductions: u64 = 0,
    lmr_nonpv_reductions: u64 = 0,
    lmr_cut_reductions: u64 = 0,
    lmr_all_reductions: u64 = 0,
    lmr_cut_reductions_3_5: u64 = 0,
    lmr_cut_reductions_6_7: u64 = 0,
    lmr_cut_reductions_8p: u64 = 0,
    lmr_deep_reductions: u64 = 0,
    lmr_cut_deep_reductions: u64 = 0,
    lmr_all_deep_reductions: u64 = 0,
    lmr_researches: u64 = 0,
    lmr_pv_researches: u64 = 0,
    lmr_nonpv_researches: u64 = 0,
    lmr_cut_researches: u64 = 0,
    lmr_all_researches: u64 = 0,
    lmr_cut_researches_3_5: u64 = 0,
    lmr_cut_researches_6_7: u64 = 0,
    lmr_cut_researches_8p: u64 = 0,
    lmr_deep_researches: u64 = 0,
    lmr_cut_deep_researches: u64 = 0,
    lmr_all_deep_researches: u64 = 0,
    lmr_cut_deep_researches_3_5: u64 = 0,
    lmr_cut_deep_researches_6_7: u64 = 0,
    lmr_cut_deep_researches_8p: u64 = 0,
    lmr_all_deep_researches_3_5: u64 = 0,
    lmr_all_deep_researches_6_7: u64 = 0,
    lmr_all_deep_researches_8p: u64 = 0,
    lmr_cut_deep_research_margin_0_31: u64 = 0,
    lmr_cut_deep_research_margin_32_95: u64 = 0,
    lmr_cut_deep_research_margin_96p: u64 = 0,
    lmr_all_deep_research_margin_0_31: u64 = 0,
    lmr_all_deep_research_margin_32_95: u64 = 0,
    lmr_all_deep_research_margin_96p: u64 = 0,
    lmr_cut_deep_research_nonpositive_history: u64 = 0,
    lmr_cut_deep_research_positive_history: u64 = 0,
    lmr_all_deep_research_nonpositive_history: u64 = 0,
    lmr_all_deep_research_positive_history: u64 = 0,
    lmr_verification_fail_lows: u64 = 0,
    lmr_verification_alpha_raises: u64 = 0,
    lmr_verification_cutoffs: u64 = 0,
    lmr_deep_verification_fail_lows: u64 = 0,
    lmr_deep_verification_alpha_raises: u64 = 0,
    lmr_deep_verification_cutoffs: u64 = 0,
    lmr_cut_verification_alpha_raises: u64 = 0,
    lmr_cut_deep_verification_fail_lows: u64 = 0,
    lmr_cut_deep_verification_alpha_raises: u64 = 0,
    lmr_cut_deep_verification_cutoffs: u64 = 0,
    lmr_cut_deep_verification_fail_lows_3_5: u64 = 0,
    lmr_cut_deep_verification_fail_lows_6_7: u64 = 0,
    lmr_cut_deep_verification_fail_lows_8p: u64 = 0,
    lmr_cut_deep_verification_cutoffs_3_5: u64 = 0,
    lmr_cut_deep_verification_cutoffs_6_7: u64 = 0,
    lmr_cut_deep_verification_cutoffs_8p: u64 = 0,
    lmr_all_deep_verification_fail_lows_3_5: u64 = 0,
    lmr_all_deep_verification_fail_lows_6_7: u64 = 0,
    lmr_all_deep_verification_fail_lows_8p: u64 = 0,
    lmr_all_deep_verification_cutoffs_3_5: u64 = 0,
    lmr_all_deep_verification_cutoffs_6_7: u64 = 0,
    lmr_all_deep_verification_cutoffs_8p: u64 = 0,
    lmr_cut_deep_verification_fail_lows_nonpositive_history: u64 = 0,
    lmr_cut_deep_verification_fail_lows_positive_history: u64 = 0,
    lmr_cut_deep_verification_cutoffs_nonpositive_history: u64 = 0,
    lmr_cut_deep_verification_cutoffs_positive_history: u64 = 0,
    lmr_all_deep_verification_fail_lows_nonpositive_history: u64 = 0,
    lmr_all_deep_verification_fail_lows_positive_history: u64 = 0,
    lmr_all_deep_verification_cutoffs_nonpositive_history: u64 = 0,
    lmr_all_deep_verification_cutoffs_positive_history: u64 = 0,
    lmr_cut_verification_fail_lows_3_5: u64 = 0,
    lmr_cut_verification_fail_lows_6_7: u64 = 0,
    lmr_cut_verification_fail_lows_8p: u64 = 0,
    lmr_cut_verification_cutoffs_3_5: u64 = 0,
    lmr_cut_verification_cutoffs_6_7: u64 = 0,
    lmr_cut_verification_cutoffs_8p: u64 = 0,
    lmr_cut_cutoffs: u64 = 0,
    lmr_cut_cutoffs_3_5: u64 = 0,
    lmr_cut_cutoffs_6_7: u64 = 0,
    lmr_cut_cutoffs_8p: u64 = 0,
    singular_candidates: u64 = 0,
    singular_cut_candidates: u64 = 0,
    singular_candidates_6_7: u64 = 0,
    singular_candidates_8p: u64 = 0,
    singular_weak_alternative_candidates: u64 = 0,
    singular_verifications: u64 = 0,
    singular_verified: u64 = 0,
    singular_extensions: u64 = 0,
    /// Of those, extensions by two plies (sweep_sing_double_margin).
    singular_double_extensions: u64 = 0,
    /// Nodes cut by the singular test's multicut.
    singular_multicuts: u64 = 0,
    /// Verification searches at PV nodes / at expected all nodes (sweep_sing_pv, sweep_sing_all).
    singular_pv_verifications: u64 = 0,
    singular_all_verifications: u64 = 0,
    /// Root iterations in which the move that repeats the game's earlier
    /// cycle asked for the tie-break against an equal draw score, and those
    /// in which its search below the draw refused it (root.zig).
    root_cycle_tie_asked: u64 = 0,
    root_cycle_tie_refused: u64 = 0,
    root_cycle_tie_granted: u64 = 0,
    /// Nodes of those searches.
    root_cycle_tie_nodes: u64 = 0,
    // The table's score against the static value (tt_eval.zig), counted
    // whatever the switches. Main search, nodes outside check:
    /// nodes with a static eval;
    tt_eval_nodes: u64 = 0,
    /// of them with an entry whose score is not decisive (no excluded move);
    tt_eval_entries: u64 = 0,
    /// of them where the bound contradicts the static value (the score is taken), and the sum of the distances;
    tt_eval_differs: u64 = 0,
    tt_eval_distance: u64 = 0,
    /// of those by more than 50, and those resting on a quiescence entry (depth 0 or less);
    tt_eval_differs_50: u64 = 0,
    tt_eval_differs_qs_entry: u64 = 0,
    /// zero-window nodes: static value below beta under a lower bound at or above beta / static value at or above beta over an upper or exact score below beta;
    tt_eval_lower_over_beta: u64 = 0,
    tt_eval_upper_under_beta: u64 = 0,
    /// reverse futility: cuts on the static value / cuts only the table's score makes / cuts the table's score refuses.
    tt_eval_rfp_static: u64 = 0,
    tt_eval_rfp_gained: u64 = 0,
    tt_eval_rfp_refused: u64 = 0,
    /// Quiescence, nodes outside check: nodes / the score is taken / stand-pat cutoffs gained / refused.
    tt_eval_qs_nodes: u64 = 0,
    tt_eval_qs_differs: u64 = 0,
    tt_eval_qs_gained: u64 = 0,
    tt_eval_qs_refused: u64 = 0,
    pvs_scouts: u64 = 0,
    pvs_researches: u64 = 0,
    aspiration_researches: u64 = 0,
    aspiration_fail_lows: u64 = 0,
    aspiration_fail_highs: u64 = 0,
    qsearch_stand_pat_cutoffs: u64 = 0,
    staged_main_movegen_nodes: u64 = 0,
    staged_main_legal_moves: u64 = 0,
    staged_main_quiet_moves: u64 = 0,
    staged_main_tactical_moves: u64 = 0,
    staged_main_tt_legal_nodes: u64 = 0,
    staged_main_nodes_with_quiets: u64 = 0,
    staged_main_no_quiet_searched_nodes: u64 = 0,
    staged_main_no_quiet_searched_quiet_moves: u64 = 0,
    qsearch_tactical_nodes: u64 = 0,
    qsearch_tactical_moves: u64 = 0,
    qsearch_bad_capture_skips: u64 = 0,
    qs_rules: QsRuleStats = .{},
    static_search_residual_nodes: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_exact: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_lower: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_upper: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_rfp: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_null: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_quiet_futility: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_late_move: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_bad_capture: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_lmr_research: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    static_search_residual_lmr_verification_fail_low: StaticSearchResidualCounters = [_]u64{0} ** STATIC_SEARCH_RESIDUAL_BUCKET_COUNT,
    move_order_searched: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_cutoffs: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_first_cutoffs: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_lmr_reductions: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_lmr_researches: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_lmr_fail_lows: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_lmr_cutoffs: MoveOrderCounters = [_]u64{0} ** MOVE_ORDER_BUCKET_COUNT,
    move_order_detail_searched: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_cutoffs: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_first_cutoffs: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_lmr_reductions: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_lmr_researches: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_lmr_fail_lows: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_lmr_cutoffs: MoveOrderDetailCounters = zero_move_order_detail_counters,
    move_order_detail_history_score_sum: MoveOrderDetailScoreSums = zero_move_order_detail_score_sums,
    iteration_stop_maximum_elapsed: u64 = 0,
    iteration_stop_maximum_projected: u64 = 0,
    iteration_stop_optimum_elapsed: u64 = 0,
    iteration_stop_optimum_projected: u64 = 0,
};
