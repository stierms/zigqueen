const std = @import("std");
const bitboard = @import("bitboard.zig");
const piece = @import("piece.zig");
const square = @import("square.zig");
const types = @import("types.zig");

const PIECE_TYPE_COUNT: usize = 6;

pub const CastlingRights = packed struct(u4) {
    white_king_side: bool = false,
    white_queen_side: bool = false,
    black_king_side: bool = false,
    black_queen_side: bool = false,

    pub inline fn hasAny(self: CastlingRights) bool {
        return self.white_king_side or self.white_queen_side or self.black_king_side or self.black_queen_side;
    }
};

pub const Position = struct {
    pieces: [2][PIECE_TYPE_COUNT]bitboard.Bitboard = .{
        [_]bitboard.Bitboard{0} ** PIECE_TYPE_COUNT,
        [_]bitboard.Bitboard{0} ** PIECE_TYPE_COUNT,
    },
    occupancies: [2]bitboard.Bitboard = [_]bitboard.Bitboard{0} ** 2,
    king_squares: [2]?square.Square = .{ null, null },
    occupied: bitboard.Bitboard = 0,
    mailbox: [64]piece.Piece = [_]piece.Piece{.none} ** 64,
    side_to_move: types.Color = .white,
    castling_rights: CastlingRights = .{},
    en_passant: ?square.Square = null,
    halfmove_clock: u16 = 0,
    fullmove_number: u16 = 1,
    zobrist_key: u64 = 0,

    pub fn empty() Position {
        return .{};
    }

    // NOTE on the element-pointer style below: `self.pieces[i][j]` with a
    // runtime color index materialises a full 128-byte stack copy of the
    // pieces array per call (LLVM lowers the runtime index on the array VALUE,
    // and the following load stalls on failed store-to-load forwarding). Same
    // defect class as HistoryTable.score's row copy; `&arr[i]` forces in-place
    // addressing. Seen live in endgame profiles: hasNonPawnMaterial ~2% /
    // kingSquare ~5% of cycles.

    pub inline fn pieceRow(self: *const Position, color: types.Color) *const [PIECE_TYPE_COUNT]bitboard.Bitboard {
        return &self.pieces[colorIndex(color)];
    }

    pub inline fn pieceBitboard(self: *const Position, color: types.Color, piece_type: piece.PieceType) bitboard.Bitboard {
        const row = self.pieceRow(color);
        return row[pieceTypeIndex(piece_type)];
    }

    pub inline fn occupancyFor(self: *const Position, color: types.Color) bitboard.Bitboard {
        const slot: *const bitboard.Bitboard = &self.occupancies[colorIndex(color)];
        return slot.*;
    }

    pub inline fn occupancy(self: *const Position) bitboard.Bitboard {
        return self.occupied;
    }

    pub inline fn pieceAt(self: *const Position, sq: square.Square) piece.Piece {
        const mailbox = &self.mailbox;
        return mailbox[sq.index()];
    }

    pub inline fn isSquareOccupied(self: *const Position, sq: square.Square) bool {
        return bitboard.contains(self.occupied, sq);
    }

    pub fn clearSquare(self: *Position, sq: square.Square) piece.Piece {
        const existing = self.pieceAt(sq);
        if (existing == .none) return .none;

        const color = existing.color().?;
        const piece_type = existing.pieceType();
        const mask = bitboard.bit(sq);
        const ci = colorIndex(color);
        const pti = pieceTypeIndex(piece_type);

        self.pieces[ci][pti] &= ~mask;
        self.occupancies[ci] &= ~mask;
        self.occupied &= ~mask;
        self.mailbox[sq.index()] = .none;
        if (piece_type == .king) self.king_squares[ci] = null;
        return existing;
    }

    pub fn setPiece(self: *Position, sq: square.Square, p: piece.Piece) void {
        _ = self.clearSquare(sq);
        self.setPieceOnEmpty(sq, p);
    }

    pub fn setPieceOnEmpty(self: *Position, sq: square.Square, p: piece.Piece) void {
        if (p == .none) return;
        std.debug.assert(self.pieceAt(sq) == .none);

        const color = p.color().?;
        const piece_type = p.pieceType();
        const mask = bitboard.bit(sq);
        const ci = colorIndex(color);
        const pti = pieceTypeIndex(piece_type);

        self.pieces[ci][pti] |= mask;
        self.occupancies[ci] |= mask;
        self.occupied |= mask;
        self.mailbox[sq.index()] = p;
        if (piece_type == .king) self.king_squares[ci] = sq;
    }

    pub inline fn countPieces(self: *const Position, color: types.Color, piece_type: piece.PieceType) u8 {
        return bitboard.popCount(self.pieceBitboard(color, piece_type));
    }

    pub inline fn kingSquare(self: *const Position, color: types.Color) ?square.Square {
        // Element pointer for the same reason as pieceRow: the [2]?Square copy
        // + tag re-read through the stack was 69% of isInCheck's self time.
        const slot: *const ?square.Square = &self.king_squares[colorIndex(color)];
        return slot.*;
    }

    pub fn eql(a: *const Position, b: *const Position) bool {
        return std.mem.eql(u64, &a.pieces[0], &b.pieces[0]) and
            std.mem.eql(u64, &a.pieces[1], &b.pieces[1]) and
            std.mem.eql(u64, &a.occupancies, &b.occupancies) and
            a.king_squares[0] == b.king_squares[0] and
            a.king_squares[1] == b.king_squares[1] and
            a.occupied == b.occupied and
            std.mem.eql(piece.Piece, &a.mailbox, &b.mailbox) and
            a.side_to_move == b.side_to_move and
            a.castling_rights.white_king_side == b.castling_rights.white_king_side and
            a.castling_rights.white_queen_side == b.castling_rights.white_queen_side and
            a.castling_rights.black_king_side == b.castling_rights.black_king_side and
            a.castling_rights.black_queen_side == b.castling_rights.black_queen_side and
            a.en_passant == b.en_passant and
            a.halfmove_clock == b.halfmove_clock and
            a.fullmove_number == b.fullmove_number and
            a.zobrist_key == b.zobrist_key;
    }
};

