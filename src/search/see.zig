const attacks = @import("../movegen/attacks.zig");
const bitboard = @import("../core/bitboard.zig");
const legality = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const piece_values = @import("../core/piece_values.zig");
const position = @import("../core/position.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

const Attacker = struct {
    from: square.Square,
    piece_type: piece.PieceType,
};

// The swap loop used to carry a private COPY of `pos.pieces` (a [2][6]u64 =
// 96-byte struct on the caller's stack) and clear a bit in it per removal. LLVM
// materialized that copy with two zmm stores and then read it back 8 bytes at a
// time — a store-to-load-forwarding stall that was 58% of `quietScore`'s samples
// and 59% of `seeGain`'s in the r8 profile.
//
// The copy is not needed: an occupancy mask alone is exactly equivalent. Every
// query in the exchange is `pieces[side][type] & attacksTo(target)`, and NO
// attack set to `target` ever contains `target` itself, so intersecting the
// position's own (immutable) piece bitboards with a mutable `occ` reproduces the
// removals bit for bit:
//   - the mover and every spent attacker are cleared from `occ`, so they drop
//     out of the intersection just as clearing their type bitboard did;
//   - the captured victim sits ON `target`, whose `occ` bit is (re)set by the
//     arriving piece, but it can never appear in an attack set aimed at its own
//     square, so leaving its bit in `pieces` is unobservable.
// Result: no copy, no spill, the piece bitboards are read straight out of the
// hot Position, and only a single u64 changes per exchange step.
//
// King legality. A king is not material that can be traded: it may capture on
// the target only if, once it has left its square, the opponent has no attacker
// left on the target (pins do not matter -- a pinned piece still gives check).
// It is always the last attacker its side uses (the least-valuable order puts
// it after everything else), so when it does capture nothing can follow and the
// exchange ends there; when it may not, its side simply stops capturing. Valuing
// the king at 0 instead made every king recapture look free, e.g. Qxf7 in the
// Scholar's pattern scored -800 with the c4 bishop covering f7.
//
// `piece_values.value(.king)` stays 0 for the king as the MOVER: every move SEE
// sees is legal, so a moving king never lands on an attacked square and the
// first exchange step never happens.

// Promotions. A pawn that captures onto rank 1 or 8 promotes (always to a
// queen here): that exchange step gains the captured piece plus queen - pawn,
// and the next capture on the square takes a queen. A white pawn can only
// capture onto rank 8 and a black one onto rank 1, so the rank alone decides.
// The mover's own promotion is credited the same way (promoted piece - pawn).
// Search callers do not pass promotions today (ordering, the bad-capture
// prune and qsearch exempt them); the initial credit keeps the API honest.

const PROMOTION_GAIN: i32 = piece_values.value(.queen) - piece_values.value(.pawn);
const LAST_RANKS: bitboard.Bitboard = 0xFF00_0000_0000_00FF;

inline fn onLastRank(target: square.Square) bool {
    return (LAST_RANKS & bitboard.bit(target)) != 0;
}

inline fn initialPromotionGain(mv: move_mod.Move) i32 {
    const promotion = mv.promotionPieceType() orelse return 0;
    return piece_values.value(promotion) - piece_values.value(.pawn);
}

/// Whether the opponent of the side to move can answer a move to `target` with
/// a promoting pawn capture: only then can a quiet move lose more than its own
/// piece. Pawn attackers are fixed squares, so no exchange can add one later.
pub inline fn promotingRecapturePossible(pos: *const position.Position, target: square.Square) bool {
    if (!onLastRank(target)) return false;
    const opponent = pos.side_to_move.other();
    return (pos.pieceBitboard(opponent, .pawn) & pawnAttackers(opponent, target)) != 0;
}

/// Whether a pawn of either colour can capture onto `target` with promotion.
/// The rank fixes the side: only a white pawn captures onto rank 8, only a
/// black one onto rank 1. The mover's own pawn matters to `quietBelow` (its
/// recapture gains the victim plus the promotion), not to `quietFloor`.
inline fn anyPromotingCapture(pos: *const position.Position, target: square.Square) bool {
    if (!onLastRank(target)) return false;
    const promoter: types.Color = if (target.rank() == 7) .white else .black;
    return (pos.pieceBitboard(promoter, .pawn) & pawnAttackers(promoter, target)) != 0;
}

/// Lower bound of `quietScore` for a non-promoting quiet move: minus the
/// moving piece's value, and minus the promotion gain on top when an enemy
/// pawn can recapture onto its last rank.
pub inline fn quietFloor(pos: *const position.Position, mv: move_mod.Move) i32 {
    const mover_value = piece_values.value(pos.pieceAt(mv.from).pieceType());
    return -mover_value - (if (promotingRecapturePossible(pos, mv.to)) PROMOTION_GAIN else 0);
}

// Pins (C-SEE-PIN). A piece pinned to its own king may not recapture off
// its pin line while the pinner still stands: the swap skips it then and
// takes the next attacker. In R2nkb2/3pppp1/8/7Q/2B5/8/8/6K1 w the d8 knight
// is pinned by Ra8, so Qxf7 is mate and scores +100, not -800 (which made
// qsearch drop it). The pinned set is taken once per node (`Pins.init`) and
// shared by every SEE call there; the per-step test only runs for pinned
// pieces still on the board, so a pin-free position costs one AND per step.
// A pinned piece still covers squares for the king rule (kingMayCapture uses
// the unfiltered attackers): a pinned piece gives check all the same. Pins
// that only arise during the exchange are not modelled.

/// Pieces of each colour pinned to their own king at the node.
pub const Pins = struct {
    pinned: [2]bitboard.Bitboard = .{ 0, 0 },

    /// No pins: the geometric swap (test reference, cold callers that
    /// prefer it).
    pub const none: Pins = .{};

    pub fn init(pos: *const position.Position) Pins {
        return .{ .pinned = .{ legality.pinnedPieces(pos, .white), legality.pinnedPieces(pos, .black) } };
    }
};

/// The pinned pieces of `side` that may not capture on `target` now: still on
/// the board, moving off the line through their king, with an enemy slider
/// (other than whatever stands on `target`, which is about to be taken) still
/// lined up on the king once the piece leaves.
fn pinnedAway(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square, pinned: bitboard.Bitboard) bitboard.Bitboard {
    const king = pos.kingSquare(side) orelse return 0;
    const enemy = side.other();
    const enemy_queens = pos.pieceBitboard(enemy, .queen);
    const live = occupied & ~bitboard.bit(target);
    const rook_like = (pos.pieceBitboard(enemy, .rook) | enemy_queens) & live;
    const bishop_like = (pos.pieceBitboard(enemy, .bishop) | enemy_queens) & live;
    var remaining = pinned & occupied;
    var blocked: bitboard.Bitboard = 0;
    while (remaining != 0) {
        const sq = bitboard.popLsbUnchecked(&remaining);
        if (legality.isCollinear(king, sq, target)) continue;
        const without = occupied & ~bitboard.bit(sq);
        if ((attacks.rookAttacksOnTheFly(king, without) & rook_like) != 0 or
            (attacks.bishopAttacksOnTheFly(king, without) & bishop_like) != 0)
        {
            blocked |= bitboard.bit(sq);
        }
    }
    return blocked;
}

/// A node's pins, taken on first use: callers keep one `?Pins` per node.
pub inline fn lazyPins(slot: *?Pins, pos: *const position.Position) *const Pins {
    if (slot.* == null) slot.* = Pins.init(pos);
    return &slot.*.?;
}

/// Pieces of `side` that may capture on `target` in this exchange step.
inline fn available(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square, pins: *const Pins) bitboard.Bitboard {
    const pinned = pins.pinned[@intFromEnum(side)];
    if ((pinned & occupied) == 0) return occupied;
    return occupied & ~pinnedAway(pos, occupied, side, target, pinned);
}

/// Whether a king of `side` that has just been removed from `occupied` may
/// capture on `target`: true when the opponent has no attacker left there.
inline fn kingMayCapture(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square) bool {
    return leastValuableAttacker(pos, occupied, occupied, side.other(), target) == null;
}

/// `captureScoreWith` with the node's pins taken here (tests, cold callers).
pub fn captureScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    const pins = Pins.init(pos);
    return captureScoreWith(pos, mv, &pins);
}

