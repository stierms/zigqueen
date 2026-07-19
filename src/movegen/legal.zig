const std = @import("std");
const attacks = @import("attacks.zig");
const bitboard = @import("../core/bitboard.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const pseudo = @import("pseudo_legal.zig");
const make_unmake = @import("make_unmake.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

pub fn isSquareAttacked(pos: *const position.Position, target: square.Square, by: types.Color) bool {
    return attacks.isSquareAttacked(pos, target, by);
}

pub fn isInCheck(pos: *const position.Position, color: types.Color) bool {
    return attacks.isInCheck(pos, color);
}

const PinDirection = enum(u3) {
    north,
    south,
    east,
    west,
    north_east,
    north_west,
    south_east,
    south_west,
};

const PIN_RAYS = initPinRays();
const PIN_ROOK_RAYS = initPinRookRays();
const PIN_BISHOP_RAYS = initPinBishopRays();

const LegalityContext = struct {
    side: types.Color,
    opponent: types.Color,
    occupied: bitboard.Bitboard,
    opponent_pawns: bitboard.Bitboard,
    opponent_knights: bitboard.Bitboard,
    opponent_bishops: bitboard.Bitboard,
    opponent_rooks: bitboard.Bitboard,
    opponent_queens: bitboard.Bitboard,
    opponent_king: bitboard.Bitboard,
    king_square: square.Square,
    king_mask: bitboard.Bitboard,
    in_check: bool,
    pinned: bitboard.Bitboard,
};

pub fn generate(pos: *const position.Position, list: *move_mod.MoveList) void {
    generateHinted(pos, list, null);
}

/// `generate` with the caller's already-known in-check status (search computes
/// isInCheck at every node BEFORE generating). `known_in_check` must equal
/// `isInCheck(pos, pos.side_to_move)` when non-null — the context then skips
/// recomputing the same attack query. Behavior-identical either way.
pub fn generateHinted(pos: *const position.Position, list: *move_mod.MoveList, known_in_check: ?bool) void {
    pseudo.generate(pos, list);
    if (list.count == 0) return;
    var ctx: LegalityContext = undefined;
    initLegalityContext(pos, known_in_check, &ctx);
    if (!ctx.in_check and ctx.pinned == 0) {
        if (pos.en_passant == null and !pos.castling_rights.hasAny()) {
            filterGeneratedNoPinsNoSpecial(pos, list, &ctx, false);
        } else {
            filterGeneratedNoPins(pos, list, &ctx, false);
        }
        return;
    }

    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < list.count) : (read_index += 1) {
        const mv = list.moves[read_index];
        if (std.debug.runtime_safety) {
            const moving_piece = pos.pieceAt(mv.from);
            std.debug.assert(moving_piece != .none);
            std.debug.assert(moving_piece.color().? == pos.side_to_move);
        }
        switch (legalityDispositionGenerated(mv, &ctx)) {
            .accept => {},
            .reject => continue,
            .needs_full_check => {
                const moving_type = pos.pieceAt(mv.from).pieceType();
                if (!isLegalPseudoMove(pos, mv, moving_type, &ctx)) continue;
            },
        }
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

pub fn generateCapturesAndPromotions(pos: *const position.Position, list: *move_mod.MoveList) void {
    generateCapturesAndPromotionsHinted(pos, list, null);
}

/// See `generateHinted` for the `known_in_check` contract.
pub fn generateCapturesAndPromotionsHinted(pos: *const position.Position, list: *move_mod.MoveList, known_in_check: ?bool) void {
    pseudo.generateTactical(pos, list);
    if (list.count == 0) return;
    var ctx: LegalityContext = undefined;
    initLegalityContext(pos, known_in_check, &ctx);
    if (!ctx.in_check and ctx.pinned == 0) {
        if (pos.en_passant == null) {
            filterGeneratedNoPinsNoSpecial(pos, list, &ctx, true);
        } else {
            filterGeneratedNoPins(pos, list, &ctx, true);
        }
        return;
    }

    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < list.count) : (read_index += 1) {
        const mv = list.moves[read_index];
        if (std.debug.runtime_safety) {
            const moving_piece = pos.pieceAt(mv.from);
            std.debug.assert(moving_piece != .none);
            std.debug.assert(moving_piece.color().? == pos.side_to_move);
            std.debug.assert(mv.isCapture() or mv.isPromotion());
        }
        switch (legalityDispositionGenerated(mv, &ctx)) {
            .accept => {},
            .reject => continue,
            .needs_full_check => {
                const moving_type = pos.pieceAt(mv.from).pieceType();
                if (!isLegalPseudoMove(pos, mv, moving_type, &ctx)) continue;
            },
        }
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

/// Legal quiet checking moves (direct checks only; see pseudo.generateQuietChecks).
pub fn generateQuietChecks(pos: *const position.Position, list: *move_mod.MoveList) void {
    generateQuietChecksHinted(pos, list, null);
}

/// See `generateHinted` for the `known_in_check` contract.
pub fn generateQuietChecksHinted(pos: *const position.Position, list: *move_mod.MoveList, known_in_check: ?bool) void {
    pseudo.generateQuietChecks(pos, list);
    if (list.count == 0) return;
    var ctx: LegalityContext = undefined;
    initLegalityContext(pos, known_in_check, &ctx);
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < list.count) : (read_index += 1) {
        const mv = list.moves[read_index];
        switch (legalityDispositionGenerated(mv, &ctx)) {
            .accept => {},
            .reject => continue,
            .needs_full_check => {
                const moving_type = pos.pieceAt(mv.from).pieceType();
                if (!isLegalPseudoMove(pos, mv, moving_type, &ctx)) continue;
            },
        }
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

/// Exact check predicate from attack geometry: does `mv` — a LEGAL move for
/// `pos.side_to_move` — give check to the opponent? Bit-identical to the
/// make/isInCheck/unmake oracle without mutating the position: build the
/// post-move occupancy and the mover's post-move piece bitboards with mask
/// ops, then run the standard is-square-attacked query against the enemy king
/// square. One query covers BOTH check kinds at once, because the slider legs
/// run over the TRUE post-move occupancy against the FULL post-move slider
/// sets:
///   - direct checks: the arrival square attacks the king under post-move
///     occupancy (including the castling rook's FINAL square and the promoted
///     piece's new type);
///   - discovered checks: vacating `from` (and, for en passant, the captured
///     pawn's square — BOTH emptied squares can open a ray) unblocks a slider
///     already aimed at the king.
/// Captured enemy pieces need no bitboard fixup: they cannot check their own
/// king, and their square stays occupied by the arriving piece in every case
/// except en passant, which is handled explicitly. The mover's king is passed
/// as empty — a king never delivers check, and after any LEGAL move the kings
/// are never adjacent.
pub fn givesCheck(pos: *const position.Position, mv: move_mod.Move) bool {
    const side = pos.side_to_move;
    const enemy_king_sq = pos.kingSquare(side.other()) orelse return false;

    const from_mask = bitboard.bit(mv.from);
    const to_mask = bitboard.bit(mv.to);

    var occupied = (pos.occupancy() & ~from_mask) | to_mask;
    var pawns = pos.pieceBitboard(side, .pawn);
    var knights = pos.pieceBitboard(side, .knight);
    var bishops = pos.pieceBitboard(side, .bishop);
    var rooks = pos.pieceBitboard(side, .rook);
    var queens = pos.pieceBitboard(side, .queen);

    switch (mv.flag) {
        .quiet, .double_push, .capture => {
            const delta = from_mask | to_mask;
            switch (pos.pieceAt(mv.from).pieceType()) {
                .pawn => pawns ^= delta,
                .knight => knights ^= delta,
                .bishop => bishops ^= delta,
                .rook => rooks ^= delta,
                .queen => queens ^= delta,
                .king => {}, // king moves can only check by discovery
                .none => unreachable,
            }
        },
        .en_passant => {
            occupied &= ~bitboard.bit(enPassantCapturedPawnSquare(side, mv.to));
            pawns ^= from_mask | to_mask;
        },
        .castle => {
            // mv.to is the KING destination; the rook hop derives from it.
            const rook_move = castleRookMove(side, mv.to);
            const rook_delta = bitboard.bit(rook_move.from) | bitboard.bit(rook_move.to);
            occupied ^= rook_delta;
            rooks ^= rook_delta;
        },
        .promo_knight,
        .promo_bishop,
        .promo_rook,
        .promo_queen,
        .promo_knight_capture,
        .promo_bishop_capture,
        .promo_rook_capture,
        .promo_queen_capture,
        => {
            pawns &= ~from_mask;
            switch (mv.promotionPieceType().?) {
                .knight => knights |= to_mask,
                .bishop => bishops |= to_mask,
                .rook => rooks |= to_mask,
                .queen => queens |= to_mask,
                else => unreachable,
            }
        },
    }

    return attacks.isSquareAttackedByBitboards(
        enemy_king_sq,
        side,
        occupied,
        pawns,
        knights,
        bishops,
        rooks,
        queens,
        0, // mover's king: never a checker (see doc comment)
    );
}

fn filterGeneratedNoPins(pos: *const position.Position, list: *move_mod.MoveList, ctx: *const LegalityContext, comptime tactical_only: bool) void {
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < list.count) : (read_index += 1) {
        const mv = list.moves[read_index];
        if (std.debug.runtime_safety) {
            const moving_piece = pos.pieceAt(mv.from);
            std.debug.assert(moving_piece != .none);
            std.debug.assert(moving_piece.color().? == pos.side_to_move);
            if (tactical_only) std.debug.assert(mv.isCapture() or mv.isPromotion());
        }
        if (capturesOpponentKing(mv, ctx)) continue;
        if (mv.from == ctx.king_square or mv.flag == .en_passant or mv.flag == .castle) {
            const moving_type: piece.PieceType = if (mv.from == ctx.king_square) .king else pos.pieceAt(mv.from).pieceType();
            if (!isLegalPseudoMove(pos, mv, moving_type, ctx)) continue;
        }
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

fn filterGeneratedNoPinsNoSpecial(pos: *const position.Position, list: *move_mod.MoveList, ctx: *const LegalityContext, comptime tactical_only: bool) void {
    // No ep, no castling, no pins, not in check: the ONLY moves that can be
    // illegal are king steps into an attacked square. Batch those: build the
    // opponent's attack map (with our king removed from occupancy, once,
    // lazily) and test each king destination with one AND — replaces a full
    // isSquareAttackedByBitboards per king move, which was ~3.9% of endgame
    // samples. Exact: occupancy AT a destination never blocks attacks TO it
    // and a captured piece never attacks its own square, so per-move occupancy
    // fixups (to-bit set, captured piece removed) cannot change the verdict.
    var king_unsafe: bitboard.Bitboard = 0;
    var king_unsafe_ready = false;
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < list.count) : (read_index += 1) {
        const mv = list.moves[read_index];
        if (std.debug.runtime_safety) {
            const moving_piece = pos.pieceAt(mv.from);
            std.debug.assert(moving_piece != .none);
            std.debug.assert(moving_piece.color().? == pos.side_to_move);
            if (tactical_only) std.debug.assert(mv.isCapture() or mv.isPromotion());
        }
        if (capturesOpponentKing(mv, ctx)) continue;
        if (mv.from == ctx.king_square) {
            if (!king_unsafe_ready) {
                king_unsafe = opponentAttacksKingRemoved(ctx);
                king_unsafe_ready = true;
            }
            if ((bitboard.bit(mv.to) & king_unsafe) != 0) continue;
        }
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

/// Every square attacked by the opponent with OUR king removed from occupancy
/// (x-ray through the king counts, exactly like the per-move query's
/// `occupied & ~from_mask` for king moves). Built from the context's cached
/// bitboards only.
fn opponentAttacksKingRemoved(ctx: *const LegalityContext) bitboard.Bitboard {
    const occ = ctx.occupied & ~ctx.king_mask;
    var attacked = attacks.pawnAttacks(ctx.opponent, ctx.opponent_pawns);
    var knights = ctx.opponent_knights;
    while (bitboard.popLsb(&knights)) |sq| attacked |= attacks.knightAttacks(sq);
    var bishop_like = ctx.opponent_bishops | ctx.opponent_queens;
    while (bitboard.popLsb(&bishop_like)) |sq| attacked |= attacks.bishopAttacks(sq, occ);
    var rook_like = ctx.opponent_rooks | ctx.opponent_queens;
    while (bitboard.popLsb(&rook_like)) |sq| attacked |= attacks.rookAttacks(sq, occ);
    var opp_king = ctx.opponent_king;
    while (bitboard.popLsb(&opp_king)) |sq| attacked |= attacks.kingAttacks(sq);
    return attacked;
}

pub fn isLegalMove(pos: *const position.Position, mv: move_mod.Move) bool {
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return false;
    if (moving_piece.color().? != pos.side_to_move) return false;
    if (!isPseudoLegalMove(pos, mv)) return false;

    var ctx: LegalityContext = undefined;
    initLegalityContext(pos, null, &ctx);
    const moving_type = moving_piece.pieceType();
    return switch (legalityDisposition(mv, moving_type, &ctx)) {
        .accept => true,
        .reject => false,
        .needs_full_check => isLegalPseudoMove(pos, mv, moving_type, &ctx),
    };
}

pub fn playMoveCopy(pos: *const position.Position, mv: move_mod.Move) position.Position {
    var next = pos.*;
    make_unmake.makeMoveForLegality(&next, mv);
    return next;
}

fn isPseudoLegalMove(pos: *const position.Position, target: move_mod.Move) bool {
    var pseudo_moves = move_mod.MoveList.init();
    pseudo.generate(pos, &pseudo_moves);
    for (pseudo_moves.slice()) |mv| {
        if (mv == target) return true;
    }
    return false;
}

inline fn isLegalPseudoMove(pos: *const position.Position, mv: move_mod.Move, moving_type: piece.PieceType, ctx: *const LegalityContext) bool {
    const from_mask = bitboard.bit(mv.from);
    const to_mask = bitboard.bit(mv.to);

    var occupied = ctx.occupied & ~from_mask;
    var opponent_pawns = ctx.opponent_pawns;
    var opponent_knights = ctx.opponent_knights;
    var opponent_bishops = ctx.opponent_bishops;
    var opponent_rooks = ctx.opponent_rooks;
    var opponent_queens = ctx.opponent_queens;
    var opponent_king = ctx.opponent_king;
    var king_square = if (moving_type == .king) mv.to else ctx.king_square;

    switch (mv.flag) {
        .quiet, .double_push => occupied |= to_mask,
        .capture => {
            const captured_piece = pos.pieceAt(mv.to);
            std.debug.assert(captured_piece != .none);
            removeCapturedFromBitboards(
                &opponent_pawns,
                &opponent_knights,
                &opponent_bishops,
                &opponent_rooks,
                &opponent_queens,
                &opponent_king,
                captured_piece,
                mv.to,
            );
            occupied |= to_mask;
        },
        .en_passant => {
            const capture_square = enPassantCapturedPawnSquare(ctx.side, mv.to);
            const capture_mask = bitboard.bit(capture_square);
            opponent_pawns &= ~capture_mask;
            occupied &= ~capture_mask;
            occupied |= to_mask;
        },
        .castle => {
            occupied |= to_mask;
            const rook_move = castleRookMove(ctx.side, mv.to);
            occupied &= ~bitboard.bit(rook_move.from);
            occupied |= bitboard.bit(rook_move.to);
            king_square = mv.to;
        },
        .promo_knight, .promo_bishop, .promo_rook, .promo_queen => occupied |= to_mask,
        .promo_knight_capture, .promo_bishop_capture, .promo_rook_capture, .promo_queen_capture => {
            const captured_piece = pos.pieceAt(mv.to);
            std.debug.assert(captured_piece != .none);
            removeCapturedFromBitboards(
                &opponent_pawns,
                &opponent_knights,
                &opponent_bishops,
                &opponent_rooks,
                &opponent_queens,
                &opponent_king,
                captured_piece,
                mv.to,
            );
            occupied |= to_mask;
        },
    }

    return !attacks.isSquareAttackedByBitboards(
        king_square,
        ctx.opponent,
        occupied,
        opponent_pawns,
        opponent_knights,
        opponent_bishops,
        opponent_rooks,
        opponent_queens,
        opponent_king,
    );
}

const LegalityDisposition = enum {
    accept,
    reject,
    needs_full_check,
};

inline fn legalityDisposition(mv: move_mod.Move, moving_type: piece.PieceType, ctx: *const LegalityContext) LegalityDisposition {
    if (capturesOpponentKing(mv, ctx)) return .reject;
    if (ctx.in_check) return .needs_full_check;
    if (moving_type == .king) return .needs_full_check;
    if (mv.flag == .en_passant or mv.flag == .castle) return .needs_full_check;
    return legalityDispositionPinned(mv, ctx);
}

inline fn legalityDispositionGenerated(mv: move_mod.Move, ctx: *const LegalityContext) LegalityDisposition {
    if (capturesOpponentKing(mv, ctx)) return .reject;
    if (ctx.in_check) return .needs_full_check;
    const from_mask = bitboard.bit(mv.from);
    const flag = mv.flag;
    if (flag != .en_passant and flag != .castle and (from_mask & (ctx.pinned | ctx.king_mask)) == 0) return .accept;
    if ((from_mask & ctx.king_mask) != 0) return .needs_full_check;
    if (flag == .en_passant or flag == .castle) return .needs_full_check;
    return legalityDispositionPinnedFromMask(mv, ctx, from_mask);
}

inline fn legalityDispositionPinned(mv: move_mod.Move, ctx: *const LegalityContext) LegalityDisposition {
    return legalityDispositionPinnedFromMask(mv, ctx, bitboard.bit(mv.from));
}

inline fn capturesOpponentKing(mv: move_mod.Move, ctx: *const LegalityContext) bool {
    return (bitboard.bit(mv.to) & ctx.opponent_king) != 0;
}

inline fn legalityDispositionPinnedFromMask(mv: move_mod.Move, ctx: *const LegalityContext, from_mask: bitboard.Bitboard) LegalityDisposition {
    if ((ctx.pinned & from_mask) == 0) return .accept;
    if (moveStaysOnPinLine(ctx.king_square, mv.from, mv.to)) return .accept;
    return .reject;
}

inline fn moveStaysOnPinLine(king_square: square.Square, from: square.Square, to: square.Square) bool {
    return isCollinear(king_square, from, to);
}

inline fn isCollinear(a: square.Square, b: square.Square, c: square.Square) bool {
    if (a.file() == b.file() and b.file() == c.file()) return true;
    if (a.rank() == b.rank() and b.rank() == c.rank()) return true;

    const af: i8 = @intCast(a.file());
    const ar: i8 = @intCast(a.rank());
    const bf: i8 = @intCast(b.file());
    const br: i8 = @intCast(b.rank());
    const cf: i8 = @intCast(c.file());
    const cr: i8 = @intCast(c.rank());

    return (af - ar == bf - br and bf - br == cf - cr) or
        (af + ar == bf + br and bf + br == cf + cr);
}

/// Fills `ctx` through an out-pointer instead of returning by value: the sret
/// return built the struct with scalar stores in a local temp and immediately
/// re-copied it with 64-byte vector loads — a store-forward stall that was 82%
/// of this function's samples in the endgame profile. `known_in_check`, when
/// non-null, must equal `isInCheck(pos, pos.side_to_move)` and skips the
/// duplicate attack query (search already computed it for the node).
fn initLegalityContext(pos: *const position.Position, known_in_check: ?bool, ctx: *LegalityContext) void {
    switch (pos.side_to_move) {
        .white => initLegalityContextFor(.white, pos, known_in_check, ctx),
        .black => initLegalityContextFor(.black, pos, known_in_check, ctx),
    }
}

fn initLegalityContextFor(comptime side: types.Color, pos: *const position.Position, known_in_check: ?bool, ctx: *LegalityContext) void {
    const opponent = side.other();
    const occupied = pos.occupancy();
    const opponent_pawns = pos.pieceBitboard(opponent, .pawn);
    const opponent_knights = pos.pieceBitboard(opponent, .knight);
    const opponent_bishops = pos.pieceBitboard(opponent, .bishop);
    const opponent_rooks = pos.pieceBitboard(opponent, .rook);
    const opponent_queens = pos.pieceBitboard(opponent, .queen);
    const opponent_king = pos.pieceBitboard(opponent, .king);
    const king_square = pos.kingSquare(side).?;
    const in_check = known_in_check orelse attacks.isSquareAttackedByBitboards(
        king_square,
        opponent,
        occupied,
        opponent_pawns,
        opponent_knights,
        opponent_bishops,
        opponent_rooks,
        opponent_queens,
        opponent_king,
    );

    ctx.* = .{
        .side = side,
        .opponent = opponent,
        .occupied = occupied,
        .opponent_pawns = opponent_pawns,
        .opponent_knights = opponent_knights,
        .opponent_bishops = opponent_bishops,
        .opponent_rooks = opponent_rooks,
        .opponent_queens = opponent_queens,
        .opponent_king = opponent_king,
        .king_square = king_square,
        .king_mask = bitboard.bit(king_square),
        .in_check = in_check,
        .pinned = if (in_check) 0 else computePinnedPieces(
            occupied,
            pos.occupancyFor(side),
            opponent_bishops | opponent_queens,
            opponent_rooks | opponent_queens,
            king_square,
        ),
    };
}

fn computePinnedPieces(
    occupied: bitboard.Bitboard,
    own_occ: bitboard.Bitboard,
    enemy_bishop_like: bitboard.Bitboard,
    enemy_rook_like: bitboard.Bitboard,
    king_square: square.Square,
) bitboard.Bitboard {
    const king_index = king_square.index();
    var pinned: bitboard.Bitboard = 0;
    if ((enemy_rook_like & PIN_ROOK_RAYS[king_index]) != 0) {
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_rook_like, king_index, .east);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_rook_like, king_index, .west);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_rook_like, king_index, .north);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_rook_like, king_index, .south);
    }
    if ((enemy_bishop_like & PIN_BISHOP_RAYS[king_index]) != 0) {
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_bishop_like, king_index, .north_east);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_bishop_like, king_index, .north_west);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_bishop_like, king_index, .south_east);
        pinned |= pinnedAlongRay(occupied, own_occ, enemy_bishop_like, king_index, .south_west);
    }
    return pinned;
}

