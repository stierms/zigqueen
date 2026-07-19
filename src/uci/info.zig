const std = @import("std");
const engine_mod = @import("../search/engine.zig");
const score_mod = @import("../search/score.zig");
const search_info = @import("../search/search_info.zig");

/// Stream one `info depth ...` line. Used for every per-iteration line, the
/// aspiration-fail `lowerbound`/`upperbound` partials, and the final line.
/// Built piecewise so no single `print` exceeds the sink's 256-byte buffer.
pub fn writeIterationLine(output: anytype, it: search_info.IterationInfo) !void {
    const nps = computeNps(it.nodes, it.time_ms);

    try output.print("info depth {d} seldepth {d}", .{ it.depth, it.seldepth });
    try writeScore(output, it.score, it.bound);
    try output.print(" nodes {d} time {d} nps {d} hashfull {d}", .{ it.nodes, it.time_ms, nps, it.hashfull });
    if (it.best_move) |best_move| {
        try output.writeAll(" pv ");
        try best_move.writeUci(output);
        if (it.pv.len != 0 and it.pv[0] == best_move) {
            for (it.pv[1..]) |mv| {
                try output.writeByte(' ');
                try mv.writeUci(output);
            }
        }
    }
    try output.writeAll("\n");
}

/// `info depth ... currmove ... currmovenumber ...` search-progress line.
pub fn writeCurrMoveLine(output: anytype, cm: search_info.CurrMoveInfo) !void {
    try output.print("info depth {d} currmove ", .{cm.depth});
    try cm.move.writeUci(output);
    try output.print(" currmovenumber {d} time {d}\n", .{ cm.move_number, cm.time_ms });
}

pub fn writeFinalLine(
    output: anytype,
    result: *const engine_mod.SearchResult,
    depth: u16,
    elapsed_ms: u64,
    hashfull: u16,
) !void {
    try writeIterationLine(output, .{
        .depth = depth,
        .seldepth = @max(depth, result.seldepth),
        .score = result.score,
        .bound = .exact,
        .nodes = result.nodes,
        .time_ms = elapsed_ms,
        .hashfull = hashfull,
        .best_move = result.best_move,
        .pv = result.pv.slice(),
    });
}

pub fn computeNps(nodes: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return @intCast((@as(u128, nodes) * std.time.ms_per_s) / elapsed_ms);
}

fn writeScore(output: anytype, score: i32, bound: search_info.ScoreBound) !void {
    if (score_mod.isMateLike(score)) {
        try output.print(" score mate {d}", .{score_mod.scoreToMate(score)});
    } else {
        try output.print(" score cp {d}", .{score});
    }
    switch (bound) {
        .exact => {},
        .lower => try output.writeAll(" lowerbound"),
        .upper => try output.writeAll(" upperbound"),
    }
}

test "info formatting uses mate scores when appropriate" {
    const move_mod = @import("../core/move.zig");

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    var result = engine_mod.SearchResult{
        .best_move = move_mod.Move.init(.f7, .g7, .quiet),
        .score = 28_999,
        .depth = 1,
        .seldepth = 1,
        .nodes = 66,
    };
    result.pv.push(result.best_move.?);

    try writeFinalLine(&sink.writer, &result, 1, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "score mate 1") != null);
}
