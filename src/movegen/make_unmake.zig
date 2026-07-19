const std = @import("std");
const bitboard = @import("../core/bitboard.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");
const zobrist = @import("../core/zobrist.zig");

pub const StateInfo = struct {
    captured_piece: piece.Piece = .none,
    moved_piece: piece.Piece = .none,
    previous_en_passant: ?square.Square = null,
    previous_castling_rights: position.CastlingRights = .{},
    previous_halfmove_clock: u16 = 0,
    previous_fullmove_number: u16 = 1,
    previous_zobrist_key: u64 = 0,
};

pub inline fn isIrreversibleMove(moving_piece: piece.Piece, mv: move_mod.Move) bool {
    const flag = @intFromEnum(mv.flag);
    return moving_piece.pieceType() == .pawn or
        flag == @intFromEnum(move_mod.MoveFlag.capture) or
        flag == @intFromEnum(move_mod.MoveFlag.en_passant) or
        flag >= @intFromEnum(move_mod.MoveFlag.promo_knight_capture);
}

/// Returns the position's NEW zobrist key. The value is live in a register at
/// the end of applyMove's xor chain; returning it lets hot callers (negamax /
/// qsearch move loops) feed their TT/RFP-hint prefetches and repetition push
/// from the register instead of reloading `pos.zobrist_key` — a load that had
/// to wait on the store makeMove just issued (7.9% of negamax's middlegame
/// samples, ~5% endgame, at the post-make reload cluster 0x30de3f1..0x30de413).
pub fn makeMove(pos: *position.Position, mv: move_mod.Move, state: *StateInfo) u64 {
    const side = pos.side_to_move;
    const moving_piece = pos.pieceAt(mv.from);
    std.debug.assert(moving_piece != .none);

    state.* = .{
        .captured_piece = .none,
        .moved_piece = moving_piece,
        .previous_en_passant = pos.en_passant,
        .previous_castling_rights = pos.castling_rights,
        .previous_halfmove_clock = pos.halfmove_clock,
        .previous_fullmove_number = pos.fullmove_number,
        .previous_zobrist_key = pos.zobrist_key,
    };

    applyMove(pos, mv, moving_piece, side, &state.captured_piece);
    return pos.zobrist_key;
}

