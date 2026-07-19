const std = @import("std");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const eval_backend_info = @import("eval_backend_info.zig");
const tt = @import("../search/tt.zig");

pub fn run(writer: anytype, pos: *const position.Position, depth: u16) !void {
    try runWithOptions(writer, pos, depth, .{});
}

pub fn runWithOptions(writer: anytype, pos: *const position.Position, depth: u16, eval_options: search_engine.EvalOptions) !void {
    var engine = try search_engine.Engine.initWithOptions(std.heap.page_allocator, tt.DEFAULT_HASH_MB, eval_options);
    defer engine.deinit();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    var timer = std.time.Timer.start() catch null;
    const result = engine.search(pos, &history, .{ .depth = depth }, &stop_flag);
    const elapsed_ns: u64 = if (timer) |*search_timer| search_timer.read() else 0;
    const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
    const nps: u64 = if (elapsed_ms == 0) 0 else (result.nodes * std.time.ms_per_s) / elapsed_ms;

    var move_buffer: [5]u8 = undefined;
    const bestmove = if (result.best_move) |mv| mv.toUci(&move_buffer) else "0000";

    try eval_backend_info.write(writer, &engine.evaluator);
    try writer.print("depth {d}\nseldepth {d}\nscore {d}\nnodes {d}\ntime_ms {d}\nnps {d}\nbestmove {s}\n", .{
        result.depth,
        result.seldepth,
        result.score,
        result.nodes,
        elapsed_ms,
        nps,
        bestmove,
    });
}

test "bench prints a bestmove line" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos, 1);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "bestmove ") != null);
}
