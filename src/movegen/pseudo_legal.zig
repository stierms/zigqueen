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
    generatePawnMoves(side, pos, list, false, 0);
    generateLeaperMoves(side, pos, .knight, attacks.knightAttacksFrom, list, false, 0);
    generateSliderMoves(side, pos, .bishop, attacks.bishopAttacksOnTheFly, list, false, 0);
    generateSliderMoves(side, pos, .rook, attacks.rookAttacksOnTheFly, list, false, 0);
    generateSliderMoves(side, pos, .queen, attacks.queenAttacksOnTheFly, list, false, 0);
    generateLeaperMoves(side, pos, .king, attacks.kingAttacksFrom, list, false, 0);
    generateCastlingMoves(side, pos, list);
}

/// Legality-FUSED generation (perf-r8; pins, castling and en passant since
/// perf r3) for a side NOT in check. A pseudo-legal move can then be illegal
/// only as a capture of the enemy king (`enemy_king` is masked out of every
/// target set, the filter's `capturesOpponentKing` guard), a king step onto a
/// square the opponent attacks (`king_unsafe`: the opponent's attack map with
/// our king removed from occupancy; occupancy at a destination never blocks
/// attacks to it, and a captured piece never attacks its own square), a
/// pinned piece leaving its line through the king (it keeps only
/// `pin_lines[from]`, the squares the filter's collinearity test accepts), or
/// one of the two moves a mask cannot decide, en passant and castling, which
/// are emitted only when `special.allows` them (the filter's full per-move
/// check). So the caller no longer re-reads and re-packs the whole list, and
/// move CONTENT and ORDER are identical to generate-then-filter: every move
/// is emitted at its generator position or dropped exactly when the filter
/// drops it.
pub fn generateLegalPinned(
    pos: *const position.Position,
    list: *move_mod.MoveList,
    enemy_king: bitboard.Bitboard,
    king_unsafe: bitboard.Bitboard,
    pinned: bitboard.Bitboard,
    pin_lines: *const [64]bitboard.Bitboard,
    special: anytype,
) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateLegalPinnedFor(.white, pos, list, enemy_king, king_unsafe, pinned, pin_lines, special),
        .black => generateLegalPinnedFor(.black, pos, list, enemy_king, king_unsafe, pinned, pin_lines, special),
    }
}

fn generateLegalPinnedFor(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    enemy_king: bitboard.Bitboard,
    king_unsafe: bitboard.Bitboard,
    pinned: bitboard.Bitboard,
    pin_lines: *const [64]bitboard.Bitboard,
    special: anytype,
) void {
    generatePawnMovesPinned(side, pos, list, enemy_king, pinned, pin_lines, special);
    generatePieceMovesPinned(side, pos, .knight, list, enemy_king, pinned, pin_lines);
    generatePieceMovesPinned(side, pos, .bishop, list, enemy_king, pinned, pin_lines);
    generatePieceMovesPinned(side, pos, .rook, list, enemy_king, pinned, pin_lines);
    generatePieceMovesPinned(side, pos, .queen, list, enemy_king, pinned, pin_lines);
    generateLeaperMoves(side, pos, .king, attacks.kingAttacksFrom, list, true, enemy_king | king_unsafe);
    // generateCastlingMoves emits nothing without a right of the mover; the
    // test spares its in-check query.
    const rights: u4 = @bitCast(pos.castling_rights);
    const mover_rights: u4 = if (side == .white) 0b0011 else 0b1100;
    if ((rights & mover_rights) == 0) return;
    const before_castling = list.count;
    generateCastlingMoves(side, pos, list);
    var write_index = before_castling;
    for (list.moves[before_castling..list.count]) |mv| {
        if (!special.allows(mv)) continue;
        list.moves[write_index] = mv;
        write_index += 1;
    }
    list.count = write_index;
}

/// The squares a piece on `from` may move to: all when it is not pinned, its
/// line through the king when it is.
inline fn pinAllowed(pinned: bitboard.Bitboard, pin_lines: *const [64]bitboard.Bitboard, from: square.Square) bitboard.Bitboard {
    const index = @intFromEnum(from);
    return if (((pinned >> index) & 1) != 0) pin_lines[index] else ~@as(bitboard.Bitboard, 0);
}

