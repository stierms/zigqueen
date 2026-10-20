const std = @import("std");
const attacks = @import("attacks.zig");
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
pub fn makeMove(pos: *position.Position, mv: move_mod.Move, state: *StateInfo) align(64) u64 { // align(64): pins hot entry placement (layout stability, not call speed)
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

/// The zobrist key `makeMove(pos, mv)` would produce, for prefetch hints only.
/// Exact for quiet moves, captures and double pushes that change no castling
/// right; castling, en passant, promotions and right-changing moves give a
/// near key, i.e. a wasted hint. Callers must never use it for anything but a
/// prefetch address, so it cannot change any search result.
pub inline fn prefetchKeyAfter(pos: *const position.Position, mv: move_mod.Move) u64 {
    const to = @intFromEnum(mv.to);
    const moving_row = zobrist.pieceSquareRow(@intFromEnum(pos.pieceAt(mv.from)));
    // Row 12 (Piece.none) is all zeros, so a quiet move's target adds nothing.
    const captured_row = zobrist.pieceSquareRow(@intFromEnum(pos.pieceAt(mv.to)));
    var key = pos.zobrist_key ^ zobrist.SIDE_TO_MOVE_KEY ^ moving_row[@intFromEnum(mv.from)] ^ moving_row[to] ^ captured_row[to];
    if (pos.en_passant) |ep| key ^= zobrist.EN_PASSANT_FILE_KEYS[ep.file()];
    if (mv.flag == .double_push and doublePushTargetCapturable(pos, pos.side_to_move, mv)) key ^= zobrist.EN_PASSANT_FILE_KEYS[mv.to.file()];
    return key;
}

/// Whether the target square a double push of `side` leaves behind can be
/// taken en passant, i.e. an enemy pawn stands beside the pushed pawn (the
/// squares a `side` pawn on the target would attack). Only then are the
/// target and its key recorded: a target no pawn can use is not part of the
/// position, and recording it gave identical positions two keys (missed
/// repetitions, unshared TT entries; C-EP-KEY). Pseudo-legal: a capture that
/// a pin would forbid still counts, as in the FEN target rule.
pub inline fn doublePushTargetCapturable(pos: *const position.Position, side: types.Color, mv: move_mod.Move) bool {
    const target = betweenSquare(mv.from, mv.to);
    return (attacks.pawnAttacksFrom(side, target) & pos.pieceBitboard(side.other(), .pawn)) != 0;
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

pub fn unmakeMove(pos: *position.Position, mv: move_mod.Move, state: *const StateInfo) align(64) void { // align(64): pins hot entry placement (layout stability, not call speed)
    const side = pos.side_to_move.other();

    pos.side_to_move = side;
    pos.castling_rights = state.previous_castling_rights;
    pos.en_passant = state.previous_en_passant;
    pos.halfmove_clock = state.previous_halfmove_clock;
    pos.fullmove_number = state.previous_fullmove_number;

    if (@intFromEnum(mv.flag) < @intFromEnum(move_mod.MoveFlag.castle)) {
        // Quiet, capture and double push share one branch-free path: the
        // captured piece is .none unless the move captured (see restoreIfAny).
        movePieceWithoutHash(pos, state.moved_piece, mv.to, mv.from);
        restoreIfAny(pos, state.captured_piece, mv.to);
    } else switch (mv.flag) {
        .quiet, .capture, .double_push => unreachable,
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

    // Branch-free clock updates: reset (all-zero mask) on an irreversible
    // move, else count; the full-move number steps after Black's move.
    const keep_clock: u16 = @intFromBool(!isIrreversibleMove(moving_piece, mv));
    pos.halfmove_clock = (pos.halfmove_clock +% 1) & (0 -% keep_clock);
    pos.fullmove_number += @intFromBool(side == .black);

    const flag = @intFromEnum(mv.flag);
    if (flag < @intFromEnum(move_mod.MoveFlag.castle)) {
        // Quiet, capture and double push share one branch-free path: the
        // target holds the captured piece, or .none for the two quiet kinds,
        // and removing .none changes nothing (removeIfAny).
        const captured = pos.pieceAt(mv.to);
        std.debug.assert((captured != .none) == (mv.flag == .capture));
        captured_piece.* = captured;
        removeIfAny(pos, captured, mv.to);
        movePiece(pos, moving_piece, mv.from, mv.to);
        if (flag == @intFromEnum(move_mod.MoveFlag.double_push) and doublePushTargetCapturable(pos, side, mv)) pos.en_passant = betweenSquare(mv.from, mv.to);
    } else switch (mv.flag) {
        .quiet, .capture, .double_push => unreachable,
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

    // Castling rights lost to this move (see KING_RIGHTS): the mover's, and a
    // rook captured on its home corner. An en passant capture takes a pawn,
    // which owns no right, so `mv.to` serves as its capture square here.
    const rights: u4 = @bitCast(pos.castling_rights);
    const lost = KING_RIGHTS[@intFromEnum(moving_piece)] |
        (CORNER_RIGHT[@intFromEnum(mv.from)] & ROOK_RIGHTS[@intFromEnum(moving_piece)]) |
        (CORNER_RIGHT[@intFromEnum(mv.to)] & ROOK_RIGHTS[@intFromEnum(captured_piece.*)]);
    pos.castling_rights = @bitCast(rights & ~lost);

    // Unchanged rights xor the same key twice (a no-op), so no branch.
    const new_castling_index = zobrist.castlingIndex(pos.castling_rights);
    pos.zobrist_key ^= zobrist.CASTLING_KEYS[old_castling_index] ^ zobrist.CASTLING_KEYS[new_castling_index];
    if (pos.en_passant) |ep| pos.zobrist_key ^= zobrist.EN_PASSANT_FILE_KEYS[ep.file()];
    pos.side_to_move = opponent;
    pos.zobrist_key ^= zobrist.SIDE_TO_MOVE_KEY;
}

// Castling-right bits (`position.CastlingRights` as u4: white king side 1,
// white queen side 2, black king side 4, black queen side 8) that a piece can
// remove, indexed by `piece.Piece`. A king's move removes both of its side's
// rights wherever it starts. A rook removes the right of its own home corner
// when it leaves that corner or is captured on it: CORNER_RIGHT names the
// corner's right and ROOK_RIGHTS keeps it only for the rook of that side
// (a white rook on a8 removes nothing). Same rights as the per-piece
// switches these tables replaced, without their jump table.
const KING_RIGHTS = blk: {
    var table = [_]u4{0} ** 13;
    table[@intFromEnum(piece.Piece.white_king)] = 0b0011;
    table[@intFromEnum(piece.Piece.black_king)] = 0b1100;
    break :blk table;
};
const ROOK_RIGHTS = blk: {
    var table = [_]u4{0} ** 13;
    table[@intFromEnum(piece.Piece.white_rook)] = 0b0011;
    table[@intFromEnum(piece.Piece.black_rook)] = 0b1100;
    break :blk table;
};
const CORNER_RIGHT = blk: {
    var table = [_]u4{0} ** 64;
    table[@intFromEnum(square.Square.h1)] = 0b0001;
    table[@intFromEnum(square.Square.a1)] = 0b0010;
    table[@intFromEnum(square.Square.h8)] = 0b0100;
    table[@intFromEnum(square.Square.a8)] = 0b1000;
    break :blk table;
};

/// The square a double push passes: same file, middle rank, i.e. the mean of
/// the two indices (they differ by exactly 16).
fn betweenSquare(from: square.Square, to: square.Square) square.Square {
    std.debug.assert(((@as(u7, @intFromEnum(from)) + @intFromEnum(to)) & 1) == 0);
    return @enumFromInt(@as(u6, @intCast((@as(u7, @intFromEnum(from)) + @intFromEnum(to)) >> 1)));
}

/// The pawn an en passant capture to `destination` removes: one rank behind it
/// from the capturer's side (index - 8 for White, + 8 for Black).
fn enPassantCapturedPawnSquare(side: types.Color, destination: square.Square) square.Square {
    const index: u6 = @intFromEnum(destination);
    return @enumFromInt(switch (side) {
        .white => index - 8,
        .black => index + 8,
    });
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

    const from_index = @intFromEnum(from);
    const to_index = @intFromEnum(to);
    const from_mask = @as(bitboard.Bitboard, 1) << from_index;
    const to_mask = @as(bitboard.Bitboard, 1) << to_index;
    const delta = from_mask | to_mask;
    const piece_index = @intFromEnum(p);
    const ci = pieceColorIndex(p);

    const key_row = zobrist.pieceSquareRow(piece_index);
    pos.zobrist_key ^= key_row[from_index] ^ key_row[to_index];
    pieceSlot(pos, p).* ^= delta;
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

    pieceSlot(pos, p).* |= mask;
    pos.occupancies[ci] |= mask;
    pos.occupied |= mask;
    pos.mailbox[@intFromEnum(sq)] = p;
    updateKingSquareForAdd(pos, p, sq);
}

fn removePieceWithoutHash(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    std.debug.assert(p != .none);
    std.debug.assert(pos.pieceAt(sq) == p);

    const mask = bitboard.bit(sq);
    const ci = pieceColorIndex(p);

    pieceSlot(pos, p).* &= ~mask;
    pos.occupancies[ci] &= ~mask;
    pos.occupied &= ~mask;
    pos.mailbox[@intFromEnum(sq)] = .none;
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

    pieceSlot(pos, p).* ^= delta;
    pos.occupancies[ci] ^= delta;
    pos.occupied ^= delta;
    pos.mailbox[@intFromEnum(from)] = .none;
    pos.mailbox[@intFromEnum(to)] = p;
    updateKingSquareForMove(pos, p, to);
}

fn restoreCaptured(pos: *position.Position, captured: piece.Piece, sq: square.Square) void {
    if (captured != .none) addPieceWithoutHash(pos, captured, sq);
}

/// `removePiece` for a piece that may be .none (then nothing changes: a zero
/// mask, the all-zero key row 12, and any valid bitboard slot), without a
/// branch on it.
inline fn removeIfAny(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    std.debug.assert(p != .white_king and p != .black_king);
    const sq_index = @intFromEnum(sq);
    const mask = (@as(bitboard.Bitboard, 1) << sq_index) & (0 -% @as(bitboard.Bitboard, @intFromBool(p != .none)));
    pos.zobrist_key ^= zobrist.pieceSquareRow(@intFromEnum(p))[sq_index];
    const flat: *[12]bitboard.Bitboard = @ptrCast(&pos.pieces);
    flat[@min(@intFromEnum(p), 11)] &= ~mask;
    pos.occupancies[pieceColorIndex(p)] &= ~mask;
    pos.occupied &= ~mask;
    pos.mailbox[sq_index] = .none;
}

/// `restoreCaptured` without a branch on .none (see removeIfAny); also
/// writes the mailbox square (.none stays .none).
inline fn restoreIfAny(pos: *position.Position, p: piece.Piece, sq: square.Square) void {
    std.debug.assert(p != .white_king and p != .black_king);
    const sq_index = @intFromEnum(sq);
    const mask = (@as(bitboard.Bitboard, 1) << sq_index) & (0 -% @as(bitboard.Bitboard, @intFromBool(p != .none)));
    const flat: *[12]bitboard.Bitboard = @ptrCast(&pos.pieces);
    flat[@min(@intFromEnum(p), 11)] |= mask;
    pos.occupancies[pieceColorIndex(p)] |= mask;
    pos.occupied |= mask;
    pos.mailbox[sq_index] = p;
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
    // The mover's colour slot is rewritten either way (with its own value
    // unless a king moved), the value picked by index: a select on the
    // optional compiled to branches on the piece.
    const slot = &pos.king_squares[pieceColorIndex(p)];
    const is_king = (p == .white_king) or (p == .black_king);
    const choices = [2]?square.Square{ slot.*, to };
    slot.* = choices[@intFromBool(is_king)];
}

inline fn pieceColorIndex(p: piece.Piece) usize {
    return @intFromBool(@intFromEnum(p) >= 6);
}

/// The bitboard of piece `p`: `pieces[c][t]` is element `c * 6 + t` of the
/// contiguous [2][6] array, and that is exactly the `piece.Piece` encoding,
/// so the piece indexes it directly (no divide-by-6 split and re-multiply).
inline fn pieceSlot(pos: *position.Position, p: piece.Piece) *bitboard.Bitboard {
    std.debug.assert(@intFromEnum(p) < 12);
    const flat: *[12]bitboard.Bitboard = @ptrCast(&pos.pieces);
    return &flat[@intFromEnum(p)];
}

fn pieceKey(p: piece.Piece, sq: square.Square) u64 {
    return zobrist.pieceSquareRow(@intFromEnum(p))[@intFromEnum(sq)];
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

test "double push records and hashes the en passant target only when it can be used" {
    const fen = @import("../core/fen.zig");
    const zobrist_check = @import("../core/zobrist.zig");

    // Judge C repro: e4, then a knight shuffle back to the same position. The
    // key after the shuffle must equal the key right after e4 (it did not,
    // because only the first carried the unusable e3 target).
    var pos = try fen.startpos();
    var states: [5]StateInfo = undefined;
    const e4 = try findLegalMoveBySpec(&pos, .e2, .e4, .double_push);
    const after_e4 = makeMove(&pos, e4, &states[0]);
    try std.testing.expectEqual(@as(?square.Square, null), pos.en_passant);
    try std.testing.expectEqual(zobrist_check.hashPosition(&pos), after_e4);
    const shuffle = [_][2]square.Square{ .{ .g8, .f6 }, .{ .g1, .f3 }, .{ .f6, .g8 }, .{ .f3, .g1 } };
    for (shuffle, 1..) |pair, i| {
        const mv = try findLegalMoveBySpec(&pos, pair[0], pair[1], .quiet);
        _ = makeMove(&pos, mv, &states[i]);
    }
    try std.testing.expectEqual(after_e4, pos.zobrist_key);
    try std.testing.expectEqual(pos.zobrist_key, (try fen.parse("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 4 3")).zobrist_key);

    // An enemy pawn beside the pushed pawn: the target is real, both colours.
    var white_push = try fen.parse("4k3/8/8/8/3p4/8/4P3/4K3 w - - 0 1");
    var state = StateInfo{};
    const key = makeMove(&white_push, try findLegalMoveBySpec(&white_push, .e2, .e4, .double_push), &state);
    try std.testing.expectEqual(@as(?square.Square, .e3), white_push.en_passant);
    try std.testing.expectEqual(zobrist_check.hashPosition(&white_push), key);
    var black_push = try fen.parse("4k3/2p5/8/1P6/8/8/8/4K3 b - - 0 1");
    _ = makeMove(&black_push, try findLegalMoveBySpec(&black_push, .c7, .c5, .double_push), &state);
    try std.testing.expectEqual(@as(?square.Square, .c6), black_push.en_passant);
    try std.testing.expectEqual(zobrist_check.hashPosition(&black_push), black_push.zobrist_key);
}

test "prefetch key matches the made key for double pushes" {
    const fen = @import("../core/fen.zig");
    for ([_][]const u8{ "4k3/8/8/8/3p4/8/4P3/4K3 w - - 0 1", "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", "4k3/2p5/8/1P6/8/8/8/4K3 b - - 0 1", "4k3/2p5/8/8/8/8/8/4K3 b - - 0 1" }) |fen_text| {
        var pos = try fen.parse(fen_text);
        var list = move_mod.MoveList.init();
        @import("legal.zig").generate(&pos, &list);
        for (list.slice()) |mv| {
            if (mv.flag != .double_push) continue;
            const hinted = prefetchKeyAfter(&pos, mv);
            var state = StateInfo{};
            try std.testing.expectEqual(hinted, makeMove(&pos, mv, &state));
            unmakeMove(&pos, mv, &state);
        }
    }
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

test "prefetchKeyAfter matches makeMove on quiet moves, captures and double pushes" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    var list = move_mod.MoveList.init();
    @import("legal.zig").generate(&pos, &list);
    var checked: usize = 0;
    for (list.slice()) |mv| {
        switch (mv.flag) {
            .quiet, .capture, .double_push => {},
            else => continue,
        }
        const moving = pos.pieceAt(mv.from);
        if (moving == .white_king or moving == .white_rook) continue;
        if (pos.pieceAt(mv.to) == .black_rook) continue;
        const predicted = prefetchKeyAfter(&pos, mv);
        var state: StateInfo = .{};
        const actual = makeMove(&pos, mv, &state);
        unmakeMove(&pos, mv, &state);
        try std.testing.expectEqual(actual, predicted);
        checked += 1;
    }
    try std.testing.expect(checked > 20);
}
