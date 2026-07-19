const std = @import("std");
const fen = @import("../core/fen.zig");
const legal = @import("legal.zig");
const make_unmake = @import("make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");

pub fn perft(pos: *const position.Position, depth: u32) u64 {
    var temp = pos.*;
    return perftMutable(&temp, depth);
}

fn perftMutable(pos: *position.Position, depth: u32) u64 {
    if (depth == 0) return 1;

    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    if (depth == 1) return moves.count;

    var nodes: u64 = 0;
    for (moves.slice()) |mv| {
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(pos, mv, &state);
        nodes += perftMutable(pos, depth - 1);
        make_unmake.unmakeMove(pos, mv, &state);
    }
    return nodes;
}

const PerftCase = struct {
    name: []const u8,
    fen_text: []const u8,
    depth: u32,
    nodes: u64,
};

fn expectPerftCase(case: PerftCase) !void {
    const pos = try fen.parse(case.fen_text);
    const actual = perft(&pos, case.depth);
    try std.testing.expectEqual(case.nodes, actual);
}

test "start position perft depth ladder" {
    const pos = try fen.startpos();
    try std.testing.expectEqual(@as(u64, 20), perft(&pos, 1));
    try std.testing.expectEqual(@as(u64, 400), perft(&pos, 2));
    try std.testing.expectEqual(@as(u64, 8902), perft(&pos, 3));
    try std.testing.expectEqual(@as(u64, 197281), perft(&pos, 4));
}

test "canonical perft positions" {
    const cases = [_]PerftCase{
        .{ .name = "kiwipete d3", .fen_text = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 3, .nodes = 97862 },
        .{ .name = "position3 d4", .fen_text = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 4, .nodes = 43238 },
        .{ .name = "position6 d3", .fen_text = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", .depth = 3, .nodes = 89890 },
        .{ .name = "position5 d4", .fen_text = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", .depth = 4, .nodes = 2103487 },
    };

    for (cases) |case| try expectPerftCase(case);
}

test "castling legality regressions" {
    const cases = [_]PerftCase{
        .{ .name = "regression 1 d3", .fen_text = "1rb1kb1r/3n1ppp/p3p3/qp2P3/4BBn1/3Q1N2/PP2NPPP/R3K2R w KQk - 1 15", .depth = 3, .nodes = 14089 },
        .{ .name = "regression 2 d3", .fen_text = "r4rk1/pp2pp1p/6p1/2pP4/2Q1P3/5B2/P3RPPP/q3K2R w K - 1 18", .depth = 3, .nodes = 1753 },
    };

    for (cases) |case| try expectPerftCase(case);
}