inline fn pinnedAlongRay(
    occupied: bitboard.Bitboard,
    own_occ: bitboard.Bitboard,
    enemy_sliders: bitboard.Bitboard,
    king_index: u6,
    comptime direction: PinDirection,
) bitboard.Bitboard {
    const blockers = PIN_RAYS[king_index][@intFromEnum(direction)] & occupied;
    if (blockers == 0) return 0;

    const candidate = firstBlocker(blockers, direction);
    const candidate_mask = bitboard.bit(candidate);
    if ((own_occ & candidate_mask) == 0) return 0;

    const beyond_candidate = PIN_RAYS[candidate.index()][@intFromEnum(direction)] & occupied;
    if (beyond_candidate == 0) return 0;
    const pinner = firstBlocker(beyond_candidate, direction);
    return if ((enemy_sliders & bitboard.bit(pinner)) != 0) candidate_mask else 0;
}

inline fn firstBlocker(blockers: bitboard.Bitboard, comptime direction: PinDirection) square.Square {
    return switch (direction) {
        .north, .east, .north_east, .north_west => bitboard.lsb(blockers).?,
        .south, .west, .south_east, .south_west => bitboard.msb(blockers).?,
    };
}

fn initPinRays() [64][8]bitboard.Bitboard {
    @setEvalBranchQuota(20_000);
    var table = [_][8]bitboard.Bitboard{[_]bitboard.Bitboard{0} ** 8} ** 64;
    for (0..64) |idx| {
        const from = square.Square.fromIndex(@intCast(idx));
        table[idx][@intFromEnum(PinDirection.north)] = rayMask(from, 0, 1);
        table[idx][@intFromEnum(PinDirection.south)] = rayMask(from, 0, -1);
        table[idx][@intFromEnum(PinDirection.east)] = rayMask(from, 1, 0);
        table[idx][@intFromEnum(PinDirection.west)] = rayMask(from, -1, 0);
        table[idx][@intFromEnum(PinDirection.north_east)] = rayMask(from, 1, 1);
        table[idx][@intFromEnum(PinDirection.north_west)] = rayMask(from, -1, 1);
        table[idx][@intFromEnum(PinDirection.south_east)] = rayMask(from, 1, -1);
        table[idx][@intFromEnum(PinDirection.south_west)] = rayMask(from, -1, -1);
    }
    return table;
}

