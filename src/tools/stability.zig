const std = @import("std");
const fen = @import("../core/fen.zig");
const legal = @import("../movegen/legal.zig");
const position = @import("../core/position.zig");
const pv = @import("../search/pv.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const tt = @import("../search/tt.zig");

const Case = struct {
    name: []const u8,
    fen_text: []const u8,
    depth: u16,
};

const CASES = [_]Case{
    .{ .name = "startpos", .fen_text = fen.STARTPOS_FEN, .depth = 2 },
    .{ .name = "kiwipete", .fen_text = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 2 },
    .{ .name = "mate-in-one", .fen_text = "6k1/5Q2/6K1/8/8/8/8/8 w - - 0 1", .depth = 1 },
    .{ .name = "endgame", .fen_text = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 3 },
    .{ .name = "in-check", .fen_text = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1", .depth = 1 },
};

const Snapshot = struct {
    best_move: ?@import("../core/move.zig").Move,
    score: i32,
    pv: pv.Line,
};

pub const StabilityError = error{
    IllegalBestMove,
    IllegalPv,
    UnstableBestMove,
    UnstableScore,
    UnstablePv,
};

pub fn run(writer: anytype, iterations: u8) !void {
    for (CASES) |case| {
        try verifyCase(case, iterations);
        try writer.print("ok {s} depth {d} iterations {d}\n", .{ case.name, case.depth, iterations });
    }
}

pub fn verifyRepresentativeSuite(iterations: u8) StabilityError!void {
    for (CASES) |case| try verifyCase(case, iterations);
}

fn verifyCase(case: Case, iterations: u8) StabilityError!void {
    const pos = fen.parse(case.fen_text) catch unreachable;
    var history = repetition.History{};
    history.push(pos.zobrist_key);

    var baseline: ?Snapshot = null;
    var run_index: u8 = 0;
    while (run_index < iterations) : (run_index += 1) {
        var engine = search_engine.Engine.init(std.heap.page_allocator, tt.DEFAULT_HASH_MB) catch unreachable;
        defer engine.deinit();
        var stop_flag = std.atomic.Value(bool).init(false);
        const result = engine.search(&pos, &history, .{ .depth = case.depth }, &stop_flag);

        try ensureLegalResult(&pos, &history, &result);

        const snapshot = Snapshot{
            .best_move = result.best_move,
            .score = result.score,
            .pv = result.pv,
        };

        if (baseline) |expected| {
            if (expected.best_move != snapshot.best_move) return error.UnstableBestMove;
            if (expected.score != snapshot.score) return error.UnstableScore;
            if (!expected.pv.eql(&snapshot.pv)) return error.UnstablePv;
        } else {
            baseline = snapshot;
        }
    }
}

fn ensureLegalResult(
    pos: *const position.Position,
    history: *const repetition.History,
    result: *const search_engine.SearchResult,
) StabilityError!void {
    var moves = @import("../core/move.zig").MoveList.init();
    legal.generate(pos, &moves);

    if (moves.count == 0) {
        if (result.best_move != null) return error.IllegalBestMove;
    } else {
        const best_move = result.best_move orelse return error.IllegalBestMove;
        if (!legal.isLegalMove(pos, best_move)) return error.IllegalBestMove;
    }

    if (!pv.isLegal(pos, history, &result.pv)) return error.IllegalPv;
    if (result.pv.len != 0 and result.best_move != null and result.pv.slice()[0] != result.best_move.?) {
        return error.IllegalPv;
    }
}

test "representative fixed-depth suite is stable and legal" {
    try verifyRepresentativeSuite(3);
}
