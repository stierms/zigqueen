const std = @import("std");
const piece = @import("piece.zig");
const position = @import("position.zig");
const square = @import("square.zig");
const types = @import("types.zig");
const zobrist = @import("zobrist.zig");

pub const STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

/// Largest halfmove clock or fullmove number a FEN may carry. make/unmake
/// increment both as plain u16 adds; keeping the parsed value in the lower
/// half of the range leaves 32,768 increments of headroom, more plies than
/// any replayed game can add.
pub const MAX_MOVE_COUNTER: u16 = 32_767;

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
    pos.castling_rights = supportedCastling(&pos, try parseCastling(castling_field));
    pos.en_passant = try parseEnPassant(ep_field);
    if (pos.en_passant) |ep| {
        try validateEnPassant(&pos, ep);
        // Same rule as a double push in make_unmake: keep (and hash) the
        // target only when a pawn of the side to move can take on it, so the
        // FEN and the same position reached by moves get one key.
        if (!enPassantTargetUsable(&pos, ep)) pos.en_passant = null;
    }
    pos.halfmove_clock = std.fmt.parseInt(u16, halfmove_field, 10) catch return error.InvalidHalfmoveClock;
    if (pos.halfmove_clock > MAX_MOVE_COUNTER) return error.InvalidHalfmoveClock;
    pos.fullmove_number = std.fmt.parseInt(u16, fullmove_field, 10) catch return error.InvalidFullmoveNumber;
    if (pos.fullmove_number == 0 or pos.fullmove_number > MAX_MOVE_COUNTER) return error.InvalidFullmoveNumber;

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

/// Castling rights the board cannot support are dropped: each right needs its
/// king and its rook on their home squares. Make/unmake only ever clears
/// rights, so an unsupported one would otherwise come back to life once a rook
/// reached the corner: after `4k3/8/8/8/8/8/8/R3K3 w K - 0 1` and the rook's
/// walk a1-a2-h2-h1, e1g1 was generated as legal (audit C, C-FEN-CASTLE).
/// Clearing, not rejecting, keeps the parser accepting what GUIs send; the
/// key is computed afterwards, so it covers the rights actually kept.
fn supportedCastling(pos: *const position.Position, rights: position.CastlingRights) position.CastlingRights {
    const white_king = pos.pieceAt(.e1) == .white_king;
    const black_king = pos.pieceAt(.e8) == .black_king;
    return .{
        .white_king_side = rights.white_king_side and white_king and pos.pieceAt(.h1) == .white_rook,
        .white_queen_side = rights.white_queen_side and white_king and pos.pieceAt(.a1) == .white_rook,
        .black_king_side = rights.black_king_side and black_king and pos.pieceAt(.h8) == .black_rook,
        .black_queen_side = rights.black_queen_side and black_king and pos.pieceAt(.a8) == .black_rook,
    };
}

fn parseEnPassant(field: []const u8) FenError!?square.Square {
    if (std.mem.eql(u8, field, "-")) return null;
    const sq = square.Square.parse(field) catch return error.InvalidEnPassant;
    const rank = sq.rank();
    if (rank != 2 and rank != 5) return error.InvalidEnPassant;
    return sq;
}

/// The generators trust an en passant target: they emit the capture and remove
/// a pawn from the square in front of it without looking. So the target must
/// be on the rank the side to move captures onto, be empty, and have the
/// opponent's double-pushed pawn in front of it. A capturing pawn beside it is
/// not required (FEN records the target after every double push); without one
/// the parser drops the target (`enPassantTargetUsable`).
fn validateEnPassant(pos: *const position.Position, ep: square.Square) FenError!void {
    const white_to_move = pos.side_to_move == .white;
    if (ep.rank() != @as(u8, if (white_to_move) 5 else 2)) return error.InvalidEnPassant;
    if (pos.pieceAt(ep) != .none) return error.InvalidEnPassant;
    const pushed = square.Square.fromCoords(@intCast(ep.file()), if (white_to_move) 4 else 3);
    const expected: piece.Piece = if (white_to_move) .black_pawn else .white_pawn;
    if (pos.pieceAt(pushed) != expected) return error.InvalidEnPassant;
}