pub inline fn captureScoreWith(pos: *const position.Position, mv: move_mod.Move, pins: *const Pins) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) + initialPromotionGain(mv) - seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type), pins);
}

/// `quietScoreWith` with the node's pins taken here (tests, cold callers).
pub fn quietScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    const pins = Pins.init(pos);
    return quietScoreWith(pos, mv, &pins);
}

/// SEE of a QUIET (non-capture) move from the mover's point of view: 0 if the
/// destination is safe, negative if the piece walks into a losing exchange there.
/// Mirrors `captureScore` but with no captured victim -- the opponent initiates
/// the exchange on `mv.to`. Used for SEE-based quiet pruning of late moves.
/// Only a quiet promotion can score above 0 (its promotion gain).
pub fn quietScoreWith(pos: *const position.Position, mv: move_mod.Move, pins: *const Pins) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return initialPromotionGain(mv) - seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type), pins);
}

/// `quietBelowWith` with the node's pins taken here (tests, cold callers).
pub fn quietBelow(pos: *const position.Position, mv: move_mod.Move, threshold: i32) bool {
    const pins = Pins.init(pos);
    return quietBelowWith(pos, mv, threshold, &pins);
}

/// Exact threshold predicate for quietScore, using the same attacker sequence.
/// For G=max(0,V-reply), G>K is equivalent to !(reply>V-K-1) when
/// 0<=K<V. Carry that inversion until a material bound or empty tail decides it.
pub fn quietBelowWith(pos: *const position.Position, mv: move_mod.Move, threshold: i32, pins: *const Pins) bool {
    // Promotion geometry breaks the material bounds below (a promoting pawn
    // of either side gains more than the piece it takes; a quiet promotion
    // scores above 0): answer those rare moves from the exact score.
    if (mv.isPromotion() or anyPromotingCapture(pos, mv.to)) return quietScoreWith(pos, mv, pins) < threshold;
    // quietScore is nonpositive here, including its capture/empty-source sentinels.
    if (threshold > 0) return true;
    if (mv.isCapture()) return false;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return false;
    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    var victim_value = piece_values.value(mover_after_type);
    // This also handles minInt(i32) before negating the threshold.
    if (threshold <= -victim_value) return false;

    var bound = -threshold;
    var inverted = false;
    var occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);
    var side = pos.side_to_move.other();
    while (true) {
        if (bound >= victim_value) return inverted;
        const attacker = leastValuableAttacker(pos, occupied, available(pos, occupied, side, mv.to, pins), side, mv.to) orelse return inverted;
        occupied &= ~bitboard.bit(attacker.from);
        // A king that may not capture is the same as no attacker. One that may
        // ends the exchange: the next pass finds no reply and returns.
        if (attacker.piece_type == .king and !kingMayCapture(pos, occupied, side, mv.to)) return inverted;
        bound = victim_value - bound - 1;
        victim_value = piece_values.value(attacker.piece_type);
        side = side.other();
        inverted = !inverted;
    }
}