pub fn makeMoveForLegality(pos: *position.Position, mv: move_mod.Move) void {
    const side = pos.side_to_move;
    const moving_piece = pos.pieceAt(mv.from);
    std.debug.assert(moving_piece != .none);

    switch (mv.flag) {
        .quiet, .double_push => movePieceWithoutHash(pos, moving_piece, mv.from, mv.to),
        .capture => {
            const captured_piece = pos.pieceAt(mv.to);
            removePieceWithoutHash(pos, captured_piece, mv.to);
            movePieceWithoutHash(pos, moving_piece, mv.from, mv.to);
        },
        .en_passant => {
            const capture_square = enPassantCapturedPawnSquare(side, mv.to);
            const captured_piece = pos.pieceAt(capture_square);
            removePieceWithoutHash(pos, captured_piece, capture_square);
            movePieceWithoutHash(pos, moving_piece, mv.from, mv.to);
        },
        .castle => {
            movePieceWithoutHash(pos, moving_piece, mv.from, mv.to);
            applyCastleRookMoveWithoutHash(pos, side, mv.to);
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        => {
            removePieceWithoutHash(pos, moving_piece, mv.from);
            addPieceWithoutHash(pos, promotedPiece(side, mv), mv.to);
        },
        .promo_knight_capture,
        .promo_bishop_capture,
        .promo_rook_capture,
        .promo_queen_capture,
        => {
            const captured_piece = pos.pieceAt(mv.to);
            removePieceWithoutHash(pos, captured_piece, mv.to);
            removePieceWithoutHash(pos, moving_piece, mv.from);
            addPieceWithoutHash(pos, promotedPiece(side, mv), mv.to);
        },
    }
}

pub fn unmakeMove(pos: *position.Position, mv: move_mod.Move, state: *const StateInfo) void {
    const side = pos.side_to_move.other();

    pos.side_to_move = side;
    pos.castling_rights = state.previous_castling_rights;
    pos.en_passant = state.previous_en_passant;
    pos.halfmove_clock = state.previous_halfmove_clock;
    pos.fullmove_number = state.previous_fullmove_number;

    switch (mv.flag) {
        .quiet, .double_push => movePieceWithoutHash(pos, state.moved_piece, mv.to, mv.from),
        .capture => {
            movePieceWithoutHash(pos, state.moved_piece, mv.to, mv.from);
            restoreCaptured(pos, state.captured_piece, mv.to);
        },
        .en_passant => {
            movePieceWithoutHash(pos, state.moved_piece, mv.to, mv.from);
            restoreCaptured(pos, state.captured_piece, enPassantCapturedPawnSquare(side, mv.to));
        },
        .castle => {
            movePieceWithoutHash(pos, state.moved_piece, mv.to, mv.from);
            undoCastleRookMove(pos, side, mv.to);
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        => {
            removePieceWithoutHash(pos, promotedPiece(side, mv), mv.to);
            addPieceWithoutHash(pos, state.moved_piece, mv.from);
        },
        .promo_knight_capture,
        .promo_bishop_capture,
        .promo_rook_capture,
        .promo_queen_capture,
        => {
            removePieceWithoutHash(pos, promotedPiece(side, mv), mv.to);
            addPieceWithoutHash(pos, state.moved_piece, mv.from);
            restoreCaptured(pos, state.captured_piece, mv.to);
        },
    }

    pos.zobrist_key = state.previous_zobrist_key;
}

pub fn makeNullMove(pos: *position.Position, state: *StateInfo) void {
    const side = pos.side_to_move;

    state.* = .{
        .captured_piece = .none,
        .moved_piece = .none,
        .previous_en_passant = pos.en_passant,
        .previous_castling_rights = pos.castling_rights,
        .previous_halfmove_clock = pos.halfmove_clock,
        .previous_fullmove_number = pos.fullmove_number,
        .previous_zobrist_key = pos.zobrist_key,
    };

    if (pos.en_passant) |ep| pos.zobrist_key ^= zobrist.EN_PASSANT_FILE_KEYS[ep.file()];
    pos.en_passant = null;
    pos.halfmove_clock += 1;
    if (side == .black) pos.fullmove_number += 1;
    pos.side_to_move = side.other();
    pos.zobrist_key ^= zobrist.SIDE_TO_MOVE_KEY;
}

pub fn unmakeNullMove(pos: *position.Position, state: *const StateInfo) void {
    pos.side_to_move = pos.side_to_move.other();
    pos.castling_rights = state.previous_castling_rights;
    pos.en_passant = state.previous_en_passant;
    pos.halfmove_clock = state.previous_halfmove_clock;
    pos.fullmove_number = state.previous_fullmove_number;
    pos.zobrist_key = state.previous_zobrist_key;
}

fn applyMove(
    pos: *position.Position,
    mv: move_mod.Move,
    moving_piece: piece.Piece,
    side: types.Color,
    captured_piece: *piece.Piece,
) void {
    const opponent = side.other();

    if (pos.en_passant) |ep| pos.zobrist_key ^= zobrist.EN_PASSANT_FILE_KEYS[ep.file()];
    const old_castling_index = zobrist.castlingIndex(pos.castling_rights);
    pos.en_passant = null;

    if (isIrreversibleMove(moving_piece, mv)) {
        pos.halfmove_clock = 0;
    } else {
        pos.halfmove_clock += 1;
    }
    if (side == .black) pos.fullmove_number += 1;

    switch (mv.flag) {
        .quiet => movePiece(pos, moving_piece, mv.from, mv.to),
        .capture => {
            captured_piece.* = pos.pieceAt(mv.to);
            removePiece(pos, captured_piece.*, mv.to);
            movePiece(pos, moving_piece, mv.from, mv.to);
        },
        .double_push => {
            movePiece(pos, moving_piece, mv.from, mv.to);
            pos.en_passant = betweenSquare(mv.from, mv.to);
        },
        .en_passant => {
            const capture_square = enPassantCapturedPawnSquare(side, mv.to);
            captured_piece.* = pos.pieceAt(capture_square);
            removePiece(pos, captured_piece.*, capture_square);
            movePiece(pos, moving_piece, mv.from, mv.to);
        },
        .castle => {
            movePiece(pos, moving_piece, mv.from, mv.to);
            applyCastleRookMove(pos, side, mv.to);
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        => {
            removePiece(pos, moving_piece, mv.from);
            addPiece(pos, promotedPiece(side, mv), mv.to);
        },
        .promo_knight_capture,
        .promo_bishop_capture,
        .promo_rook_capture,
        .promo_queen_capture,
        => {
            captured_piece.* = pos.pieceAt(mv.to);
            removePiece(pos, captured_piece.*, mv.to);
            removePiece(pos, moving_piece, mv.from);
            addPiece(pos, promotedPiece(side, mv), mv.to);
        },
    }

    updateCastlingRightsForMove(pos, moving_piece, mv.from);
    updateCastlingRightsForCapture(pos, captured_piece.*, captureSquareForRights(side, mv));

    const new_castling_index = zobrist.castlingIndex(pos.castling_rights);
    if (new_castling_index != old_castling_index) {
        pos.zobrist_key ^= zobrist.CASTLING_KEYS[old_castling_index] ^ zobrist.CASTLING_KEYS[new_castling_index];
    }
    if (pos.en_passant) |ep| pos.zobrist_key ^= zobrist.EN_PASSANT_FILE_KEYS[ep.file()];
    pos.side_to_move = opponent;
    pos.zobrist_key ^= zobrist.SIDE_TO_MOVE_KEY;
}

fn updateCastlingRightsForMove(pos: *position.Position, moving_piece: piece.Piece, from: square.Square) void {
    switch (moving_piece) {
        .white_king => {
            pos.castling_rights.white_king_side = false;
            pos.castling_rights.white_queen_side = false;
        },
        .black_king => {
            pos.castling_rights.black_king_side = false;
            pos.castling_rights.black_queen_side = false;
        },
        .white_rook => switch (from) {
            .a1 => pos.castling_rights.white_queen_side = false,
            .h1 => pos.castling_rights.white_king_side = false,
            else => {},
        },
        .black_rook => switch (from) {
            .a8 => pos.castling_rights.black_queen_side = false,
            .h8 => pos.castling_rights.black_king_side = false,
            else => {},
        },
        else => {},
    }
}

fn updateCastlingRightsForCapture(pos: *position.Position, captured_piece: piece.Piece, capture_square: square.Square) void {
    switch (captured_piece) {
        .white_rook => switch (capture_square) {
            .a1 => pos.castling_rights.white_queen_side = false,
            .h1 => pos.castling_rights.white_king_side = false,
            else => {},
        },
        .black_rook => switch (capture_square) {
            .a8 => pos.castling_rights.black_queen_side = false,
            .h8 => pos.castling_rights.black_king_side = false,
            else => {},
        },
        else => {},
    }
}

fn captureSquareForRights(side: types.Color, mv: move_mod.Move) square.Square {
    return if (mv.flag == .en_passant) enPassantCapturedPawnSquare(side, mv.to) else mv.to;
}

fn betweenSquare(from: square.Square, to: square.Square) square.Square {
    const mid_rank: u3 = @intCast((@as(u8, from.rank()) + @as(u8, to.rank())) / 2);
    return square.Square.fromCoords(from.file(), mid_rank);
}

fn enPassantCapturedPawnSquare(side: types.Color, destination: square.Square) square.Square {
    return switch (side) {
        .white => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) - 1)),
        .black => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) + 1)),
    };
}