fn initPinRookRays() [64]bitboard.Bitboard {
    var table = [_]bitboard.Bitboard{0} ** 64;
    for (0..64) |idx| {
        table[idx] = PIN_RAYS[idx][@intFromEnum(PinDirection.north)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.south)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.east)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.west)];
    }
    return table;
}

fn initPinBishopRays() [64]bitboard.Bitboard {
    var table = [_]bitboard.Bitboard{0} ** 64;
    for (0..64) |idx| {
        table[idx] = PIN_RAYS[idx][@intFromEnum(PinDirection.north_east)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.north_west)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.south_east)] |
            PIN_RAYS[idx][@intFromEnum(PinDirection.south_west)];
    }
    return table;
}

fn rayMask(from: square.Square, file_delta: i8, rank_delta: i8) bitboard.Bitboard {
    var file: i8 = @intCast(from.file());
    var rank: i8 = @intCast(from.rank());
    var mask: bitboard.Bitboard = 0;
    while (true) {
        file += file_delta;
        rank += rank_delta;
        if (file < 0 or file >= 8 or rank < 0 or rank >= 8) break;
        mask |= bitboard.bit(square.Square.fromCoords(@intCast(file), @intCast(rank)));
    }
    return mask;
}

const CastleRookMove = struct {
    from: square.Square,
    to: square.Square,
};

