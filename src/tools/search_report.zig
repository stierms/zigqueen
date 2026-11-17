const std = @import("std");
const root = @import("../search/root.zig");
const search_engine = @import("../search/engine.zig");
const stats_mod = @import("../search/stats.zig");

pub fn write(writer: anytype, result: *const search_engine.SearchResult, elapsed_ms: u64, hashfull: u16) !void {
    const nps: u64 = if (elapsed_ms == 0) 0 else (result.nodes * std.time.ms_per_s) / elapsed_ms;
    const stats = result.diagnostics.stats;
    // Saturating: a hard-stopped (timed) search can leave the total-node and
    // qnode counters momentarily inconsistent (qnodes briefly > total).
    const main_nodes = result.nodes -| stats.qnodes;

    var move_buffer: [5]u8 = undefined;
    const bestmove = if (result.best_move) |mv| mv.toUci(&move_buffer) else "0000";

    try writer.print("depth {d}\n", .{result.depth});
    try writer.print("seldepth {d}\n", .{result.seldepth});
    try writer.print("score {d}\n", .{result.score});
    try writer.print("nodes {d}\n", .{result.nodes});
    try writer.print("horizon_transitions {d}\n", .{stats.horizon_transitions});
    try writer.print("main_nodes {d}\n", .{main_nodes});
    try writer.print("qnodes {d}\n", .{stats.qnodes});
    try writer.print("qnode_ratio_permille {d}\n", .{ratioPermille(stats.qnodes, result.nodes)});
    try writer.print("main_static_evals {d}\n", .{stats.main_static_evals});
    try writer.print("reverse_futility_prunes {d}\n", .{stats.reverse_futility_prunes});
    try writer.print("reverse_futility_prunes_depth_1 {d}\n", .{stats.reverse_futility_prunes_depth_1});
    try writer.print("reverse_futility_prunes_depth_2 {d}\n", .{stats.reverse_futility_prunes_depth_2});
    try writer.print("reverse_futility_prunes_depth_3 {d}\n", .{stats.reverse_futility_prunes_depth_3});
    try writer.print("reverse_futility_rate_permille {d}\n", .{ratioPermille(stats.reverse_futility_prunes, stats.main_static_evals)});
    try writer.print("iir_reductions {d}\n", .{stats.iir_reductions});
    try writer.print("iir_pv_reductions {d}\n", .{stats.iir_pv_reductions});
    try writer.print("iir_cut_reductions {d}\n", .{stats.iir_cut_reductions});
    try writer.print("iir_all_reductions {d}\n", .{stats.iir_all_reductions});
    try writer.print("check_extensions {d}\n", .{stats.check_extensions});
    try writer.print("hindsight_depth_extensions {d}\n", .{stats.hindsight_depth_extensions});
    try writer.print("hindsight_depth_reductions {d}\n", .{stats.hindsight_depth_reductions});
    // Raw-eval cache (perf-r11): probes fire only after a TT static-eval miss,
    // so the hit rates below ARE the hit-after-TT-miss rates per phase.
    try writer.print("eval_cache_probes {d}\n", .{stats.eval_cache_probes});
    try writer.print("eval_cache_hits {d}\n", .{stats.eval_cache_hits});
    try writer.print("eval_cache_hit_after_tt_miss_permille {d}\n", .{ratioPermille(stats.eval_cache_hits, stats.eval_cache_probes)});
    try writer.print("eval_cache_q_probes {d}\n", .{stats.eval_cache_q_probes});
    try writer.print("eval_cache_q_hits {d}\n", .{stats.eval_cache_q_hits});
    try writer.print("eval_cache_q_hit_after_tt_miss_permille {d}\n", .{ratioPermille(stats.eval_cache_q_hits, stats.eval_cache_q_probes)});
    try writer.print("quiet_futility_prunes {d}\n", .{stats.quiet_futility_prunes});
    try writer.print("quiet_futility_rate_permille {d}\n", .{ratioPermille(stats.quiet_futility_prunes, stats.main_static_evals)});
    try writer.print("late_move_prunes {d}\n", .{stats.late_move_prunes});
    try writer.print("bad_capture_prunes {d}\n", .{stats.bad_capture_prunes});
    try writer.print("bad_capture_rate_permille {d}\n", .{ratioPermille(stats.bad_capture_prunes, stats.main_static_evals)});
    try writer.print("time_ms {d}\n", .{elapsed_ms});
    try writer.print("nps {d}\n", .{nps});
    try writer.print("hashfull {d}\n", .{hashfull});
    try writer.print("tt_probes {d}\n", .{stats.tt_probes});
    try writer.print("tt_hits {d}\n", .{stats.tt_hits});
    try writer.print("tt_hit_current_generation {d}\n", .{stats.tt_hit_current_generation});
    try writer.print("tt_hit_old_generation {d}\n", .{stats.tt_hit_old_generation});
    try writer.print("tt_hit_age_1 {d}\n", .{stats.tt_hit_age_1});
    try writer.print("tt_hit_age_2_3 {d}\n", .{stats.tt_hit_age_2_3});
    try writer.print("tt_hit_age_4p {d}\n", .{stats.tt_hit_age_4p});
    try writer.print("tt_hit_with_move {d}\n", .{stats.tt_hit_with_move});
    try writer.print("tt_hit_without_move {d}\n", .{stats.tt_hit_without_move});
    try writer.print("tt_hit_exact_bound {d}\n", .{stats.tt_hit_exact_bound});
    try writer.print("tt_hit_lower_bound {d}\n", .{stats.tt_hit_lower_bound});
    try writer.print("tt_hit_upper_bound {d}\n", .{stats.tt_hit_upper_bound});
    try writer.print("tt_shallow_hits {d}\n", .{stats.tt_shallow_hits});
    try writer.print("tt_ordering_only_hits {d}\n", .{stats.tt_ordering_only_hits});
    try writer.print("tt_ordering_only_current_generation {d}\n", .{stats.tt_ordering_only_current_generation});
    try writer.print("tt_ordering_only_old_generation {d}\n", .{stats.tt_ordering_only_old_generation});
    try writer.print("tt_bound_no_cutoff_hits {d}\n", .{stats.tt_bound_no_cutoff_hits});
    try writer.print("tt_hit_rate_permille {d}\n", .{ratioPermille(stats.tt_hits, stats.tt_probes)});
    try writer.print("tt_cutoffs {d}\n", .{stats.tt_cutoffs});
    try writer.print("tt_cutoffs_current_generation {d}\n", .{stats.tt_cutoffs_current_generation});
    try writer.print("tt_cutoffs_old_generation {d}\n", .{stats.tt_cutoffs_old_generation});
    try writer.print("tt_stores {d}\n", .{stats.tt_stores});
    try writer.print("tt_store_skipped_same_generation_deeper {d}\n", .{stats.tt_store_skipped_same_generation_deeper});
    try writer.print("tt_store_skip_new_with_move {d}\n", .{stats.tt_store_skip_new_with_move});
    try writer.print("tt_store_skip_new_without_move {d}\n", .{stats.tt_store_skip_new_without_move});
    try writer.print("tt_store_skip_victim_with_move {d}\n", .{stats.tt_store_skip_victim_with_move});
    try writer.print("tt_store_skip_victim_without_move {d}\n", .{stats.tt_store_skip_victim_without_move});
    try writer.print("tt_store_empty {d}\n", .{stats.tt_store_empty});
    try writer.print("tt_store_same_key {d}\n", .{stats.tt_store_same_key});
    try writer.print("tt_store_replacements {d}\n", .{stats.tt_store_replacements});
    try writer.print("tt_store_replaced_current_generation {d}\n", .{stats.tt_store_replaced_current_generation});
    try writer.print("tt_store_replaced_old_generation {d}\n", .{stats.tt_store_replaced_old_generation});
    try writer.print("tt_store_replaced_with_move {d}\n", .{stats.tt_store_replaced_with_move});
    try writer.print("tt_store_replaced_without_move {d}\n", .{stats.tt_store_replaced_without_move});
    try writer.print("tt_store_replaced_exact_bound {d}\n", .{stats.tt_store_replaced_exact_bound});
    try writer.print("tt_store_replaced_lower_bound {d}\n", .{stats.tt_store_replaced_lower_bound});
    try writer.print("tt_store_replaced_upper_bound {d}\n", .{stats.tt_store_replaced_upper_bound});
    try writer.print("tt_store_new_with_move {d}\n", .{stats.tt_store_new_with_move});
    try writer.print("tt_store_new_without_move {d}\n", .{stats.tt_store_new_without_move});
    try writer.print("tt_store_new_exact_bound {d}\n", .{stats.tt_store_new_exact_bound});
    try writer.print("tt_store_new_lower_bound {d}\n", .{stats.tt_store_new_lower_bound});
    try writer.print("tt_store_new_upper_bound {d}\n", .{stats.tt_store_new_upper_bound});
    try writer.print("tt_exact_cutoffs {d}\n", .{stats.tt_exact_cutoffs});
    try writer.print("tt_lower_cutoffs {d}\n", .{stats.tt_lower_cutoffs});
    try writer.print("tt_upper_cutoffs {d}\n", .{stats.tt_upper_cutoffs});
    try writer.print("beta_cutoffs {d}\n", .{stats.beta_cutoffs});
    try writer.print("beta_cutoffs_first {d}\n", .{stats.beta_cutoffs_first});
    try writer.print("beta_first_ratio_permille {d}\n", .{ratioPermille(stats.beta_cutoffs_first, stats.beta_cutoffs)});
    try writer.print("main_capture_cutoffs {d}\n", .{stats.main_capture_cutoffs});
    try writer.print("main_capture_cutoffs_first {d}\n", .{stats.main_capture_cutoffs_first});
    try writer.print("main_capture_cutoffs_1_2 {d}\n", .{stats.main_capture_cutoffs_1_2});
    try writer.print("main_capture_cutoffs_3_5 {d}\n", .{stats.main_capture_cutoffs_3_5});
    try writer.print("main_capture_cutoffs_6p {d}\n", .{stats.main_capture_cutoffs_6p});
    try writer.print("main_good_capture_cutoffs {d}\n", .{stats.main_good_capture_cutoffs});
    try writer.print("main_bad_capture_cutoffs {d}\n", .{stats.main_bad_capture_cutoffs});
    try writer.print("main_quiet_cutoffs {d}\n", .{stats.main_quiet_cutoffs});
    try writer.print("main_quiet_cutoffs_first {d}\n", .{stats.main_quiet_cutoffs_first});
    try writer.print("main_quiet_cutoffs_1_2 {d}\n", .{stats.main_quiet_cutoffs_1_2});
    try writer.print("main_quiet_cutoffs_3_5 {d}\n", .{stats.main_quiet_cutoffs_3_5});
    try writer.print("main_quiet_cutoffs_6p {d}\n", .{stats.main_quiet_cutoffs_6p});
    try writer.print("main_quiet_tt_cutoffs {d}\n", .{stats.main_quiet_tt_cutoffs});
    try writer.print("main_quiet_killer_a_cutoffs {d}\n", .{stats.main_quiet_killer_a_cutoffs});
    try writer.print("main_quiet_killer_b_cutoffs {d}\n", .{stats.main_quiet_killer_b_cutoffs});
    try writer.print("main_quiet_countermove_cutoffs {d}\n", .{stats.main_quiet_countermove_cutoffs});
    try writer.print("countermove_table_probes {d}\n", .{stats.countermove_table_probes});
    try writer.print("countermove_table_misses {d}\n", .{stats.countermove_table_misses});
    try writer.print("countermove_table_hits {d}\n", .{stats.countermove_table_hits});
    try writer.print("countermove_table_legal_hits {d}\n", .{stats.countermove_table_legal_hits});
    try writer.print("countermove_table_stale_hits {d}\n", .{stats.countermove_table_stale_hits});
    try writer.print("countermove_table_hit_permille {d}\n", .{ratioPermille(stats.countermove_table_hits, stats.countermove_table_probes)});
    try writer.print("countermove_table_legal_hit_permille {d}\n", .{ratioPermille(stats.countermove_table_legal_hits, stats.countermove_table_hits)});
    try writer.print("main_quiet_positive_history_cutoffs {d}\n", .{stats.main_quiet_positive_history_cutoffs});
    try writer.print("main_quiet_nonpositive_history_cutoffs {d}\n", .{stats.main_quiet_nonpositive_history_cutoffs});
    try writer.print("qsearch_capture_cutoffs {d}\n", .{stats.qsearch_capture_cutoffs});
    try writer.print("qsearch_capture_cutoffs_first {d}\n", .{stats.qsearch_capture_cutoffs_first});
    try writer.print("qsearch_capture_cutoffs_1_2 {d}\n", .{stats.qsearch_capture_cutoffs_1_2});
    try writer.print("qsearch_capture_cutoffs_3_5 {d}\n", .{stats.qsearch_capture_cutoffs_3_5});
    try writer.print("qsearch_capture_cutoffs_6p {d}\n", .{stats.qsearch_capture_cutoffs_6p});
    try writer.print("qsearch_good_capture_cutoffs {d}\n", .{stats.qsearch_good_capture_cutoffs});
    try writer.print("qsearch_bad_capture_cutoffs {d}\n", .{stats.qsearch_bad_capture_cutoffs});
    try writer.print("null_tries {d}\n", .{stats.null_tries});
    try writer.print("null_cutoffs {d}\n", .{stats.null_cutoffs});
    try writer.print("null_cutoff_rate_permille {d}\n", .{ratioPermille(stats.null_cutoffs, stats.null_tries)});
    try writer.print("hard_stops_external {d}\n", .{stats.hard_stops_external});
    try writer.print("hard_stops_node_limit {d}\n", .{stats.hard_stops_node_limit});
    try writer.print("hard_stops_maximum_budget {d}\n", .{stats.hard_stops_maximum_budget});
    try writer.print("hard_stops_soft_budget {d}\n", .{stats.hard_stops_soft_budget});
    try writer.print("interrupted_challengers {d}\n", .{stats.interrupted_challengers});
    try writer.print("iteration_stop_maximum_elapsed {d}\n", .{stats.iteration_stop_maximum_elapsed});
    try writer.print("iteration_stop_maximum_projected {d}\n", .{stats.iteration_stop_maximum_projected});
    try writer.print("iteration_stop_optimum_elapsed {d}\n", .{stats.iteration_stop_optimum_elapsed});
    try writer.print("iteration_stop_optimum_projected {d}\n", .{stats.iteration_stop_optimum_projected});
    try writer.print("last_iteration_elapsed_ms {d}\n", .{@divFloor(result.diagnostics.last_iteration_elapsed_ns, std.time.ns_per_ms)});
    try writer.print("projected_next_iteration_ms {d}\n", .{@divFloor(result.diagnostics.projected_next_iteration_ns, std.time.ns_per_ms)});
    try writer.print("stable_iteration_streak {d}\n", .{result.diagnostics.stable_iteration_streak});
    try writer.print("iteration_stop_reason {s}\n", .{stopReasonName(result.diagnostics.iteration_stop_reason)});
    try writer.print("lmr_reductions {d}\n", .{stats.lmr_reductions});
    try writer.print("lmr_total_reduction {d}\n", .{stats.lmr_total_reduction});
    try writer.print("lmr_avg_reduction_permille {d}\n", .{ratioPermille(stats.lmr_total_reduction, stats.lmr_reductions)});
    try writer.print("lmr_pv_reductions {d}\n", .{stats.lmr_pv_reductions});
    try writer.print("lmr_nonpv_reductions {d}\n", .{stats.lmr_nonpv_reductions});
    try writer.print("lmr_cut_reductions {d}\n", .{stats.lmr_cut_reductions});
    try writer.print("lmr_all_reductions {d}\n", .{stats.lmr_all_reductions});
    try writer.print("lmr_cut_reductions_3_5 {d}\n", .{stats.lmr_cut_reductions_3_5});
    try writer.print("lmr_cut_reductions_6_7 {d}\n", .{stats.lmr_cut_reductions_6_7});
    try writer.print("lmr_cut_reductions_8p {d}\n", .{stats.lmr_cut_reductions_8p});
    try writer.print("lmr_cut_rate_permille {d}\n", .{ratioPermille(stats.lmr_cut_reductions, stats.lmr_nonpv_reductions)});
    try writer.print("lmr_deep_reductions {d}\n", .{stats.lmr_deep_reductions});
    try writer.print("lmr_cut_deep_reductions {d}\n", .{stats.lmr_cut_deep_reductions});
    try writer.print("lmr_all_deep_reductions {d}\n", .{stats.lmr_all_deep_reductions});
    try writer.print("lmr_deep_rate_permille {d}\n", .{ratioPermille(stats.lmr_deep_reductions, stats.lmr_reductions)});
    try writer.print("lmr_researches {d}\n", .{stats.lmr_researches});
    try writer.print("lmr_pv_researches {d}\n", .{stats.lmr_pv_researches});
    try writer.print("lmr_nonpv_researches {d}\n", .{stats.lmr_nonpv_researches});
    try writer.print("lmr_cut_researches {d}\n", .{stats.lmr_cut_researches});
    try writer.print("lmr_all_researches {d}\n", .{stats.lmr_all_researches});
    try writer.print("lmr_cut_researches_3_5 {d}\n", .{stats.lmr_cut_researches_3_5});
    try writer.print("lmr_cut_researches_6_7 {d}\n", .{stats.lmr_cut_researches_6_7});
    try writer.print("lmr_cut_researches_8p {d}\n", .{stats.lmr_cut_researches_8p});
    try writer.print("lmr_deep_researches {d}\n", .{stats.lmr_deep_researches});
    try writer.print("lmr_cut_deep_researches {d}\n", .{stats.lmr_cut_deep_researches});
    try writer.print("lmr_all_deep_researches {d}\n", .{stats.lmr_all_deep_researches});
    try writer.print("lmr_cut_deep_researches_3_5 {d}\n", .{stats.lmr_cut_deep_researches_3_5});
    try writer.print("lmr_cut_deep_researches_6_7 {d}\n", .{stats.lmr_cut_deep_researches_6_7});
    try writer.print("lmr_cut_deep_researches_8p {d}\n", .{stats.lmr_cut_deep_researches_8p});
    try writer.print("lmr_all_deep_researches_3_5 {d}\n", .{stats.lmr_all_deep_researches_3_5});
    try writer.print("lmr_all_deep_researches_6_7 {d}\n", .{stats.lmr_all_deep_researches_6_7});
    try writer.print("lmr_all_deep_researches_8p {d}\n", .{stats.lmr_all_deep_researches_8p});
    try writer.print("lmr_cut_deep_research_margin_0_31 {d}\n", .{stats.lmr_cut_deep_research_margin_0_31});
    try writer.print("lmr_cut_deep_research_margin_32_95 {d}\n", .{stats.lmr_cut_deep_research_margin_32_95});
    try writer.print("lmr_cut_deep_research_margin_96p {d}\n", .{stats.lmr_cut_deep_research_margin_96p});
    try writer.print("lmr_all_deep_research_margin_0_31 {d}\n", .{stats.lmr_all_deep_research_margin_0_31});
    try writer.print("lmr_all_deep_research_margin_32_95 {d}\n", .{stats.lmr_all_deep_research_margin_32_95});
    try writer.print("lmr_all_deep_research_margin_96p {d}\n", .{stats.lmr_all_deep_research_margin_96p});
    try writer.print("lmr_cut_deep_research_nonpositive_history {d}\n", .{stats.lmr_cut_deep_research_nonpositive_history});
    try writer.print("lmr_cut_deep_research_positive_history {d}\n", .{stats.lmr_cut_deep_research_positive_history});
    try writer.print("lmr_all_deep_research_nonpositive_history {d}\n", .{stats.lmr_all_deep_research_nonpositive_history});
    try writer.print("lmr_all_deep_research_positive_history {d}\n", .{stats.lmr_all_deep_research_positive_history});
    try writer.print("lmr_deep_research_rate_permille {d}\n", .{ratioPermille(stats.lmr_deep_researches, stats.lmr_researches)});
    try writer.print("lmr_verification_fail_lows {d}\n", .{stats.lmr_verification_fail_lows});
    try writer.print("lmr_verification_alpha_raises {d}\n", .{stats.lmr_verification_alpha_raises});
    try writer.print("lmr_verification_cutoffs {d}\n", .{stats.lmr_verification_cutoffs});
    try writer.print("lmr_deep_verification_fail_lows {d}\n", .{stats.lmr_deep_verification_fail_lows});
    try writer.print("lmr_deep_verification_alpha_raises {d}\n", .{stats.lmr_deep_verification_alpha_raises});
    try writer.print("lmr_deep_verification_cutoffs {d}\n", .{stats.lmr_deep_verification_cutoffs});
    try writer.print("lmr_verification_fail_low_rate_permille {d}\n", .{ratioPermille(stats.lmr_verification_fail_lows, stats.lmr_researches)});
    try writer.print("lmr_verification_cutoff_rate_permille {d}\n", .{ratioPermille(stats.lmr_verification_cutoffs, stats.lmr_researches)});
    try writer.print("lmr_deep_verification_fail_low_rate_permille {d}\n", .{ratioPermille(stats.lmr_deep_verification_fail_lows, stats.lmr_deep_researches)});
    try writer.print("lmr_deep_verification_cutoff_rate_permille {d}\n", .{ratioPermille(stats.lmr_deep_verification_cutoffs, stats.lmr_deep_researches)});
    try writer.print("lmr_cut_verification_alpha_raises {d}\n", .{stats.lmr_cut_verification_alpha_raises});
    try writer.print("lmr_cut_deep_verification_fail_lows {d}\n", .{stats.lmr_cut_deep_verification_fail_lows});
    try writer.print("lmr_cut_deep_verification_alpha_raises {d}\n", .{stats.lmr_cut_deep_verification_alpha_raises});
    try writer.print("lmr_cut_deep_verification_cutoffs {d}\n", .{stats.lmr_cut_deep_verification_cutoffs});
    try writer.print("lmr_cut_deep_verification_fail_lows_3_5 {d}\n", .{stats.lmr_cut_deep_verification_fail_lows_3_5});
    try writer.print("lmr_cut_deep_verification_fail_lows_6_7 {d}\n", .{stats.lmr_cut_deep_verification_fail_lows_6_7});
    try writer.print("lmr_cut_deep_verification_fail_lows_8p {d}\n", .{stats.lmr_cut_deep_verification_fail_lows_8p});
    try writer.print("lmr_cut_deep_verification_cutoffs_3_5 {d}\n", .{stats.lmr_cut_deep_verification_cutoffs_3_5});
    try writer.print("lmr_cut_deep_verification_cutoffs_6_7 {d}\n", .{stats.lmr_cut_deep_verification_cutoffs_6_7});
    try writer.print("lmr_cut_deep_verification_cutoffs_8p {d}\n", .{stats.lmr_cut_deep_verification_cutoffs_8p});
    try writer.print("lmr_all_deep_verification_fail_lows_3_5 {d}\n", .{stats.lmr_all_deep_verification_fail_lows_3_5});
    try writer.print("lmr_all_deep_verification_fail_lows_6_7 {d}\n", .{stats.lmr_all_deep_verification_fail_lows_6_7});
    try writer.print("lmr_all_deep_verification_fail_lows_8p {d}\n", .{stats.lmr_all_deep_verification_fail_lows_8p});
    try writer.print("lmr_all_deep_verification_cutoffs_3_5 {d}\n", .{stats.lmr_all_deep_verification_cutoffs_3_5});
    try writer.print("lmr_all_deep_verification_cutoffs_6_7 {d}\n", .{stats.lmr_all_deep_verification_cutoffs_6_7});
    try writer.print("lmr_all_deep_verification_cutoffs_8p {d}\n", .{stats.lmr_all_deep_verification_cutoffs_8p});
    try writer.print("lmr_cut_deep_verification_fail_lows_nonpositive_history {d}\n", .{stats.lmr_cut_deep_verification_fail_lows_nonpositive_history});
    try writer.print("lmr_cut_deep_verification_fail_lows_positive_history {d}\n", .{stats.lmr_cut_deep_verification_fail_lows_positive_history});
    try writer.print("lmr_cut_deep_verification_cutoffs_nonpositive_history {d}\n", .{stats.lmr_cut_deep_verification_cutoffs_nonpositive_history});
    try writer.print("lmr_cut_deep_verification_cutoffs_positive_history {d}\n", .{stats.lmr_cut_deep_verification_cutoffs_positive_history});
    try writer.print("lmr_all_deep_verification_fail_lows_nonpositive_history {d}\n", .{stats.lmr_all_deep_verification_fail_lows_nonpositive_history});
    try writer.print("lmr_all_deep_verification_fail_lows_positive_history {d}\n", .{stats.lmr_all_deep_verification_fail_lows_positive_history});
    try writer.print("lmr_all_deep_verification_cutoffs_nonpositive_history {d}\n", .{stats.lmr_all_deep_verification_cutoffs_nonpositive_history});
    try writer.print("lmr_all_deep_verification_cutoffs_positive_history {d}\n", .{stats.lmr_all_deep_verification_cutoffs_positive_history});
    try writer.print("lmr_cut_verification_fail_lows_3_5 {d}\n", .{stats.lmr_cut_verification_fail_lows_3_5});
    try writer.print("lmr_cut_verification_fail_lows_6_7 {d}\n", .{stats.lmr_cut_verification_fail_lows_6_7});
    try writer.print("lmr_cut_verification_fail_lows_8p {d}\n", .{stats.lmr_cut_verification_fail_lows_8p});
    try writer.print("lmr_cut_verification_cutoffs_3_5 {d}\n", .{stats.lmr_cut_verification_cutoffs_3_5});
    try writer.print("lmr_cut_verification_cutoffs_6_7 {d}\n", .{stats.lmr_cut_verification_cutoffs_6_7});
    try writer.print("lmr_cut_verification_cutoffs_8p {d}\n", .{stats.lmr_cut_verification_cutoffs_8p});
    try writer.print("lmr_cut_cutoffs {d}\n", .{stats.lmr_cut_cutoffs});
    try writer.print("lmr_cut_cutoffs_3_5 {d}\n", .{stats.lmr_cut_cutoffs_3_5});
    try writer.print("lmr_cut_cutoffs_6_7 {d}\n", .{stats.lmr_cut_cutoffs_6_7});
    try writer.print("lmr_cut_cutoffs_8p {d}\n", .{stats.lmr_cut_cutoffs_8p});
    try writeOnlyMove(writer, "", &stats.only_move);
    try writeQsRules(writer, "", &stats.qs_rules);
    try writer.print("singular_candidates {d}\n", .{stats.singular_candidates});
    try writer.print("singular_cut_candidates {d}\n", .{stats.singular_cut_candidates});
    try writer.print("singular_candidates_6_7 {d}\n", .{stats.singular_candidates_6_7});
    try writer.print("singular_candidates_8p {d}\n", .{stats.singular_candidates_8p});
    try writer.print("singular_weak_alternative_candidates {d}\n", .{stats.singular_weak_alternative_candidates});
    try writer.print("singular_verifications {d}\n", .{stats.singular_verifications});
    try writer.print("singular_verified {d}\n", .{stats.singular_verified});
    try writer.print("singular_extensions {d}\n", .{stats.singular_extensions});
    try writer.print("singular_weak_alternative_rate_permille {d}\n", .{ratioPermille(stats.singular_weak_alternative_candidates, stats.singular_candidates)});
    try writer.print("singular_verification_rate_permille {d}\n", .{ratioPermille(stats.singular_verifications, stats.singular_candidates)});
    try writer.print("singular_verified_rate_permille {d}\n", .{ratioPermille(stats.singular_verified, stats.singular_verifications)});
    try writer.print("lmr_research_rate_permille {d}\n", .{ratioPermille(stats.lmr_researches, stats.lmr_reductions)});
    try writer.print("pvs_scouts {d}\n", .{stats.pvs_scouts});
    try writer.print("pvs_researches {d}\n", .{stats.pvs_researches});
    try writer.print("pvs_research_rate_permille {d}\n", .{ratioPermille(stats.pvs_researches, stats.pvs_scouts)});
    try writer.print("aspiration_researches {d}\n", .{stats.aspiration_researches});
    try writer.print("aspiration_fail_lows {d}\n", .{stats.aspiration_fail_lows});
    try writer.print("aspiration_fail_highs {d}\n", .{stats.aspiration_fail_highs});
    try writer.print("qsearch_stand_pat_cutoffs {d}\n", .{stats.qsearch_stand_pat_cutoffs});
    try writer.print("staged_main_movegen_nodes {d}\n", .{stats.staged_main_movegen_nodes});
    try writer.print("staged_main_legal_moves {d}\n", .{stats.staged_main_legal_moves});
    try writer.print("staged_main_quiet_moves {d}\n", .{stats.staged_main_quiet_moves});
    try writer.print("staged_main_tactical_moves {d}\n", .{stats.staged_main_tactical_moves});
    try writer.print("staged_main_tt_legal_nodes {d}\n", .{stats.staged_main_tt_legal_nodes});
    try writer.print("staged_main_nodes_with_quiets {d}\n", .{stats.staged_main_nodes_with_quiets});
    try writer.print("staged_main_no_quiet_searched_nodes {d}\n", .{stats.staged_main_no_quiet_searched_nodes});
    try writer.print("staged_main_no_quiet_searched_quiet_moves {d}\n", .{stats.staged_main_no_quiet_searched_quiet_moves});
    try writer.print("staged_main_avg_legal_moves_permille {d}\n", .{ratioPermille(stats.staged_main_legal_moves, stats.staged_main_movegen_nodes)});
    try writer.print("staged_main_quiet_share_permille {d}\n", .{ratioPermille(stats.staged_main_quiet_moves, stats.staged_main_legal_moves)});
    try writer.print("staged_main_no_quiet_searched_rate_permille {d}\n", .{ratioPermille(stats.staged_main_no_quiet_searched_nodes, stats.staged_main_nodes_with_quiets)});
    try writer.print("qsearch_tactical_nodes {d}\n", .{stats.qsearch_tactical_nodes});
    try writer.print("qsearch_tactical_moves {d}\n", .{stats.qsearch_tactical_moves});
    try writer.print("qsearch_avg_tactical_moves_permille {d}\n", .{ratioPermille(stats.qsearch_tactical_moves, stats.qsearch_tactical_nodes)});
    try writer.print("qsearch_bad_capture_skips {d}\n", .{stats.qsearch_bad_capture_skips});
    try writeBucketCounters(writer, "static_search_residual_nodes", &stats.static_search_residual_nodes);
    try writeBucketCounters(writer, "static_search_residual_exact", &stats.static_search_residual_exact);
    try writeBucketCounters(writer, "static_search_residual_lower", &stats.static_search_residual_lower);
    try writeBucketCounters(writer, "static_search_residual_upper", &stats.static_search_residual_upper);
    try writeBucketCounters(writer, "static_search_residual_rfp", &stats.static_search_residual_rfp);
    try writeBucketCounters(writer, "static_search_residual_null", &stats.static_search_residual_null);
    try writeBucketCounters(writer, "static_search_residual_quiet_futility", &stats.static_search_residual_quiet_futility);
    try writeBucketCounters(writer, "static_search_residual_late_move", &stats.static_search_residual_late_move);
    try writeBucketCounters(writer, "static_search_residual_bad_capture", &stats.static_search_residual_bad_capture);
    try writeBucketCounters(writer, "static_search_residual_lmr_research", &stats.static_search_residual_lmr_research);
    try writeBucketCounters(writer, "static_search_residual_lmr_verification_fail_low", &stats.static_search_residual_lmr_verification_fail_low);
    try writeMoveOrderCounters(writer, "move_order_searched", &stats.move_order_searched);
    try writeMoveOrderCounters(writer, "move_order_cutoffs", &stats.move_order_cutoffs);
    try writeMoveOrderCounters(writer, "move_order_first_cutoffs", &stats.move_order_first_cutoffs);
    try writeMoveOrderCounters(writer, "move_order_lmr_reductions", &stats.move_order_lmr_reductions);
    try writeMoveOrderCounters(writer, "move_order_lmr_researches", &stats.move_order_lmr_researches);
    try writeMoveOrderCounters(writer, "move_order_lmr_fail_lows", &stats.move_order_lmr_fail_lows);
    try writeMoveOrderCounters(writer, "move_order_lmr_cutoffs", &stats.move_order_lmr_cutoffs);
    try writeMoveOrderDetails(writer, &stats);
    try writer.print("completed_iterations {d}\n", .{result.diagnostics.trace_len});
    try writer.print("bestmove {s}\n", .{bestmove});

    if (result.pv.len != 0) {
        try writer.writeAll("pv ");
        try result.pv.writeUci(writer);
        try writer.writeByte('\n');
    }

    for (result.diagnostics.trace[0..result.diagnostics.trace_len]) |entry| {
        var iteration_move_buffer: [5]u8 = undefined;
        const iteration_bestmove = if (entry.best_move) |mv| mv.toUci(&iteration_move_buffer) else "0000";
        try writer.print("iteration depth {d} seldepth {d} score {d} nodes {d} bestmove {s}", .{
            entry.depth,
            entry.seldepth,
            entry.score,
            entry.nodes,
            iteration_bestmove,
        });
        if (entry.pv.len != 0) {
            try writer.writeAll(" pv ");
            try entry.pv.writeUci(writer);
        }
        try writer.writeByte('\n');
        try writeRootOrder(writer, entry.depth, &entry.root_order);
    }
}