fn seeGain(pos: *const position.Position, start_occupied: bitboard.Bitboard, side: types.Color, target: square.Square, victim_value: i32, pins: *const Pins) i32 {
    var gains: [32]i32 = undefined;
    var ply: usize = 0;
    var attacker_side = side;
    var next_victim_value = victim_value;
    var occupied = start_occupied;
    const promotion_square = onLastRank(target);

    while (true) {
        const attacker = leastValuableAttacker(pos, occupied, available(pos, occupied, attacker_side, target, pins), attacker_side, target) orelse break;
        occupied &= ~bitboard.bit(attacker.from);
        if (attacker.piece_type == .king) {
            // Last possible step either way: the king captures only onto an
            // uncovered square, and then the opponent has nothing to reply with.
            if (kingMayCapture(pos, occupied, attacker_side, target)) {
                gains[ply] = next_victim_value;
                ply += 1;
            }
            break;
        }
        const promotes = promotion_square and attacker.piece_type == .pawn;
        gains[ply] = next_victim_value + (if (promotes) PROMOTION_GAIN else 0);
        ply += 1;
        next_victim_value = piece_values.value(if (promotes) .queen else attacker.piece_type);
        attacker_side = attacker_side.other();
    }

    var gain: i32 = 0;
    while (ply > 0) {
        ply -= 1;
        gain = @max(@as(i32, 0), gains[ply] - gain);
    }
    return gain;
}

/// `occupied` shapes the slider lines (a pinned piece still blocks them);
/// `movable` (a subset of it) is who may capture this step.
inline fn leastValuableAttacker(pos: *const position.Position, occupied: bitboard.Bitboard, movable: bitboard.Bitboard, side: types.Color, target: square.Square) ?Attacker {
    const row = pos.pieceRow(side);

    var candidates = row[pieceTypeIndex(.pawn)] & movable & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = row[pieceTypeIndex(.knight)] & movable & attacks.knightAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.bishop)] & movable & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.rook)] & movable & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = row[pieceTypeIndex(.queen)] & movable & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = row[pieceTypeIndex(.king)] & movable & attacks.kingAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .king };

    return null;
}

fn pawnAttackers(side: types.Color, target: square.Square) bitboard.Bitboard {
    return switch (side) {
        .white => attacks.BLACK_PAWN_ATTACKS[@intFromEnum(target)],
        .black => attacks.WHITE_PAWN_ATTACKS[@intFromEnum(target)],
    };
}

fn pieceTypeIndex(piece_type: piece.PieceType) usize {
    return @intFromEnum(piece_type);
}

test "see scores an undefended queen capture positively" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("4k3/8/8/4q3/2N5/8/8/4K3 w - - 0 1");
    const mv = move_mod.Move.init(.c4, .e5, .capture);

    try @import("std").testing.expect(captureScore(&pos, mv) > 0);
}

test "see scores a bad queen takes pawn capture negatively" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.parse("4k3/8/8/3p4/4Q3/3r4/8/4K3 w - - 0 1");
    const mv = move_mod.Move.init(.e4, .d5, .capture);

    try @import("std").testing.expect(captureScore(&pos, mv) < 0);
}

// ---------------------------------------------------------------------------
// Independent reference (tests only). Deliberately keeps the ORIGINAL
// materialised-state formulation — a private copy of the piece bitboards with
// real bit removals and a recursive swap — so it validates the occupancy-mask
// equivalence argument above from the outside instead of restating it.
// ---------------------------------------------------------------------------

const RefState = struct {
    pieces: [2][6]bitboard.Bitboard,
    occupied: bitboard.Bitboard,

    fn fromPosition(pos: *const position.Position) RefState {
        return .{ .pieces = pos.pieces, .occupied = pos.occupied };
    }

    fn removePieceByType(self: *RefState, side: types.Color, piece_type: piece.PieceType, sq: square.Square) void {
        self.pieces[@intFromEnum(side)][pieceTypeIndex(piece_type)] &= ~bitboard.bit(sq);
        self.occupied &= ~bitboard.bit(sq);
    }

    fn removePiece(self: *RefState, p: piece.Piece, sq: square.Square) void {
        self.removePieceByType(p.color().?, p.pieceType(), sq);
    }
};

fn leastValuableAttackerReference(state: *const RefState, side: types.Color, target: square.Square) ?Attacker {
    const ci = @intFromEnum(side);

    var candidates = state.pieces[ci][pieceTypeIndex(.pawn)] & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = state.pieces[ci][pieceTypeIndex(.knight)] & attacks.knightAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacksOnTheFly(target, state.occupied);
    candidates = state.pieces[ci][pieceTypeIndex(.bishop)] & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacksOnTheFly(target, state.occupied);
    candidates = state.pieces[ci][pieceTypeIndex(.rook)] & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = state.pieces[ci][pieceTypeIndex(.queen)] & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = state.pieces[ci][pieceTypeIndex(.king)] & attacks.kingAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .king };

    return null;
}

