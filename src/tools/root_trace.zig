const std = @import("std");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const tt = @import("../search/tt.zig");

pub fn run(writer: anytype, pos: *const position.Position, depth: u16) !void {
    var engine = try search_engine.Engine.init(std.heap.page_allocator, tt.DEFAULT_HASH_MB);
    defer engine.deinit();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);

    const result = engine.search(pos, &history, .{ .depth = depth }, &stop_flag);
    for (result.diagnostics.trace[0..result.diagnostics.trace_len]) |entry| {
        var move_buffer: [5]u8 = undefined;
        const bestmove = if (entry.best_move) |mv| mv.toUci(&move_buffer) else "0000";
        try writer.print("depth {d} seldepth {d} score {d} nodes {d} bestmove {s}", .{ entry.depth, entry.seldepth, entry.score, entry.nodes, bestmove });
        if (entry.pv.len != 0) {
            try writer.writeAll(" pv ");
            try entry.pv.writeUci(writer);
        }
        try writer.writeByte('\n');
    }
}

test "root trace prints iterative depths" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos, 2);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "depth 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "seldepth ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "depth 2") != null);
}
