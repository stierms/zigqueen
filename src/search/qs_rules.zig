//! Per-move rules of the quiescence search (round 3, 2026-11-13).
//!
//! Every rule is a tuning-flavour switch; the release flavour reads the
//! compiled-in defaults (`tunables.knob`), so both flavours search the same
//! tree at the defaults. The predicates take their inputs as plain values,
//! so each rule is tested without a search.

const std = @import("std");
const attacks = @import("../movegen/attacks.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const score_mod = @import("score.zig");
const tunables = @import("tunables.zig");
const types = @import("../core/types.zig");

/// Victim classes of the gain table: pawn, minor piece, rook, queen.
pub const VICTIM_CLASS_COUNT: usize = 4;
pub const VICTIM_CLASS_NAMES = [VICTIM_CLASS_COUNT][]const u8{ "pawn", "minor", "rook", "queen" };

pub fn victimClass(victim: piece.PieceType) usize {
    return switch (victim) {
        .pawn => 0,
        .knight, .bishop => 1,
        .rook => 2,
        else => 3,
    };
}

/// What a capture may add to the stand-pat, by victim, in the evaluation's
/// own unit (a pawn is about 220 near equality and the scale saturates near
/// 850 to 1150; the exchange evaluator's 100/320/330/500/900 is another unit).
pub const Gains = [VICTIM_CLASS_COUNT]types.Score;

pub inline fn moveFutilityEnabled() bool {
    return tunables.knob("qs_move_futility") != 0;
}

pub inline fn gains() Gains {
    return .{
        tunables.knob("qs_gain_pawn"),
        tunables.knob("qs_gain_minor"),
        tunables.knob("qs_gain_rook"),
        tunables.knob("qs_gain_queen"),
    };
}

/// With the switch on, a capture that gives check is searched whatever the
/// distance to alpha.
pub inline fn futilityKeepsChecks() bool {
    return tunables.knob("qs_futility_keep_checks") != 0;
}

/// The victim of a capture that is not a promotion (en passant takes a pawn).
pub inline fn capturedType(pos: anytype, mv: move_mod.Move) piece.PieceType {
    return if (mv.flag == .en_passant) .pawn else pos.pieceAt(mv.to).pieceType();
}

/// QsMoveFutility: the stand-pat plus all the capture can gain does not reach
/// the best value so far. `best` is the node's running lower bound (alpha or
/// better); a decisive one is never argued with in evaluation units.
pub fn captureFutile(stand_pat: types.Score, gain: types.Score, best: types.Score) bool {
    if (score_mod.isDecisive(best)) return false;
    return stand_pat + gain <= best;
}

/// QsEqualExchangeMargin, 0 = off.
pub inline fn equalExchangeMargin() types.Score {
    return tunables.knob("qs_equal_exchange_margin");
}

/// QsEqualExchangeMargin: a capture whose exchange value is exactly 0 nets
/// nothing by the exchange evaluator's count, so it is skipped once the
/// stand-pat is `margin` or more below the best value so far.
pub fn equalExchangeFutile(margin: types.Score, exchange_value: i32, stand_pat: types.Score, best: types.Score) bool {
    if (margin <= 0 or exchange_value != 0) return false;
    if (score_mod.isDecisive(best)) return false;
    return stand_pat + margin <= best;
}

/// Whether the ordering's exchange value of a capture is a computed one. It
/// is 0 without a computation for the table move (`scoreTacticalMoves`
/// writes it) and for every en passant capture (`see.captureScoreWith`
/// returns it); promotions get 0 as well and never reach the capture rules.
/// Only a plain capture that is not the table move has a real value, and
/// only that can be an equal exchange.
pub fn exchangeValueComputed(mv: move_mod.Move, is_table_move: bool) bool {
    return !is_table_move and mv.flag == .capture;
}

test "only a plain capture that is not the table move has a computed exchange value" {
    const capture = move_mod.Move.init(.e4, .d5, .capture);
    try std.testing.expect(exchangeValueComputed(capture, false));
    try std.testing.expect(!exchangeValueComputed(capture, true));
    // En passant: the exchange evaluator's 0 is a placeholder.
    try std.testing.expect(!exchangeValueComputed(move_mod.Move.init(.e5, .d6, .en_passant), false));
    // Promotions with capture are scored as promotions, with 0.
    try std.testing.expect(!exchangeValueComputed(move_mod.Move.init(.e7, .d8, .promo_queen_capture), false));
    try std.testing.expect(!exchangeValueComputed(move_mod.Move.init(.e7, .d8, .promo_knight_capture), false));
    try std.testing.expect(!exchangeValueComputed(move_mod.Move.init(.e2, .e4, .quiet), false));
}

test "QsEqualExchangeMargin skips only an exchange of exactly 0, a margin below alpha, and is off at 0" {
    try std.testing.expect(equalExchangeFutile(150, 0, 50, 200));
    try std.testing.expect(!equalExchangeFutile(150, 0, 51, 200));
    // An exchange that wins or loses anything is not this rule's.
    try std.testing.expect(!equalExchangeFutile(150, 1, -500, 200));
    try std.testing.expect(!equalExchangeFutile(150, -1, -500, 200));
    // Margin 0 is the switch's off position.
    try std.testing.expect(!equalExchangeFutile(0, 0, -500, 200));
    try std.testing.expect(!equalExchangeFutile(150, 0, 50, score_mod.MATE_SCORE - 10));
}

pub inline fn noUnderpromotion() bool {
    return tunables.knob("qs_no_underpromotion") != 0;
}

/// QsNoUnderpromotion names the promotions to a rook or a bishop, with or
/// without a capture. A queen does all either does except in stalemate
/// tricks; the knight's promotion is a different move and stays.
pub fn isRookOrBishopPromotion(mv: move_mod.Move) bool {
    return switch (mv.flag) {
        .promo_rook, .promo_bishop, .promo_rook_capture, .promo_bishop_capture => true,
        else => false,
    };
}

test "QsNoUnderpromotion names rook and bishop promotions and keeps the knight's and the queen's" {
    const Flag = move_mod.MoveFlag;
    for ([_]Flag{ .promo_rook, .promo_bishop, .promo_rook_capture, .promo_bishop_capture }) |flag| {
        try std.testing.expect(isRookOrBishopPromotion(move_mod.Move.init(.a7, .a8, flag)));
    }
    for ([_]Flag{ .promo_knight, .promo_queen, .promo_knight_capture, .promo_queen_capture, .capture, .quiet, .en_passant }) |flag| {
        try std.testing.expect(!isRookOrBishopPromotion(move_mod.Move.init(.a7, .a8, flag)));
    }
}

/// QsCheckGate: which first-ply nodes search their quiet checks.
pub const CheckGate = enum(u2) {
    /// Every node (as before the gate).
    all = 0,
    /// Nodes near alpha, or with the enemy king boxed in.
    near_or_boxed = 1,
    /// The same nodes; the checks go by piece and end after a number of
    /// them that raise nothing, unless the king is boxed in.
    near_or_boxed_limited = 2,
    /// Only nodes that have no capture or promotion to try (the control).
    none = 3,
};

pub inline fn checkGate() CheckGate {
    return @enumFromInt(@as(u2, @intCast(tunables.knob("qs_check_gate"))));
}

pub inline fn checkMargin() types.Score {
    return tunables.knob("qs_check_margin");
}

pub inline fn checkFailLowLimit() u32 {
    return @intCast(tunables.knob("qs_check_fail_lows"));
}

/// The stand-pat is the margin or more below the best value so far.
pub fn checkFar(stand_pat: types.Score, margin: types.Score, best: types.Score) bool {
    if (score_mod.isDecisive(best)) return false;
    return stand_pat + margin <= best;
}

/// The side to move has a queen and the enemy king has at most one square to
/// go to that this side does not attack: the picture of a mate or a
/// perpetual one move past the horizon. Attacks are taken on the board as it
/// stands (a slider does not see through the king).
pub fn kingBoxed(pos: anytype) bool {
    const side = pos.side_to_move;
    if (pos.pieceBitboard(side, .queen) == 0) return false;
    const enemy = side.other();
    const king = pos.kingSquare(enemy) orelse return false;
    const flights = attacks.kingAttacksFrom(king) & ~pos.occupancyFor(enemy) & ~attacks.attackedSquares(pos, side);
    return @popCount(flights) <= 1;
}

/// Whether the gate's answer depends on the king test.
pub fn checkGateAsksKing(gate: CheckGate, empty_tactical: bool, far: bool) bool {
    return switch (gate) {
        .all, .none => false,
        .near_or_boxed, .near_or_boxed_limited => !empty_tactical and far,
    };
}

/// A node without a capture or promotion always searches its quiet checks:
/// nothing else there can see a mate in one.
pub fn checkGateOpen(gate: CheckGate, empty_tactical: bool, far: bool, king_boxed: bool) bool {
    if (empty_tactical) return true;
    return switch (gate) {
        .all => true,
        .near_or_boxed, .near_or_boxed_limited => !far or king_boxed,
        .none => false,
    };
}

/// Order of the quiet checks under the limited gate: queen, rook, minor
/// piece, then the rest (pawns, and kings that uncover a check).
pub const CHECK_CLASS_COUNT: usize = 4;

pub fn checkClass(mover: piece.PieceType) usize {
    return switch (mover) {
        .queen => 0,
        .rook => 1,
        .bishop, .knight => 2,
        else => 3,
    };
}

test "QsCheckGate opens near alpha, for a boxed-in king and always without a capture" {
    try std.testing.expect(!checkFar(100, 200, 299));
    try std.testing.expect(checkFar(100, 200, 300));
    try std.testing.expect(!checkFar(100, 200, score_mod.MATE_SCORE - 10));
    inline for (.{ CheckGate.all, CheckGate.near_or_boxed, CheckGate.near_or_boxed_limited, CheckGate.none }) |gate| {
        // No capture or promotion: the checks are all the node has.
        try std.testing.expect(checkGateOpen(gate, true, true, false));
        try std.testing.expect(!checkGateAsksKing(gate, true, true));
    }
    try std.testing.expect(checkGateOpen(.all, false, true, false));
    try std.testing.expect(!checkGateOpen(.none, false, false, true));
    inline for (.{ CheckGate.near_or_boxed, CheckGate.near_or_boxed_limited }) |gate| {
        try std.testing.expect(checkGateOpen(gate, false, false, false));
        try std.testing.expect(!checkGateOpen(gate, false, true, false));
        try std.testing.expect(checkGateOpen(gate, false, true, true));
        try std.testing.expect(checkGateAsksKing(gate, false, true));
        try std.testing.expect(!checkGateAsksKing(gate, false, false));
    }
    try std.testing.expectEqual(@as(usize, 0), checkClass(.queen));
    try std.testing.expectEqual(@as(usize, 1), checkClass(.rook));
    try std.testing.expectEqual(checkClass(.bishop), checkClass(.knight));
    try std.testing.expectEqual(@as(usize, 3), checkClass(.pawn));
    const defaults = tunables.Tunables{};
    try std.testing.expectEqual(@as(types.Score, 0), defaults.qs_check_gate);
    try std.testing.expectEqual(@as(types.Score, 200), defaults.qs_check_margin);
    try std.testing.expectEqual(@as(types.Score, 2), defaults.qs_check_fail_lows);
}

test "the king test needs a queen and a king with at most one free square" {
    const fen = @import("../core/fen.zig");
    // h8 has g8, g7 and h7, all attacked by the queen on g6.
    try std.testing.expect(kingBoxed(&try fen.parse("7k/8/5KQ1/8/8/8/8/8 w - - 0 1")));
    // The same king against a rook: no queen, no test.
    try std.testing.expect(!kingBoxed(&try fen.parse("7k/8/5KR1/8/8/8/8/8 w - - 0 1")));
    // A castled king behind its pawns and beside its rook has h8 only.
    try std.testing.expect(kingBoxed(&try fen.parse("5rk1/5ppp/8/8/8/8/8/Q3K3 w - - 0 1")));
    // Two free squares (f8, h8) are too many.
    try std.testing.expect(!kingBoxed(&try fen.parse("6k1/5ppp/8/8/8/8/8/Q3K3 w - - 0 1")));
    // A king in the open.
    try std.testing.expect(!kingBoxed(&try fen.parse("8/8/4k3/8/8/8/8/Q3K3 w - - 0 1")));
}

test "QsMoveFutility skips a capture only when stand-pat plus the victim's gain stays at or below alpha" {
    const table = Gains{ 300, 850, 950, 1100 };
    // A pawn cannot lift a position 300 or more below alpha; one unit less can.
    try std.testing.expect(captureFutile(-100, table[victimClass(.pawn)], 200));
    try std.testing.expect(!captureFutile(-99, table[victimClass(.pawn)], 200));
    // The same distance is within a knight's, bishop's, rook's or queen's gain.
    try std.testing.expect(!captureFutile(-100, table[victimClass(.knight)], 200));
    try std.testing.expect(!captureFutile(-100, table[victimClass(.bishop)], 700));
    try std.testing.expect(captureFutile(-100, table[victimClass(.bishop)], 750));
    try std.testing.expect(!captureFutile(-100, table[victimClass(.rook)], 849));
    try std.testing.expect(captureFutile(-100, table[victimClass(.rook)], 850));
    try std.testing.expect(captureFutile(-100, table[victimClass(.queen)], 1000));
    try std.testing.expect(!captureFutile(-100, table[victimClass(.queen)], 999));
    // A mate or tablebase bound as alpha is no distance in evaluation units.
    try std.testing.expect(!captureFutile(-100, 300, score_mod.MATE_SCORE - 10));
    try std.testing.expect(!captureFutile(-100, 300, score_mod.TB_WIN_SCORE - 10));
    try std.testing.expect(!captureFutile(-score_mod.ORDINARY_SCORE_LIMIT, 300, -score_mod.MATE_SCORE + 10));
}

test "the quiescence rules' integration defaults: the capture rules on, the check gate off" {
    const defaults = tunables.Tunables{};
    try std.testing.expectEqual(@as(types.Score, 1), defaults.qs_move_futility);
    try std.testing.expectEqual(@as(types.Score, 1), defaults.qs_futility_keep_checks);
    try std.testing.expectEqual(@as(types.Score, 350), defaults.qs_gain_pawn);
    try std.testing.expectEqual(@as(types.Score, 1000), defaults.qs_gain_minor);
    try std.testing.expectEqual(@as(types.Score, 1200), defaults.qs_gain_rook);
    try std.testing.expectEqual(@as(types.Score, 1400), defaults.qs_gain_queen);
    try std.testing.expectEqual(@as(types.Score, 450), defaults.qs_equal_exchange_margin);
    try std.testing.expectEqual(@as(types.Score, 1), defaults.qs_no_underpromotion);
    try std.testing.expectEqual(@as(types.Score, 0), defaults.qs_check_gate);
}