/// Whether a pawn of the side to move attacks the (validated) target. The
/// squares it would capture from are the squares an opponent pawn standing on
/// the target attacks. Pseudo-legal, like the rule in make_unmake.
fn enPassantTargetUsable(pos: *const position.Position, ep: square.Square) bool {
    const side = pos.side_to_move;
    const pawn: piece.Piece = if (side == .white) .white_pawn else .black_pawn;
    const capture_from = pawnCaptureSources(side, ep);
    for (capture_from) |maybe_sq| {
        const sq = maybe_sq orelse continue;
        if (pos.pieceAt(sq) == pawn) return true;
    }
    return false;
}

/// The (at most two) squares from which a `side` pawn captures onto `target`.
fn pawnCaptureSources(side: types.Color, target: square.Square) [2]?square.Square {
    const rank: i8 = @as(i8, target.rank()) + @as(i8, if (side == .white) -1 else 1);
    var sources = [2]?square.Square{ null, null };
    if (rank < 0 or rank > 7) return sources;
    const file: i8 = target.file();
    for ([_]i8{ -1, 1 }, 0..) |delta, slot| {
        const f = file + delta;
        if (f >= 0 and f <= 7) sources[slot] = square.Square.fromCoords(@intCast(f), @intCast(rank));
    }
    return sources;
}

test "fen parser rejects en passant targets the generators could not honour" {
    // No pawn to capture.
    try std.testing.expectError(error.InvalidEnPassant, parse("4k3/8/8/4P3/8/8/8/4K3 w - d6 0 1"));
    // Target on the mover's own double-push rank.
    try std.testing.expectError(error.InvalidEnPassant, parse("4k3/8/8/8/3pP3/8/8/4K3 w - e3 0 1"));
    // Target square occupied.
    try std.testing.expectError(error.InvalidEnPassant, parse("4k3/8/3n4/3pP3/8/8/8/4K3 w - d6 0 1"));
    // Wrong colour in front of the target.
    try std.testing.expectError(error.InvalidEnPassant, parse("4k3/8/8/3PP3/8/8/8/4K3 w - d6 0 1"));
    // A consistent target with no capturing pawn beside it is ordinary FEN:
    // accepted, but dropped (it is not part of the position).
    const after_e4 = try parse("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1");
    try std.testing.expectEqual(@as(?square.Square, null), after_e4.en_passant);
    const black_pushed = try parse("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2");
    try std.testing.expectEqual(@as(?square.Square, .d6), black_pushed.en_passant);
}