fn captureScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    var state = RefState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.pieces[@intFromEnum(pos.side_to_move.other())][pieceTypeIndex(captured_piece.pieceType())] &= ~bitboard.bit(mv.to);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) + initialPromotionGain(mv) - seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn quietScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    var state = RefState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return initialPromotionGain(mv) - seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// Whether `by` attacks `target` in `state`, worked out forwards from every
/// piece's own attack set rather than backwards from the target as the swap
/// does, so the king-legality rule is checked by a second formulation.
fn squareAttackedReference(state: *const RefState, by: types.Color, target: square.Square) bool {
    const ci = @intFromEnum(by);
    for ([_]piece.PieceType{ .pawn, .knight, .bishop, .rook, .queen, .king }) |piece_type| {
        var remaining = state.pieces[ci][pieceTypeIndex(piece_type)];
        while (remaining != 0) {
            const from = bitboard.popLsbUnchecked(&remaining);
            const reach = switch (piece_type) {
                .pawn => attacks.pawnAttacksFrom(by, from),
                .knight => attacks.knightAttacksFrom(from),
                .bishop => attacks.bishopAttacksOnTheFly(from, state.occupied),
                .rook => attacks.rookAttacksOnTheFly(from, state.occupied),
                .queen => attacks.bishopAttacksOnTheFly(from, state.occupied) | attacks.rookAttacksOnTheFly(from, state.occupied),
                .king => attacks.kingAttacksFrom(from),
                .none => unreachable,
            };
            if (bitboard.contains(reach, target)) return true;
        }
    }
    return false;
}

fn seeGainReference(state: RefState, side: types.Color, target: square.Square, victim_value: i32) i32 {
    const attacker = leastValuableAttackerReference(&state, side, target) orelse return 0;

    var next = state;
    next.removePiece(piece.Piece.make(side, attacker.piece_type), attacker.from);
    // An illegal king capture is no capture: this side stands pat.
    if (attacker.piece_type == .king and squareAttackedReference(&next, side.other(), target)) return 0;

    // A pawn taking on a last-rank square promotes: it also gains queen - pawn
    // and leaves a queen to be taken.
    const promotes = attacker.piece_type == .pawn and (target.rank() == 0 or target.rank() == 7);
    const taken = victim_value + (if (promotes) piece_values.value(.queen) - piece_values.value(.pawn) else 0);
    const left_on_target = piece_values.value(if (promotes) .queen else attacker.piece_type);
    const gain = taken - seeGainReference(next, side.other(), target, left_on_target);
    return @max(@as(i32, 0), gain);
}

const DIFFERENTIAL_FENS = [_][]const u8{
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R b KQkq - 0 1",
    "4k3/8/8/3p4/4Q3/3r4/8/4K3 w - - 0 1",
    "4k3/8/3n4/4P3/8/8/8/4K3 w - - 0 1",
    "4k3/P7/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "2r3k1/5ppp/p3p3/1p6/3P4/P3P1P1/1P3P1P/2R3K1 w - - 0 1",
    "8/5pk1/6p1/8/5PK1/6P1/8/3r3R w - - 0 1",
    "3rr1k1/pp3pp1/1qn2np1/8/3p4/PP1R1P2/2P1NQPP/R1B3K1 b - - 0 1",
    // Battery / x-ray dense: queen behind rook behind rook, bishops stacked.
    "3r2k1/3r4/3q4/8/3P4/3R4/3R4/3QK3 w - - 0 1",
    "6k1/8/2b5/3b4/4P3/5B2/6B1/6K1 w - - 0 1",
    // King-as-attacker endgames (the ONLY case where an aligned non-slider is
    // removed mid-swap, so it exercises the x-ray edge of the argument).
    "8/8/4k3/3p4/4K3/8/8/8 w - - 0 1",
    "8/8/3rk3/3p4/3RK3/3R4/8/8 w - - 0 1",
};

/// The reference is geometric (no pins), so it checks the swap with
/// `Pins.none`; pinned recaptures have their own absolute cases below. The
/// pin-aware threshold walk is checked against the pin-aware full score.
fn expectSeeMatchesReference(pos: *position.Position) !usize {
    const legal_mod = @import("../movegen/legal.zig");
    const none = Pins.none;
    const pins = Pins.init(pos);
    var moves = move_mod.MoveList.init();
    legal_mod.generate(pos, &moves);
    for (moves.slice()) |mv| {
        try @import("std").testing.expectEqual(captureScoreReference(pos, mv), captureScoreWith(pos, mv, &none));
        try @import("std").testing.expectEqual(quietScoreReference(pos, mv), quietScoreWith(pos, mv, &none));
        if (!mv.isCapture() and !mv.isPromotion()) {
            const floor = quietFloor(pos, mv);
            const reference = quietScoreReference(pos, mv);
            try @import("std").testing.expect(reference >= floor);
            try @import("std").testing.expect(quietScoreWith(pos, mv, &pins) >= floor);
            for ([_]i32{ floor - 1, floor, floor + 1, 0 }) |threshold| {
                try @import("std").testing.expectEqual(reference < threshold, threshold > floor and quietScoreWith(pos, mv, &none) < threshold);
            }
        }
        const reference_quiet = quietScoreReference(pos, mv);
        const pinned_quiet = quietScoreWith(pos, mv, &pins);
        for ([_]i32{
            @import("std").math.minInt(i32), -901,                -900,                            -501, -500,
            -331,                            -330,                -321,                            -320, -101,
            -100,                            -1,                  0,                               1,    reference_quiet - 1,
            reference_quiet,                 reference_quiet + 1, @import("std").math.maxInt(i32),
        }) |threshold| {
            try @import("std").testing.expectEqual(reference_quiet < threshold, quietBelowWith(pos, mv, threshold, &none));
            try @import("std").testing.expectEqual(pinned_quiet < threshold, quietBelowWith(pos, mv, threshold, &pins));
        }
        for ([_]i32{ pinned_quiet - 1, pinned_quiet, pinned_quiet + 1 }) |threshold| {
            try @import("std").testing.expectEqual(pinned_quiet < threshold, quietBelowWith(pos, mv, threshold, &pins));
        }
    }
    return moves.count;
}

