const std = @import("std");
const types = @import("types.zig");

pub const ParsePieceError = error{InvalidPiece};

pub const PieceType = enum(u3) {
    pawn = 0,
    knight = 1,
    bishop = 2,
    rook = 3,
    queen = 4,
    king = 5,
    none = 6,
};

pub const Piece = enum(u8) {
    white_pawn = 0,
    white_knight = 1,
    white_bishop = 2,
    white_rook = 3,
    white_queen = 4,
    white_king = 5,
    black_pawn = 6,
    black_knight = 7,
    black_bishop = 8,
    black_rook = 9,
    black_queen = 10,
    black_king = 11,
    none = 12,

    const MAKE_TABLE = [_][7]Piece{
        .{ .white_pawn, .white_knight, .white_bishop, .white_rook, .white_queen, .white_king, .none },
        .{ .black_pawn, .black_knight, .black_bishop, .black_rook, .black_queen, .black_king, .none },
    };

    pub inline fn make(side: types.Color, piece_type: PieceType) Piece {
        return MAKE_TABLE[@intFromEnum(side)][@intFromEnum(piece_type)];
    }

    const COLORS = [_]?types.Color{
        .white, .white, .white, .white, .white, .white,
        .black, .black, .black, .black, .black, .black,
        null,
    };

    const PIECE_TYPES = [_]PieceType{
        .pawn, .knight, .bishop, .rook, .queen, .king,
        .pawn, .knight, .bishop, .rook, .queen, .king,
        .none,
    };

    pub inline fn color(self: Piece) ?types.Color {
        return COLORS[@intFromEnum(self)];
    }

    pub inline fn pieceType(self: Piece) PieceType {
        return PIECE_TYPES[@intFromEnum(self)];
    }

    pub fn fromFenChar(ch: u8) ParsePieceError!Piece {
        return switch (ch) {
            'P' => .white_pawn,
            'N' => .white_knight,
            'B' => .white_bishop,
            'R' => .white_rook,
            'Q' => .white_queen,
            'K' => .white_king,
            'p' => .black_pawn,
            'n' => .black_knight,
            'b' => .black_bishop,
            'r' => .black_rook,
            'q' => .black_queen,
            'k' => .black_king,
            else => error.InvalidPiece,
        };
    }

    pub fn toFenChar(self: Piece) ?u8 {
        return switch (self) {
            .white_pawn => 'P',
            .white_knight => 'N',
            .white_bishop => 'B',
            .white_rook => 'R',
            .white_queen => 'Q',
            .white_king => 'K',
            .black_pawn => 'p',
            .black_knight => 'n',
            .black_bishop => 'b',
            .black_rook => 'r',
            .black_queen => 'q',
            .black_king => 'k',
            .none => null,
        };
    }
};

test "piece make and decomposition are consistent" {
    const piece = Piece.make(.black, .queen);
    try std.testing.expectEqual(Piece.black_queen, piece);
    try std.testing.expectEqual(types.Color.black, piece.color().?);
    try std.testing.expectEqual(PieceType.queen, piece.pieceType());
}

test "piece fen conversion works" {
    try std.testing.expectEqual(Piece.white_knight, try Piece.fromFenChar('N'));
    try std.testing.expectEqual(Piece.black_king, try Piece.fromFenChar('k'));
    try std.testing.expectEqual(@as(?u8, 'Q'), Piece.white_queen.toFenChar());
    try std.testing.expectEqual(@as(?u8, 'p'), Piece.black_pawn.toFenChar());
}
