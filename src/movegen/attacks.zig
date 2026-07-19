const std = @import("std");
const bitboard = @import("../core/bitboard.zig");
const magics = @import("magics.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

pub const KNIGHT_ATTACKS = initKnightAttacks();
pub const KING_ATTACKS = initKingAttacks();
pub const WHITE_PAWN_ATTACKS = initPawnAttacks(.white);
pub const BLACK_PAWN_ATTACKS = initPawnAttacks(.black);
pub const BISHOP_RAYS = initBishopRays();
pub const ROOK_RAYS = initRookRays();

const FILE_A: bitboard.Bitboard = 0x0101_0101_0101_0101;
const FILE_H: bitboard.Bitboard = 0x8080_8080_8080_8080;
const NOT_FILE_A: bitboard.Bitboard = ~FILE_A;
const NOT_FILE_H: bitboard.Bitboard = ~FILE_H;

pub fn knightAttacks(sq: square.Square) bitboard.Bitboard {
    return KNIGHT_ATTACKS[sq.index()];
}

pub fn kingAttacks(sq: square.Square) bitboard.Bitboard {
    return KING_ATTACKS[sq.index()];
}

pub fn pawnAttacksFrom(color: types.Color, sq: square.Square) bitboard.Bitboard {
    return switch (color) {
        .white => WHITE_PAWN_ATTACKS[sq.index()],
        .black => BLACK_PAWN_ATTACKS[sq.index()],
    };
}

/// Set-wise pawn attacks for a whole pawn bitboard (two shifts, no per-square loop).
pub fn pawnAttacks(color: types.Color, pawns: bitboard.Bitboard) bitboard.Bitboard {
    return switch (color) {
        .white => ((pawns & NOT_FILE_A) << 7) | ((pawns & NOT_FILE_H) << 9),
        .black => ((pawns & NOT_FILE_A) >> 9) | ((pawns & NOT_FILE_H) >> 7),
    };
}

/// Magic-bitboard lookup (movegen/magics.zig).
pub fn bishopAttacks(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    return magics.bishopAttacks(sq, occupied);
}

/// Magic-bitboard lookup (movegen/magics.zig).
pub fn rookAttacks(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    return magics.rookAttacks(sq, occupied);
}

pub fn queenAttacks(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    return bishopAttacks(sq, occupied) | rookAttacks(sq, occupied);
}

pub fn attackedSquares(pos: *const position.Position, by: types.Color) bitboard.Bitboard {
    const occupied = pos.occupancy();
    var attacked: bitboard.Bitboard = 0;

    attacked |= pawnAttacks(by, pos.pieceBitboard(by, .pawn));

    var knights = pos.pieceBitboard(by, .knight);
    while (bitboard.popLsb(&knights)) |sq| attacked |= knightAttacks(sq);

    var bishops = pos.pieceBitboard(by, .bishop);
    while (bitboard.popLsb(&bishops)) |sq| attacked |= bishopAttacks(sq, occupied);

    var rooks = pos.pieceBitboard(by, .rook);
    while (bitboard.popLsb(&rooks)) |sq| attacked |= rookAttacks(sq, occupied);

    var queens = pos.pieceBitboard(by, .queen);
    while (bitboard.popLsb(&queens)) |sq| attacked |= queenAttacks(sq, occupied);

    var kings = pos.pieceBitboard(by, .king);
    while (bitboard.popLsb(&kings)) |sq| attacked |= kingAttacks(sq);

    return attacked;
}

pub inline fn isSquareAttackedByBitboards(
    target: square.Square,
    by: types.Color,
    occupied: bitboard.Bitboard,
    pawns: bitboard.Bitboard,
    knights: bitboard.Bitboard,
    bishops: bitboard.Bitboard,
    rooks: bitboard.Bitboard,
    queens: bitboard.Bitboard,
    king: bitboard.Bitboard,
) bool {
    const target_index = target.index();
    const pawn_attackers = switch (by) {
        .white => BLACK_PAWN_ATTACKS[target_index],
        .black => WHITE_PAWN_ATTACKS[target_index],
    };
    if ((pawns & pawn_attackers) != 0) return true;
    if ((knights & KNIGHT_ATTACKS[target_index]) != 0) return true;
    if ((king & KING_ATTACKS[target_index]) != 0) return true;

    const bishop_like = bishops | queens;
    if ((bishop_like & BISHOP_RAYS[target_index]) != 0 and (bishop_like & bishopAttacks(target, occupied)) != 0) return true;

    const rook_like = rooks | queens;
    if ((rook_like & ROOK_RAYS[target_index]) != 0 and (rook_like & rookAttacks(target, occupied)) != 0) return true;

    return false;
}

pub inline fn isSquareAttacked(pos: *const position.Position, target: square.Square, by: types.Color) bool {
    return isSquareAttackedByBitboards(
        target,
        by,
        pos.occupancy(),
        pos.pieceBitboard(by, .pawn),
        pos.pieceBitboard(by, .knight),
        pos.pieceBitboard(by, .bishop),
        pos.pieceBitboard(by, .rook),
        pos.pieceBitboard(by, .queen),
        pos.pieceBitboard(by, .king),
    );
}

pub inline fn isInCheck(pos: *const position.Position, color: types.Color) bool {
    const king_sq = pos.kingSquare(color) orelse return false;
    const by = color.other();
    const by_pieces = &pos.pieces[@intFromEnum(by)];
    return isSquareAttackedByBitboards(
        king_sq,
        by,
        pos.occupied,
        by_pieces[@intFromEnum(piece.PieceType.pawn)],
        by_pieces[@intFromEnum(piece.PieceType.knight)],
        by_pieces[@intFromEnum(piece.PieceType.bishop)],
        by_pieces[@intFromEnum(piece.PieceType.rook)],
        by_pieces[@intFromEnum(piece.PieceType.queen)],
        by_pieces[@intFromEnum(piece.PieceType.king)],
    );
}

fn initKnightAttacks() [64]bitboard.Bitboard {
    const deltas = [_][2]i8{
        .{ 1, 2 },   .{ 2, 1 },   .{ 2, -1 }, .{ 1, -2 },
        .{ -1, -2 }, .{ -2, -1 }, .{ -2, 1 }, .{ -1, 2 },
    };
    return initLeaperAttacks(deltas);
}

fn initKingAttacks() [64]bitboard.Bitboard {
    const deltas = [_][2]i8{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },  .{ 1, 0 },  .{ -1, 1 },
        .{ 0, 1 },   .{ 1, 1 },
    };
    return initLeaperAttacks(deltas);
}

