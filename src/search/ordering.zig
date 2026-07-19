const std = @import("std");
const piece_values = @import("../core/piece_values.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const types = @import("../core/types.zig");
const history_mod = @import("history.zig");
const see = @import("see.zig");

pub const Killers = struct {
    a: ?move_mod.Move = null,
    b: ?move_mod.Move = null,
};

const COUNTERMOVE_SCORE: i32 = 246_000;

/// Outside the u16 move-pattern range: compares equal to no real move, so a
/// null tt/killer/countermove needs no per-move tag test.
const NO_MOVE_SENTINEL: u32 = 1 << 16;

pub const MovePicker = struct {
    list: *move_mod.MoveList,
    scores: *[move_mod.MAX_MOVES]i32,
    capture_see_scores: ?*[move_mod.MAX_MOVES]i32,

    pub inline fn init(
        list: *move_mod.MoveList,
        scores: *[move_mod.MAX_MOVES]i32,
        capture_see_scores: ?*[move_mod.MAX_MOVES]i32,
    ) MovePicker {
        return .{
            .list = list,
            .scores = scores,
            .capture_see_scores = capture_see_scores,
        };
    }

    pub inline fn next(self: *MovePicker, start_index: usize) move_mod.Move {
        return pickNext(self.list, self.scores, self.capture_see_scores, start_index);
    }

    pub inline fn captureSee(self: *const MovePicker, index: usize) i32 {
        const see_scores = self.capture_see_scores orelse return 0;
        return see_scores[index];
    }
};

pub fn scoreMoves(
    pos: *const position.Position,
    list: *const move_mod.MoveList,
    tt_move: ?move_mod.Move,
    killers: Killers,
    countermove: ?move_mod.Move,
    history: *const history_mod.HistoryTable,
    cont: *const history_mod.ContContext,
    noalias scores: *[move_mod.MAX_MOVES]i32,
    noalias capture_see_scores: ?*[move_mod.MAX_MOVES]i32,
) void {
    // Hoist the conthist context resolution out of the per-move loop: the
    // compiler cannot prove the scores[] stores don't alias *cont/*history, so
    // calling contTotal per move reloaded the table pointer, both prev keys,
    // and redid the row address chain for every scored move. Row addresses are
    // fixed for the node; per-move reads still see the live table values.
    const cont_rows = history.contRows(cont);
    // Further loop-invariant hoists (profile-driven — scoreMoves was ~11% of
    // endgame cycles, almost all in the quiet path):
    // - tt/killer/countermove candidates as raw u16 move patterns with an
    //   out-of-u16 sentinel: one register compare per move instead of an
    //   optional-tag reload + compare (the by-ref optionals were re-read every
    //   iteration for the same aliasing reason as above; `scores` is now also
    //   declared noalias so the stores can't pin those reloads).
    // - the moving side: every move in the list is by pos.side_to_move, so the
    //   side half of the quiet-history row address and of the cont key is
    //   node-invariant — this drops the per-move mailbox color-table lookup
    //   and the per-move side*6 cmove chain in contKey.
    // All hoists are value-identical: scores come out bit-identical, so the
    // swap-based picker's ordering (ties included) is unchanged.
    const tt_raw: u32 = if (tt_move) |m| @as(u16, @bitCast(m)) else NO_MOVE_SENTINEL;
    const killer_a_raw: u32 = if (killers.a) |m| @as(u16, @bitCast(m)) else NO_MOVE_SENTINEL;
    const killer_b_raw: u32 = if (killers.b) |m| @as(u16, @bitCast(m)) else NO_MOVE_SENTINEL;
    const counter_raw: u32 = if (countermove) |m| @as(u16, @bitCast(m)) else NO_MOVE_SENTINEL;
    const stm = pos.side_to_move;
    const quiet_plane = history.quietPlane(stm);
    for (list.slice(), 0..) |mv, idx| {
        const scored = scoreMove(pos, mv, tt_raw, killer_a_raw, killer_b_raw, counter_raw, stm, quiet_plane, &cont_rows);
        scores[idx] = scored.score;
        if (capture_see_scores) |see_scores| see_scores[idx] = scored.capture_see;
    }
}

pub fn scoreTacticalMoves(
    pos: *const position.Position,
    list: *const move_mod.MoveList,
    tt_move: ?move_mod.Move,
    scores: *[move_mod.MAX_MOVES]i32,
    capture_see_scores: *[move_mod.MAX_MOVES]i32,
) void {
    for (list.slice(), 0..) |mv, idx| {
        if (tt_move) |candidate| {
            if (candidate == mv) {
                scores[idx] = 1_000_000;
                capture_see_scores[idx] = 0;
                continue;
            }
        }

        const flag = @intFromEnum(mv.flag);
        if (flag >= @intFromEnum(move_mod.MoveFlag.promo_knight)) {
            scores[idx] = 900_000 + piece_values.value(mv.promotionPieceType().?);
            capture_see_scores[idx] = 0;
            continue;
        }

        const moving_piece = pos.pieceAt(mv.from);
        const moving_type = moving_piece.pieceType();
        const captured_piece = capturedPiece(pos, mv, moving_piece);
        const tactical_score = 16 * piece_values.value(captured_piece.pieceType()) - piece_values.value(moving_type);
        const see_score = see.captureScore(pos, mv);
        capture_see_scores[idx] = see_score;
        scores[idx] = if (see_score >= 0)
            500_000 + tactical_score + @min(see_score, 1024)
        else
            200_000 + see_score;
    }
}

pub fn pickNext(
    list: *move_mod.MoveList,
    scores: *[move_mod.MAX_MOVES]i32,
    capture_see_scores: ?*[move_mod.MAX_MOVES]i32,
    start_index: usize,
) move_mod.Move {
    if (start_index + 1 >= list.count) return list.moves[start_index];

    var best_index = start_index;
    var best_score = scores[start_index];
    var i = start_index + 1;
    while (i < list.count) : (i += 1) {
        if (scores[i] > best_score) {
            best_score = scores[i];
            best_index = i;
        }
    }

    if (best_index != start_index) {
        const best_move = list.moves[best_index];
        list.moves[best_index] = list.moves[start_index];
        list.moves[start_index] = best_move;

        const best_score_value = scores[best_index];
        scores[best_index] = scores[start_index];
        scores[start_index] = best_score_value;

        if (capture_see_scores) |see_scores| {
            const best_see_score = see_scores[best_index];
            see_scores[best_index] = see_scores[start_index];
            see_scores[start_index] = best_see_score;
        }
    }

    return list.moves[start_index];
}

const ScoredMove = struct {
    score: i32,
    capture_see: i32 = 0,
};

inline fn scoreMove(
    pos: *const position.Position,
    mv: move_mod.Move,
    tt_raw: u32,
    killer_a_raw: u32,
    killer_b_raw: u32,
    counter_raw: u32,
    stm: types.Color,
    quiet_plane: *const [6][64]i16,
    cont_rows: *const history_mod.ContRows,
) ScoredMove {
    // Move equality on the packed(u16) Move is bit equality, so the raw-vs-raw
    // compares below are identical to the previous `?Move` unwrap + `==`.
    const mv_raw: u32 = @as(u16, @bitCast(mv));
    if (mv_raw == tt_raw) return .{ .score = 1_000_000 };

    const flag = @intFromEnum(mv.flag);
    if (flag >= @intFromEnum(move_mod.MoveFlag.promo_knight)) {
        return .{ .score = 900_000 + piece_values.value(mv.promotionPieceType().?) };
    }

    const is_capture = flag == @intFromEnum(move_mod.MoveFlag.capture) or flag == @intFromEnum(move_mod.MoveFlag.en_passant);
    if (is_capture) {
        const moving_piece = pos.pieceAt(mv.from);
        const moving_type = moving_piece.pieceType();
        const captured_piece = capturedPiece(pos, mv, moving_piece);
        const tactical_score = 16 * piece_values.value(captured_piece.pieceType()) - piece_values.value(moving_type);
        const see_score = see.captureScore(pos, mv);
        if (see_score >= 0) {
            return .{ .score = 500_000 + tactical_score + @min(see_score, 1024), .capture_see = see_score };
        }
        return .{ .score = 200_000 + see_score, .capture_see = see_score };
    }

    if (mv_raw == killer_a_raw) return .{ .score = 250_000 };
    if (mv_raw == killer_b_raw) return .{ .score = 249_000 };

    // Quiet path: the mover's color is the side to move for every generated
    // move, so `stm` replaces the old mailbox color().? lookup value-exactly.
    const moving_type = pos.pieceAt(mv.from).pieceType();
    // Explicit row pointer — `quiet_plane[piece][to]` with a runtime piece
    // index materialises a 128-byte stack copy of the row (the defect class
    // HistoryTable.score already documents).
    const quiet_row: *const [64]i16 = &quiet_plane[@intFromEnum(moving_type)];
    const history_score: i32 = quiet_row[mv.to.index()];
    if (mv_raw == counter_raw) return .{ .score = COUNTERMOVE_SCORE + @divTrunc(@max(history_score, 0), 4) };
    // Plain quiet: main history + continuation history. The combined magnitude
    // stays well under the bad-capture floor, so quiets keep their ordering tier.
    const cont_score = cont_rows.total(history_mod.contKey(stm, moving_type, mv.to));
    return .{ .score = history_score + cont_score };
}

inline fn capturedPiece(pos: *const position.Position, mv: move_mod.Move, moving_piece: piece.Piece) piece.Piece {
    if (mv.flag == .en_passant) return piece.Piece.make(moving_piece.color().?.other(), .pawn);
    return pos.pieceAt(mv.to);
}

test "tt move outranks other ordering terms" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var moves = move_mod.MoveList.init();
    moves.add(move_mod.Move.init(.a2, .a3, .quiet));
    moves.add(move_mod.Move.init(.e2, .e4, .double_push));

    var scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    const history = history_mod.HistoryTable{};
    const cont = history_mod.ContContext{};
    scoreMoves(&pos, &moves, move_mod.Move.init(.e2, .e4, .double_push), .{}, null, &history, &cont, &scores, null);

    const first = pickNext(&moves, &scores, null, 0);
    try std.testing.expectEqual(move_mod.Move.init(.e2, .e4, .double_push), first);
}