fn castleRookMove(side: types.Color, king_destination: square.Square) CastleRookMove {
    return switch (side) {
        .white => switch (king_destination) {
            .g1 => .{ .from = .h1, .to = .f1 },
            .c1 => .{ .from = .a1, .to = .d1 },
            else => unreachable,
        },
        .black => switch (king_destination) {
            .g8 => .{ .from = .h8, .to = .f8 },
            .c8 => .{ .from = .a8, .to = .d8 },
            else => unreachable,
        },
    };
}

fn enPassantCapturedPawnSquare(side: types.Color, destination: square.Square) square.Square {
    return switch (side) {
        .white => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) - 1)),
        .black => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) + 1)),
    };
}

fn removeCapturedFromBitboards(
    pawns: *bitboard.Bitboard,
    knights: *bitboard.Bitboard,
    bishops: *bitboard.Bitboard,
    rooks: *bitboard.Bitboard,
    queens: *bitboard.Bitboard,
    kings: *bitboard.Bitboard,
    captured_piece: piece.Piece,
    sq: square.Square,
) void {
    const mask = ~bitboard.bit(sq);
    switch (captured_piece.pieceType()) {
        .pawn => pawns.* &= mask,
        .knight => knights.* &= mask,
        .bishop => bishops.* &= mask,
        .rook => rooks.* &= mask,
        .queen => queens.* &= mask,
        .king => kings.* &= mask,
        .none => unreachable,
    }
}