fn initPawnAttacks(color: types.Color) [64]bitboard.Bitboard {
    @setEvalBranchQuota(10_000);
    var table = [_]bitboard.Bitboard{0} ** 64;
    const rank_delta: i8 = if (color == .white) 1 else -1;
    const file_deltas = [_]i8{ -1, 1 };

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        const file: i8 = @intCast(sq.file());
        const rank: i8 = @intCast(sq.rank());
        var attacks: bitboard.Bitboard = 0;
        inline for (file_deltas) |file_delta| {
            const new_file = file + file_delta;
            const new_rank = rank + rank_delta;
            if (!isOnBoard(new_file, new_rank)) continue;
            const target = square.Square.fromCoords(@intCast(new_file), @intCast(new_rank));
            attacks |= bitboard.bit(target);
        }
        table[idx] = attacks;
    }

    return table;
}

fn initBishopRays() [64]bitboard.Bitboard {
    @setEvalBranchQuota(10_000);
    var table = [_]bitboard.Bitboard{0} ** 64;
    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        table[idx] = rayAttacksReference(sq, 0, 1, 1) |
            rayAttacksReference(sq, 0, 1, -1) |
            rayAttacksReference(sq, 0, -1, 1) |
            rayAttacksReference(sq, 0, -1, -1);
    }
    return table;
}

fn initRookRays() [64]bitboard.Bitboard {
    @setEvalBranchQuota(10_000);
    var table = [_]bitboard.Bitboard{0} ** 64;
    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        table[idx] = rayAttacksReference(sq, 0, 1, 0) |
            rayAttacksReference(sq, 0, -1, 0) |
            rayAttacksReference(sq, 0, 0, 1) |
            rayAttacksReference(sq, 0, 0, -1);
    }
    return table;
}

fn initLeaperAttacks(comptime deltas: anytype) [64]bitboard.Bitboard {
    @setEvalBranchQuota(10_000);
    var table = [_]bitboard.Bitboard{0} ** 64;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        const file: i8 = @intCast(sq.file());
        const rank: i8 = @intCast(sq.rank());
        var attacks: bitboard.Bitboard = 0;

        inline for (deltas) |delta| {
            const new_file = file + delta[0];
            const new_rank = rank + delta[1];
            if (!isOnBoard(new_file, new_rank)) continue;
            const target = square.Square.fromCoords(@intCast(new_file), @intCast(new_rank));
            attacks |= bitboard.bit(target);
        }

        table[idx] = attacks;
    }

    return table;
}