/// `generatePawnMoves` with every push, double push, promotion and capture
/// target intersected with the pawn's pin mask, captures of the enemy king
/// dropped, and en passant emitted only when `special.allows` it. Same
/// per-pawn emission order.
fn generatePawnMovesPinned(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    enemy_king: bitboard.Bitboard,
    pinned: bitboard.Bitboard,
    pin_lines: *const [64]bitboard.Bitboard,
    special: anytype,
) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other()) & ~enemy_king;
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: u3 = if (side == .white) 1 else 6;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (pawns != 0) {
        const from = bitboard.popLsbUnchecked(&pawns);
        const file = from.file();
        const rank = from.rank();
        const allowed = pinAllowed(pinned, pin_lines, from);

        const one_step_rank_i: i8 = @as(i8, @intCast(rank)) + forward_delta;
        if (one_step_rank_i >= 0 and one_step_rank_i < 8) {
            const one_step = square.Square.fromCoords(file, @intCast(one_step_rank_i));
            if (!pos.isSquareOccupied(one_step)) {
                const one_step_allowed = (allowed & bitboard.bit(one_step)) != 0;
                if (rank == promotion_from_rank) {
                    if (one_step_allowed) addPromotions(list, from, one_step, false);
                } else {
                    if (one_step_allowed) list.add(move_mod.Move.init(from, one_step, .quiet));
                    if (rank == start_rank) {
                        const two_step_rank_i = one_step_rank_i + forward_delta;
                        if (two_step_rank_i >= 0 and two_step_rank_i < 8) {
                            const two_step = square.Square.fromCoords(file, @intCast(two_step_rank_i));
                            if (!pos.isSquareOccupied(two_step) and (allowed & bitboard.bit(two_step)) != 0) {
                                list.add(move_mod.Move.init(from, two_step, .double_push));
                            }
                        }
                    }
                }
            }
        }

        var capture_targets = attacks.pawnAttacksFrom(side, from) & opponent_occ & allowed;
        while (capture_targets != 0) {
            const to = bitboard.popLsbUnchecked(&capture_targets);
            if (rank == promotion_from_rank) {
                addPromotions(list, from, to, true);
            } else {
                list.add(move_mod.Move.init(from, to, .capture));
            }
        }

        if (pos.en_passant) |ep_square| {
            const ep_mask = bitboard.bit(ep_square);
            if ((attacks.pawnAttacksFrom(side, from) & ep_mask) != 0) {
                const mv = move_mod.Move.init(from, ep_square, .en_passant);
                if (special.allows(mv)) list.add(mv);
            }
        }
    }
}

/// `generateLeaperMoves` / `generateSliderMoves` (knight, bishop, rook,
/// queen) with each piece's targets intersected with its pin mask and the
/// enemy king dropped. A pinned knight keeps nothing (no knight step stays on
/// a line through its square).
fn generatePieceMovesPinned(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    list: *move_mod.MoveList,
    enemy_king: bitboard.Bitboard,
    pinned: bitboard.Bitboard,
    pin_lines: *const [64]bitboard.Bitboard,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const blocked = pos.occupancyFor(side) | enemy_king;
    const opp_occ = pos.occupancyFor(side.other());
    const occupied = pos.occupancy();

    while (pieces != 0) {
        const from = bitboard.popLsbUnchecked(&pieces);
        const reach = switch (piece_type) {
            .knight => attacks.knightAttacksFrom(from),
            .bishop => attacks.bishopAttacksOnTheFly(from, occupied),
            .rook => attacks.rookAttacksOnTheFly(from, occupied),
            .queen => attacks.queenAttacksOnTheFly(from, occupied),
            else => @compileError("pawns and kings have their own generators"),
        };
        var targets = reach & ~blocked & pinAllowed(pinned, pin_lines, from);
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            const flag: move_mod.MoveFlag = if ((opp_occ & bitboard.bit(to)) != 0) .capture else .quiet;
            list.add(move_mod.Move.init(from, to, flag));
        }
    }
}

/// Candidate generation for a side IN CHECK (perf push 2026-10-08). `allow`
/// holds the squares a non-king move must land on to possibly resolve the
/// check: the single checker plus the squares between it and the king, or 0
/// under double check (see legal.evasionTargets). A pseudo-legal non-king move
/// that is not en passant and lands outside `allow` leaves the checker
/// attacking the king, so the legality filter rejects it; masking the target
/// sets deletes exactly such moves at the source. King moves and en passant
/// are emitted unmasked, castling is never generated in check, and the caller
/// still runs the full legality filter over what is emitted, so the filtered
/// list (content AND order) is identical to generate-then-filter.
pub fn generateEvasionCandidates(pos: *const position.Position, list: *move_mod.MoveList, allow: bitboard.Bitboard) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateEvasionCandidatesFor(.white, pos, list, allow),
        .black => generateEvasionCandidatesFor(.black, pos, list, allow),
    }
}

fn generateEvasionCandidatesFor(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    allow: bitboard.Bitboard,
) void {
    generatePawnEvasionCandidates(side, pos, list, allow);
    // masked=true: targets & ~(own | ~allow) == targets & ~own & allow.
    generateLeaperMoves(side, pos, .knight, attacks.knightAttacksFrom, list, true, ~allow);
    generateSliderMoves(side, pos, .bishop, attacks.bishopAttacksOnTheFly, list, true, ~allow);
    generateSliderMoves(side, pos, .rook, attacks.rookAttacksOnTheFly, list, true, ~allow);
    generateSliderMoves(side, pos, .queen, attacks.queenAttacksOnTheFly, list, true, ~allow);
    generateLeaperMoves(side, pos, .king, attacks.kingAttacksFrom, list, false, 0);
    // No castling: generateCastlingMoves emits nothing while in check.
}

