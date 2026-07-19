const std = @import("std");
const attacks = @import("attacks.zig");
const bitboard = @import("../core/bitboard.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

pub fn generate(pos: *const position.Position, list: *move_mod.MoveList) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateFor(.white, pos, list),
        .black => generateFor(.black, pos, list),
    }
}

fn generateFor(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generatePawnMoves(side, pos, list);
    generateKnightMoves(side, pos, list);
    generateBishopMoves(side, pos, list);
    generateRookMoves(side, pos, list);
    generateQueenMoves(side, pos, list);
    generateKingMoves(side, pos, list);
    generateCastlingMoves(side, pos, list);
}

pub fn generateTactical(pos: *const position.Position, list: *move_mod.MoveList) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateTacticalFor(.white, pos, list),
        .black => generateTacticalFor(.black, pos, list),
    }
}

fn generateTacticalFor(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalPawnMoves(side, pos, list);
    generateTacticalKnightMoves(side, pos, list);
    generateTacticalBishopMoves(side, pos, list);
    generateTacticalRookMoves(side, pos, list);
    generateTacticalQueenMoves(side, pos, list);
    generateTacticalKingMoves(side, pos, list);
}

fn generatePawnMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other());
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: u3 = if (side == .white) 1 else 6;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (bitboard.popLsb(&pawns)) |from| {
        const file = from.file();
        const rank = from.rank();

        const one_step_rank_i: i8 = @as(i8, @intCast(rank)) + forward_delta;
        if (one_step_rank_i >= 0 and one_step_rank_i < 8) {
            const one_step = square.Square.fromCoords(file, @intCast(one_step_rank_i));
            if (!pos.isSquareOccupied(one_step)) {
                if (rank == promotion_from_rank) {
                    addPromotions(list, from, one_step, false);
                } else {
                    list.add(move_mod.Move.init(from, one_step, .quiet));
                    if (rank == start_rank) {
                        const two_step_rank_i = one_step_rank_i + forward_delta;
                        if (two_step_rank_i >= 0 and two_step_rank_i < 8) {
                            const two_step = square.Square.fromCoords(file, @intCast(two_step_rank_i));
                            if (!pos.isSquareOccupied(two_step)) {
                                list.add(move_mod.Move.init(from, two_step, .double_push));
                            }
                        }
                    }
                }
            }
        }

        var capture_targets = attacks.pawnAttacksFrom(side, from) & opponent_occ;
        while (bitboard.popLsb(&capture_targets)) |to| {
            if (rank == promotion_from_rank) {
                addPromotions(list, from, to, true);
            } else {
                list.add(move_mod.Move.init(from, to, .capture));
            }
        }

        if (pos.en_passant) |ep_square| {
            const ep_mask = bitboard.bit(ep_square);
            if ((attacks.pawnAttacksFrom(side, from) & ep_mask) != 0) {
                list.add(move_mod.Move.init(from, ep_square, .en_passant));
            }
        }
    }
}

fn generateTacticalPawnMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other());
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (bitboard.popLsb(&pawns)) |from| {
        const file = from.file();
        const rank = from.rank();

        if (rank == promotion_from_rank) {
            const one_step_rank_i: i8 = @as(i8, @intCast(rank)) + forward_delta;
            if (one_step_rank_i >= 0 and one_step_rank_i < 8) {
                const one_step = square.Square.fromCoords(file, @intCast(one_step_rank_i));
                if (!pos.isSquareOccupied(one_step)) addPromotions(list, from, one_step, false);
            }
        }

        var capture_targets = attacks.pawnAttacksFrom(side, from) & opponent_occ;
        while (bitboard.popLsb(&capture_targets)) |to| {
            if (rank == promotion_from_rank) {
                addPromotions(list, from, to, true);
            } else {
                list.add(move_mod.Move.init(from, to, .capture));
            }
        }

        if (pos.en_passant) |ep_square| {
            const ep_mask = bitboard.bit(ep_square);
            if ((attacks.pawnAttacksFrom(side, from) & ep_mask) != 0) {
                list.add(move_mod.Move.init(from, ep_square, .en_passant));
            }
        }
    }
}

