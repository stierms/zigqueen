const std = @import("std");
const types = @import("../core/types.zig");

pub const MATE_SCORE: types.Score = 29_000;
pub const MATE_THRESHOLD: types.Score = MATE_SCORE - 128;
pub const TB_WIN_SCORE: types.Score = 28_000;
pub const TB_DECISIVE_THRESHOLD: types.Score = TB_WIN_SCORE - 1024;

fn absScore(score: types.Score) types.Score {
    return if (score < 0) -score else score;
}

pub fn isMateLike(score: types.Score) bool {
    return absScore(score) >= MATE_THRESHOLD;
}

pub fn isTablebaseDecisive(score: types.Score) bool {
    const abs_score = absScore(score);
    return abs_score >= TB_DECISIVE_THRESHOLD and abs_score < MATE_THRESHOLD;
}

pub fn isDecisive(score: types.Score) bool {
    return isMateLike(score) or isTablebaseDecisive(score);
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

test "decisive score predicate includes tablebase band without changing mate classification" {
    try std.testing.expect(isDecisive(MATE_SCORE - 1));
    try std.testing.expect(isDecisive(TB_WIN_SCORE));
    try std.testing.expect(isDecisive(-TB_WIN_SCORE + 128));
    try std.testing.expect(isDecisive(TB_DECISIVE_THRESHOLD));
    try std.testing.expect(!isDecisive(TB_DECISIVE_THRESHOLD - 1));
    try std.testing.expect(!isMateLike(TB_WIN_SCORE));
}
