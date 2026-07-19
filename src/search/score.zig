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