fn writeBucketCounters(writer: anytype, prefix: []const u8, counters: *const stats_mod.StaticSearchResidualCounters) !void {
    inline for (stats_mod.STATIC_SEARCH_RESIDUAL_BUCKET_NAMES, 0..) |name, index| {
        try writer.print("{s}_{s} {d}\n", .{ prefix, name, counters[index] });
    }
}

fn writeMoveOrderCounters(writer: anytype, prefix: []const u8, counters: *const stats_mod.MoveOrderCounters) !void {
    inline for (stats_mod.MOVE_ORDER_BUCKET_NAMES, 0..) |name, index| {
        try writer.print("{s}_{s} {d}\n", .{ prefix, name, counters[index] });
    }
}

fn writeMoveOrderDetails(writer: anytype, stats: *const stats_mod.SearchStats) !void {
    inline for (stats_mod.MOVE_ORDER_NODE_TYPE_NAMES, 0..) |node_name, node_index| {
        inline for (stats_mod.MOVE_ORDER_DEPTH_BAND_NAMES, 0..) |depth_name, depth_index| {
            inline for (stats_mod.MOVE_ORDER_BUCKET_NAMES, 0..) |bucket_name, bucket_index| {
                const searched = stats.move_order_detail_searched[node_index][depth_index][bucket_index];
                const cutoffs = stats.move_order_detail_cutoffs[node_index][depth_index][bucket_index];
                const first_cutoffs = stats.move_order_detail_first_cutoffs[node_index][depth_index][bucket_index];
                const lmr_reductions = stats.move_order_detail_lmr_reductions[node_index][depth_index][bucket_index];
                const lmr_researches = stats.move_order_detail_lmr_researches[node_index][depth_index][bucket_index];
                const lmr_fail_lows = stats.move_order_detail_lmr_fail_lows[node_index][depth_index][bucket_index];
                const lmr_cutoffs = stats.move_order_detail_lmr_cutoffs[node_index][depth_index][bucket_index];
                const history_score_sum = stats.move_order_detail_history_score_sum[node_index][depth_index][bucket_index];
                if (searched != 0 or cutoffs != 0 or first_cutoffs != 0 or lmr_reductions != 0 or lmr_researches != 0 or lmr_fail_lows != 0 or lmr_cutoffs != 0 or history_score_sum != 0) {
                    try writer.print(
                        "move_order_detail node {s} depth_band {s} bucket {s} searched {d} cutoffs {d} first_cutoffs {d} lmr_reductions {d} lmr_researches {d} lmr_fail_lows {d} lmr_cutoffs {d} history_score_sum {d}\n",
                        .{ node_name, depth_name, bucket_name, searched, cutoffs, first_cutoffs, lmr_reductions, lmr_researches, lmr_fail_lows, lmr_cutoffs, history_score_sum },
                    );
                }
            }
        }
    }
}