fn colorIndex(color: types.Color) usize {
    return @intFromEnum(color);
}

fn pieceTypeIndex(piece_type: piece.PieceType) usize {
    std.debug.assert(piece_type != .none);
    return @intFromEnum(piece_type);
}

test "position set and clear piece update all caches" {
    var pos = Position.empty();
    pos.setPiece(.e1, .white_king);
    pos.setPiece(.e8, .black_king);
    pos.setPiece(.d4, .white_queen);

    try std.testing.expectEqual(piece.Piece.white_queen, pos.pieceAt(.d4));
    try std.testing.expect(pos.isSquareOccupied(.d4));
    try std.testing.expect(bitboard.contains(pos.occupancyFor(.white), .d4));
    try std.testing.expect(bitboard.contains(pos.occupancy(), .d4));
    try std.testing.expectEqual(@as(u8, 1), pos.countPieces(.white, .queen));

    const removed = pos.clearSquare(.d4);
    try std.testing.expectEqual(piece.Piece.white_queen, removed);
    try std.testing.expectEqual(piece.Piece.none, pos.pieceAt(.d4));
    try std.testing.expect(!pos.isSquareOccupied(.d4));
    try std.testing.expectEqual(@as(u8, 0), pos.countPieces(.white, .queen));
}

test "position kingSquare cache tracks set and clear" {
    var pos = Position.empty();
    pos.setPiece(.b1, .white_king);
    pos.setPiece(.g7, .black_king);

    try std.testing.expectEqual(square.Square.b1, pos.kingSquare(.white).?);
    try std.testing.expectEqual(square.Square.g7, pos.kingSquare(.black).?);

    try std.testing.expectEqual(piece.Piece.white_king, pos.clearSquare(.b1));
    try std.testing.expectEqual(@as(?square.Square, null), pos.kingSquare(.white));
}