fn rayAttacksReference(sq: square.Square, occupied: bitboard.Bitboard, file_delta: i8, rank_delta: i8) bitboard.Bitboard {
    var file: i8 = @intCast(sq.file());
    var rank: i8 = @intCast(sq.rank());
    var attacks: bitboard.Bitboard = 0;

    while (true) {
        file += file_delta;
        rank += rank_delta;
        if (!isOnBoard(file, rank)) break;

        const target = square.Square.fromCoords(@intCast(file), @intCast(rank));
        const mask = bitboard.bit(target);
        attacks |= mask;
        if ((occupied & mask) != 0) break;
    }

    return attacks;
}

fn isOnBoard(file: i8, rank: i8) bool {
    return file >= 0 and file < 8 and rank >= 0 and rank < 8;
}

fn squaresMask(comptime squares: []const square.Square) bitboard.Bitboard {
    var mask: bitboard.Bitboard = 0;
    inline for (squares) |sq| mask |= bitboard.bit(sq);
    return mask;
}

test "knight attacks from corner match expected mask" {
    const expected = squaresMask(&.{ .b3, .c2 });
    try std.testing.expectEqual(expected, knightAttacks(.a1));
}

test "king attacks from center match expected mask" {
    const expected = squaresMask(&.{ .d3, .e3, .f3, .d4, .f4, .d5, .e5, .f5 });
    try std.testing.expectEqual(expected, kingAttacks(.e4));
}

test "pawn attacks depend on side" {
    try std.testing.expectEqual(squaresMask(&.{ .d5, .f5 }), pawnAttacksFrom(.white, .e4));
    try std.testing.expectEqual(squaresMask(&.{ .d4, .f4 }), pawnAttacksFrom(.black, .e5));
}

test "pawn attack bitboard unions per-pawn attacks" {
    var white_pawns: bitboard.Bitboard = 0;
    white_pawns |= bitboard.bit(.a2);
    white_pawns |= bitboard.bit(.e4);
    try std.testing.expectEqual(squaresMask(&.{ .b3, .d5, .f5 }), pawnAttacks(.white, white_pawns));

    var black_pawns: bitboard.Bitboard = 0;
    black_pawns |= bitboard.bit(.h7);
    black_pawns |= bitboard.bit(.e5);
    try std.testing.expectEqual(squaresMask(&.{ .g6, .d4, .f4 }), pawnAttacks(.black, black_pawns));
}

test "bishop attacks stop at blockers and include capture square" {
    var occupied: bitboard.Bitboard = 0;
    occupied |= bitboard.bit(.f6);
    occupied |= bitboard.bit(.b2);

    const expected = squaresMask(&.{ .e5, .f6, .c5, .b6, .a7, .e3, .f2, .g1, .c3, .b2 });
    try std.testing.expectEqual(expected, bishopAttacks(.d4, occupied));
}

test "rook attacks stop at blockers and include capture square" {
    var occupied: bitboard.Bitboard = 0;
    occupied |= bitboard.bit(.d6);
    occupied |= bitboard.bit(.f4);
    occupied |= bitboard.bit(.d2);

    const expected = squaresMask(&.{ .d5, .d6, .e4, .f4, .c4, .b4, .a4, .d3, .d2 });
    try std.testing.expectEqual(expected, rookAttacks(.d4, occupied));
}

test "attacked squares map matches per-square attack detection" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    const white_attacks = attackedSquares(&pos, .white);
    const black_attacks = attackedSquares(&pos, .black);

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        try std.testing.expectEqual(isSquareAttacked(&pos, sq, .white), bitboard.contains(white_attacks, sq));
        try std.testing.expectEqual(isSquareAttacked(&pos, sq, .black), bitboard.contains(black_attacks, sq));
    }
}

test "magic sliding attacks match step reference" {
    var seed: u64 = 0x9e37_79b9_7f4a_7c15;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        var occupied: bitboard.Bitboard = 0;
        var sample: usize = 0;
        while (sample < 64) : (sample += 1) {
            seed ^= seed << 7;
            seed ^= seed >> 9;
            seed ^= seed << 8;
            occupied = seed;

            try std.testing.expectEqual(
                rayAttacksReference(sq, occupied, 1, 1) |
                    rayAttacksReference(sq, occupied, -1, 1) |
                    rayAttacksReference(sq, occupied, 1, -1) |
                    rayAttacksReference(sq, occupied, -1, -1),
                bishopAttacks(sq, occupied),
            );
            try std.testing.expectEqual(
                rayAttacksReference(sq, occupied, 1, 0) |
                    rayAttacksReference(sq, occupied, -1, 0) |
                    rayAttacksReference(sq, occupied, 0, 1) |
                    rayAttacksReference(sq, occupied, 0, -1),
                rookAttacks(sq, occupied),
            );
        }
    }
}