test "iterative see matches recursive reference on legal captures AND quiets" {
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");

    var checked: usize = 0;
    for (DIFFERENTIAL_FENS) |fen_text| {
        var root = try fen.parse(fen_text);
        checked += try expectSeeMatchesReference(&root);
        // One ply deep as well: multiplies the occupancy/x-ray shapes seen by
        // both implementations by ~30x for a few ms of test time.
        var root_moves = move_mod.MoveList.init();
        legal.generate(&root, &root_moves);
        for (root_moves.slice()) |mv| {
            var child = legal.playMoveCopy(&root, mv);
            checked += try expectSeeMatchesReference(&child);
        }
    }
    // The king-legality, promotion, pin and pinned-promotion positions
    // below, in both colours, one ply deep too.
    for (KING_RULE_CASES ++ PROMOTION_CASES ++ PIN_CASES ++ PIN_PROMOTION_CASES) |case| {
        var buffer: [128]u8 = undefined;
        for ([_][]const u8{ case.fen, try mirrorFen(case.fen, &buffer) }) |fen_text| {
            var root = try fen.parse(fen_text);
            checked += try expectSeeMatchesReference(&root);
            var root_moves = move_mod.MoveList.init();
            legal.generate(&root, &root_moves);
            for (root_moves.slice()) |mv| {
                var child = legal.playMoveCopy(&root, mv);
                checked += try expectSeeMatchesReference(&child);
            }
        }
    }
    try @import("std").testing.expect(checked > 10_000);
}

// ---------------------------------------------------------------------------
// Absolute values for the king-legality rule. The differential test above
// cannot see a semantic error the reference shares, so these pin the expected
// numbers on the engine's 100/320/330/500/900 scale. Each case is checked as
// written and colour-mirrored, and the move must be legal in the position.
// ---------------------------------------------------------------------------

const KingRuleCase = struct {
    name: []const u8,
    fen: []const u8,
    from: square.Square,
    to: square.Square,
    flag: move_mod.MoveFlag,
    /// captureScore for a capture, quietScore for a quiet move.
    expected: i32,
};

const KING_RULE_CASES = [_]KingRuleCase{
    // Scholar's pattern: Bc4 covers f7, so Ke8 cannot take back. Was -800.
    .{ .name = "Qxf7, bishop covers f7", .fen = "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", .from = .h5, .to = .f7, .flag = .capture, .expected = 100 },
    // Same with the bishop still on f1: Kxf7 is legal and must stay -800.
    .{ .name = "Qxf7, f7 uncovered", .fen = "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 2 3", .from = .h5, .to = .f7, .flag = .capture, .expected = -800 },
    // Cover already spent: Qxf7 Nxf7 Bxf7+ Kxf7, the last capture is legal.
    // A rule that forbids the king whenever f7 started out covered gives -480.
    .{ .name = "Qxf7, covering bishop spent first", .fen = "r1bqkb1r/pppp1ppp/2n4n/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", .from = .h5, .to = .f7, .flag = .capture, .expected = -800 },
    // The covering bishop is pinned to its own king by Rc8; it still covers.
    .{ .name = "Qxf7, covering bishop pinned", .fen = "2r1k3/5p2/8/7Q/2B5/8/8/2K5 w - - 0 1", .from = .h5, .to = .f7, .flag = .capture, .expected = 100 },
    // Supported Qg7: Bb2 sees g7 once the queen leaves d4. Was -900.
    .{ .name = "quiet Qg7, bishop behind", .fen = "6k1/5p1p/6p1/8/3Q4/8/1B6/6K1 w - - 0 1", .from = .d4, .to = .g7, .flag = .quiet, .expected = 0 },
    .{ .name = "quiet Qg7, unsupported", .fen = "6k1/5p1p/6p1/8/3Q4/8/8/2B3K1 w - - 0 1", .from = .d4, .to = .g7, .flag = .quiet, .expected = -900 },
    // Knight-defended rook, capturing and quiet. Were -400 and -500.
    .{ .name = "Rxg7, knight covers g7", .fen = "6k1/6p1/8/5N2/8/8/8/6RK w - - 0 1", .from = .g1, .to = .g7, .flag = .capture, .expected = 100 },
    .{ .name = "Rxg7, g7 uncovered", .fen = "6k1/6p1/8/8/8/8/8/6RK w - - 0 1", .from = .g1, .to = .g7, .flag = .capture, .expected = -400 },
    .{ .name = "quiet Rg7, knight covers g7", .fen = "6k1/R7/8/5N2/8/8/8/7K w - - 0 1", .from = .a7, .to = .g7, .flag = .quiet, .expected = 0 },
    // Bxg7 Nxg7 Kxg7: the knight is spent, so the king's capture is legal.
    .{ .name = "quiet Rg7, bishop and king defend", .fen = "6k1/R7/7b/5N2/8/8/8/7K w - - 0 1", .from = .a7, .to = .g7, .flag = .quiet, .expected = -490 },
    .{ .name = "RxR, only the king defends", .fen = "6k1/6r1/8/5N2/8/8/8/6RK w - - 0 1", .from = .g1, .to = .g7, .flag = .capture, .expected = 500 },
    // RxR Nxg7 Nxg7 Kxg7: spent knight again, even trade.
    .{ .name = "RxR, knight and king defend", .fen = "4n1k1/6r1/8/5N2/8/8/8/6RK w - - 0 1", .from = .g1, .to = .g7, .flag = .capture, .expected = 0 },
    // The mover's own king: Qxd5 Nxd5 and Kxd5 is illegal (Bf7 covers d5).
    // Was -480 (the king took back for free).
    .{ .name = "Qxd5, own king may not retake", .fen = "7k/5b2/1n6/3pK3/8/8/8/3Q4 w - - 0 1", .from = .d1, .to = .d5, .flag = .capture, .expected = -800 },
    .{ .name = "Qxd5, own king retakes", .fen = "7k/8/1n6/3pK3/8/8/8/3Q4 w - - 0 1", .from = .d1, .to = .d5, .flag = .capture, .expected = -480 },
    // Both kings touch e5 and White's rook stands behind its own king. Ke4
    // can never take on e5 (Ke6 covers it). A large king VALUE alone would
    // let Re3 "recapture" the black king and score this -220 as before.
    .{ .name = "Nxe5, opposing king covers, x-ray behind king", .fen = "8/8/2n1k3/4P3/4K3/4R3/8/8 b - - 0 1", .from = .c6, .to = .e5, .flag = .capture, .expected = 100 },
};

