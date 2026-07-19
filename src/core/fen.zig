const std = @import("std");
const piece = @import("piece.zig");
const position = @import("position.zig");
const square = @import("square.zig");
const types = @import("types.zig");
const zobrist = @import("zobrist.zig");

pub const STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

pub const FenError = error{
    InvalidFen,
    InvalidPiecePlacement,
    InvalidSideToMove,
    InvalidCastling,
    InvalidEnPassant,
    InvalidHalfmoveClock,
    InvalidFullmoveNumber,
    InvalidKingCount,
    OutOfMemory,
};

pub fn parse(fen: []const u8) FenError!position.Position {
    return parseWithHash(fen, true);
}

pub fn parseNoHash(fen: []const u8) FenError!position.Position {
    return parseWithHash(fen, false);
}

fn parseWithHash(fen: []const u8, comptime compute_hash: bool) FenError!position.Position {
    var fields = std.mem.tokenizeScalar(u8, fen, ' ');
    const piece_field = fields.next() orelse return error.InvalidFen;
    const side_field = fields.next() orelse return error.InvalidFen;
    const castling_field = fields.next() orelse return error.InvalidFen;
    const ep_field = fields.next() orelse return error.InvalidFen;
    const halfmove_field = fields.next() orelse return error.InvalidFen;
    const fullmove_field = fields.next() orelse return error.InvalidFen;
    if (fields.next() != null) return error.InvalidFen;

    var pos = position.Position.empty();
    try parsePiecePlacement(piece_field, &pos);
    pos.side_to_move = try parseSideToMove(side_field);
    pos.castling_rights = try parseCastling(castling_field);
    pos.en_passant = try parseEnPassant(ep_field);
    pos.halfmove_clock = std.fmt.parseInt(u16, halfmove_field, 10) catch return error.InvalidHalfmoveClock;
    pos.fullmove_number = std.fmt.parseInt(u16, fullmove_field, 10) catch return error.InvalidFullmoveNumber;
    if (pos.fullmove_number == 0) return error.InvalidFullmoveNumber;

    if (pos.countPieces(.white, .king) != 1 or pos.countPieces(.black, .king) != 1) {
        return error.InvalidKingCount;
    }

    if (compute_hash) pos.zobrist_key = zobrist.hashPosition(&pos);
    return pos;
}

pub fn format(allocator: std.mem.Allocator, pos: *const position.Position) FenError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try write(pos, &aw.writer);
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn write(pos: *const position.Position, writer: anytype) FenError!void {
    var rank: i8 = 7;
    while (rank >= 0) : (rank -= 1) {
        var empty_run: u8 = 0;
        var file: u8 = 0;
        while (file < 8) : (file += 1) {
            const sq = square.Square.fromCoords(@intCast(file), @intCast(rank));
            const p = pos.pieceAt(sq);
            if (p == .none) {
                empty_run += 1;
                continue;
            }
            if (empty_run != 0) {
                try writeByte(writer, '0' + empty_run);
                empty_run = 0;
            }
            try writeByte(writer, p.toFenChar().?);
        }
        if (empty_run != 0) try writeByte(writer, '0' + empty_run);
        if (rank != 0) try writeByte(writer, '/');
    }

    try writeByte(writer, ' ');
    try writeByte(writer, if (pos.side_to_move == .white) 'w' else 'b');
    try writeByte(writer, ' ');

    if (!pos.castling_rights.hasAny()) {
        try writeByte(writer, '-');
    } else {
        if (pos.castling_rights.white_king_side) try writeByte(writer, 'K');
        if (pos.castling_rights.white_queen_side) try writeByte(writer, 'Q');
        if (pos.castling_rights.black_king_side) try writeByte(writer, 'k');
        if (pos.castling_rights.black_queen_side) try writeByte(writer, 'q');
    }

    try writeByte(writer, ' ');
    if (pos.en_passant) |ep| {
        const chars = ep.chars();
        try writeAll(writer, &chars);
    } else {
        try writeByte(writer, '-');
    }

    writer.print(" {d} {d}", .{ pos.halfmove_clock, pos.fullmove_number }) catch return error.OutOfMemory;
}