test "fen parser drops castling rights the board cannot support" {
    const Rights = position.CastlingRights;
    // Rook missing from its corner: the audit C witness.
    try std.testing.expectEqual(Rights{}, (try parse("4k3/8/8/8/8/8/8/R3K3 w K - 0 1")).castling_rights);
    // Every right kept when kings and rooks are home.
    const all = Rights{ .white_king_side = true, .white_queen_side = true, .black_king_side = true, .black_queen_side = true };
    try std.testing.expectEqual(all, (try parse("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")).castling_rights);
    // A displaced king loses both of its side's rights, and only those.
    try std.testing.expectEqual(Rights{ .black_king_side = true, .black_queen_side = true }, (try parse("r3k2r/8/8/8/8/8/8/R2K3R w KQkq - 0 1")).castling_rights);
    try std.testing.expectEqual(Rights{ .white_king_side = true, .white_queen_side = true }, (try parse("r2k3r/8/8/8/8/8/8/R3K2R b KQkq - 0 1")).castling_rights);
    // One missing rook (a8), one wrong-colour rook (h1): only those rights go.
    try std.testing.expectEqual(Rights{ .white_queen_side = true, .black_king_side = true }, (try parse("4k2r/8/8/8/8/8/8/R3K2r w KQkq - 0 1")).castling_rights);
    // The key covers the rights actually kept, so equal boards hash equally.
    try std.testing.expectEqual((try parse("4k3/8/8/8/8/8/8/R3K3 w Q - 0 1")).zobrist_key, (try parse("4k3/8/8/8/8/8/8/R3K3 w KQkq - 0 1")).zobrist_key);
    // The legal generator never sees the stale right: after the rook walks to
    // h1 the king may not castle.
    var pos = try parse("4k3/8/8/8/8/8/8/R3K3 w K - 0 1");
    const make_unmake = @import("../movegen/make_unmake.zig");
    const move_mod = @import("move.zig");
    var states: [6]make_unmake.StateInfo = undefined;
    for ([_]move_mod.Move{
        move_mod.Move.init(.a1, .a2, .quiet), move_mod.Move.init(.e8, .d8, .quiet),
        move_mod.Move.init(.a2, .h2, .quiet), move_mod.Move.init(.d8, .e8, .quiet),
        move_mod.Move.init(.h2, .h1, .quiet), move_mod.Move.init(.e8, .d8, .quiet),
    }, &states) |mv, *state| _ = make_unmake.makeMove(&pos, mv, state);
    var moves = move_mod.MoveList.init();
    @import("../movegen/legal.zig").generate(&pos, &moves);
    for (moves.slice()) |mv| try std.testing.expect(!(mv.from == .e1 and mv.to == .g1));
}

test "fen keeps an en passant target only when the side to move can capture" {
    // Capturing pawn on either side, both colours.
    try std.testing.expectEqual(@as(?square.Square, .d6), (try parse("4k3/8/8/2Pp4/8/8/8/4K3 w - d6 0 2")).en_passant);
    try std.testing.expectEqual(@as(?square.Square, .a3), (try parse("4k3/8/8/8/Pp6/8/8/4K3 b - a3 0 1")).en_passant);
    try std.testing.expectEqual(@as(?square.Square, .h3), (try parse("4k3/8/8/8/6pP/8/8/4K3 b - h3 0 1")).en_passant);
    // Own pawn or a piece beside the pushed pawn: no capture, no target.
    try std.testing.expectEqual(@as(?square.Square, null), (try parse("4k3/8/8/2pp4/8/8/8/4K3 w - d6 0 2")).en_passant);
    try std.testing.expectEqual(@as(?square.Square, null), (try parse("4k3/8/8/3pN3/8/8/8/4K3 w - d6 0 2")).en_passant);
    // A pinned capturer still keeps it (pseudo-legal rule).
    try std.testing.expectEqual(@as(?square.Square, .e6), (try parse("k2r4/8/8/3Pp3/8/8/8/3K4 w - e6 0 2")).en_passant);
    // The dropped target hashes like "-".
    const with_target = try parse("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1");
    const without = try parse("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1");
    try std.testing.expectEqual(without.zobrist_key, with_target.zobrist_key);
}

test "fen parser bounds the move counters" {
    try std.testing.expectError(error.InvalidFullmoveNumber, parse("4k3/8/8/8/8/8/8/4K3 b - - 0 65535"));
    try std.testing.expectError(error.InvalidFullmoveNumber, parse("4k3/8/8/8/8/8/8/4K3 b - - 0 32768"));
    try std.testing.expectError(error.InvalidHalfmoveClock, parse("4k3/8/8/8/8/8/8/4K3 b - - 40000 1"));
    const pos = try parse("4k3/8/8/8/8/8/8/4K3 b - - 32767 32767");
    try std.testing.expectEqual(MAX_MOVE_COUNTER, pos.fullmove_number);
    try std.testing.expectEqual(MAX_MOVE_COUNTER, pos.halfmove_clock);
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
