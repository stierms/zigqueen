const attacks = @import("../movegen/attacks.zig");
const bitboard = @import("../core/bitboard.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const piece_values = @import("../core/piece_values.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

const Attacker = struct {
    from: square.Square,
    piece_type: piece.PieceType,
};

// The swap loop used to carry a private COPY of `pos.pieces` (a [2][6]u64 =
// 96-byte struct on the caller's stack) and clear a bit in it per removal. LLVM
// materialized that copy with two zmm stores and then read it back 8 bytes at a
// time — a store-to-load-forwarding stall that was 58% of `quietScore`'s samples
// and 59% of `seeGain`'s in the r8 profile.
//
// The copy is not needed: an occupancy mask alone is exactly equivalent. Every
// query in the exchange is `pieces[side][type] & attacksTo(target)`, and NO
// attack set to `target` ever contains `target` itself, so intersecting the
// position's own (immutable) piece bitboards with a mutable `occ` reproduces the
// removals bit for bit:
//   - the mover and every spent attacker are cleared from `occ`, so they drop
//     out of the intersection just as clearing their type bitboard did;
//   - the captured victim sits ON `target`, whose `occ` bit is (re)set by the
//     arriving piece, but it can never appear in an attack set aimed at its own
//     square, so leaving its bit in `pieces` is unobservable.
// Result: no copy, no spill, the piece bitboards are read straight out of the
// hot Position, and only a single u64 changes per exchange step.

pub fn captureScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) - seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// SEE of a QUIET (non-capture) move from the mover's point of view: 0 if the
/// destination is safe, negative if the piece walks into a losing exchange there.
/// Mirrors `captureScore` but with no captured victim -- the opponent initiates
/// the exchange on `mv.to`. Used for SEE-based quiet pruning of late moves.
pub fn quietScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return -seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn seeGain(pos: *const position.Position, start_occupied: bitboard.Bitboard, side: types.Color, target: square.Square, victim_value: i32) i32 {
    var gains: [32]i32 = undefined;
    var ply: usize = 0;
    var attacker_side = side;
    var next_victim_value = victim_value;
    var occupied = start_occupied;

    while (true) {
        const attacker = leastValuableAttacker(pos, occupied, attacker_side, target) orelse break;
        gains[ply] = next_victim_value;
        ply += 1;
        occupied &= ~bitboard.bit(attacker.from);
        next_victim_value = piece_values.value(attacker.piece_type);
        attacker_side = attacker_side.other();
    }

    var gain: i32 = 0;
    while (ply > 0) {
        ply -= 1;
        gain = @max(@as(i32, 0), gains[ply] - gain);
    }
    return gain;
}

fn leastValuableAttacker(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square) ?Attacker {
    const row = pos.pieceRow(side);

    var candidates = row[pieceTypeIndex(.pawn)] & occupied & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = row[pieceTypeIndex(.knight)] & occupied & attacks.knightAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.bishop)] & occupied & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.rook)] & occupied & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = row[pieceTypeIndex(.queen)] & occupied & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = row[pieceTypeIndex(.king)] & occupied & attacks.kingAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .king };

    return null;
}

fn pawnAttackers(side: types.Color, target: square.Square) bitboard.Bitboard {
    return switch (side) {
        .white => attacks.BLACK_PAWN_ATTACKS[target.index()],
        .black => attacks.WHITE_PAWN_ATTACKS[target.index()],
    };
}

fn pieceTypeIndex(piece_type: piece.PieceType) usize {
    return @intFromEnum(piece_type);
}

test "see scores an undefended queen capture positively" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("4k3/8/8/4q3/2N5/8/8/4K3 w - - 0 1");
    const mv = move_mod.Move.init(.c4, .e5, .capture);

    try @import("std").testing.expect(captureScore(&pos, mv) > 0);
}

test "see scores a bad queen takes pawn capture negatively" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("4k3/8/8/3p4/4Q3/3r4/8/4K3 w - - 0 1");
    const mv = move_mod.Move.init(.e4, .d5, .capture);

    try @import("std").testing.expect(captureScore(&pos, mv) < 0);
}

// ---------------------------------------------------------------------------
// Independent reference (tests only). Deliberately keeps the ORIGINAL
// materialised-state formulation — a private copy of the piece bitboards with
// real bit removals and a recursive swap — so it validates the occupancy-mask
// equivalence argument above from the outside instead of restating it.
// ---------------------------------------------------------------------------

