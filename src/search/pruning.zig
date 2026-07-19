const std = @import("std");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

const tunables = @import("tunables.zig");

// Pruning margins/caps are runtime-tunable (SPSA scaffold). Defaults (in
// `tunables.zig`) are the shipped values, so behaviour is identical out of the
// box; an SPSA driver perturbs them via UCI options (-Dtunables builds)
// without recompiling. Forward pruning extends into the mid-tree (RFP to
// depth 6, quiet futility to depth 4) with larger deep margins; the shallow
// range (<= the const below) keeps the separately-tuned shallow margin. The
// min-index gates stay const (structural, not tuned).
const REVERSE_FUTILITY_SHALLOW_MAX_DEPTH: u16 = 3;

pub fn shouldTryNullMove(
    allow_null: bool,
    pos: *const position.Position,
    depth: u16,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    static_eval: ?types.Score,
) bool {
    if (!allow_null) return false;
    if (depth < 3) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;

    const eval_score = static_eval orelse return false;
    if (eval_score + tunables.active.null_static_margin < beta) return false;
    return hasNonPawnMaterial(pos, pos.side_to_move);
}

pub fn shouldReverseFutilityPrune(
    depth: u16,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    static_eval: ?types.Score,
    improving: bool,
) bool {
    if (depth == 0 or depth > @as(u16, @intCast(tunables.active.rfp_max_depth))) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;

    const eval_score = static_eval orelse return false;
    return eval_score - reverseFutilityMargin(depth, improving) >= beta;
}

pub fn isRfpHintApplicable(depth: u16, alpha: types.Score, beta: types.Score) bool {
    if (depth == 0 or depth > @as(u16, @intCast(tunables.active.rfp_max_depth))) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;
    return true;
}

pub fn shouldRazor(
    depth: u16,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    static_eval: ?types.Score,
) bool {
    if (depth == 0 or depth > 2) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;

    const eval_score = static_eval orelse return false;
    return eval_score + razorMargin(depth) <= alpha;
}

pub fn shouldLatePrune(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    improving: bool,
    killer_a: ?move_mod.Move,
    killer_b: ?move_mod.Move,
) bool {
    if (depth < 3 or depth > 6) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;
    if (mv.isCapture() or mv.isPromotion()) return false;
    if (killer_a) |killer| {
        if (killer == mv) return false;
    }
    if (killer_b) |killer| {
        if (killer == mv) return false;
    }
    return move_index >= latePruneThreshold(depth, improving);
}

fn latePruneThreshold(depth: u16, improving: bool) usize {
    const d: usize = @intCast(depth);
    const base: usize = @as(usize, @intCast(tunables.active.lmp_base)) + d * d; // LMP onset (SPSA-tuned)
    if (improving) return base;
    return base / 2;
}

// History pruning: skip late quiet moves whose quiet-history is strongly
// negative in the mid-tree. Conservative: only mid-depth, only past the first
// few moves, and only when history is well below a depth-scaled (more negative
// with depth = safer deeper) threshold.
const HISTORY_PRUNE_MIN_INDEX: usize = 3;

// SEE-based quiet pruning: skip late quiets that walk
// into a losing exchange (SEE below a depth-scaled margin). The gate runs the
// cheap checks first so SEE (expensive) is only computed for the few late quiets
// that could actually be pruned.
const SEE_QUIET_MIN_INDEX: usize = 3;

pub fn seeQuietPruneGate(
    depth: u16,
    move_index: usize,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
) bool {
    if (depth == 0 or depth > @as(u16, @intCast(tunables.active.see_quiet_max_depth))) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    return move_index >= SEE_QUIET_MIN_INDEX;
}

pub fn seeQuietPruneMargin(depth: u16) i32 {
    return tunables.active.see_quiet_margin_per_ply * @as(i32, @intCast(depth));
}

pub fn shouldHistoryPruneQuiet(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    history_score: i32,
    killer_a: ?move_mod.Move,
    killer_b: ?move_mod.Move,
) bool {
    if (depth == 0 or depth > @as(u16, @intCast(tunables.active.history_prune_max_depth))) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (move_index < HISTORY_PRUNE_MIN_INDEX) return false;
    if (killer_a) |killer| {
        if (killer == mv) return false;
    }
    if (killer_b) |killer| {
        if (killer == mv) return false;
    }
    return history_score < tunables.active.history_prune_margin_per_ply * @as(i32, @intCast(depth));
}

