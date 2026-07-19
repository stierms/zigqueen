const std = @import("std");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const types = @import("../core/types.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const nnue768 = @import("../eval/nnue768.zig");

pub const MAX_PLY: usize = 128;

/// Lazy-accumulator state: `clean` = acc holds this
/// ply's position (or the entry was never part of a make chain — tests refresh
/// directly); `dirty_*` = a make recorded its inputs but the update is deferred
/// until an eval at-or-below this ply materializes the ancestor chain.
pub const AccState = enum(u2) { clean, dirty_move, dirty_null };

pub const StackEntry = struct {
    state: make_unmake.StateInfo = .{},
    acc: nnue768.Accumulator = .{},
    acc_state: AccState = .clean,
    /// Deferred applyMove input (valid while acc_state == .dirty_move): the move
    /// that produced this ply. Everything else applyMove needs is recovered at
    /// materialization time — the PARENT entry's live `state` (the make's own
    /// undo info, valid until its unmake) plus board reconstruction from the
    /// live position by unmake/re-make (bit-exact round trip). No eager
    /// Position snapshot: the old ~210B copy per make was the endgame-annotate
    /// stall family, paid even on the 20-72% of makes that never materialize.
    pending_mv: move_mod.Move = move_mod.Move.init(.a1, .a1, .quiet),
    killer_a: ?move_mod.Move = null,
    killer_b: ?move_mod.Move = null,
    prev_move: ?move_mod.Move = null,
    /// Moving piece type of `prev_move`, recorded only for quiet predecessors
    /// (drives countermoves + quiet-history learning).
    prev_piece_type: ?piece.PieceType = null,
    /// Moving piece type of `prev_move` for ANY move type (quiet or tactical);
    /// used to key continuation history. Null only after a null move / at root.
    prev_cont_piece: ?piece.PieceType = null,
    static_eval: ?types.Score = null,
};

pub const SearchStack = struct {
    entries: [MAX_PLY]StackEntry = [_]StackEntry{.{}} ** MAX_PLY,

    pub fn entry(self: *SearchStack, ply: usize) *StackEntry {
        std.debug.assert(ply < self.entries.len);
        return &self.entries[ply];
    }
};

test "search stack exposes bounded entries" {
    var stack = SearchStack{};
    stack.entry(0).killer_a = move_mod.Move.init(.e2, .e4, .double_push);
    try std.testing.expectEqual(move_mod.Move.init(.e2, .e4, .double_push), stack.entry(0).killer_a.?);
}