fn generateKnightMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateLeaperMoves(side, pos, .knight, attacks.knightAttacks, list);
}

fn generateTacticalKnightMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalLeaperMoves(side, pos, .knight, attacks.knightAttacks, list);
}

/// Pseudo-legal QUIET moves that give DIRECT check to the enemy king. No
/// captures or promotions (generateTactical covers those) and no discovered
/// checks — deliberate under-generation: every move generated IS a check, but
/// a slider stepping along its own existing check-ray can be missed. Safe for
/// qsearch, which only loses a rare extra candidate.
pub fn generateQuietChecks(pos: *const position.Position, list: *move_mod.MoveList) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateQuietChecksFor(.white, pos, list),
        .black => generateQuietChecksFor(.black, pos, list),
    }
}

fn generateQuietChecksFor(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    const enemy = side.other();
    var king_bb = pos.pieceBitboard(enemy, .king);
    const ksq = bitboard.popLsb(&king_bb) orelse return;
    const occ = pos.occupied;
    const empty = ~occ;

    // Squares from which each piece type delivers check under CURRENT occupancy.
    // Filling `to` never blocks its own ray and emptying `from` only opens lines,
    // so every generated move checks; see the doc comment for the rare misses.
    const knight_checks = attacks.knightAttacks(ksq) & empty;
    const bishop_checks = attacks.bishopAttacks(ksq, occ) & empty;
    const rook_checks = attacks.rookAttacks(ksq, occ) & empty;
    const pawn_checks = attacks.pawnAttacksFrom(enemy, ksq) & empty;

    var knights = pos.pieceBitboard(side, .knight);
    while (bitboard.popLsb(&knights)) |from| {
        var targets = attacks.knightAttacks(from) & knight_checks;
        while (bitboard.popLsb(&targets)) |to| list.add(move_mod.Move.init(from, to, .quiet));
    }
    var bishops = pos.pieceBitboard(side, .bishop);
    while (bitboard.popLsb(&bishops)) |from| {
        var targets = attacks.bishopAttacks(from, occ) & bishop_checks;
        while (bitboard.popLsb(&targets)) |to| list.add(move_mod.Move.init(from, to, .quiet));
    }
    var rooks = pos.pieceBitboard(side, .rook);
    while (bitboard.popLsb(&rooks)) |from| {
        var targets = attacks.rookAttacks(from, occ) & rook_checks;
        while (bitboard.popLsb(&targets)) |to| list.add(move_mod.Move.init(from, to, .quiet));
    }
    var queens = pos.pieceBitboard(side, .queen);
    while (bitboard.popLsb(&queens)) |from| {
        const from_attacks = attacks.bishopAttacks(from, occ) | attacks.rookAttacks(from, occ);
        var targets = from_attacks & (bishop_checks | rook_checks);
        while (bitboard.popLsb(&targets)) |to| list.add(move_mod.Move.init(from, to, .quiet));
    }

    // Pawn pushes landing on a checking square. A checking landing square is
    // never on the promotion rank (the king would have to stand off-board), so
    // these are always plain pushes.
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: i8 = if (side == .white) 1 else 6;
    const my_pawns = pos.pieceBitboard(side, .pawn);
    var pawn_targets = pawn_checks;
    while (bitboard.popLsb(&pawn_targets)) |to| {
        const from_rank_i: i8 = @as(i8, @intCast(to.rank())) - forward_delta;
        if (from_rank_i < 0 or from_rank_i > 7) continue;
        const from_sq = square.Square.fromCoords(to.file(), @intCast(from_rank_i));
        if ((my_pawns & bitboard.bit(from_sq)) != 0) {
            list.add(move_mod.Move.init(from_sq, to, .quiet));
            continue;
        }
        const dbl_from_rank_i = from_rank_i - forward_delta;
        if (dbl_from_rank_i == start_rank and !pos.isSquareOccupied(from_sq)) {
            const dbl_from = square.Square.fromCoords(to.file(), @intCast(dbl_from_rank_i));
            if ((my_pawns & bitboard.bit(dbl_from)) != 0) {
                list.add(move_mod.Move.init(dbl_from, to, .double_push));
            }
        }
    }
}

