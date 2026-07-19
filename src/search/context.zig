const std = @import("std");
const build_options = @import("build_options");
const core_types = @import("../core/types.zig");
const move_mod = @import("../core/move.zig");
const eval_backend = @import("../eval/backend.zig");
const nnue768 = @import("../eval/nnue768.zig");
const eval_cache_mod = @import("eval_cache.zig");
const history_mod = @import("history.zig");
const repetition = @import("repetition.zig");
const rfp_hint = @import("rfp_hint.zig");
const score_mod = @import("score.zig");
const search_info = @import("search_info.zig");
const stack = @import("stack.zig");
const stats = @import("stats.zig");
const time = @import("time.zig");
const tt = @import("tt.zig");

/// Diagnostic-counter switch (-Dsearch-stats, default off for the release
/// engine; the `zigqueen-stats` twin binary builds with it on). When false,
/// every diagnostic ctx.note*() body — and the record_* outcome-classification
/// paths in the hot loops — compiles to nothing. FUNCTIONAL counters are always
/// kept: noteNode (node count -> time management + UCI nodes/nps), noteQNode's
/// noteNode part, observePly (seldepth -> UCI), and the stop/hard-stop control
/// flow itself.
pub const stats_enabled: bool = build_options.search_stats;

pub const Resources = struct {
    tt: *tt.TranspositionTable,
    rfp_hint: *rfp_hint.HintTable,
    eval_cache: *eval_cache_mod.EvalCache,
    history: *history_mod.HistoryTable,
    evaluator: *eval_backend.EngineState,
};

pub const StaticSearchOutcomeFlags = struct {
    rfp_cutoff: bool = false,
    null_cutoff: bool = false,
    quiet_futility_prune: bool = false,
    late_move_prune: bool = false,
    bad_capture_prune: bool = false,
    lmr_research: bool = false,
    lmr_verification_fail_low: bool = false,
};

const StaticSearchBoundClass = enum {
    exact,
    lower,
    upper,
};