fn applyCastleRookMove(pos: *position.Position, side: types.Color, king_destination: square.Square) void {
    switch (side) {
        .white => switch (king_destination) {
            .g1 => movePiece(pos, .white_rook, .h1, .f1),
            .c1 => movePiece(pos, .white_rook, .a1, .d1),
            else => unreachable,
        },
        .black => switch (king_destination) {
            .g8 => movePiece(pos, .black_rook, .h8, .f8),
            .c8 => movePiece(pos, .black_rook, .a8, .d8),
            else => unreachable,
        },
    }
}

fn applyCastleRookMoveWithoutHash(pos: *position.Position, side: types.Color, king_destination: square.Square) void {
    switch (side) {
        .white => switch (king_destination) {
            .g1 => movePieceWithoutHash(pos, .white_rook, .h1, .f1),
            .c1 => movePieceWithoutHash(pos, .white_rook, .a1, .d1),
            else => unreachable,
        },
        .black => switch (king_destination) {
            .g8 => movePieceWithoutHash(pos, .black_rook, .h8, .f8),
            .c8 => movePieceWithoutHash(pos, .black_rook, .a8, .d8),
            else => unreachable,
        },
    }
}

fn undoCastleRookMove(pos: *position.Position, side: types.Color, king_destination: square.Square) void {
    switch (side) {
        .white => switch (king_destination) {
            .g1 => movePieceWithoutHash(pos, .white_rook, .f1, .h1),
            .c1 => movePieceWithoutHash(pos, .white_rook, .d1, .a1),
            else => unreachable,
        },
        .black => switch (king_destination) {
            .g8 => movePieceWithoutHash(pos, .black_rook, .f8, .h8),
            .c8 => movePieceWithoutHash(pos, .black_rook, .d8, .a8),
            else => unreachable,
        },
    }
}

fn promotedPiece(side: types.Color, mv: move_mod.Move) piece.Piece {
    return piece.Piece.make(side, mv.promotionPieceType().?);
}

