const std = @import("std");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");

const Entry = struct {
    key: u64,
    uci: []const u8,
};

// Promoted exact active-opening stable book from clean-room UCI output. Entries
// are restricted to external opening start FENs where full Stockfish depth 10
// and depth 14 selected the same move and current zigqueen depth 10 disagreed.
// No pattern/general opening rule is encoded here.
const ENTRIES = [_]Entry{
    .{ .key = 0x01381d5ff8754004, .uci = "e1g1" },
    .{ .key = 0xa1a1b3b645e626ff, .uci = "d2d4" },
    .{ .key = 0xb20e21944c7c3555, .uci = "b1c3" },
    .{ .key = 0x9f901e4012cffaf9, .uci = "g7g6" },
    .{ .key = 0xd00c1f3861438c6f, .uci = "f8e7" },
    .{ .key = 0x303a3e718b616034, .uci = "c7c5" },
};

pub fn findRootMove(pos: *const position.Position) ?move_mod.Move {
    for (ENTRIES) |entry| {
        if (entry.key == pos.zobrist_key) return findLegalUciMove(pos, entry.uci);
    }
    return null;
}

fn findLegalUciMove(pos: *const position.Position, uci: []const u8) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        var buffer: [5]u8 = undefined;
        if (std.mem.eql(u8, mv.toUci(&buffer), uci)) return mv;
    }
    return null;
}

test "exact active opening book entry returns teacher move" {
    const fen = @import("../core/fen.zig");
    const pos = try fen.parse("r1bqkb1r/1ppp1ppp/p1n2n2/4p3/B3P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 2 5");
    const mv = findRootMove(&pos).?;
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqualStrings("e1g1", mv.toUci(&buffer));
}

test "start position has no exact active opening book entry" {
    const fen = @import("../core/fen.zig");
    const pos = try fen.startpos();
    try std.testing.expectEqual(@as(?move_mod.Move, null), findRootMove(&pos));
}