fn writeRootOrder(writer: anytype, depth: u16, trace: *const root.RootOrderTrace) !void {
    if (trace.legal_count == 0) return;
    var tt_buffer: [5]u8 = undefined;
    const tt_move = if (trace.tt_move) |mv| mv.toUci(&tt_buffer) else "0000";
    try writer.print("root_order depth {d} legal {d} shown {d} tt {s}\n", .{ depth, trace.legal_count, trace.count, tt_move });
    for (trace.entries[0..trace.count], 0..) |entry, rank| {
        var move_buffer: [5]u8 = undefined;
        const move_text = entry.mv.toUci(&move_buffer);
        const searched_score = if (entry.searched_score) |score| score else 0;
        const searched = entry.searched_score != null;
        try writer.print(
            "root_candidate depth {d} rank {d} move {s} initial_score {d} previous_hint_bonus {d} searched {any} searched_score {d} subtree_nodes {d}\n",
            .{ depth, rank + 1, move_text, entry.initial_score, entry.previous_hint_bonus, searched, searched_score, entry.subtree_nodes },
        );
    }
}

fn stopReasonName(reason: ?search_engine.IterationStopReason) []const u8 {
    return if (reason) |value| @tagName(value) else "none";
}

fn ratioPermille(numerator: u64, denominator: u64) u16 {
    if (denominator == 0) return 0;
    return @intCast((@as(u128, numerator) * 1000) / denominator);
}

