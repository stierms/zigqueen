const attacks = @import("../movegen/attacks.zig");
const bitboard = @import("../core/bitboard.zig");
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

/// Whether a king of `side` that has just been removed from `occupied` may
/// capture on `target`: true when the opponent has no attacker left there.
inline fn kingMayCapture(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square) bool {
    return leastValuableAttacker(pos, occupied, side.other(), target) == null;
}

pub fn captureScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (!mv.isCapture()) return 0;
    if (mv.flag == .en_passant) return 0;

    const moving_piece = pos.pieceAt(mv.from);
    const captured_piece = pos.pieceAt(mv.to);
    if (moving_piece == .none or captured_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return piece_values.value(captured_piece.pieceType()) - seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// SEE of a QUIET (non-capture) move from the mover's point of view: 0 if the
/// destination is safe, negative if the piece walks into a losing exchange there.
/// Mirrors `captureScore` but with no captured victim -- the opponent initiates
/// the exchange on `mv.to`. Used for SEE-based quiet pruning of late moves.
pub fn quietScore(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    const occupied = (pos.occupied & ~bitboard.bit(mv.from)) | bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return -seeGain(pos, occupied, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// Exact threshold predicate for quietScore, using the same attacker sequence.
/// For G=max(0,V-reply), G>K is equivalent to !(reply>V-K-1) when
/// 0<=K<V. Carry that inversion until a material bound or empty tail decides it.
pub fn quietBelow(pos: *const position.Position, mv: move_mod.Move, threshold: i32) bool {
    // quietScore is nonpositive, including its capture/empty-source sentinels.
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
        const attacker = leastValuableAttacker(pos, occupied, side, mv.to) orelse return inverted;
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

fn seeGain(pos: *const position.Position, start_occupied: bitboard.Bitboard, side: types.Color, target: square.Square, victim_value: i32) i32 {
    var gains: [32]i32 = undefined;
    var ply: usize = 0;
    var attacker_side = side;
    var next_victim_value = victim_value;
    var occupied = start_occupied;

    while (true) {
        const attacker = leastValuableAttacker(pos, occupied, attacker_side, target) orelse break;
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
        gains[ply] = next_victim_value;
        ply += 1;
        next_victim_value = piece_values.value(attacker.piece_type);
        attacker_side = attacker_side.other();
    }

    var gain: i32 = 0;
    while (ply > 0) {
        ply -= 1;
        gain = @max(@as(i32, 0), gains[ply] - gain);
    }
    return gain;
}

inline fn leastValuableAttacker(pos: *const position.Position, occupied: bitboard.Bitboard, side: types.Color, target: square.Square) ?Attacker {
    const row = pos.pieceRow(side);

    var candidates = row[pieceTypeIndex(.pawn)] & occupied & pawnAttackers(side, target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .pawn };

    candidates = row[pieceTypeIndex(.knight)] & occupied & attacks.knightAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .knight };

    const bishop_attacks = attacks.bishopAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.bishop)] & occupied & bishop_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .bishop };

    const rook_attacks = attacks.rookAttacksOnTheFly(target, occupied);
    candidates = row[pieceTypeIndex(.rook)] & occupied & rook_attacks;
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .rook };

    candidates = row[pieceTypeIndex(.queen)] & occupied & (bishop_attacks | rook_attacks);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .queen };

    candidates = row[pieceTypeIndex(.king)] & occupied & attacks.kingAttacksFrom(target);
    if (bitboard.lsb(candidates)) |sq| return .{ .from = sq, .piece_type = .king };

    return null;
}

fn pawnAttackers(side: types.Color, target: square.Square) bitboard.Bitboard {
    return switch (side) {
        .white => attacks.BLACK_PAWN_ATTACKS[target.index()],
        .black => attacks.WHITE_PAWN_ATTACKS[target.index()],
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
    return piece_values.value(captured_piece.pieceType()) - seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

fn quietScoreReference(pos: *const position.Position, mv: move_mod.Move) i32 {
    if (mv.isCapture()) return 0;
    const moving_piece = pos.pieceAt(mv.from);
    if (moving_piece == .none) return 0;

    var state = RefState.fromPosition(pos);
    state.removePiece(moving_piece, mv.from);
    state.occupied |= bitboard.bit(mv.to);

    const mover_after_type = if (mv.promotionPieceType()) |promotion| promotion else moving_piece.pieceType();
    return -seeGainReference(state, pos.side_to_move.other(), mv.to, piece_values.value(mover_after_type));
}

/// Whether `by` attacks `target` in `state`, worked out forwards from every
/// piece's own attack set rather than backwards from the target as the swap
/// does, so the king-legality rule is checked by a second formulation.
fn squareAttackedReference(state: *const RefState, by: types.Color, target: square.Square) bool {
    const ci = @intFromEnum(by);
    for ([_]piece.PieceType{ .pawn, .knight, .bishop, .rook, .queen, .king }) |piece_type| {
        var remaining = state.pieces[ci][pieceTypeIndex(piece_type)];
        while (bitboard.popLsb(&remaining)) |from| {
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

    const gain = victim_value - seeGainReference(next, side.other(), target, piece_values.value(attacker.piece_type));
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

fn expectSeeMatchesReference(pos: *position.Position) !usize {
    const legal = @import("../movegen/legal.zig");
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        try @import("std").testing.expectEqual(captureScoreReference(pos, mv), captureScore(pos, mv));
        try @import("std").testing.expectEqual(quietScoreReference(pos, mv), quietScore(pos, mv));
        if (!mv.isCapture() and !mv.isPromotion()) {
            const floor = -piece_values.value(pos.pieceAt(mv.from).pieceType());
            const reference = quietScoreReference(pos, mv);
            try @import("std").testing.expect(reference >= floor);
            for ([_]i32{ floor - 1, floor, floor + 1, 0 }) |threshold| {
                try @import("std").testing.expectEqual(reference < threshold, threshold > floor and quietScore(pos, mv) < threshold);
            }
        }
        const reference_quiet = quietScoreReference(pos, mv);
        for ([_]i32{
            @import("std").math.minInt(i32), -901,                -900,                            -501, -500,
            -331,                            -330,                -321,                            -320, -101,
            -100,                            -1,                  0,                               1,    reference_quiet - 1,
            reference_quiet,                 reference_quiet + 1, @import("std").math.maxInt(i32),
        }) |threshold| {
            try @import("std").testing.expectEqual(reference_quiet < threshold, quietBelow(pos, mv, threshold));
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
    // The king-legality positions below, in both colours, one ply deep too.
    for (KING_RULE_CASES) |case| {
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

fn mirrorSquare(sq: square.Square) square.Square {
    return square.Square.fromIndex(sq.index() ^ 56);
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
        for ([_]i32{ std.math.minInt(i32), expected - 1, expected, expected + 1, -901, -900, -899, -491, -490, -489, -1, 0, 1 }) |threshold| {
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