test "killer quiet outranks quiet history ordering" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var moves = move_mod.MoveList.init();
    moves.add(move_mod.Move.init(.a2, .a3, .quiet));
    moves.add(move_mod.Move.init(.h2, .h3, .quiet));

    var history = history_mod.HistoryTable{};
    history.bonus(.white, .pawn, .a3, 4);

    var scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    const cont = history_mod.ContContext{};
    scoreMoves(&pos, &moves, null, .{ .a = move_mod.Move.init(.h2, .h3, .quiet) }, null, &history, &cont, &scores, null);

    const first = pickNext(&moves, &scores, null, 0);
    try std.testing.expectEqual(move_mod.Move.init(.h2, .h3, .quiet), first);
}

test "countermove quiet outranks plain quiet history but stays below killers" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var moves = move_mod.MoveList.init();
    const history_move = move_mod.Move.init(.a2, .a3, .quiet);
    const counter_move = move_mod.Move.init(.h2, .h3, .quiet);
    moves.add(history_move);
    moves.add(counter_move);

    var history = history_mod.HistoryTable{};
    history.bonus(.white, .pawn, history_move.to, 10);

    var scores: [move_mod.MAX_MOVES]i32 = [_]i32{0} ** move_mod.MAX_MOVES;
    const cont = history_mod.ContContext{};
    scoreMoves(&pos, &moves, null, .{}, counter_move, &history, &cont, &scores, null);
    try std.testing.expect(scores[1] > scores[0]);

    scoreMoves(&pos, &moves, null, .{ .a = history_move }, counter_move, &history, &cont, &scores, null);
    try std.testing.expect(scores[0] > scores[1]);
}
