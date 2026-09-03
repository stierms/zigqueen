const std = @import("std");
const fen = @import("../core/fen.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
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

    try writeTsv(writer, pos, &result, elapsed_ms);
}

fn writeTsv(writer: anytype, pos: *const position.Position, result: *const search_engine.SearchResult, elapsed_ms: u64) !void {
    var bestmove_buffer: [5]u8 = undefined;
    const bestmove = if (result.best_move) |mv| mv.toUci(&bestmove_buffer) else "0000";
    const score_white_pov = switch (pos.side_to_move) {
        .white => result.score,
        .black => -result.score,
    };

    try writer.writeAll("fen\tzobrist_hex\tside_to_move\tbestmove\tscore_stm\tscore_white_pov\tdepth\tseldepth\tnodes\telapsed_ms\tpv\n");
    try fen.write(pos, writer);
    try writer.print("\t{x:0>16}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t", .{
        pos.zobrist_key,
        @tagName(pos.side_to_move),
        bestmove,
        result.score,
        score_white_pov,
        result.depth,
        result.seldepth,
        result.nodes,
        elapsed_ms,
    });
    for (result.pv.slice(), 0..) |mv, i| {
        var pv_buffer: [5]u8 = undefined;
        if (i != 0) try writer.writeByte(' ');
        try writer.writeAll(mv.toUci(&pv_buffer));
    }
    try writer.writeByte('\n');
}

test "raw search probe emits tsv header and bestmove" {
    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos, 1);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "fen\tzobrist_hex\tside_to_move\tbestmove") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\twhite\t") != null);
}
