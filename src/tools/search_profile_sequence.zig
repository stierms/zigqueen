const std = @import("std");
const fen = @import("../core/fen.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const tt = @import("../search/tt.zig");

const MAX_FEN_FILE_BYTES: usize = 8 * 1024 * 1024;

pub fn runFile(writer: anytype, path: []const u8, depth: u16) !void {
    try runFileWithOptions(writer, path, depth, .{});
}

pub fn runFileWithOptions(writer: anytype, path: []const u8, depth: u16, eval_options: search_engine.EvalOptions) !void {
    const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, MAX_FEN_FILE_BYTES);
    defer std.heap.page_allocator.free(data);

    var engine = try search_engine.Engine.initWithOptions(std.heap.page_allocator, tt.DEFAULT_HASH_MB, eval_options);
    defer engine.deinit();
    engine.record_static_search_outcomes = true;
    engine.record_move_order_outcomes = true;

    try writer.writeAll(
        "index\tdepth\tscore\tnodes\tqnodes\tmain_static_evals\treverse_futility_prunes\t" ++
            "quiet_futility_prunes\tlate_move_prunes\tbad_capture_prunes\tnull_tries\tnull_cutoffs\t" ++
            "lmr_reductions\tlmr_researches\tmain_bad_capture_cutoffs\tmain_quiet_cutoffs\t" ++
            "qsearch_bad_capture_cutoffs\trfp_hint_probes\trfp_hint_cutoffs\t" ++
            "rfp_hint_cutoffs_depth_1\trfp_hint_cutoffs_depth_2\trfp_hint_cutoffs_depth_3\t" ++
            "rfp_hint_alpha_raises\tbestmove\thashfull\ttt_probes\ttt_hits\t" ++
            "tt_hit_current_generation\ttt_hit_old_generation\ttt_hit_age_1\ttt_hit_age_2_3\t" ++
            "tt_hit_age_4p\ttt_hit_with_move\ttt_hit_without_move\ttt_cutoffs\t" ++
            "tt_cutoffs_current_generation\ttt_cutoffs_old_generation\ttt_ordering_only_hits\t" ++
            "tt_ordering_only_current_generation\ttt_ordering_only_old_generation\ttt_stores\t" ++
            "tt_store_skipped_same_generation_deeper\ttt_store_skip_new_with_move\t" ++
            "tt_store_skip_new_without_move\ttt_store_skip_victim_with_move\t" ++
            "tt_store_skip_victim_without_move\ttt_store_empty\ttt_store_same_key\t" ++
            "tt_store_replacements\ttt_store_replaced_current_generation\t" ++
            "tt_store_replaced_old_generation\ttt_store_replaced_with_move\t" ++
            "tt_store_replaced_without_move\ttt_store_new_with_move\ttt_store_new_without_move\t" ++
            "tt_store_new_exact_bound\ttt_store_new_lower_bound\ttt_store_new_upper_bound\tfen\n",
    );

    var lines = std.mem.splitScalar(u8, data, '\n');
    var index: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "fen")) continue;
        const pos = fen.parse(line) catch continue;
        index += 1;

        var history = repetition.History{};
        history.push(pos.zobrist_key);
        var stop_flag = std.atomic.Value(bool).init(false);
        const result = engine.search(&pos, &history, .{ .depth = depth }, &stop_flag);
        const stats = result.diagnostics.stats;
        var move_buffer: [5]u8 = undefined;
        const bestmove = if (result.best_move) |mv| mv.toUci(&move_buffer) else "0000";
        try writer.print(
            "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t",
            .{
                index,
                result.depth,
                result.score,
                result.nodes,
                stats.qnodes,
                stats.main_static_evals,
                stats.reverse_futility_prunes,
                stats.quiet_futility_prunes,
                stats.late_move_prunes,
                stats.bad_capture_prunes,
                stats.null_tries,
                stats.null_cutoffs,
                stats.lmr_reductions,
                stats.lmr_researches,
                stats.main_bad_capture_cutoffs,
                stats.main_quiet_cutoffs,
                stats.qsearch_bad_capture_cutoffs,
                stats.rfp_hint_probes,
                stats.rfp_hint_cutoffs,
                stats.rfp_hint_cutoffs_depth_1,
                stats.rfp_hint_cutoffs_depth_2,
                stats.rfp_hint_cutoffs_depth_3,
                stats.rfp_hint_alpha_raises,
            },
        );
        try writer.print(
            "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t",
            .{
                bestmove,
                engine.hashfullPermille(),
                stats.tt_probes,
                stats.tt_hits,
                stats.tt_hit_current_generation,
                stats.tt_hit_old_generation,
                stats.tt_hit_age_1,
                stats.tt_hit_age_2_3,
                stats.tt_hit_age_4p,
                stats.tt_hit_with_move,
                stats.tt_hit_without_move,
                stats.tt_cutoffs,
                stats.tt_cutoffs_current_generation,
                stats.tt_cutoffs_old_generation,
                stats.tt_ordering_only_hits,
                stats.tt_ordering_only_current_generation,
                stats.tt_ordering_only_old_generation,
            },
        );
        try writer.print(
            "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n",
            .{
                stats.tt_stores,
                stats.tt_store_skipped_same_generation_deeper,
                stats.tt_store_skip_new_with_move,
                stats.tt_store_skip_new_without_move,
                stats.tt_store_skip_victim_with_move,
                stats.tt_store_skip_victim_without_move,
                stats.tt_store_empty,
                stats.tt_store_same_key,
                stats.tt_store_replacements,
                stats.tt_store_replaced_current_generation,
                stats.tt_store_replaced_old_generation,
                stats.tt_store_replaced_with_move,
                stats.tt_store_replaced_without_move,
                stats.tt_store_new_with_move,
                stats.tt_store_new_without_move,
                stats.tt_store_new_exact_bound,
                stats.tt_store_new_lower_bound,
                stats.tt_store_new_upper_bound,
                line,
            },
        );
    }
}
