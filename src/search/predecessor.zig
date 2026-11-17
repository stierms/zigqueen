//! The game's last search, as far as the next search may build on it: the
//! clock pressure's gate (basin.Params.progress_root_gate), or any other
//! choice that is made before a search from how the last one ended.
//!
//! A search is the successor of another when its root is exactly one legal
//! move from the position that search left behind: its own root after its
//! own best move. That is a fact about two positions. It does not depend on
//! move counters or on how the position was given (a move list, a bare FEN
//! each move). Nothing else is a successor: another game at the same move
//! number, a jump, the same position searched again, a position the best
//! move was not played in.
//!
//! One record, owned by the engine that publishes the search's result: the
//! serial engine, or with Threads > 1 the coordinator, which takes the
//! verdict before the helpers start and hands it to them in the job
//! (shared_job.Job.predecessor). Helpers keep no record.
//!
//! The record is used up by the search that asks for it and written again
//! only from a published result with a completed iteration, so a search that
//! ends early (a claimed draw, a tablebase root) breaks the chain. An
//! infinite search (analysis) neither has a predecessor nor leaves a record.
//! The owner clears the record wherever it clears or replaces its tables
//! (Engine.reset, a Hash resize); a new engine starts without one.

const std = @import("std");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const types = @import("../core/types.zig");

/// What a search learns of the one it succeeds.
pub const Last = struct {
    /// The score that search ended with, for its root side.
    score: types.Score,
    /// Whether it ran under the clock pressure (the gate has two lines:
    /// progress.gateOpen).
    pressure: bool,
};

pub const Predecessor = struct {
    valid: bool = false,
    last: Last = .{ .score = 0, .pressure = false },
    /// Its root after its best move.
    after: position.Position = undefined,

    pub fn clear(self: *Predecessor) void {
        self.valid = false;
    }

    /// The last search's score and state when the search of `root` is its
    /// successor, null otherwise. Uses the record up either way.
    pub fn take(self: *Predecessor, root: *const position.Position, infinite: bool) ?Last {
        const valid = self.valid;
        self.valid = false;
        if (!valid or infinite) return null;
        var after = self.after;
        var moves = move_mod.MoveList.init();
        legal.generate(&after, &moves);
        for (moves.moves[0..moves.count]) |mv| {
            var state = make_unmake.StateInfo{};
            _ = make_unmake.makeMove(&after, mv, &state);
            // The same position, reached by that one move: the key, and the
            // clock the move gives (the key does not hold the clock).
            const reached = after.zobrist_key == root.zobrist_key and after.halfmove_clock == root.halfmove_clock;
            make_unmake.unmakeMove(&after, mv, &state);
            if (reached) return self.last;
        }
        return null;
    }

    /// Called with the published result of a search of `root`: its best move,
    /// the depth it completed, its score for the root side, and whether it
    /// ran under the clock pressure.
    pub fn leave(self: *Predecessor, root: *const position.Position, best_move: ?move_mod.Move, depth: usize, score: types.Score, pressure: bool, infinite: bool) void {
        self.valid = false;
        const mv = best_move orelse return;
        if (depth == 0 or infinite) return;
        var after = root.*;
        if (!legal.isLegalMove(&after, mv)) return;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&after, mv, &state);
        self.* = .{ .valid = true, .last = .{ .score = score, .pressure = pressure }, .after = after };
    }
};

test "a search has a predecessor only one legal move after the position the last search left" {
    const fen = @import("../core/fen.zig");
    var record = Predecessor{};
    const root = try fen.parse("4k3/pppp4/8/8/8/8/PPPP4/RNBQK3 w Q - 4 20");
    const best = move_mod.Move.init(.d1, .h5, .quiet);

    // No record: no predecessor.
    try std.testing.expectEqual(@as(?Last, null), record.take(&root, false));

    // The game goes on: the best move and any reply.
    record.leave(&root, best, 9, 512, false, false);
    try std.testing.expect(record.valid);
    const successor = try fen.parse("3k4/pppp4/8/7Q/8/8/PPPP4/RNB1K3 w Q - 6 21");
    try std.testing.expectEqual(@as(?Last, .{ .score = 512, .pressure = false }), record.take(&successor, false));
    // Used up: the same question again has no answer.
    try std.testing.expectEqual(@as(?Last, null), record.take(&successor, false));

    // However the position was sent: the same position with other counters
    // in the FEN's move number is still that position. The record carries
    // whether its search ran under the pressure.
    record.leave(&root, best, 9, 512, true, false);
    const renumbered = try fen.parse("3k4/pppp4/8/7Q/8/8/PPPP4/RNB1K3 w Q - 6 77");
    try std.testing.expectEqual(@as(?Last, .{ .score = 512, .pressure = true }), record.take(&renumbered, false));

    const Case = struct { name: []const u8, text: []const u8 };
    for ([_]Case{
        .{ .name = "another game at the same move number and side", .text = "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 21" },
        .{ .name = "the same root again", .text = "4k3/pppp4/8/8/8/8/PPPP4/RNBQK3 w Q - 4 20" },
        .{ .name = "the position after the best move only", .text = "4k3/pppp4/8/7Q/8/8/PPPP4/RNB1K3 b Q - 5 20" },
        .{ .name = "a reply after another move than the best", .text = "3k4/pppp4/8/8/8/8/PPPPQ3/RNB1K3 w Q - 6 21" },
        .{ .name = "two moves further on", .text = "4k3/pppp4/8/8/8/8/PPPPQ3/RNB1K3 w Q - 8 22" },
        .{ .name = "the right position with another clock", .text = "3k4/pppp4/8/7Q/8/8/PPPP4/RNB1K3 w Q - 0 21" },
    }) |case| {
        record.leave(&root, best, 9, 512, false, false);
        const other = try fen.parse(case.text);
        std.testing.expectEqual(@as(?Last, null), record.take(&other, false)) catch |err| {
            std.debug.print("predecessor accepted: {s}\n", .{case.name});
            return err;
        };
        try std.testing.expect(!record.valid);
    }

    // Analysis neither has a predecessor nor leaves one.
    record.leave(&root, best, 9, 512, false, false);
    try std.testing.expectEqual(@as(?Last, null), record.take(&successor, true));
    try std.testing.expect(!record.valid);
    record.leave(&root, best, 9, 512, false, true);
    try std.testing.expect(!record.valid);

    // No completed iteration, no move, or a move that is not legal there: no record.
    record.leave(&root, best, 0, 512, false, false);
    try std.testing.expect(!record.valid);
    record.leave(&root, null, 9, 512, false, false);
    try std.testing.expect(!record.valid);
    record.leave(&root, move_mod.Move.init(.a1, .a8, .quiet), 9, 512, false, false);
    try std.testing.expect(!record.valid);

    // Cleared by its owner.
    record.leave(&root, best, 9, 512, false, false);
    record.clear();
    try std.testing.expectEqual(@as(?Last, null), record.take(&successor, false));
}