const RefState = struct {
    pieces: [2][6]bitboard.Bitboard,
    occupied: bitboard.Bitboard,

    fn fromPosition(pos: *const position.Position) RefState {
        return .{ .pieces = pos.pieces, .occupied = pos.occupied };
    }

    fn removePieceByType(self: *RefState, side: types.Color, piece_type: piece.PieceType, sq: square.Square) void {
        self.pieces[@intFromEnum(side)][pieceTypeIndex(piece_type)] &= ~bitboard.bit(sq);
        self.occupied &= ~bitboard.bit(sq);
    }

    fn removePiece(self: *RefState, p: piece.Piece, sq: square.Square) void {
        self.removePieceByType(p.color().?, p.pieceType(), sq);
    }
};

fn leastValuableAttackerReference(state: *const RefState, side: types.Color, target: square.Square) ?Attacker {
    const ci = @intFromEnum(side);

    var candidates = state.pieces[ci][pieceTypeIndex(.pawn)] & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = state.pieces[ci][pieceTypeIndex(.knight)] & attacks.knightAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacksOnTheFly(target, state.occupied);
    candidates = state.pieces[ci][pieceTypeIndex(.bishop)] & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacksOnTheFly(target, state.occupied);
    candidates = state.pieces[ci][pieceTypeIndex(.rook)] & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = state.pieces[ci][pieceTypeIndex(.queen)] & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = state.pieces[ci][pieceTypeIndex(.king)] & attacks.kingAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .king };

    return null;
}

fn captureScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    var state = RefState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.pieces[@intFromEnum(pos.side_to_move.other())][pieceTypeIndex(captured_piece.pieceType())] &= ~bitboard.bit(mv.to);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) - seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn quietScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    var state = RefState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return -seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn seeGainReference(state: RefState, side: types.Color, target: square.Square, victim_value: i32) i32 {
    const attacker = leastValuableAttackerReference(&state, side, target) orelse return 0;

    var next = state;
    next.removePiece(piece.Piece.make(side, attacker.piece_type), attacker.from);

    const gain = victim_value - seeGainReference(next, side.other(), target, piece_values.value(attacker.piece_type));
    return @max(@as(i32, 0), gain);
}

const DIFFERENTIAL_FENS = [_][]const u8{
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R b KQkq - 0 1",
    "4k3/8/8/3p4/4Q3/3r4/8/4K3 w - - 0 1",
    "4k3/8/3n4/4P3/8/8/8/4K3 w - - 0 1",
    "4k3/P7/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "2r3k1/5ppp/p3p3/1p6/3P4/P3P1P1/1P3P1P/2R3K1 w - - 0 1",
    "8/5pk1/6p1/8/5PK1/6P1/8/3r3R w - - 0 1",
    "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
    // Battery / x-ray dense: queen behind rook behind rook, bishops stacked.
    "3r2k1/3r4/3q4/8/3P4/3R4/3R4/3QK3 w - - 0 1",
    "6k1/8/2b5/3b4/4P3/5B2/6B1/6K1 w - - 0 1",
    // King-as-attacker endgames (the ONLY case where an aligned non-slider is
    // removed mid-swap, so it exercises the x-ray edge of the argument).
    "8/8/4k3/3p4/4K3/8/8/8 w - - 0 1",
    "8/8/3rk3/3p4/3RK3/3R4/8/8 w - - 0 1",
};

fn expectSeeMatchesReference(pos: *position.Position) !usize {
    const legal = @import("../movegen/legal.zig");
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        try @import("std").testing.expectEqual(captureScoreReference(pos, mv), captureScore(pos, mv));
        try @import("std").testing.expectEqual(quietScoreReference(pos, mv), quietScore(pos, mv));
    }
    return moves.count;
}

test "iterative see matches recursive reference on legal captures AND quiets" {
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");

    var checked: usize = 0;
    for (DIFFERENTIAL_FENS) |fen_text| {
        var root = try fen.parse(fen_text);
        checked += try expectSeeMatchesReference(&root);
        // One ply deep as well: multiplies the occupancy/x-ray shapes seen by
        // both implementations by ~30x for a few ms of test time.
        var root_moves = move_mod.MoveList.init();
        legal.generate(&root, &root_moves);
        for (root_moves.slice()) |mv| {
            var child = legal.playMoveCopy(&root, mv);
            checked += try expectSeeMatchesReference(&child);
        }
    }
    try @import("std").testing.expect(checked > 10_000);
}