/// The root's cycle tie-break (root.zig), the counters of one search on one line.
pub fn writeRootTie(writer: anytype, comptime prefix: []const u8, stats: *const stats_mod.SearchStats) !void {
    var buffer: [128]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.print(prefix ++ "roottie asked {d} refused {d} nodes {d} granted {d}\n", .{ stats.root_cycle_tie_asked, stats.root_cycle_tie_refused, stats.root_cycle_tie_nodes, stats.root_cycle_tie_granted });
    try writer.writeAll(line.buffered());
}

/// The singular test's counters of one search, on one line (stats flavour,
/// for drivers that set its switches over UCI).
pub fn writeSingular(writer: anytype, comptime prefix: []const u8, stats: *const stats_mod.SearchStats, nodes: u64) !void {
    var buffer: [512]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.print(prefix ++ "singular nodes {d} candidates {d} verifications {d} pv_verifications {d} all_verifications {d} verified {d} extensions {d} double_extensions {d} multicuts {d}\n", .{
        nodes,
        stats.singular_candidates,
        stats.singular_verifications,
        stats.singular_pv_verifications,
        stats.singular_all_verifications,
        stats.singular_verified,
        stats.singular_extensions,
        stats.singular_double_extensions,
        stats.singular_multicuts,
    });
    try writer.writeAll(line.buffered());
}

