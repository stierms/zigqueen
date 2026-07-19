const std = @import("std");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const eval_backend_info = @import("eval_backend_info.zig");
const search_report = @import("search_report.zig");
const search_time = @import("../search/time.zig");
const tt = @import("../search/tt.zig");

pub fn run(writer: anytype, pos: *const position.Position, movetime_ms: u64) !void {
    try runWithOptions(writer, pos, movetime_ms, .{});
}

pub fn runWithOptions(writer: anytype, pos: *const position.Position, movetime_ms: u64, eval_options: search_engine.EvalOptions) !void {
    const go_limits = search_time.GoLimits{ .movetime_ms = movetime_ms };
    try runGoLimitsWithOptions(writer, pos, go_limits, eval_options);
}

pub fn runSuddenDeathWithOptions(
    writer: anytype,
    pos: *const position.Position,
    wtime_ms: u64,
    btime_ms: u64,
    winc_ms: u64,
    binc_ms: u64,
    eval_options: search_engine.EvalOptions,
) !void {
    const go_limits = search_time.GoLimits{
        .wtime_ms = wtime_ms,
        .btime_ms = btime_ms,
        .winc_ms = winc_ms,
        .binc_ms = binc_ms,
    };
    try runGoLimitsWithOptions(writer, pos, go_limits, eval_options);
}

fn runGoLimitsWithOptions(
    writer: anytype,
    pos: *const position.Position,
    go_limits: search_time.GoLimits,
    eval_options: search_engine.EvalOptions,
) !void {
    var engine = try search_engine.Engine.initWithOptions(std.heap.page_allocator, tt.DEFAULT_HASH_MB, eval_options);
    defer engine.deinit();
    engine.record_static_search_outcomes = true;
    engine.record_move_order_outcomes = true;
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const plan = go_limits.plan(pos.side_to_move, search_time.DEFAULT_MOVE_OVERHEAD_MS).?;
    const controller_limits = go_limits.toControllerLimits(pos.side_to_move, search_time.DEFAULT_MOVE_OVERHEAD_MS);

    var timer = std.time.Timer.start() catch null;
    const result = engine.search(pos, &history, controller_limits, &stop_flag);
    const elapsed_ns: u64 = if (timer) |*search_timer| search_timer.read() else 0;
    const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));

    try eval_backend_info.write(writer, &engine.evaluator);
    if (go_limits.movetime_ms) |movetime_ms| try writer.print("requested_movetime_ms {d}\n", .{movetime_ms});
    if (go_limits.wtime_ms) |wtime_ms| try writer.print("requested_wtime_ms {d}\n", .{wtime_ms});
    if (go_limits.btime_ms) |btime_ms| try writer.print("requested_btime_ms {d}\n", .{btime_ms});
    try writer.print("requested_winc_ms {d}\n", .{go_limits.winc_ms});
    try writer.print("requested_binc_ms {d}\n", .{go_limits.binc_ms});
    if (go_limits.movestogo) |movestogo| try writer.print("requested_movestogo {d}\n", .{movestogo});
    try writer.print("optimum_budget_ms {d}\n", .{plan.optimum_ms});
    try writer.print("maximum_budget_ms {d}\n", .{plan.maximum_ms});
    try search_report.write(writer, &result, elapsed_ms, engine.hashfullPermille());
}

test "time profile prints the requested and planned budgets" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos, 20);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "requested_movetime_ms 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "optimum_budget_ms ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "maximum_budget_ms ") != null);
}