// Promotions inside the exchange (judges A and C, both directions) and the
// mover's own promotion. Values on the same 100/320/330/500/900 scale.
const PROMOTION_CASES = [_]KingRuleCase{
    // a2xb1=Q answers: the rook is lost and the pawn becomes a queen. Was 0.
    .{ .name = "Rxb1, pawn retakes and promotes", .fen = "7k/8/8/8/8/7K/pR6/1r6 w - - 0 1", .from = .b2, .to = .b1, .flag = .capture, .expected = -800 },
    // Quiet form: below minus the rook's value. Was -500.
    .{ .name = "quiet Rb1, pawn takes and promotes", .fen = "7k/8/8/8/8/7K/pR6/8 w - - 0 1", .from = .b2, .to = .b1, .flag = .quiet, .expected = -1300 },
    // Rc1 takes the new queen back: the promotion gain cancels.
    .{ .name = "Rxb1, Rc1 retakes the new queen", .fen = "7k/8/8/8/8/7K/pR6/1rR5 w - - 0 1", .from = .b2, .to = .b1, .flag = .capture, .expected = 100 },
    // A losing capture that used to look winning. Was +180.
    .{ .name = "Nxc1, pawn retakes and promotes", .fen = "7k/8/8/8/8/1N4K1/1p6/2r5 w - - 0 1", .from = .b3, .to = .c1, .flag = .capture, .expected = -620 },
    // The mover's own pawn retakes with promotion, so Rxb8 is not played.
    // Was -80 (qsearch skipped a winning capture).
    .{ .name = "Qxb8, own pawn would retake and promote", .fen = "1nr4k/P7/8/8/8/8/8/1Q4K1 w - - 0 1", .from = .b1, .to = .b8, .flag = .capture, .expected = 320 },
    // The mover's own promotion is credited. Were -400 and -900.
    .{ .name = "bxa8=Q, king retakes", .fen = "rk6/1P6/8/8/8/8/8/4K3 w - - 0 1", .from = .b7, .to = .a8, .flag = .promo_queen_capture, .expected = 400 },
    .{ .name = "a8=Q, rook retakes", .fen = "1r5k/P7/8/8/8/8/8/4K3 w - - 0 1", .from = .a7, .to = .a8, .flag = .promo_queen, .expected = -100 },
    // Quiet moves onto the mover's own promotion square: the opponent declines
    // the exchange, since the mover's pawn would retake and promote. The
    // threshold walk (quietBelow) used to value that pawn as a pawn and
    // answered "below" for thresholds from 0 down to -100 or further
    // (review round, judges A F2 / C F1).
    .{ .name = "quiet Qb8, own pawn would retake and promote", .fen = "2r4k/P7/8/8/8/8/8/1Q4K1 w - - 0 1", .from = .b1, .to = .b8, .flag = .quiet, .expected = 0 },
    .{ .name = "quiet Rb8+, own pawn would retake and promote", .fen = "7k/P2n4/8/8/8/8/1R6/6K1 w - - 0 1", .from = .b2, .to = .b8, .flag = .quiet, .expected = 0 },
    .{ .name = "quiet Qb8+ from g3, own pawn would retake and promote", .fen = "7k/P7/1r6/8/8/6Q1/8/6K1 w - - 0 1", .from = .g3, .to = .b8, .flag = .quiet, .expected = 0 },
    .{ .name = "quiet Qb8+, knight takes, own pawn would retake and promote", .fen = "3k4/P7/n7/8/8/8/8/1Q4K1 w - - 0 1", .from = .b1, .to = .b8, .flag = .quiet, .expected = 0 },
};

test "see promotions inside the exchange and of the mover, absolute values" {
    for (PROMOTION_CASES) |case| {
        errdefer @import("std").debug.print("promotion case failed: {s}\n", .{case.name});
        try expectKingRuleCase(case.fen, move_mod.Move.init(case.from, case.to, case.flag), case.expected);

        var buffer: [128]u8 = undefined;
        const mirrored = try mirrorFen(case.fen, &buffer);
        try expectKingRuleCase(mirrored, move_mod.Move.init(mirrorSquare(case.from), mirrorSquare(case.to), case.flag), case.expected);
    }
}