/// The verified only-move extension's counters: one line per grid, cells
/// named <node type>_<depth band>, then the scalar counters. Each line is
/// built whole and written with one writeAll (`writer` may be a UCI output).
/// One line of table counters for a finished search (stats flavour, UCI):
/// what the transposition table and the raw eval cache were asked and what
/// they kept, so table pressure can be read
/// from real game sequences (`setoption Hash`, `go nodes`).
/// The table's score against the static value (tt_eval.zig), the counters of one search on one line.
pub fn writeTtEval(writer: anytype, comptime prefix: []const u8, nodes: u64, stats: *const stats_mod.SearchStats) !void {
    var buffer: [1024]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.print(prefix ++ "tteval nodes {d} main {d} entries {d} differs {d} distance {d} differs_50 {d} differs_qs_entry {d} lower_over_beta {d} upper_under_beta {d} rfp_static {d} rfp_gained {d} rfp_refused {d} qs {d} qs_differs {d} qs_gained {d} qs_refused {d}\n", .{
        nodes,
        stats.tt_eval_nodes,
        stats.tt_eval_entries,
        stats.tt_eval_differs,
        stats.tt_eval_distance,
        stats.tt_eval_differs_50,
        stats.tt_eval_differs_qs_entry,
        stats.tt_eval_lower_over_beta,
        stats.tt_eval_upper_under_beta,
        stats.tt_eval_rfp_static,
        stats.tt_eval_rfp_gained,
        stats.tt_eval_rfp_refused,
        stats.tt_eval_qs_nodes,
        stats.tt_eval_qs_differs,
        stats.tt_eval_qs_gained,
        stats.tt_eval_qs_refused,
    });
    try writer.writeAll(line.buffered());
}