/// `generatePawnMoves` (unmasked form) with every push, double push,
/// promotion and capture target intersected with `allow`; en passant is kept
/// unmasked (its captured pawn is not on `to`). Same per-pawn emission order.
fn generatePawnEvasionCandidates(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    allow: bitboard.Bitboard,
) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other());
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: u3 = if (side == .white) 1 else 6;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (pawns != 0) {
        const from = bitboard.popLsbUnchecked(&pawns);
        const file = from.file();
        const rank = from.rank();

        const one_step_rank_i: i8 = @as(i8, @intCast(rank)) + forward_delta;
        if (one_step_rank_i >= 0 and one_step_rank_i < 8) {
            const one_step = square.Square.fromCoords(file, @intCast(one_step_rank_i));
            if (!pos.isSquareOccupied(one_step)) {
                const one_step_allowed = (allow & bitboard.bit(one_step)) != 0;
                if (rank == promotion_from_rank) {
                    if (one_step_allowed) addPromotions(list, from, one_step, false);
                } else {
                    if (one_step_allowed) list.add(move_mod.Move.init(from, one_step, .quiet));
                    if (rank == start_rank) {
                        const two_step_rank_i = one_step_rank_i + forward_delta;
                        if (two_step_rank_i >= 0 and two_step_rank_i < 8) {
                            const two_step = square.Square.fromCoords(file, @intCast(two_step_rank_i));
                            if (!pos.isSquareOccupied(two_step) and (allow & bitboard.bit(two_step)) != 0) {
                                list.add(move_mod.Move.init(from, two_step, .double_push));
                            }
                        }
                    }
                }
            }
        }

        var capture_targets = attacks.pawnAttacksFrom(side, from) & opponent_occ & allow;
        while (capture_targets != 0) {
            const to = bitboard.popLsbUnchecked(&capture_targets);
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

pub fn generateTactical(pos: *const position.Position, list: *move_mod.MoveList) void {
    list.clear();
    switch (pos.side_to_move) {
        .white => generateTacticalFor(.white, pos, list),
        .black => generateTacticalFor(.black, pos, list),
    }
}

fn generateTacticalFor(comptime side: types.Color, pos: *const position.Position, list: *move_mod.MoveList) void {
    generateTacticalPawnMoves(side, pos, list, false, 0);
    generateTacticalLeaperMoves(side, pos, .knight, attacks.knightAttacksFrom, list, false, 0);
    generateTacticalSliderMoves(side, pos, .bishop, attacks.bishopAttacksOnTheFly, list, false, 0);
    generateTacticalSliderMoves(side, pos, .rook, attacks.rookAttacksOnTheFly, list, false, 0);
    generateTacticalSliderMoves(side, pos, .queen, attacks.queenAttacksOnTheFly, list, false, 0);
    generateTacticalLeaperMoves(side, pos, .king, attacks.kingAttacksFrom, list, false, 0);
}

fn generatePawnMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other());
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: u3 = if (side == .white) 1 else 6;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (pawns != 0) {
        const from = bitboard.popLsbUnchecked(&pawns);
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
        if (masked) capture_targets &= ~forbidden;
        while (capture_targets != 0) {
            const to = bitboard.popLsbUnchecked(&capture_targets);
            if (rank == promotion_from_rank) {
                addPromotions(list, from, to, true);
            } else {
                list.add(move_mod.Move.init(from, to, .capture));
            }
        }

        // The fused caller guarantees that no pawn of the side to move attacks
        // `pos.en_passant` (legal.canFuseLegality), so on that path this block
        // emits nothing.
        if (!masked) {
            if (pos.en_passant) |ep_square| {
                const ep_mask = bitboard.bit(ep_square);
                if ((attacks.pawnAttacksFrom(side, from) & ep_mask) != 0) {
                    list.add(move_mod.Move.init(from, ep_square, .en_passant));
                }
            }
        }
    }
}