fn writeByte(writer: anytype, byte: u8) FenError!void {
    writer.writeByte(byte) catch return error.OutOfMemory;
}

fn writeAll(writer: anytype, bytes: []const u8) FenError!void {
    writer.writeAll(bytes) catch return error.OutOfMemory;
}

pub fn startpos() FenError!position.Position {
    return parse(STARTPOS_FEN);
}

fn parsePiecePlacement(field: []const u8, pos: *position.Position) FenError!void {
    var rank: i8 = 7;
    var file: u8 = 0;
    var slash_count: u8 = 0;

    for (field) |ch| {
        if (ch == '/') {
            if (file != 8 or rank == 0) return error.InvalidPiecePlacement;
            slash_count += 1;
            rank -= 1;
            file = 0;
            continue;
        }

        if (ch >= '1' and ch <= '8') {
            file += ch - '0';
            if (file > 8) return error.InvalidPiecePlacement;
            continue;
        }

        const parsed_piece = piece.Piece.fromFenChar(ch) catch return error.InvalidPiecePlacement;
        if (file >= 8) return error.InvalidPiecePlacement;
        const sq = square.Square.fromCoords(@intCast(file), @intCast(rank));
        pos.setPieceOnEmpty(sq, parsed_piece);
        file += 1;
    }

    if (rank != 0 or file != 8 or slash_count != 7) return error.InvalidPiecePlacement;
}

fn parseSideToMove(field: []const u8) FenError!types.Color {
    if (std.mem.eql(u8, field, "w")) return .white;
    if (std.mem.eql(u8, field, "b")) return .black;
    return error.InvalidSideToMove;
}

fn parseCastling(field: []const u8) FenError!position.CastlingRights {
    if (std.mem.eql(u8, field, "-")) return .{};

    var rights = position.CastlingRights{};
    for (field) |ch| {
        switch (ch) {
            'K' => {
                if (rights.white_king_side) return error.InvalidCastling;
                rights.white_king_side = true;
            },
            'Q' => {
                if (rights.white_queen_side) return error.InvalidCastling;
                rights.white_queen_side = true;
            },
            'k' => {
                if (rights.black_king_side) return error.InvalidCastling;
                rights.black_king_side = true;
            },
            'q' => {
                if (rights.black_queen_side) return error.InvalidCastling;
                rights.black_queen_side = true;
            },
            else => return error.InvalidCastling,
        }
    }
    return rights;
}

fn parseEnPassant(field: []const u8) FenError!?square.Square {
    if (std.mem.eql(u8, field, "-")) return null;
    const sq = square.Square.parse(field) catch return error.InvalidEnPassant;
    const rank = sq.rank();
    if (rank != 2 and rank != 5) return error.InvalidEnPassant;
    return sq;
}

test "startpos fen parses with correct piece counts" {
    const pos = try parse(STARTPOS_FEN);
    try std.testing.expectEqual(@as(u8, 8), pos.countPieces(.white, .pawn));
    try std.testing.expectEqual(@as(u8, 8), pos.countPieces(.black, .pawn));
    try std.testing.expectEqual(@as(u8, 2), pos.countPieces(.white, .rook));
    try std.testing.expectEqual(@as(u8, 2), pos.countPieces(.black, .knight));
    try std.testing.expectEqual(types.Color.white, pos.side_to_move);
    try std.testing.expect(pos.castling_rights.white_king_side);
    try std.testing.expect(pos.castling_rights.black_queen_side);
    try std.testing.expectEqual(@as(?square.Square, null), pos.en_passant);
}

test "startpos fen formats exactly" {
    const pos = try parse(STARTPOS_FEN);
    const rendered = try format(std.testing.allocator, &pos);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(STARTPOS_FEN, rendered);
}

test "custom fen round trips" {
    const custom = "r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1";
    const pos = try parse(custom);
    const rendered = try format(std.testing.allocator, &pos);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(custom, rendered);
}

test "fen parser rejects missing kings" {
    try std.testing.expectError(error.InvalidKingCount, parse("8/8/8/8/8/8/8/8 w - - 0 1"));
}