fn addPiece(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    pos.zobrist_key ^= pieceKey(p, sq);
    addPieceWithoutHash(pos, p, sq);
}

fn removePiece(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    pos.zobrist_key ^= pieceKey(p, sq);
    removePieceWithoutHash(pos, p, sq);
}

fn movePiece(pos: *position.Position, p: piece.Piece, from: square.Square, to: square.Square) void {
    std.debug.assert(p != .none);
    std.debug.assert(pos.pieceAt(from) == p);
    std.debug.assert(pos.pieceAt(to) == .none);

    const from_index = from.index();
    const to_index = to.index();
    const from_mask = @as(bitboard.Bitboard, 1) << from_index;
    const to_mask = @as(bitboard.Bitboard, 1) << to_index;
    const delta = from_mask | to_mask;
    const piece_index = @intFromEnum(p);
    const ci = @as(usize, piece_index) / 6;
    const pti = @as(usize, piece_index) % 6;

    pos.zobrist_key ^= zobrist.PIECE_SQUARE_KEYS[piece_index][from_index] ^ zobrist.PIECE_SQUARE_KEYS[piece_index][to_index];
    pos.pieces[ci][pti] ^= delta;
    pos.occupancies[ci] ^= delta;
    pos.occupied ^= delta;
    pos.mailbox[from_index] = .none;
    pos.mailbox[to_index] = p;
    updateKingSquareForMove(pos, p, to);
}

fn addPieceWithoutHash(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    std.debug.assert(p != .none);
    std.debug.assert(pos.pieceAt(sq) == .none);

    const mask = bitboard.bit(sq);
    const ci = pieceColorIndex(p);
    const pti = pieceTypeIndex(p);

    pos.pieces[ci][pti] |= mask;
    pos.occupancies[ci] |= mask;
    pos.occupied |= mask;
    pos.mailbox[sq.index()] = p;
    updateKingSquareForAdd(pos, p, sq);
}

fn removePieceWithoutHash(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    std.debug.assert(p != .none);
    std.debug.assert(pos.pieceAt(sq) == p);

    const mask = bitboard.bit(sq);
    const ci = pieceColorIndex(p);
    const pti = pieceTypeIndex(p);

    pos.pieces[ci][pti] &= ~mask;
    pos.occupancies[ci] &= ~mask;
    pos.occupied &= ~mask;
    pos.mailbox[sq.index()] = .none;
    updateKingSquareForRemove(pos, p);
}

fn movePieceWithoutHash(pos: *position.Position, p: piece.Piece, from: square.Square, to: square.Square) void {
    std.debug.assert(p != .none);
    std.debug.assert(pos.pieceAt(from) == p);
    std.debug.assert(pos.pieceAt(to) == .none);

    const from_mask = bitboard.bit(from);
    const to_mask = bitboard.bit(to);
    const delta = from_mask | to_mask;
    const ci = pieceColorIndex(p);
    const pti = pieceTypeIndex(p);

    pos.pieces[ci][pti] ^= delta;
    pos.occupancies[ci] ^= delta;
    pos.occupied ^= delta;
    pos.mailbox[from.index()] = .none;
    pos.mailbox[to.index()] = p;
    updateKingSquareForMove(pos, p, to);
}

fn restoreCaptured(pos: *position.Position, captured: piece.Piece, sq: square.Square) void {
    if (captured != .none) addPieceWithoutHash(pos, captured, sq);
}

inline fn updateKingSquareForAdd(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    switch (p) {
        .white_king => pos.king_squares[@intFromEnum(types.Color.white)] = sq,
        .black_king => pos.king_squares[@intFromEnum(types.Color.black)] = sq,
        else => {},
    }
}

inline fn updateKingSquareForRemove(pos: *position.Position, p: piece.Piece) void {
    switch (p) {
        .white_king => pos.king_squares[@intFromEnum(types.Color.white)] = null,
        .black_king => pos.king_squares[@intFromEnum(types.Color.black)] = null,
        else => {},
    }
}

inline fn updateKingSquareForMove(pos: *position.Position, p: piece.Piece, to: square.Square) void {
    switch (p) {
        .white_king => pos.king_squares[@intFromEnum(types.Color.white)] = to,
        .black_king => pos.king_squares[@intFromEnum(types.Color.black)] = to,
        else => {},
    }
}

inline fn pieceColorIndex(p: piece.Piece) usize {
    return @as(usize, @intFromEnum(p)) / 6;
}

inline fn pieceTypeIndex(p: piece.Piece) usize {
    return @as(usize, @intFromEnum(p)) % 6;
}