fn testContainsMove(list: *const move_mod.MoveList, target: move_mod.Move) bool {
    for (list.slice()) |mv| {
        if (mv == target) return true;
    }
    return false;
}

test "start position has 20 legal moves" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.startpos();
    var list = move_mod.MoveList.init();
    generate(&pos, &list);
    try std.testing.expectEqual(@as(usize, 20), list.count);
}

test "legal generator rejects pseudo captures of the opponent king" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("6k1/5Q2/6K1/8/8/8/8/8 w - - 0 1");

    var legal_moves = move_mod.MoveList.init();
    generate(&pos, &legal_moves);
    try std.testing.expect(!testContainsMove(&legal_moves, move_mod.Move.init(.f7, .g8, .capture)));

    var tactical_moves = move_mod.MoveList.init();
    generateCapturesAndPromotions(&pos, &tactical_moves);
    try std.testing.expect(!testContainsMove(&tactical_moves, move_mod.Move.init(.f7, .g8, .capture)));
}

test "legal generator filters pinned rook moves that expose king" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1");
    var list = move_mod.MoveList.init();
    generate(&pos, &list);

    for (list.slice()) |mv| {
        try std.testing.expect(!(mv.from == .e2 and mv.to == .d2));
    }
}

test "en passant legality rejects discovered self-check" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    var list = move_mod.MoveList.init();
    generate(&pos, &list);

    for (list.slice()) |mv| {
        try std.testing.expect(!(mv.from == .e5 and mv.to == .d6 and mv.flag == .en_passant));
    }
}