test "see quiet floor bounds every quiet move, promoting recaptures included" {
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");
    for (PROMOTION_CASES) |case| {
        var buffer: [128]u8 = undefined;
        for ([_][]const u8{ case.fen, try mirrorFen(case.fen, &buffer) }) |fen_text| {
            const pos = try fen.parse(fen_text);
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            for (moves.slice()) |mv| {
                if (mv.isCapture() or mv.isPromotion()) continue;
                try @import("std").testing.expect(quietScore(&pos, mv) >= quietFloor(&pos, mv));
            }
        }
    }
    // Rb1 can lose rook and promotion: the floor must reach -1300.
    const pos = try fen.parse("7k/8/8/8/8/7K/pR6/8 w - - 0 1");
    try @import("std").testing.expectEqual(@as(i32, -1300), quietFloor(&pos, move_mod.Move.init(.b2, .b1, .quiet)));
    try @import("std").testing.expectEqual(@as(i32, -500), quietFloor(&pos, move_mod.Move.init(.b2, .c2, .quiet)));
}

// Pinned recapturers (C-SEE-PIN), checked as written and colour-mirrored.
const PIN_CASES = [_]KingRuleCase{
    // Judge C repro: Nd8 is pinned by Ra8 and may not take on f7, and Ke8
    // may not either (Bc4), so Qxf7 is mate. Was -800.
    .{ .name = "Qxf7, recapturing knight pinned", .fen = "R2nkb2/3pppp1/8/7Q/2B5/8/8/6K1 w - - 0 1", .from = .h5, .to = .f7, .flag = .capture, .expected = 100 },
    // Control without the pinning rook: Nxf7 Bxf7+ Kxf7 stays -800.
    .{ .name = "Qxf7, knight free", .fen = "3nkb2/3pppp1/8/7Q/2B5/8/8/6K1 w - - 0 1", .from = .h5, .to = .f7, .flag = .capture, .expected = -800 },
    // A pinned piece may take along its pin line: dxc6 keeps the d7 pawn on
    // the a4-e8 diagonal, then Bxc6. Without that exception this was 0.
    .{ .name = "quiet Nc6, pinned pawn takes along its line", .fen = "4k3/3p4/8/8/B2N4/8/8/4K3 w - - 0 1", .from = .d4, .to = .c6, .flag = .quiet, .expected = -220 },
    // The same pawn may not take off its line: e6 leaves the diagonal.
    .{ .name = "quiet Ne6, pinned pawn may not take", .fen = "4k3/3p4/8/8/B4N2/8/8/4K3 w - - 0 1", .from = .f4, .to = .e6, .flag = .quiet, .expected = 0 },
};

test "see skips recaptures by pinned pieces, absolute values" {
    for (PIN_CASES) |case| {
        errdefer @import("std").debug.print("pin case failed: {s}\n", .{case.name});
        try expectPinCase(case.fen, move_mod.Move.init(case.from, case.to, case.flag), case.expected);

        var buffer: [128]u8 = undefined;
        const mirrored = try mirrorFen(case.fen, &buffer);
        try expectPinCase(mirrored, move_mod.Move.init(mirrorSquare(case.from), mirrorSquare(case.to), case.flag), case.expected);
    }
}

fn expectPinCase(fen_text: []const u8, mv: move_mod.Move, expected: i32) !void {
    const std = @import("std");
    const fen = @import("../core/fen.zig");
    const legal_mod = @import("../movegen/legal.zig");

    const pos = try fen.parse(fen_text);
    var moves = move_mod.MoveList.init();
    legal_mod.generate(&pos, &moves);
    var found = false;
    for (moves.slice()) |candidate| found = found or candidate == mv;
    try std.testing.expect(found);

    if (mv.isCapture()) {
        try std.testing.expectEqual(expected, captureScore(&pos, mv));
    } else {
        try std.testing.expectEqual(expected, quietScore(&pos, mv));
        for ([_]i32{ std.math.minInt(i32), expected - 1, expected, expected + 1, -321, -320, -221, -220, -219, -1, 0, 1 }) |threshold| {
            try std.testing.expectEqual(expected < threshold, quietBelow(&pos, mv, threshold));
        }
    }
}

// A pinned recapturer that would also promote (C-SEE-PIN meets the
// promotion-aware SEE). Rd2 pins b2 to Ka2 along rank 2, so b2xc1=Q would
// leave the pin line and nothing recaptures on c1. The geometric swap lets
// the pawn retake and promote: -620 for Nxc1, -1120 for the quiet Nc1.
const PIN_PROMOTION_CASES = [_]KingRuleCase{
    .{ .name = "Nxc1, promoting recapturer pinned", .fen = "8/8/8/8/8/1N4K1/kp1R4/2r5 w - - 0 1", .from = .b3, .to = .c1, .flag = .capture, .expected = 500 },
    .{ .name = "quiet Nc1, promoting recapturer pinned", .fen = "8/8/8/8/8/1N4K1/kp1R4/8 w - - 0 1", .from = .b3, .to = .c1, .flag = .quiet, .expected = 0 },
};