pub fn writeTables(writer: anytype, comptime prefix: []const u8, nodes: u64, stats: *const stats_mod.SearchStats) !void {
    var buffer: [2048]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.print(prefix ++ "tables nodes {d} qnodes {d} tt_probes {d} tt_hits {d} tt_foreign_hits {d} tt_hit_current {d} tt_hit_old {d} tt_cutoffs {d} tt_shallow_hits {d} tt_ordering_only {d}", .{
        nodes,
        stats.qnodes,
        stats.tt_probes,
        stats.tt_hits,
        stats.tt_foreign_hits,
        stats.tt_hit_current_generation,
        stats.tt_hit_old_generation,
        stats.tt_cutoffs,
        stats.tt_shallow_hits,
        stats.tt_ordering_only_hits,
    });
    try line.print(" tt_stores {d} tt_store_skipped {d} tt_store_empty {d} tt_store_same_key {d} tt_store_replacements {d} tt_store_replaced_current {d} tt_store_replaced_old {d}", .{
        stats.tt_stores,
        stats.tt_store_skipped_same_generation_deeper,
        stats.tt_store_empty,
        stats.tt_store_same_key,
        stats.tt_store_replacements,
        stats.tt_store_replaced_current_generation,
        stats.tt_store_replaced_old_generation,
    });
    try line.print(" iir {d} eval_cache_probes {d} eval_cache_hits {d} eval_cache_q_probes {d} eval_cache_q_hits {d} main_static_evals {d}\n", .{
        stats.iir_reductions,
        stats.eval_cache_probes,
        stats.eval_cache_hits,
        stats.eval_cache_q_probes,
        stats.eval_cache_q_hits,
        stats.main_static_evals,
    });
    try writer.writeAll(line.buffered());
}