test "playMoveCopy handles castling rook relocation" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    const next = playMoveCopy(&pos, move_mod.Move.init(.e1, .g1, .castle));

    try std.testing.expectEqual(piece.Piece.white_king, next.pieceAt(.g1));
    try std.testing.expectEqual(piece.Piece.white_rook, next.pieceAt(.f1));
    try std.testing.expectEqual(piece.Piece.none, next.pieceAt(.e1));
    try std.testing.expectEqual(piece.Piece.none, next.pieceAt(.h1));
}

fn isLegalMoveReference(pos: *const position.Position, mv: move_mod.Move) bool {
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return false;
    if (moving_piece.color().? != pos.side_to_move) return false;

    const next = playMoveCopy(pos, mv);
    return !isInCheck(&next, pos.side_to_move);
}

fn generateReference(pos: *const position.Position, list: *move_mod.MoveList) void {
    var pseudo_moves = move_mod.MoveList.init();
    pseudo.generate(pos, &pseudo_moves);

    list.clear();
    for (pseudo_moves.slice()) |mv| {
        if (isLegalMoveReference(pos, mv)) list.add(mv);
    }
}

test "optimized legal generation matches reference ordering on representative positions" {
    const fen = @import("../core/fen.zig");
    const fens = [_][]const u8{
        "rn1qkbnr/pbpppppp/8/1p6/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
        "4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1",
        // No-pins/no-special king-map path: x-ray retreat along the attacker's
        // ray, a defended capture, and plain endgame king walks.
        "4k3/8/8/8/r3K3/8/8/8 w - - 0 1",
        "4k3/8/5b2/8/3q4/4K3/8/8 w - - 0 1",
        "8/2k5/3p4/p2P1p2/P2P1P2/8/8/4K3 w - - 0 1",
        "8/8/4k3/8/4K3/8/8/8 w - - 0 1",
    };

    for (fens) |fen_text| {
        var pos = try fen.parse(fen_text);
        var actual = move_mod.MoveList.init();
        var expected = move_mod.MoveList.init();
        generate(&pos, &actual);
        generateReference(&pos, &expected);

        try std.testing.expectEqual(expected.count, actual.count);
        for (expected.slice(), 0..) |mv, idx| {
            try std.testing.expectEqual(mv, actual.slice()[idx]);
        }
    }
}