fn generateKingMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateLeaperMoves(side, pos, .king, attacks.kingAttacks, list);
}

fn generateTacticalKingMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalLeaperMoves(side, pos, .king, attacks.kingAttacks, list);
}

fn generateLeaperMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square) bitboard.Bitboard,
    list: *move_mod.MoveList,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const own_occ = pos.occupancyFor(side);
    const opp_occ = pos.occupancyFor(side.other());

    while (bitboard.popLsb(&pieces)) |from| {
        var targets = attack_fn(from) & ~own_occ;
        while (bitboard.popLsb(&targets)) |to| {
            const flag: move_mod.MoveFlag = if ((opp_occ & bitboard.bit(to)) != 0) .capture else .quiet;
            list.add(move_mod.Move.init(from, to, flag));
        }
    }
}

fn generateTacticalLeaperMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square) bitboard.Bitboard,
    list: *move_mod.MoveList,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const opp_occ = pos.occupancyFor(side.other());

    while (bitboard.popLsb(&pieces)) |from| {
        var targets = attack_fn(from) & opp_occ;
        while (bitboard.popLsb(&targets)) |to| {
            list.add(move_mod.Move.init(from, to, .capture));
        }
    }
}

fn generateBishopMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateSliderMoves(side, pos, .bishop, attacks.bishopAttacks, list);
}

fn generateTacticalBishopMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalSliderMoves(side, pos, .bishop, attacks.bishopAttacks, list);
}

fn generateRookMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateSliderMoves(side, pos, .rook, attacks.rookAttacks, list);
}

fn generateTacticalRookMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalSliderMoves(side, pos, .rook, attacks.rookAttacks, list);
}

fn generateQueenMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateSliderMoves(side, pos, .queen, attacks.queenAttacks, list);
}

fn generateTacticalQueenMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalSliderMoves(side, pos, .queen, attacks.queenAttacks, list);
}

fn generateSliderMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square, bitboard.Bitboard) bitboard.Bitboard,
    list: *move_mod.MoveList,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const own_occ = pos.occupancyFor(side);
    const opp_occ = pos.occupancyFor(side.other());
    const occupied = pos.occupancy();

    while (bitboard.popLsb(&pieces)) |from| {
        var targets = attack_fn(from, occupied) & ~own_occ;
        while (bitboard.popLsb(&targets)) |to| {
            const flag: move_mod.MoveFlag = if ((opp_occ & bitboard.bit(to)) != 0) .capture else .quiet;
            list.add(move_mod.Move.init(from, to, flag));
        }
    }
}

fn generateTacticalSliderMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square, bitboard.Bitboard) bitboard.Bitboard,
    list: *move_mod.MoveList,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const opp_occ = pos.occupancyFor(side.other());
    const occupied = pos.occupancy();

    while (bitboard.popLsb(&pieces)) |from| {
        var targets = attack_fn(from, occupied) & opp_occ;
        while (bitboard.popLsb(&targets)) |to| {
            list.add(move_mod.Move.init(from, to, .capture));
        }
    }
}