/// The quiescence move rules' counters, one line per counter (stats flavour).
pub fn writeQsRules(writer: anytype, comptime prefix: []const u8, qs: *const stats_mod.QsRuleStats) !void {
    var buffer: [1024]u8 = undefined;
    inline for (@typeInfo(stats_mod.QsRuleStats).@"struct".fields) |field| {
        var line = std.Io.Writer.fixed(&buffer);
        try line.print(prefix ++ "qs_rule_{s}", .{field.name});
        if (field.type == u64) {
            try line.print(" {d}", .{@field(qs, field.name)});
        } else if (field.type == stats_mod.QsCheckPaths) {
            inline for (stats_mod.QS_CHECK_PATH_NAMES, 0..) |path_name, path| {
                try line.print(" {s} {d}", .{ path_name, @field(qs, field.name)[path] });
            }
        } else if (field.type == stats_mod.QsEqualBands) {
            inline for (stats_mod.QS_EQUAL_BAND_MARGINS, 0..) |margin, band| {
                try line.print(" m{d} {d}", .{ margin, @field(qs, field.name)[band] });
            }
        } else {
            const grid = @field(qs, field.name);
            inline for (.{ "mid", "late" }, 0..) |phase_name, late| {
                inline for (.{ "pawn", "minor", "rook", "queen" }, 0..) |victim_name, victim| {
                    try line.print(" {s}_{s} {d}", .{ phase_name, victim_name, grid[late][victim] });
                }
            }
        }
        try line.writeByte('\n');
        try writer.writeAll(line.buffered());
    }
}