test "tactical legal generation matches filtered full legal moves on representative positions" {
    const fen = @import("../core/fen.zig");
    const fens = [_][]const u8{
        fen.STARTPOS_FEN,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "4k3/P7/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    };

    for (fens) |fen_text| {
        var pos = try fen.parse(fen_text);
        try std.testing.expect(!isInCheck(&pos, pos.side_to_move));

        var actual = move_mod.MoveList.init();
        var full = move_mod.MoveList.init();
        generateCapturesAndPromotions(&pos, &actual);
        generate(&pos, &full);

        var expected = move_mod.MoveList.init();
        for (full.slice()) |mv| {
            if (mv.isCapture() or mv.isPromotion()) expected.add(mv);
        }

        try std.testing.expectEqual(expected.count, actual.count);
        for (actual.slice()) |mv| {
            try std.testing.expect(mv.isCapture() or mv.isPromotion());
        }
        for (expected.slice(), 0..) |mv, idx| {
            try std.testing.expectEqual(mv, actual.slice()[idx]);
        }
    }
}

test "generateQuietChecks: every move is a legal quiet direct check" {
    const fen = @import("../core/fen.zig");
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "3k4/8/8/8/8/8/4R3/3K4 w - - 0 1",
        "4k3/8/8/3q4/8/5N2/3P4/3K4 b - - 0 1",
        "8/3k4/1p1p2p1/pP1P2Pp/P2K3P/8/4N3/8 w - - 0 1",
    };
    for (fens) |f| {
        var pos = try fen.parse(f);
        var checks = move_mod.MoveList.init();
        generateQuietChecks(&pos, &checks);
        var all = move_mod.MoveList.init();
        generate(&pos, &all);
        for (checks.slice()) |mv| {
            // quiet flag only
            try std.testing.expect(mv.flag == .quiet or mv.flag == .double_push);
            // present in the full legal list
            var found = false;
            for (all.slice()) |lm| {
                if (lm == mv) found = true;
            }
            try std.testing.expect(found);
            // actually gives check
            var state: make_unmake.StateInfo = undefined;
            _ = make_unmake.makeMove(&pos, mv, &state);
            const gives = isInCheck(&pos, pos.side_to_move);
            make_unmake.unmakeMove(&pos, mv, &state);
            try std.testing.expect(gives);
        }
    }
}

test "generateQuietChecks finds rook checks in a simple endgame" {
    const fen = @import("../core/fen.zig");
    var pos = try fen.parse("3k4/8/8/8/8/8/4R3/3K4 w - - 0 1");
    var checks = move_mod.MoveList.init();
    generateQuietChecks(&pos, &checks);
    // Re8+ (rank) and Rd2+ (file) at minimum
    try std.testing.expect(checks.count >= 2);
}

/// givesCheck must equal the make/isInCheck/unmake oracle for EVERY legal move.
fn expectGivesCheckMatchesOracle(pos: *position.Position) !void {
    var list = move_mod.MoveList.init();
    generate(pos, &list);
    for (list.slice()) |mv| {
        const predicted = givesCheck(pos, mv);
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(pos, mv, &state);
        const actual = isInCheck(pos, pos.side_to_move);
        make_unmake.unmakeMove(pos, mv, &state);
        if (predicted != actual) {
            var buf: [5]u8 = undefined;
            std.debug.print("givesCheck mismatch: move {s} predicted {} oracle {}\n", .{ mv.toUci(&buf), predicted, actual });
            return error.TestUnexpectedResult;
        }
    }
}