pub fn shouldPruneQuietMove(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    static_eval: ?types.Score,
    improving: bool,
    killer_a: ?move_mod.Move,
    killer_b: ?move_mod.Move,
) bool {
    if (depth == 0 or depth > @as(u16, @intCast(tunables.active.quiet_futility_max_depth))) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;
    if (mv.isCapture() or mv.isPromotion()) return false;
    if (move_index < quietFutilityMoveThreshold(depth, improving)) return false;
    if (killer_a) |killer| {
        if (killer == mv) return false;
    }
    if (killer_b) |killer| {
        if (killer == mv) return false;
    }

    const eval_score = static_eval orelse return false;
    return eval_score + quietFutilityMargin(depth, improving) <= alpha;
}

pub fn shouldPruneBadCaptureMove(
    depth: u16,
    move_index: usize,
    mv: move_mod.Move,
    alpha: types.Score,
    beta: types.Score,
    in_check: bool,
    static_eval: ?types.Score,
    improving: bool,
    see_score: i32,
) bool {
    if (depth != 1) return false;
    if (in_check) return false;
    if (isPvWindow(alpha, beta)) return false;
    if (score_mod.isMateLike(alpha) or score_mod.isMateLike(beta)) return false;
    if (!mv.isCapture() or mv.isPromotion()) return false;
    if (see_score >= 0) return false;
    if (move_index < badCaptureMoveThreshold(depth, improving)) return false;

    const eval_score = static_eval orelse return false;
    return eval_score + badCaptureMargin(depth, improving) + see_score <= alpha;
}

fn isPvWindow(alpha: types.Score, beta: types.Score) bool {
    return beta - alpha > 1;
}

fn reverseFutilityMargin(depth: u16, improving: bool) types.Score {
    // Depths 1-3 keep the SPSA-tuned shallow margin; the newly-pruned 4-6 range
    // uses a larger SF-calibrated per-ply margin so deep RFP stays sound.
    const per_ply = if (depth <= REVERSE_FUTILITY_SHALLOW_MAX_DEPTH)
        tunables.active.rfp_margin_per_ply
    else
        tunables.active.rfp_deep_margin_per_ply;
    var margin = @as(types.Score, @intCast(depth)) * per_ply;
    if (!improving) margin += tunables.active.rfp_non_improving_bonus;
    return margin;
}

fn razorMargin(depth: u16) types.Score {
    return tunables.active.razor_base + @as(types.Score, @intCast(depth)) * tunables.active.razor_per_ply;
}

fn quietFutilityMargin(depth: u16, improving: bool) types.Score {
    var margin = tunables.active.quiet_futility_base + @as(types.Score, @intCast(depth)) * tunables.active.quiet_futility_per_ply;
    if (!improving) margin += tunables.active.quiet_futility_non_improving_bonus;
    return margin;
}

fn quietFutilityMoveThreshold(depth: u16, improving: bool) usize {
    return switch (depth) {
        1 => if (improving) 8 else 7,
        2 => if (improving) 14 else 12,
        3 => if (improving) 20 else 17,
        4 => if (improving) 26 else 22,
        5 => if (improving) 32 else 27,
        6 => if (improving) 38 else 32,
        else => std.math.maxInt(usize),
    };
}

fn badCaptureMargin(depth: u16, improving: bool) types.Score {
    var margin = tunables.active.bad_capture_base + @as(types.Score, @intCast(depth)) * tunables.active.bad_capture_per_ply;
    if (!improving) margin += tunables.active.bad_capture_non_improving_bonus;
    return margin;
}

fn badCaptureMoveThreshold(depth: u16, improving: bool) usize {
    return switch (depth) {
        1 => if (improving) 5 else 4,
        2 => if (improving) 8 else 7,
        else => std.math.maxInt(usize),
    };
}

fn hasNonPawnMaterial(pos: *const position.Position, side: types.Color) bool {
    // One row pointer + a branchless OR of the four minor/major bitboards.
    // The previous four short-circuited pieceBitboard calls each copied the
    // whole pieces array to the stack (1.8% of endgame cycles for what is a
    // four-load test); the OR keeps the identical truth value.
    const row = pos.pieceRow(side);
    const non_pawn = row[@intFromEnum(piece.PieceType.knight)] |
        row[@intFromEnum(piece.PieceType.bishop)] |
        row[@intFromEnum(piece.PieceType.rook)] |
        row[@intFromEnum(piece.PieceType.queen)];
    return non_pawn != 0;
}