pub fn writeOnlyMove(writer: anytype, comptime prefix: []const u8, om: *const stats_mod.OnlyMoveStats) !void {
    var buffer: [2048]u8 = undefined;
    inline for (.{ "verified", "single", "double", "cut", "shortened", "verify_nodes" }) |grid_name| {
        const grid = @field(om, grid_name);
        var line = std.Io.Writer.fixed(&buffer);
        try line.print(prefix ++ "only_move_{s}", .{grid_name});
        inline for (stats_mod.MOVE_ORDER_NODE_TYPE_NAMES, 0..) |node_name, t| {
            inline for (stats_mod.ONLY_MOVE_DEPTH_BAND_NAMES, 0..) |depth_name, d| {
                try line.print(" {s}_{s} {d}", .{ node_name, depth_name, grid[t][d] });
            }
        }
        try line.writeByte('\n');
        try writer.writeAll(line.buffered());
    }
    var line = std.Io.Writer.fixed(&buffer);
    try line.print(prefix ++ "only_move_scalars verified_in_check {d} capped {d} ext_check {d} ext_ldse {d} ext_verified {d} root_confirms {d} root_confirms_rejected {d} root_displaced_scouts {d} root_displaced_returns {d} pv_confirms {d} pv_confirms_rejected {d}\n", .{
        om.verified_in_check,
        om.capped,
        om.ext_check,
        om.ext_ldse,
        om.ext_verified,
        om.root_confirms,
        om.root_confirms_rejected,
        om.root_displaced_scouts,
        om.root_displaced_returns,
        om.pv_confirms,
        om.pv_confirms_rejected,
    });
    try writer.writeAll(line.buffered());
}
