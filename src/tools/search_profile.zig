const std = @import("std");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const eval_backend_info = @import("eval_backend_info.zig");
const history_report = @import("history_report.zig");
const search_report = @import("search_report.zig");
const hugealloc = @import("../util/hugealloc.zig");
const tt = @import("../search/tt.zig");

pub fn run(writer: anytype, pos: *const position.Position, depth: u16) !void {
    try runWithOptions(writer, pos, depth, .{});
}

pub fn runWithOptions(writer: anytype, pos: *const position.Position, depth: u16, eval_options: search_engine.EvalOptions) !void {
    var engine = try search_engine.Engine.initWithOptions(std.heap.page_allocator, tt.DEFAULT_HASH_MB, eval_options);
    defer engine.deinit();
    engine.record_static_search_outcomes = true;
    engine.record_move_order_outcomes = true;
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    var timer = std.time.Timer.start() catch null;
    const result = engine.search(pos, &history, .{ .depth = depth }, &stop_flag);
    const elapsed_ns: u64 = if (timer) |*search_timer| search_timer.read() else 0;
    const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
    try eval_backend_info.write(writer, &engine.evaluator);
    var thp_buf: [128]u8 = undefined;
    try writer.print("hugepages tt {s} rfp_hint {s} conthist {s} thp_enabled \"{s}\"\n", .{
        engine.tt.alloc_method.name(),
        engine.rfp_hint.alloc_method.name(),
        engine.history.continuation_method.name(),
        hugealloc.thpEnabledSetting(&thp_buf) orelse "unavailable",
    });
    if (engine.evaluator.net) |net| {
        try writer.print("hugepages_net feature_weights {s} output_weights {s} threat_w8 {s} l1_weights {s} l2_weights_t {s}\n", .{
            net.weight_methods.feature_weights.name(),
            net.weight_methods.output_weights.name(),
            net.weight_methods.threat_w8.name(),
            net.weight_methods.l1_weights.name(),
            net.weight_methods.l2_weights_t.name(),
        });
    }
    // Eval-cache configuration + end-of-search occupancy (does the
    // search even fill the table?) for the sizing/replacement sweeps.
    const eval_cache_occ = engine.eval_cache.occupancy();
    try writer.print("eval_cache_config size_mb {d} assoc {d} entries {d} filled {d} fill_permille {d}\n", .{
        engine.eval_cache.cacheSizeMb(),
        engine.eval_cache.assocWays(),
        eval_cache_occ.total,
        eval_cache_occ.filled,
        if (eval_cache_occ.total == 0) 0 else eval_cache_occ.filled * 1000 / eval_cache_occ.total,
    });
    try search_report.write(writer, &result, elapsed_ms, engine.hashfullPermille());
    try history_report.write(writer, &engine.history);
}

test "search profile prints search counters" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos, 2);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "qnodes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "tt_probes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "iteration depth 1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "history_table_entries ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "countermove_table_probes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "countermove_table_slots ") != null);
}