test "null move stays off in pawn endings, pv windows, and low static eval nodes" {
    const fen = @import("../core/fen.zig");

    const pawns_only = try fen.parse("4k3/8/8/3p4/8/8/4P3/4K3 w - - 0 1");
    const middlegame = try fen.startpos();

    try @import("std").testing.expect(!shouldTryNullMove(true, &pawns_only, 4, -10, 10, false, 10));
    try @import("std").testing.expect(!shouldTryNullMove(true, &middlegame, 4, -20, 20, false, 0));
    try @import("std").testing.expect(!shouldTryNullMove(true, &middlegame, 4, 9, 10, false, -80));
    try @import("std").testing.expect(shouldTryNullMove(true, &middlegame, 4, 9, 10, false, 10));
}

test "reverse futility pruning stays conservative" {
    // Written against the depth-cap constant so it survives margin/cap tuning.
    // Beyond the cap, RFP is off regardless of how large the eval is.
    try @import("std").testing.expect(!shouldReverseFutilityPrune(@as(u16, @intCast(tunables.active.rfp_max_depth)) + 1, 50, 51, false, 30000, true));
    // Guards: PV window, null eval, and in-check nodes never RFP-prune.
    try @import("std").testing.expect(!shouldReverseFutilityPrune(2, -20, 20, true, 500, true));
    try @import("std").testing.expect(!shouldReverseFutilityPrune(2, -20, 20, false, null, true));
    // Shallow node fires when the eval clears beta by the (small) margin, not otherwise.
    try @import("std").testing.expect(shouldReverseFutilityPrune(2, 50, 51, false, 320, true));
    try @import("std").testing.expect(!shouldReverseFutilityPrune(2, 50, 51, false, 100, true));
    // A node at the deep cap needs a much larger margin (sound): tiny edge off, huge edge on.
    try @import("std").testing.expect(!shouldReverseFutilityPrune(@as(u16, @intCast(tunables.active.rfp_max_depth)), 50, 51, false, 200, true));
    try @import("std").testing.expect(shouldReverseFutilityPrune(@as(u16, @intCast(tunables.active.rfp_max_depth)), 50, 51, false, 9000, true));
}

test "razoring stays off in pv windows checks and healthy eval nodes" {
    try @import("std").testing.expect(!shouldRazor(3, 20, 21, false, -500));
    try @import("std").testing.expect(!shouldRazor(2, -20, 20, false, -500));
    try @import("std").testing.expect(!shouldRazor(2, 20, 21, true, -500));
    try @import("std").testing.expect(!shouldRazor(2, 20, 21, false, 100));
    try @import("std").testing.expect(shouldRazor(1, 50, 51, false, -260));
    try @import("std").testing.expect(shouldRazor(2, 50, 51, false, -450));
}

test "quiet futility pruning stays off for pv and tactical moves" {
    const quiet = move_mod.Move.init(.a2, .a3, .quiet);
    const capture = move_mod.Move.init(.a2, .b3, .capture);

    try @import("std").testing.expect(!shouldPruneQuietMove(2, 20, quiet, -10, 20, false, -600, false, null, null));
    try @import("std").testing.expect(!shouldPruneQuietMove(2, 3, quiet, 20, 21, false, -600, false, null, null));
    try @import("std").testing.expect(!shouldPruneQuietMove(2, 20, capture, 20, 21, false, -600, false, null, null));
    try @import("std").testing.expect(!shouldPruneQuietMove(2, 20, quiet, 20, 21, false, -600, false, quiet, null));
    try @import("std").testing.expect(shouldPruneQuietMove(1, 8, quiet, 20, 21, false, -500, false, null, null));
    try @import("std").testing.expect(shouldPruneQuietMove(2, 20, quiet, 20, 21, false, -600, false, null, null));
}

test "bad capture pruning stays off for early, pv, and non-losing captures" {
    const capture = move_mod.Move.init(.e4, .d5, .capture);
    const quiet = move_mod.Move.init(.a2, .a3, .quiet);
    const promo_capture = move_mod.Move.init(.a7, .b8, .promo_queen_capture);

    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 20, quiet, 20, 21, false, -600, false, -200));
    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 20, capture, -10, 20, false, -600, false, -200));
    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 3, capture, 20, 21, false, -600, false, -200));
    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 20, capture, 20, 21, false, -600, false, 0));
    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 20, promo_capture, 20, 21, false, -600, false, -200));
    try @import("std").testing.expect(shouldPruneBadCaptureMove(1, 5, capture, 20, 21, false, -500, false, -200));
    try @import("std").testing.expect(!shouldPruneBadCaptureMove(2, 8, capture, 20, 21, false, -700, false, -200));
}