fn generateCastlingMoves(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    if (side == .white) {
        if (pos.pieceAt(.e1) == .white_king and !attacks.isInCheck(pos, .white)) {
            if (pos.castling_rights.white_king_side and
                pos.pieceAt(.h1) == .white_rook and
                !pos.isSquareOccupied(.f1) and
                !pos.isSquareOccupied(.g1) and
                !attacks.isSquareAttacked(pos, .f1, .black) and
                !attacks.isSquareAttacked(pos, .g1, .black))
            {
                list.add(move_mod.Move.init(.e1, .g1, .castle));
            }
            if (pos.castling_rights.white_queen_side and
                pos.pieceAt(.a1) == .white_rook and
                !pos.isSquareOccupied(.b1) and
                !pos.isSquareOccupied(.c1) and
                !pos.isSquareOccupied(.d1) and
                !attacks.isSquareAttacked(pos, .d1, .black) and
                !attacks.isSquareAttacked(pos, .c1, .black))
            {
                list.add(move_mod.Move.init(.e1, .c1, .castle));
            }
        }
    } else {
        if (pos.pieceAt(.e8) == .black_king and !attacks.isInCheck(pos, .black)) {
            if (pos.castling_rights.black_king_side and
                pos.pieceAt(.h8) == .black_rook and
                !pos.isSquareOccupied(.f8) and
                !pos.isSquareOccupied(.g8) and
                !attacks.isSquareAttacked(pos, .f8, .white) and
                !attacks.isSquareAttacked(pos, .g8, .white))
            {
                list.add(move_mod.Move.init(.e8, .g8, .castle));
            }
            if (pos.castling_rights.black_queen_side and
                pos.pieceAt(.a8) == .black_rook and
                !pos.isSquareOccupied(.b8) and
                !pos.isSquareOccupied(.c8) and
                !pos.isSquareOccupied(.d8) and
                !attacks.isSquareAttacked(pos, .d8, .white) and
                !attacks.isSquareAttacked(pos, .c8, .white))
            {
                list.add(move_mod.Move.init(.e8, .c8, .castle));
            }
        }
    }
}

fn addPromotions(list: *move_mod.MoveList, from: square.Square, to: square.Square, is_capture: bool) void {
    const flags = if (is_capture)
        [_]move_mod.MoveFlag{ .promo_knight_capture, .promo_bishop_capture, .promo_rook_capture, .promo_queen_capture }
    else
        [_]move_mod.MoveFlag{ .promo_knight, .promo_bishop, .promo_rook, .promo_queen };

    inline for (flags) |flag| list.add(move_mod.Move.init(from, to, flag));
}

test "start position has 20 pseudo legal moves" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.startpos();
    var list = move_mod.MoveList.init();
    generate(&pos, &list);
    try std.testing.expectEqual(@as(usize, 20), list.count);
}

test "pseudo legal generator includes promotion choices" {
    var pos = position.Position.empty();
    pos.setPiece(.e1, .white_king);
    pos.setPiece(.e8, .black_king);
    pos.setPiece(.a7, .white_pawn);
    pos.side_to_move = .white;

    var list = move_mod.MoveList.init();
    generate(&pos, &list);

    var promotions: usize = 0;
    for (list.slice()) |mv| {
        if (mv.from == .a7 and mv.to == .a8 and mv.isPromotion()) promotions += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), promotions);
}

test "pseudo legal generator includes castling when path is clear and safe" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    var list = move_mod.MoveList.init();
    generate(&pos, &list);

    var found_short = false;
    var found_long = false;
    for (list.slice()) |mv| {
        if (mv.from == .e1 and mv.to == .g1 and mv.flag == .castle) found_short = true;
        if (mv.from == .e1 and mv.to == .c1 and mv.flag == .castle) found_long = true;
    }
    try std.testing.expect(found_short);
    try std.testing.expect(found_long);
}

test "tactical pseudo legal generator keeps captures and promotions only" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("4k3/P7/8/3pP3/8/8/8/4K3 w - d6 0 1");
    var list = move_mod.MoveList.init();
    generateTactical(&pos, &list);

    var found_quiet_promotion = false;
    var found_en_passant = false;
    for (list.slice()) |mv| {
        try std.testing.expect(mv.isCapture() or mv.isPromotion());
        if (mv.from == .a7 and mv.to == .a8 and mv.flag == .promo_queen) found_quiet_promotion = true;
        if (mv.from == .e5 and mv.to == .d6 and mv.flag == .en_passant) found_en_passant = true;
    }
    try std.testing.expect(found_quiet_promotion);
    try std.testing.expect(found_en_passant);
}