test "givesCheck matches make/unmake oracle on every legal move of a diverse suite" {
    const fen = @import("../core/fen.zig");
    const fens = [_][]const u8{
        // Broad middlegame / classic perft positions (castling, EP, promos, pins).
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R b KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        // Castling delivers check with the rook's FINAL square (all four flavors).
        "5k2/8/8/8/8/8/8/4K2R w K - 0 1",
        "3k4/8/8/8/8/8/8/R3K3 w Q - 0 1",
        "4k2r/8/8/8/8/8/8/5K2 b k - 0 1",
        "r3k3/8/8/8/8/8/8/3K4 b q - 0 1",
        // Castling available both sides, no check involved.
        "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
        "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
        // EP opens the captured pawn's file but the capturer RE-BLOCKS it on
        // d6 — must read as NO check.
        "3k4/8/8/3pP3/8/8/8/3RK3 w - d6 0 1",
        // EP discovered check through the CAPTURED pawn's square (a2-g8
        // diagonal opens at d5; the capturer lands off-ray on d6).
        "6k1/8/8/3pP3/8/8/B7/4K3 w - d6 0 1",
        // EP discovered check through the capturer's FROM square (diagonal ray).
        "7k/8/8/3pP3/8/8/1B6/4K3 w - d6 0 1",
        // EP horizontal discovery: BOTH vacated squares sit on the rook's rank.
        "8/8/8/R2pP2k/8/8/8/4K3 w - d6 0 1",
        // Same shape for black: exd3 e.p. opens h4-a4 through e4 AND d4.
        "8/8/8/8/K2Pp2r/8/8/6k1 b - d3 0 1",
        // EP capture that is itself a direct pawn check.
        "8/2k5/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "4k3/8/8/8/3Pp3/8/2K5/8 b - d3 0 1",
        // EP illegal by horizontal pin (other moves still exercised).
        "8/8/8/K2pP2q/8/8/8/6k1 w - d6 0 1",
        // Promotions: all four pieces, checking (Q/B hit d7) and non-checking.
        "8/3kP3/8/8/8/8/8/4K3 w - - 0 1",
        // Capture-promotions with check along rank 8 (Q/R) and without (N/B).
        "3n3k/4P3/8/8/8/8/8/4K3 w - - 0 1",
        // Pure DISCOVERED promotion check: b8=any vacates b7, opening Ra7-h7.
        "8/RP5k/8/8/8/8/8/4K3 w - - 0 1",
        // Capture-promotion with the same discovery.
        "2n5/RP5k/8/8/8/8/8/4K3 w - - 0 1",
        // Black capture-promotion along rank 1.
        "4k3/8/8/8/8/8/6p1/4K2R b K - 0 1",
        // Double check: Bf6+ is direct bishop + discovered rook on the d-file.
        "3k4/8/8/8/3B4/8/8/3RK3 w - - 0 1",
        // King move discovers its own rook's check.
        "4k3/8/8/8/8/8/4K3/4R3 w - - 0 1",
        // Slider direct checks on all rays, black to move.
        "3q3k/8/8/8/8/8/8/K7 b - - 0 1",
        // Knight checks (Nb3+/Nc2+ from d4), black to move.
        "k7/8/8/8/3n4/8/8/K7 b - - 0 1",
        // Pawn checks including a checking double push (d2-d4+).
        "8/8/8/4k3/8/8/3PK3/8 w - - 0 1",
        // Pinned rook: pin-restricted legal moves.
        "4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1",
        // Mover in check: evasions only (block, capture, king walk).
        "4k3/8/8/8/7b/8/8/4K3 w - - 0 1",
        // Endgame gate position + bare kings.
        "8/2k5/3p4/p2P1p2/P2P1P2/8/8/4K3 w - - 0 1",
        "8/8/4k3/8/4K3/8/8/8 w - - 0 1",
    };
    for (fens) |fen_text| {
        var pos = try fen.parse(fen_text);
        try expectGivesCheckMatchesOracle(&pos);
    }
}

fn walkGivesCheckEquivalence(pos: *position.Position, depth: usize) !void {
    var list = move_mod.MoveList.init();
    generate(pos, &list);
    for (list.slice()) |mv| {
        const predicted = givesCheck(pos, mv);
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(pos, mv, &state);
        const actual = isInCheck(pos, pos.side_to_move);
        if (predicted != actual) {
            make_unmake.unmakeMove(pos, mv, &state);
            var buf: [5]u8 = undefined;
            std.debug.print("givesCheck walk mismatch: move {s} predicted {} oracle {}\n", .{ mv.toUci(&buf), predicted, actual });
            return error.TestUnexpectedResult;
        }
        if (depth > 1) try walkGivesCheckEquivalence(pos, depth - 1);
        make_unmake.unmakeMove(pos, mv, &state);
    }
}

test "givesCheck matches oracle across a 3-ply walk of rich positions" {
    const fen = @import("../core/fen.zig");
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    };
    for (fens) |fen_text| {
        var pos = try fen.parse(fen_text);
        try walkGivesCheckEquivalence(&pos, 3);
    }
}