pub const SearchContext = struct {
    repetition: repetition.History,
    stack: stack.SearchStack = .{},
    /// Per-thread finny (accumulator-refresh) cache; reset each search via prepareRoot.
    finny: nnue768.FinnyTable = .{},
    control: time.Controller,
    stats: stats.SearchStats = .{},
    nodes: u64 = 0,
    seldepth: u16 = 0,
    stopped: bool = false,
    /// Null-move verification (SF nmp_min_ply): while a verification search runs,
    /// null move is disabled for all plies below this marker so verify subtrees
    /// cannot recursively null-cut / re-verify (depth-efficiency v2).
    nmp_min_ply: usize = 0,
    record_static_search_outcomes: bool = false,
    record_move_order_outcomes: bool = false,
    /// Draw contempt (engine-scale cp): in-tree draws (repetition, 50-move,
    /// stalemate) score -contempt for the root side and +contempt for the
    /// opponent, so equal positions prefer playing on over bailing into a
    /// repetition. 0 = classical behaviour (draws are 0), bit-identical search.
    contempt: core_types.Score = 0,
    root_color: core_types.Color = .white,
    /// Optional UCI info sink. Set per search by the worker; null for
    /// tools/tests (search runs identically, just silent).
    info_emitter: ?search_info.InfoEmitter = null,

    /// Runtime record flags, comptime-false when diagnostic stats are compiled
    /// out so the outcome-classification work in the hot loops folds away.
    pub inline fn recordMoveOrder(self: *const SearchContext) bool {
        if (comptime !stats_enabled) return false;
        return self.record_move_order_outcomes;
    }

    pub inline fn recordStaticOutcomes(self: *const SearchContext) bool {
        if (comptime !stats_enabled) return false;
        return self.record_static_search_outcomes;
    }

    pub fn drawScore(self: *const SearchContext, stm: core_types.Color) core_types.Score {
        if (self.contempt == 0) return 0;
        return if (stm == self.root_color) -self.contempt else self.contempt;
    }

    pub fn noteNode(self: *SearchContext) bool {
        self.nodes += 1;
        if (self.control.stopReasonNow(self.nodes)) |reason| {
            self.noteHardStop(reason);
            self.stopped = true;
            return true;
        }
        return false;
    }

    pub fn noteQNode(self: *SearchContext) bool {
        if (comptime stats_enabled) self.stats.qnodes += 1;
        return self.noteNode();
    }

    pub fn noteMainStaticEval(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.main_static_evals += 1;
    }

    pub fn noteReverseFutilityPrune(self: *SearchContext, depth: u16) void {
        if (comptime !stats_enabled) return;
        self.stats.reverse_futility_prunes += 1;
        switch (depth) {
            1 => self.stats.reverse_futility_prunes_depth_1 += 1,
            2 => self.stats.reverse_futility_prunes_depth_2 += 1,
            3 => self.stats.reverse_futility_prunes_depth_3 += 1,
            else => {},
        }
    }

    pub fn noteIirReduction(self: *SearchContext, pv_node: bool, cut_node: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.iir_reductions += 1;
        if (pv_node) {
            self.stats.iir_pv_reductions += 1;
        } else if (cut_node) {
            self.stats.iir_cut_reductions += 1;
        } else {
            self.stats.iir_all_reductions += 1;
        }
    }

    pub fn noteCheckExtension(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.check_extensions += 1;
    }

    pub fn noteRfpHintProbe(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.rfp_hint_probes += 1;
    }

    pub fn noteRfpHintCutoff(self: *SearchContext, depth: u16) void {
        if (comptime !stats_enabled) return;
        self.stats.rfp_hint_cutoffs += 1;
        switch (depth) {
            1 => self.stats.rfp_hint_cutoffs_depth_1 += 1,
            2 => self.stats.rfp_hint_cutoffs_depth_2 += 1,
            3 => self.stats.rfp_hint_cutoffs_depth_3 += 1,
            else => {},
        }
    }

    pub fn noteRfpHintAlphaRaise(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.rfp_hint_alpha_raises += 1;
    }

    /// Raw-eval cache: probed only after a TT static-eval miss, so
    /// the hit rate doubles as the hit-after-TT-miss rate.
    pub fn noteEvalCacheProbe(self: *SearchContext, hit: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.eval_cache_probes += 1;
        if (hit) self.stats.eval_cache_hits += 1;
    }

    pub fn noteQsearchEvalCacheProbe(self: *SearchContext, hit: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.eval_cache_q_probes += 1;
        if (hit) self.stats.eval_cache_q_hits += 1;
    }

    pub fn noteQuietFutilityPrune(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.quiet_futility_prunes += 1;
    }

    pub fn noteLatePrune(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.late_move_prunes += 1;
    }

    pub fn noteBadCapturePrune(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.bad_capture_prunes += 1;
    }

    pub fn noteTtProbe(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_probes += 1;
    }

    pub fn noteTtHit(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_hits += 1;
    }

    pub fn noteTtHitDetails(self: *SearchContext, entry: *const tt.Entry, current_generation: u8) void {
        if (comptime !stats_enabled) return;
        const age = current_generation -% entry.generation;
        if (age == 0) {
            self.stats.tt_hit_current_generation += 1;
        } else {
            self.stats.tt_hit_old_generation += 1;
            if (age == 1) {
                self.stats.tt_hit_age_1 += 1;
            } else if (age <= 3) {
                self.stats.tt_hit_age_2_3 += 1;
            } else {
                self.stats.tt_hit_age_4p += 1;
            }
        }
        if (tt.moveFromEntry(entry.*) != null)
            self.stats.tt_hit_with_move += 1
        else
            self.stats.tt_hit_without_move += 1;
        switch (entry.bound) {
            .exact => self.stats.tt_hit_exact_bound += 1,
            .lower => self.stats.tt_hit_lower_bound += 1,
            .upper => self.stats.tt_hit_upper_bound += 1,
        }
    }

    pub fn noteTtCutoffGeneration(self: *SearchContext, current_generation: bool) void {
        if (comptime !stats_enabled) return;
        if (current_generation)
            self.stats.tt_cutoffs_current_generation += 1
        else
            self.stats.tt_cutoffs_old_generation += 1;
    }

    pub inline fn noteTtStore(self: *SearchContext, outcome: tt.StoreOutcome) void {
        if (comptime !stats_enabled) return;
        if (outcome.skipped_same_generation_deeper) {
            self.stats.tt_store_skipped_same_generation_deeper += 1;
            if (outcome.new_had_move)
                self.stats.tt_store_skip_new_with_move += 1
            else
                self.stats.tt_store_skip_new_without_move += 1;
            if (outcome.victim_had_move)
                self.stats.tt_store_skip_victim_with_move += 1
            else
                self.stats.tt_store_skip_victim_without_move += 1;
            return;
        }
        if (!outcome.stored) return;
        self.stats.tt_stores += 1;
        if (outcome.new_had_move)
            self.stats.tt_store_new_with_move += 1
        else
            self.stats.tt_store_new_without_move += 1;
        switch (outcome.new_bound) {
            .exact => self.stats.tt_store_new_exact_bound += 1,
            .lower => self.stats.tt_store_new_lower_bound += 1,
            .upper => self.stats.tt_store_new_upper_bound += 1,
        }
        if (outcome.empty_slot) {
            self.stats.tt_store_empty += 1;
            return;
        }
        if (outcome.same_key) {
            self.stats.tt_store_same_key += 1;
        } else if (outcome.replaced_occupied) {
            self.stats.tt_store_replacements += 1;
        }
        if (outcome.victim_generation == outcome.current_generation)
            self.stats.tt_store_replaced_current_generation += 1
        else
            self.stats.tt_store_replaced_old_generation += 1;
        if (outcome.victim_had_move)
            self.stats.tt_store_replaced_with_move += 1
        else
            self.stats.tt_store_replaced_without_move += 1;
        switch (outcome.victim_bound) {
            .exact => self.stats.tt_store_replaced_exact_bound += 1,
            .lower => self.stats.tt_store_replaced_lower_bound += 1,
            .upper => self.stats.tt_store_replaced_upper_bound += 1,
        }
    }

    pub fn noteTtOrderingOnlyGeneration(self: *SearchContext, current_generation: bool) void {
        if (comptime !stats_enabled) return;
        if (current_generation)
            self.stats.tt_ordering_only_current_generation += 1
        else
            self.stats.tt_ordering_only_old_generation += 1;
    }

    pub fn noteTtShallowHit(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_shallow_hits += 1;
    }

    pub fn noteTtOrderingOnlyHit(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_ordering_only_hits += 1;
    }

    pub fn noteTtBoundNoCutoffHit(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_bound_no_cutoff_hits += 1;
    }

    pub fn noteTtExactCutoff(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_cutoffs += 1;
        self.stats.tt_exact_cutoffs += 1;
    }

    pub fn noteTtLowerCutoff(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_cutoffs += 1;
        self.stats.tt_lower_cutoffs += 1;
    }

    pub fn noteTtUpperCutoff(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.tt_cutoffs += 1;
        self.stats.tt_upper_cutoffs += 1;
    }

    pub fn noteBetaCutoff(self: *SearchContext, move_index: usize) void {
        if (comptime !stats_enabled) return;
        self.stats.beta_cutoffs += 1;
        if (move_index == 0) self.stats.beta_cutoffs_first += 1;
    }

    pub fn noteCaptureCutoff(self: *SearchContext, move_index: usize, see_score: i32, qsearch: bool) void {
        if (comptime !stats_enabled) return;
        if (qsearch) {
            self.stats.qsearch_capture_cutoffs += 1;
            noteCaptureBand(move_index, &self.stats.qsearch_capture_cutoffs_first, &self.stats.qsearch_capture_cutoffs_1_2, &self.stats.qsearch_capture_cutoffs_3_5, &self.stats.qsearch_capture_cutoffs_6p);
            if (see_score >= 0)
                self.stats.qsearch_good_capture_cutoffs += 1
            else
                self.stats.qsearch_bad_capture_cutoffs += 1;
            return;
        }

        self.stats.main_capture_cutoffs += 1;
        noteCaptureBand(move_index, &self.stats.main_capture_cutoffs_first, &self.stats.main_capture_cutoffs_1_2, &self.stats.main_capture_cutoffs_3_5, &self.stats.main_capture_cutoffs_6p);
        if (see_score >= 0)
            self.stats.main_good_capture_cutoffs += 1
        else
            self.stats.main_bad_capture_cutoffs += 1;
    }

    pub fn noteCountermoveTableProbe(self: *SearchContext, countermove: ?move_mod.Move, legal_hit: bool) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        self.stats.countermove_table_probes += 1;
        if (countermove == null) {
            self.stats.countermove_table_misses += 1;
            return;
        }
        self.stats.countermove_table_hits += 1;
        if (legal_hit) {
            self.stats.countermove_table_legal_hits += 1;
        } else {
            self.stats.countermove_table_stale_hits += 1;
        }
    }

    pub fn noteQuietCutoff(
        self: *SearchContext,
        move_index: usize,
        mv: move_mod.Move,
        tt_move: ?move_mod.Move,
        killer_a: ?move_mod.Move,
        killer_b: ?move_mod.Move,
        countermove: ?move_mod.Move,
        history_score: i32,
    ) void {
        if (comptime !stats_enabled) return;
        self.stats.main_quiet_cutoffs += 1;
        noteCaptureBand(move_index, &self.stats.main_quiet_cutoffs_first, &self.stats.main_quiet_cutoffs_1_2, &self.stats.main_quiet_cutoffs_3_5, &self.stats.main_quiet_cutoffs_6p);

        if (tt_move) |candidate| {
            if (candidate == mv) {
                self.stats.main_quiet_tt_cutoffs += 1;
                return;
            }
        }
        if (killer_a) |candidate| {
            if (candidate == mv) {
                self.stats.main_quiet_killer_a_cutoffs += 1;
                return;
            }
        }
        if (killer_b) |candidate| {
            if (candidate == mv) {
                self.stats.main_quiet_killer_b_cutoffs += 1;
                return;
            }
        }
        if (countermove) |candidate| {
            if (candidate == mv) {
                self.stats.main_quiet_countermove_cutoffs += 1;
                return;
            }
        }
        if (history_score > 0)
            self.stats.main_quiet_positive_history_cutoffs += 1
        else
            self.stats.main_quiet_nonpositive_history_cutoffs += 1;
    }

    pub fn noteNullTry(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.null_tries += 1;
    }

    pub fn noteNullCutoff(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.null_cutoffs += 1;
    }

    pub fn noteNullVerifyReject(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.null_verify_rejects += 1;
    }

    pub fn noteMoveOrderSearched(self: *SearchContext, sample: stats.MoveOrderSample) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_searched[bucket_index] += 1;
        self.stats.move_order_detail_searched[sample.node_type][sample.depth_band][bucket_index] += 1;
        self.stats.move_order_detail_history_score_sum[sample.node_type][sample.depth_band][bucket_index] += sample.history_score;
    }

    pub fn noteMoveOrderCutoff(self: *SearchContext, sample: stats.MoveOrderSample, first_move: bool) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_cutoffs[bucket_index] += 1;
        self.stats.move_order_detail_cutoffs[sample.node_type][sample.depth_band][bucket_index] += 1;
        if (first_move) {
            self.stats.move_order_first_cutoffs[bucket_index] += 1;
            self.stats.move_order_detail_first_cutoffs[sample.node_type][sample.depth_band][bucket_index] += 1;
        }
    }

    pub fn noteMoveOrderLmrReduction(self: *SearchContext, sample: stats.MoveOrderSample) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_lmr_reductions[bucket_index] += 1;
        self.stats.move_order_detail_lmr_reductions[sample.node_type][sample.depth_band][bucket_index] += 1;
    }

    pub fn noteMoveOrderLmrResearch(self: *SearchContext, sample: stats.MoveOrderSample) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_lmr_researches[bucket_index] += 1;
        self.stats.move_order_detail_lmr_researches[sample.node_type][sample.depth_band][bucket_index] += 1;
    }

    pub fn noteMoveOrderLmrFailLow(self: *SearchContext, sample: stats.MoveOrderSample) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_lmr_fail_lows[bucket_index] += 1;
        self.stats.move_order_detail_lmr_fail_lows[sample.node_type][sample.depth_band][bucket_index] += 1;
    }

    pub fn noteMoveOrderLmrCutoff(self: *SearchContext, sample: stats.MoveOrderSample) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        const bucket_index = @intFromEnum(sample.bucket);
        self.stats.move_order_lmr_cutoffs[bucket_index] += 1;
        self.stats.move_order_detail_lmr_cutoffs[sample.node_type][sample.depth_band][bucket_index] += 1;
    }

    pub fn noteHardStop(self: *SearchContext, reason: time.StopNowReason) void {
        if (comptime !stats_enabled) return;
        switch (reason) {
            .external => self.stats.hard_stops_external += 1,
            .node_limit => self.stats.hard_stops_node_limit += 1,
            .maximum_budget => self.stats.hard_stops_maximum_budget += 1,
        }
    }

    pub fn noteIterationStopMaximumElapsed(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.iteration_stop_maximum_elapsed += 1;
    }

    pub fn noteIterationStopMaximumProjected(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.iteration_stop_maximum_projected += 1;
    }

    pub fn noteIterationStopOptimumElapsed(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.iteration_stop_optimum_elapsed += 1;
    }

    pub fn noteIterationStopOptimumProjected(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.iteration_stop_optimum_projected += 1;
    }

    pub fn noteLmrReduction(self: *SearchContext, reduction: u16, move_index: usize, pv_node: bool, cut_node: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.lmr_reductions += 1;
        self.stats.lmr_total_reduction += reduction;
        if (pv_node) {
            self.stats.lmr_pv_reductions += 1;
        } else {
            self.stats.lmr_nonpv_reductions += 1;
            if (cut_node) {
                self.stats.lmr_cut_reductions += 1;
                noteCutLmrBand(move_index, &self.stats.lmr_cut_reductions_3_5, &self.stats.lmr_cut_reductions_6_7, &self.stats.lmr_cut_reductions_8p);
            } else {
                self.stats.lmr_all_reductions += 1;
            }
        }
        if (reduction > 1) {
            self.stats.lmr_deep_reductions += 1;
            if (!pv_node) {
                if (cut_node)
                    self.stats.lmr_cut_deep_reductions += 1
                else
                    self.stats.lmr_all_deep_reductions += 1;
            }
        }
    }

    pub fn noteLmrResearch(self: *SearchContext, move_index: usize, reduction: u16, reduced_score: i32, alpha: i32, history_score: i32, pv_node: bool, cut_node: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.lmr_researches += 1;
        const deep = reduction > 1;
        if (deep) self.stats.lmr_deep_researches += 1;
        if (pv_node) {
            self.stats.lmr_pv_researches += 1;
        } else {
            self.stats.lmr_nonpv_researches += 1;
            if (cut_node) {
                self.stats.lmr_cut_researches += 1;
                if (deep) {
                    self.stats.lmr_cut_deep_researches += 1;
                    noteCutLmrBand(move_index, &self.stats.lmr_cut_deep_researches_3_5, &self.stats.lmr_cut_deep_researches_6_7, &self.stats.lmr_cut_deep_researches_8p);
                    noteLmrResearchMargin(reduced_score - alpha, &self.stats.lmr_cut_deep_research_margin_0_31, &self.stats.lmr_cut_deep_research_margin_32_95, &self.stats.lmr_cut_deep_research_margin_96p);
                    noteLmrHistorySign(history_score, &self.stats.lmr_cut_deep_research_nonpositive_history, &self.stats.lmr_cut_deep_research_positive_history);
                }
                noteCutLmrBand(move_index, &self.stats.lmr_cut_researches_3_5, &self.stats.lmr_cut_researches_6_7, &self.stats.lmr_cut_researches_8p);
            } else {
                self.stats.lmr_all_researches += 1;
                if (deep) {
                    self.stats.lmr_all_deep_researches += 1;
                    noteCutLmrBand(move_index, &self.stats.lmr_all_deep_researches_3_5, &self.stats.lmr_all_deep_researches_6_7, &self.stats.lmr_all_deep_researches_8p);
                    noteLmrResearchMargin(reduced_score - alpha, &self.stats.lmr_all_deep_research_margin_0_31, &self.stats.lmr_all_deep_research_margin_32_95, &self.stats.lmr_all_deep_research_margin_96p);
                    noteLmrHistorySign(history_score, &self.stats.lmr_all_deep_research_nonpositive_history, &self.stats.lmr_all_deep_research_positive_history);
                }
            }
        }
    }

    pub fn noteLmrVerificationOutcome(self: *SearchContext, move_index: usize, reduction: u16, score: i32, alpha: i32, beta: i32, history_score: i32, pv_node: bool, cut_node: bool) void {
        if (comptime !stats_enabled) return;
        const deep = reduction > 1;
        if (score <= alpha) {
            self.stats.lmr_verification_fail_lows += 1;
            if (deep) self.stats.lmr_deep_verification_fail_lows += 1;
            if (cut_node) {
                if (deep) {
                    self.stats.lmr_cut_deep_verification_fail_lows += 1;
                    noteCutLmrBand(move_index, &self.stats.lmr_cut_deep_verification_fail_lows_3_5, &self.stats.lmr_cut_deep_verification_fail_lows_6_7, &self.stats.lmr_cut_deep_verification_fail_lows_8p);
                    noteLmrHistorySign(history_score, &self.stats.lmr_cut_deep_verification_fail_lows_nonpositive_history, &self.stats.lmr_cut_deep_verification_fail_lows_positive_history);
                }
                noteCutLmrBand(move_index, &self.stats.lmr_cut_verification_fail_lows_3_5, &self.stats.lmr_cut_verification_fail_lows_6_7, &self.stats.lmr_cut_verification_fail_lows_8p);
            } else if (deep and !pv_node) {
                noteCutLmrBand(move_index, &self.stats.lmr_all_deep_verification_fail_lows_3_5, &self.stats.lmr_all_deep_verification_fail_lows_6_7, &self.stats.lmr_all_deep_verification_fail_lows_8p);
                noteLmrHistorySign(history_score, &self.stats.lmr_all_deep_verification_fail_lows_nonpositive_history, &self.stats.lmr_all_deep_verification_fail_lows_positive_history);
            }
            return;
        }
        if (score >= beta) {
            self.stats.lmr_verification_cutoffs += 1;
            if (deep) self.stats.lmr_deep_verification_cutoffs += 1;
            if (cut_node) {
                if (deep) {
                    self.stats.lmr_cut_deep_verification_cutoffs += 1;
                    noteCutLmrBand(move_index, &self.stats.lmr_cut_deep_verification_cutoffs_3_5, &self.stats.lmr_cut_deep_verification_cutoffs_6_7, &self.stats.lmr_cut_deep_verification_cutoffs_8p);
                    noteLmrHistorySign(history_score, &self.stats.lmr_cut_deep_verification_cutoffs_nonpositive_history, &self.stats.lmr_cut_deep_verification_cutoffs_positive_history);
                }
                noteCutLmrBand(move_index, &self.stats.lmr_cut_verification_cutoffs_3_5, &self.stats.lmr_cut_verification_cutoffs_6_7, &self.stats.lmr_cut_verification_cutoffs_8p);
            } else if (deep and !pv_node) {
                noteCutLmrBand(move_index, &self.stats.lmr_all_deep_verification_cutoffs_3_5, &self.stats.lmr_all_deep_verification_cutoffs_6_7, &self.stats.lmr_all_deep_verification_cutoffs_8p);
                noteLmrHistorySign(history_score, &self.stats.lmr_all_deep_verification_cutoffs_nonpositive_history, &self.stats.lmr_all_deep_verification_cutoffs_positive_history);
            }
            return;
        }
        self.stats.lmr_verification_alpha_raises += 1;
        if (deep) self.stats.lmr_deep_verification_alpha_raises += 1;
        if (cut_node) {
            self.stats.lmr_cut_verification_alpha_raises += 1;
            if (deep) self.stats.lmr_cut_deep_verification_alpha_raises += 1;
        }
    }

    pub fn noteCutLmrCutoff(self: *SearchContext, move_index: usize) void {
        if (comptime !stats_enabled) return;
        self.stats.lmr_cut_cutoffs += 1;
        noteCutLmrBand(move_index, &self.stats.lmr_cut_cutoffs_3_5, &self.stats.lmr_cut_cutoffs_6_7, &self.stats.lmr_cut_cutoffs_8p);
    }

    pub fn noteSingularCandidate(self: *SearchContext, depth: u16, cut_node: bool) void {
        if (comptime !stats_enabled) return;
        self.stats.singular_candidates += 1;
        if (cut_node) self.stats.singular_cut_candidates += 1;
        switch (depth) {
            6, 7 => self.stats.singular_candidates_6_7 += 1,
            8...std.math.maxInt(u16) => self.stats.singular_candidates_8p += 1,
            else => {},
        }
    }

    pub fn noteSingularWeakAlternativeCandidate(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.singular_weak_alternative_candidates += 1;
    }

    pub fn noteSingularVerification(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.singular_verifications += 1;
    }

    pub fn noteSingularVerified(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.singular_verified += 1;
    }

    pub fn noteSingularExtension(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.singular_extensions += 1;
    }

    pub fn notePvsScout(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.pvs_scouts += 1;
    }

    pub fn notePvsResearch(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.pvs_researches += 1;
    }

    pub fn noteAspirationResearch(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.aspiration_researches += 1;
    }

    pub fn noteAspirationFailLow(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.aspiration_fail_lows += 1;
    }

    pub fn noteAspirationFailHigh(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.aspiration_fail_highs += 1;
    }

    pub fn noteQsearchStandPatCutoff(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        self.stats.qsearch_stand_pat_cutoffs += 1;
    }

    pub fn noteStagedMainMoveList(self: *SearchContext, legal_moves: usize, quiet_moves: usize, tactical_moves: usize, tt_move_legal: bool) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        self.stats.staged_main_movegen_nodes += 1;
        self.stats.staged_main_legal_moves += @intCast(legal_moves);
        self.stats.staged_main_quiet_moves += @intCast(quiet_moves);
        self.stats.staged_main_tactical_moves += @intCast(tactical_moves);
        if (quiet_moves != 0) self.stats.staged_main_nodes_with_quiets += 1;
        if (tt_move_legal) self.stats.staged_main_tt_legal_nodes += 1;
    }

    pub fn noteStagedMainNoQuietSearched(self: *SearchContext, quiet_moves: usize) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        if (quiet_moves == 0) return;
        self.stats.staged_main_no_quiet_searched_nodes += 1;
        self.stats.staged_main_no_quiet_searched_quiet_moves += @intCast(quiet_moves);
    }

    pub fn noteQsearchTacticalList(self: *SearchContext, tactical_moves: usize) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        self.stats.qsearch_tactical_nodes += 1;
        self.stats.qsearch_tactical_moves += @intCast(tactical_moves);
    }

    pub fn noteQsearchBadCaptureSkip(self: *SearchContext) void {
        if (comptime !stats_enabled) return;
        if (!self.record_move_order_outcomes) return;
        self.stats.qsearch_bad_capture_skips += 1;
    }

    pub fn noteStaticSearchOutcome(self: *SearchContext, static_eval: i32, score: i32, alpha_orig: i32, beta: i32, flags: StaticSearchOutcomeFlags) void {
        if (comptime !stats_enabled) return;
        if (!self.record_static_search_outcomes) return;
        if (score_mod.isMateLike(static_eval) or score_mod.isMateLike(score)) return;

        var bounded_score = score;
        const bound_class: StaticSearchBoundClass = if (score >= beta) blk: {
            bounded_score = beta;
            break :blk .lower;
        } else if (score <= alpha_orig) blk: {
            bounded_score = alpha_orig;
            break :blk .upper;
        } else .exact;

        const bucket = staticSearchResidualBucket(bounded_score, static_eval);
        self.stats.static_search_residual_nodes[bucket] += 1;
        switch (bound_class) {
            .exact => self.stats.static_search_residual_exact[bucket] += 1,
            .lower => self.stats.static_search_residual_lower[bucket] += 1,
            .upper => self.stats.static_search_residual_upper[bucket] += 1,
        }
        if (flags.rfp_cutoff) self.stats.static_search_residual_rfp[bucket] += 1;
        if (flags.null_cutoff) self.stats.static_search_residual_null[bucket] += 1;
        if (flags.quiet_futility_prune) self.stats.static_search_residual_quiet_futility[bucket] += 1;
        if (flags.late_move_prune) self.stats.static_search_residual_late_move[bucket] += 1;
        if (flags.bad_capture_prune) self.stats.static_search_residual_bad_capture[bucket] += 1;
        if (flags.lmr_research) self.stats.static_search_residual_lmr_research[bucket] += 1;
        if (flags.lmr_verification_fail_low) self.stats.static_search_residual_lmr_verification_fail_low[bucket] += 1;
    }

    pub fn observePly(self: *SearchContext, ply: usize) void {
        const observed: u16 = @intCast(@min(ply, std.math.maxInt(u16)));
        if (observed > self.seldepth) self.seldepth = observed;
    }
};

