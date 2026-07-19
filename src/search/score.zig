const std = @import("std");
const types = @import("../core/types.zig");

pub const MATE_SCORE: types.Score = 29_000;
pub const MATE_THRESHOLD: types.Score = MATE_SCORE - 128;

pub fn isMateLike(score: types.Score) bool {
    const abs_score = if (score < 0) -score else score;
    return abs_score >= MATE_THRESHOLD;
}

pub fn scoreToMate(score: types.Score) i32 {
    std.debug.assert(isMateLike(score));
    const sign: i32 = if (score >= 0) 1 else -1;
    const abs_score = if (score < 0) -score else score;
    const plies_to_mate = MATE_SCORE - abs_score;
    const moves_to_mate = @divFloor(plies_to_mate + 1, 2);
    return sign * moves_to_mate;
}

test "mate helpers classify and convert mate scores" {
    try std.testing.expect(isMateLike(28_999));
    try std.testing.expect(!isMateLike(400));
    try std.testing.expectEqual(@as(i32, 1), scoreToMate(28_999));
    try std.testing.expectEqual(@as(i32, -2), scoreToMate(-28_997));
}


/// Rule-50 eval decay (conversion pressure): as the halfmove clock climbs
/// toward the 50-move draw, the static advantage visibly shrinks, so the
/// search prefers lines that reset the clock (pawn moves, captures) over
/// shuffling. Apply AFTER cache retrieval — the TT/eval-cache store the
/// undecayed value because the zobrist key excludes the halfmove clock.
pub inline fn rule50Decay(eval_score: @import("../core/types.zig").Score, halfmove_clock: u16) @import("../core/types.zig").Score {
    // Thresholded: no distortion in the normal-play clock range (the fast-TC
    // tax lived there); full conversion pressure once shuffling territory
    // begins. Decays linearly from 1.0 at hmc=20 to 0.5 at hmc=100.
    const hmc: i32 = @min(@as(i32, halfmove_clock), 100);
    if (hmc <= 20) return eval_score;
    return @intCast(@divTrunc(@as(i32, eval_score) * (180 - (hmc - 20)), 180));
}

test "rule50 decay: unity below the threshold, shrinking above" {
    const t = @import("std").testing;
    try t.expectEqual(@as(i32, 100), rule50Decay(100, 0));
    try t.expectEqual(@as(i32, 100), rule50Decay(100, 20));
    try t.expectEqual(@as(i32, 83), rule50Decay(100, 50)); // (180-30)/180
    try t.expectEqual(@as(i32, 55), rule50Decay(100, 100)); // (180-80)/180
    try t.expectEqual(@as(i32, -83), rule50Decay(-100, 50));
    try t.expectEqual(@as(i32, 0), rule50Decay(0, 80));
    try t.expectEqual(@as(i32, 55), rule50Decay(100, 250)); // clamped
}
