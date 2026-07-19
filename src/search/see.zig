const attacks = @import("../movegen/attacks.zig");
const bitboard = @import("../core/bitboard.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const piece_values = @import("../core/piece_values.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

const AttackState = struct {
    pieces: [2][6]bitboard.Bitboard,
    occupied: bitboard.Bitboard,

    fn fromPosition(pos: *const position.Position) AttackState {
        return .{
            .pieces = pos.pieces,
            .occupied = pos.occupied,
        };
    }

    inline fn removePiece(self: *AttackState, p: piece.Piece, sq: square.Square) void {
        self.removePieceByType(p.color().?, p.pieceType(), sq);
    }

    inline fn removePieceByType(self: *AttackState, side: types.Color, piece_type: piece.PieceType, sq: square.Square) void {
        self.pieces[@intFromEnum(side)][pieceTypeIndex(piece_type)] &= ~bitboard.bit(sq);
        self.occupied &= ~bitboard.bit(sq);
    }
};

const Attacker = struct {
    from: square.Square,
    piece_type: piece.PieceType,
};

pub fn captureScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    var state = AttackState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.removePieceByType(pos.side_to_move.other(), captured_piece.pieceType(), mv.to);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) - seeGain(&state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// SEE of a QUIET (non-capture) move from the mover's point of view: 0 if the
/// destination is safe, negative if the piece walks into a losing exchange there.
/// Mirrors `captureScore` but with no captured victim -- the opponent initiates
/// the exchange on `mv.to`. Used for SEE-based quiet pruning of late moves.
pub fn quietScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    var state = AttackState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return -seeGain(&state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn seeGain(state: *AttackState, side: types.Color, target: square.Square, victim_value: i32) i32 {
    var gains: [32]i32 = undefined;
    var ply: usize = 0;
    var attacker_side = side;
    var next_victim_value = victim_value;

    while (true) {
        const attacker = leastValuableAttacker(state, attacker_side, target) orelse break;
        gains[ply] = next_victim_value;
        ply += 1;
        state.removePieceByType(attacker_side, attacker.piece_type, attacker.from);
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

fn leastValuableAttacker(state: *const AttackState, side: types.Color, target: square.Square) ?Attacker {
    const color_index = @intFromEnum(side);

    var candidates = state.pieces[color_index][pieceTypeIndex(.pawn)] & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = state.pieces[color_index][pieceTypeIndex(.knight)] & attacks.knightAttacks(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacks(target, state.occupied);
    candidates = state.pieces[color_index][pieceTypeIndex(.bishop)] & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacks(target, state.occupied);
    candidates = state.pieces[color_index][pieceTypeIndex(.rook)] & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = state.pieces[color_index][pieceTypeIndex(.queen)] & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = state.pieces[color_index][pieceTypeIndex(.king)] & attacks.kingAttacks(target);
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

fn captureScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    var state = AttackState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.pieces[@intFromEnum(pos.side_to_move.other())][pieceTypeIndex(captured_piece.pieceType())] &= ~bitboard.bit(mv.to);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) - seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn seeGainReference(state: AttackState, side: types.Color, target: square.Square, victim_value: i32) i32 {
    const attacker = leastValuableAttacker(&state, side, target) orelse return 0;

    var next = state;
    next.removePiece(piece.Piece.make(side, attacker.piece_type), attacker.from);

    const gain = victim_value - seeGainReference(next, side.other(), target, piece_values.value(attacker.piece_type));
    return @max(@as(i32, 0), gain);
}

test "iterative see matches recursive reference on representative legal captures" {
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");

    const fens = [_][]const u8{
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "4k3/8/8/3p4/4Q3/3r4/8/4K3 w - - 0 1",
        "4k3/8/3n4/4P3/8/8/8/4K3 w - - 0 1",
        "4k3/P7/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    };

    for (fens) |fen_text| {
        var pos = try fen.parse(fen_text);
        var moves = move_mod.MoveList.init();
        legal.generate(&pos, &moves);
        for (moves.slice()) |mv| {
            if (!mv.isCapture()) continue;
            try @import("std").testing.expectEqual(captureScoreReference(&pos, mv), captureScore(&pos, mv));
        }
    }
}
