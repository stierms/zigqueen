const std = @import("std");
const types = @import("../core/types.zig");

pub const MATE_SCORE: types.Score = 29_000;
pub const MATE_THRESHOLD: types.Score = MATE_SCORE - 128;
pub const TB_WIN_SCORE: types.Score = 28_000;
pub const TB_DECISIVE_THRESHOLD: types.Score = TB_WIN_SCORE - 1024;
/// The largest ordinary score: evaluations and the margin arithmetic built on
/// them stay within +/- this, so the band above holds only tablebase distances
/// and mates (`toTt` rebases it by ply). The NNUE Scale Percent option alone
/// could otherwise lift an evaluation into it: at 360 a five-queen position
/// evaluated to 27,396 (review round, S-TB-PLY). Raw and corrected evaluation
/// and the qsearch fail-low margin clamp to it (`clampOrdinary`).
pub const ORDINARY_SCORE_LIMIT: types.Score = TB_DECISIVE_THRESHOLD - 1;

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

/// An ordinary score kept below the tablebase band (`ORDINARY_SCORE_LIMIT`).
pub inline fn clampOrdinary(score: types.Score) types.Score {
    return std.math.clamp(score, -ORDINARY_SCORE_LIMIT, ORDINARY_SCORE_LIMIT);
}

/// The TT form of a score found `ply` plies from the root. A tablebase win or
/// loss (`wdlScore`: TB_WIN_SCORE - ply of the probe) is stored as a distance
/// from this node rather than from the root, so an entry read back at another
/// ply, after a transposition or in a later search, keeps the right distance
/// (audit A, S-TB-PLY). Every other score is stored as it is: mate scores are
/// never trusted for cutoffs (tt_probe.zig), and ordinary scores are clamped
/// below the tablebase band (`ORDINARY_SCORE_LIMIT`).
pub inline fn toTt(score: types.Score, ply: usize) types.Score {
    if (!isTablebaseDecisive(score)) return score;
    const distance: types.Score = @intCast(ply);
    return if (score > 0) score + distance else score - distance;
}

/// The inverse of `toTt` for an entry read at `ply`.
pub inline fn fromTt(score: types.Score, ply: usize) types.Score {
    if (!isTablebaseDecisive(score)) return score;
    const distance: types.Score = @intCast(ply);
    return if (score > 0) score - distance else score + distance;
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

test "tablebase scores are stored relative to the node and read back at any ply" {
    // Report 2's case: a TB win found at ply 8, stored by its ply-2 ancestor,
    // read back at ply 4 is two plies nearer the root's view.
    const found = TB_WIN_SCORE - 8;
    const stored = toTt(found, 2);
    try std.testing.expectEqual(TB_WIN_SCORE - 6, stored);
    try std.testing.expectEqual(found, fromTt(stored, 2));
    try std.testing.expectEqual(TB_WIN_SCORE - 10, fromTt(stored, 4));
    // Losses mirror wins.
    try std.testing.expectEqual(-TB_WIN_SCORE + 6, toTt(-found, 2));
    try std.testing.expectEqual(-TB_WIN_SCORE + 10, fromTt(toTt(-found, 2), 4));
    // Evaluations, draws and mate scores are untouched at every ply.
    for ([_]types.Score{ 0, 31, -450, TB_DECISIVE_THRESHOLD - 1, -(TB_DECISIVE_THRESHOLD - 1), MATE_SCORE - 3, -MATE_SCORE + 5 }) |score| {
        for ([_]usize{ 0, 1, 7, 100 }) |ply| {
            try std.testing.expectEqual(score, toTt(score, ply));
            try std.testing.expectEqual(score, fromTt(score, ply));
        }
    }
    // Ply 0 (the root) is the identity for tablebase scores too.
    try std.testing.expectEqual(found, toTt(found, 0));
}

test "ordinary scores are clamped below the tablebase band and never rebased" {
    // Review round (S-TB-PLY): 27,396, an evaluation at NNUE Scale Percent 360,
    // was stored at ply 2 as 27,398 and read at ply 4 as 27,394.
    try std.testing.expectEqual(ORDINARY_SCORE_LIMIT, clampOrdinary(27_396));
    try std.testing.expectEqual(-ORDINARY_SCORE_LIMIT, clampOrdinary(-27_396));
    for ([_]types.Score{ 0, 31, -3_348, ORDINARY_SCORE_LIMIT, -ORDINARY_SCORE_LIMIT }) |score| {
        try std.testing.expectEqual(score, clampOrdinary(score));
        try std.testing.expect(!isDecisive(score));
        for ([_]usize{ 0, 2, 4, 100 }) |ply| {
            try std.testing.expectEqual(score, toTt(score, ply));
            try std.testing.expectEqual(score, fromTt(score, ply));
        }
    }
    // Genuine tablebase distances, down to the band's edge, still rebase.
    try std.testing.expectEqual(TB_DECISIVE_THRESHOLD + 2, toTt(TB_DECISIVE_THRESHOLD, 2));
    try std.testing.expectEqual(-TB_WIN_SCORE + 12, fromTt(-TB_WIN_SCORE + 8, 4));
}