fn generateTacticalPawnMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    list: *move_mod.MoveList,
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pawns = pos.pieceBitboard(side, .pawn);
    const opponent_occ = pos.occupancyFor(side.other());
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const promotion_from_rank: u3 = if (side == .white) 6 else 1;

    while (pawns != 0) {
        const from = bitboard.popLsbUnchecked(&pawns);
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
        if (masked) capture_targets &= ~forbidden;
        while (capture_targets != 0) {
            const to = bitboard.popLsbUnchecked(&capture_targets);
            if (rank == promotion_from_rank) {
                addPromotions(list, from, to, true);
            } else {
                list.add(move_mod.Move.init(from, to, .capture));
            }
        }

        // The fused caller guarantees that no pawn of the side to move attacks
        // `pos.en_passant` (legal.canFuseLegality), so on that path this block
        // emits nothing.
        if (!masked) {
            if (pos.en_passant) |ep_square| {
                const ep_mask = bitboard.bit(ep_square);
                if ((attacks.pawnAttacksFrom(side, from) & ep_mask) != 0) {
                    list.add(move_mod.Move.init(from, ep_square, .en_passant));
                }
            }
        }
    }
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
    const knight_checks = attacks.knightAttacksFrom(ksq) & empty;
    const bishop_checks = attacks.bishopAttacksOnTheFly(ksq, occ) & empty;
    const rook_checks = attacks.rookAttacksOnTheFly(ksq, occ) & empty;
    const pawn_checks = attacks.pawnAttacksFrom(enemy, ksq) & empty;

    var knights = pos.pieceBitboard(side, .knight);
    while (knights != 0) {
        const from = bitboard.popLsbUnchecked(&knights);
        var targets = attacks.knightAttacksFrom(from) & knight_checks;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            list.add(move_mod.Move.init(from, to, .quiet));
        }
    }
    var bishops = pos.pieceBitboard(side, .bishop);
    while (bishops != 0) {
        const from = bitboard.popLsbUnchecked(&bishops);
        var targets = attacks.bishopAttacksOnTheFly(from, occ) & bishop_checks;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            list.add(move_mod.Move.init(from, to, .quiet));
        }
    }
    var rooks = pos.pieceBitboard(side, .rook);
    while (rooks != 0) {
        const from = bitboard.popLsbUnchecked(&rooks);
        var targets = attacks.rookAttacksOnTheFly(from, occ) & rook_checks;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            list.add(move_mod.Move.init(from, to, .quiet));
        }
    }
    var queens = pos.pieceBitboard(side, .queen);
    while (queens != 0) {
        const from = bitboard.popLsbUnchecked(&queens);
        const from_attacks = attacks.bishopAttacksOnTheFly(from, occ) | attacks.rookAttacksOnTheFly(from, occ);
        var targets = from_attacks & (bishop_checks | rook_checks);
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            list.add(move_mod.Move.init(from, to, .quiet));
        }
    }

    // Pawn pushes landing on a checking square. A checking landing square is
    // never on the promotion rank (the king would have to stand off-board), so
    // these are always plain pushes.
    const forward_delta: i8 = if (side == .white) 1 else -1;
    const start_rank: i8 = if (side == .white) 1 else 6;
    const my_pawns = pos.pieceBitboard(side, .pawn);
    var pawn_targets = pawn_checks;
    while (pawn_targets != 0) {
        const to = bitboard.popLsbUnchecked(&pawn_targets);
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

fn generateLeaperMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square) bitboard.Bitboard,
    list: *move_mod.MoveList,
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const blocked = if (masked) pos.occupancyFor(side) | forbidden else pos.occupancyFor(side);
    const opp_occ = pos.occupancyFor(side.other());

    while (pieces != 0) {
        const from = bitboard.popLsbUnchecked(&pieces);
        var targets = attack_fn(from) & ~blocked;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
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
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const opp_occ = if (masked) pos.occupancyFor(side.other()) & ~forbidden else pos.occupancyFor(side.other());

    while (pieces != 0) {
        const from = bitboard.popLsbUnchecked(&pieces);
        var targets = attack_fn(from) & opp_occ;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
            list.add(move_mod.Move.init(from, to, .capture));
        }
    }
}

fn generateSliderMoves(
    comptime side: types.Color,
    pos: *const position.Position,
    comptime piece_type: piece.PieceType,
    comptime attack_fn: fn (square.Square, bitboard.Bitboard) bitboard.Bitboard,
    list: *move_mod.MoveList,
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const blocked = if (masked) pos.occupancyFor(side) | forbidden else pos.occupancyFor(side);
    const opp_occ = pos.occupancyFor(side.other());
    const occupied = pos.occupancy();

    while (pieces != 0) {
        const from = bitboard.popLsbUnchecked(&pieces);
        var targets = attack_fn(from, occupied) & ~blocked;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
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
    comptime masked: bool,
    forbidden: bitboard.Bitboard,
) void {
    var pieces = pos.pieceBitboard(side, piece_type);
    const opp_occ = if (masked) pos.occupancyFor(side.other()) & ~forbidden else pos.occupancyFor(side.other());
    const occupied = pos.occupancy();

    while (pieces != 0) {
        const from = bitboard.popLsbUnchecked(&pieces);
        var targets = attack_fn(from, occupied) & opp_occ;
        while (targets != 0) {
            const to = bitboard.popLsbUnchecked(&targets);
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