test "see skips a pinned promoting recapture, and the threshold walk uses the caller's pins" {
    const std = @import("std");
    const fen = @import("../core/fen.zig");
    for (PIN_PROMOTION_CASES) |case| {
        errdefer std.debug.print("pinned promotion case failed: {s}\n", .{case.name});
        try expectPinCase(case.fen, move_mod.Move.init(case.from, case.to, case.flag), case.expected);

        var buffer: [128]u8 = undefined;
        const mirrored = try mirrorFen(case.fen, &buffer);
        try expectPinCase(mirrored, move_mod.Move.init(mirrorSquare(case.from), mirrorSquare(case.to), case.flag), case.expected);
    }
    // quietBelow answers a move onto a promoting recapture from the exact
    // score, with the pins it was given: none gives the geometric -1120.
    const none = Pins.none;
    const capture_pos = try fen.parse(PIN_PROMOTION_CASES[0].fen);
    try std.testing.expectEqual(@as(i32, -620), captureScoreWith(&capture_pos, move_mod.Move.init(.b3, .c1, .capture), &none));
    const pos = try fen.parse(PIN_PROMOTION_CASES[1].fen);
    const mv = move_mod.Move.init(.b3, .c1, .quiet);
    const pins = Pins.init(&pos);
    try std.testing.expectEqual(@as(i32, -1120), quietScoreWith(&pos, mv, &none));
    for ([_]i32{ -1121, -1120, -1119, -1, 0, 1 }) |threshold| {
        try std.testing.expectEqual(-1120 < threshold, quietBelowWith(&pos, mv, threshold, &none));
        try std.testing.expectEqual(0 < threshold, quietBelowWith(&pos, mv, threshold, &pins));
    }
}

fn mirrorSquare(sq: square.Square) square.Square {
    return square.Square.fromIndex(@intFromEnum(sq) ^ 56);
}

fn swapCase(byte: u8) u8 {
    return switch (byte) {
        'a'...'z' => byte - 32,
        'A'...'Z' => byte + 32,
        else => byte,
    };
}

/// Colour mirror of a FEN: ranks reversed, piece colours, side to move,
/// castling rights and the en-passant rank swapped. Test helper only.
fn mirrorFen(text: []const u8, out: []u8) ![]const u8 {
    const std = @import("std");
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    const placement = fields.next() orelse return error.InvalidFen;
    const side = fields.next() orelse return error.InvalidFen;
    const castling = fields.next() orelse return error.InvalidFen;
    const en_passant = fields.next() orelse return error.InvalidFen;
    const halfmove = fields.next() orelse "0";
    const fullmove = fields.next() orelse "1";

    var ranks: [8][]const u8 = undefined;
    var rank_count: usize = 0;
    var rank_iter = std.mem.splitScalar(u8, placement, '/');
    while (rank_iter.next()) |rank| {
        if (rank_count == ranks.len) return error.InvalidFen;
        ranks[rank_count] = rank;
        rank_count += 1;
    }
    if (rank_count != ranks.len) return error.InvalidFen;

    var len: usize = 0;
    for (0..ranks.len) |i| {
        if (i > 0) {
            out[len] = '/';
            len += 1;
        }
        for (ranks[ranks.len - 1 - i]) |byte| {
            out[len] = swapCase(byte);
            len += 1;
        }
    }
    const mirrored_side: []const u8 = if (std.mem.eql(u8, side, "w")) " b " else " w ";
    @memcpy(out[len..][0..3], mirrored_side);
    len += 3;
    for (castling) |byte| {
        out[len] = swapCase(byte);
        len += 1;
    }
    out[len] = ' ';
    len += 1;
    if (std.mem.eql(u8, en_passant, "-")) {
        out[len] = '-';
        len += 1;
    } else {
        if (en_passant.len != 2) return error.InvalidFen;
        out[len] = en_passant[0];
        out[len + 1] = '1' + ('8' - en_passant[1]);
        len += 2;
    }
    const tail = try std.fmt.bufPrint(out[len..], " {s} {s}", .{ halfmove, fullmove });
    return out[0 .. len + tail.len];
}

fn expectKingRuleCase(fen_text: []const u8, mv: move_mod.Move, expected: i32) !void {
    const std = @import("std");
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");

    const pos = try fen.parse(fen_text);
    var moves = move_mod.MoveList.init();
    legal.generate(&pos, &moves);
    var found = false;
    for (moves.slice()) |candidate| found = found or candidate == mv;
    try std.testing.expect(found);

    if (mv.isCapture()) {
        try std.testing.expectEqual(expected, captureScore(&pos, mv));
        try std.testing.expectEqual(expected, captureScoreReference(&pos, mv));
    } else {
        try std.testing.expectEqual(expected, quietScore(&pos, mv));
        try std.testing.expectEqual(expected, quietScoreReference(&pos, mv));
        for ([_]i32{ std.math.minInt(i32), expected - 1, expected, expected + 1, -901, -900, -899, -700, -491, -490, -489, -300, -200, -100, -1, 0, 1 }) |threshold| {
            try std.testing.expectEqual(expected < threshold, quietBelow(&pos, mv, threshold));
        }
    }
}

test "see king may only recapture onto an uncovered square, absolute values" {
    for (KING_RULE_CASES) |case| {
        errdefer @import("std").debug.print("king-rule case failed: {s}\n", .{case.name});
        try expectKingRuleCase(case.fen, move_mod.Move.init(case.from, case.to, case.flag), case.expected);

        var buffer: [128]u8 = undefined;
        const mirrored = try mirrorFen(case.fen, &buffer);
        try expectKingRuleCase(mirrored, move_mod.Move.init(mirrorSquare(case.from), mirrorSquare(case.to), case.flag), case.expected);
    }
}

test "see mirrorFen helper round-trips and mirrors" {
    const std = @import("std");
    var once: [128]u8 = undefined;
    var twice: [128]u8 = undefined;
    const fen_text = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq e3 3 17";
    const mirrored = try mirrorFen(fen_text, &once);
    try std.testing.expectEqualStrings("r3k2r/pppbbppp/2n2q1P/1P2p3/3pn3/BN2PNP1/P1PPQPB1/R3K2R b kqKQ e6 3 17", mirrored);
    try std.testing.expectEqualStrings(fen_text, try mirrorFen(mirrored, &twice));
}