fn staticSearchResidualBucket(score: i32, static_eval: i32) usize {
    const delta: i64 = @as(i64, score) - @as(i64, static_eval);
    const abs_delta: u64 = @intCast(if (delta < 0) -delta else delta);
    if (abs_delta <= 15) return 0;
    if (abs_delta <= 31) return 1;
    if (abs_delta <= 63) return 2;
    if (abs_delta <= 127) return 3;
    if (abs_delta <= 255) return 4;
    return 5;
}

fn noteCutLmrBand(move_index: usize, band_3_5: *u64, band_6_7: *u64, band_8p: *u64) void {
    if (move_index >= 8) {
        band_8p.* += 1;
    } else if (move_index >= 6) {
        band_6_7.* += 1;
    } else {
        band_3_5.* += 1;
    }
}

fn noteCaptureBand(move_index: usize, first: *u64, band_1_2: *u64, band_3_5: *u64, band_6p: *u64) void {
    if (move_index == 0) {
        first.* += 1;
    } else if (move_index <= 2) {
        band_1_2.* += 1;
    } else if (move_index <= 5) {
        band_3_5.* += 1;
    } else {
        band_6p.* += 1;
    }
}

fn noteLmrResearchMargin(margin: i32, band_0_31: *u64, band_32_95: *u64, band_96p: *u64) void {
    if (margin >= 96) {
        band_96p.* += 1;
    } else if (margin >= 32) {
        band_32_95.* += 1;
    } else {
        band_0_31.* += 1;
    }
}

fn noteLmrHistorySign(history_score: i32, nonpositive: *u64, positive: *u64) void {
    if (history_score > 0) {
        positive.* += 1;
    } else {
        nonpositive.* += 1;
    }
}