fn pieceKey(p: piece.Piece, sq: square.Square) u64 {
    return zobrist.PIECE_SQUARE_KEYS[@intFromEnum(p)][sq.index()];
}

fn expectRoundTrip(fen_text: []const u8, mv: move_mod.Move) !void {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse(fen_text);
    const original = pos;
    var state = StateInfo{};
    _ = makeMove(&pos, mv, &state);
    unmakeMove(&pos, mv, &state);
    try std.testing.expect(position.Position.eql(&original, &pos));
}

fn findLegalMoveBySpec(pos: *const position.Position, from: square.Square, to: square.Square, flag: move_mod.MoveFlag) !move_mod.Move {
    const legal = @import("legal.zig");
    var list = move_mod.MoveList.init();
    legal.generate(pos, &list);
    for (list.slice()) |mv| {
        if (mv.from == from and mv.to == to and mv.flag == flag) return mv;
    }
    return error.MoveNotFound;
}

test "quiet move round-trips exactly" {
    try expectRoundTrip("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", move_mod.Move.init(.e2, .e4, .double_push));
}

test "capture move round-trips exactly" {
    try expectRoundTrip("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", move_mod.Move.init(.e4, .d5, .capture));
}

test "castle move round-trips exactly" {
    try expectRoundTrip("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", move_mod.Move.init(.e1, .g1, .castle));
}

test "en passant move round-trips exactly" {
    try expectRoundTrip("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", move_mod.Move.init(.e5, .d6, .en_passant));
}

test "promotion capture round-trips exactly" {
    try expectRoundTrip("1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1", move_mod.Move.init(.a7, .b8, .promo_queen_capture));
}

test "null move round-trips exactly" {
    const fen = @import("../core/fen.zig");

    var pos = try fen.parse("r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 7 12");
    const original = pos;
    var state = StateInfo{};

    makeNullMove(&pos, &state);
    try std.testing.expectEqual(types.Color.black, pos.side_to_move);
    try std.testing.expectEqual(@as(?square.Square, null), pos.en_passant);
    try std.testing.expectEqual(@as(u16, 8), pos.halfmove_clock);
    try std.testing.expectEqual(@as(u16, 12), pos.fullmove_number);

    unmakeNullMove(&pos, &state);
    try std.testing.expect(position.Position.eql(&original, &pos));
}

test "multi-move sequence make and unmake restores exact position" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.startpos();
    const original = pos;

    var moves: [4]move_mod.Move = undefined;
    var states: [4]StateInfo = undefined;

    moves[0] = try findLegalMoveBySpec(&pos, .e2, .e4, .double_push);
    _ = makeMove(&pos, moves[0], &states[0]);

    moves[1] = try findLegalMoveBySpec(&pos, .c7, .c5, .double_push);
    _ = makeMove(&pos, moves[1], &states[1]);

    moves[2] = try findLegalMoveBySpec(&pos, .g1, .f3, .quiet);
    _ = makeMove(&pos, moves[2], &states[2]);

    moves[3] = try findLegalMoveBySpec(&pos, .d7, .d6, .quiet);
    _ = makeMove(&pos, moves[3], &states[3]);

    var i: usize = moves.len;
    while (i > 0) {
        i -= 1;
        unmakeMove(&pos, moves[i], &states[i]);
    }

    try std.testing.expect(position.Position.eql(&original, &pos));
}

fn nextDeterministic(seed: *u64) u64 {
    seed.* +%= 0x9E37_79B9_7F4A_7C15;
    var z = seed.*;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

test "deterministic legal sequence preserves hash integrity and round-trips" {
    const fen = @import("../core/fen.zig");
    const legal = @import("legal.zig");

    var pos = try fen.startpos();
    const original = pos;

    var moves: [128]move_mod.Move = undefined;
    var states: [128]StateInfo = undefined;
    var count: usize = 0;
    var seed: u64 = 0xC0FFEE_1234_5678;

    while (count < 64) {
        var list = move_mod.MoveList.init();
        legal.generate(&pos, &list);
        if (list.count == 0) break;

        const choice = @as(usize, @intCast(nextDeterministic(&seed) % list.count));
        const mv = list.slice()[choice];
        moves[count] = mv;
        _ = makeMove(&pos, mv, &states[count]);
        try std.testing.expectEqual(zobrist.hashPosition(&pos), pos.zobrist_key);
        count += 1;
    }

    while (count > 0) {
        count -= 1;
        unmakeMove(&pos, moves[count], &states[count]);
        try std.testing.expectEqual(zobrist.hashPosition(&pos), pos.zobrist_key);
    }

    try std.testing.expect(position.Position.eql(&original, &pos));
}
