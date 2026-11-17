//! Progress terms: what the search adds to the network's eval so that a won
//! position scores higher the closer it is to being won (roadmap item 4,
//! conversion). The network's eval is flat there: K+R against K shuffled at
//! +6.0 to +6.3 for fifty moves, and nothing in a 5k-node search tells
//! progress from waiting.
//!
//! - With a pawn on the board: what favours the root side beyond the decided
//!   threshold is damped by the halfmove clock (basin.Params.clockPressure),
//!   so a pawn move or capture is worth more to the side that has to win than
//!   waiting. Only the side that is ahead is pressed: the root side's view of
//!   a position it is defending stays the network's.
//! - Without pawns nothing cheap resets the clock. The one case with a known
//!   direction is a bare king against mating material: the bare king has to
//!   go to the edge (with bishop and knight, to a corner of the bishop's
//!   colour) and the other king has to come close (`bareKingBonus`).

const std = @import("std");
const basin = @import("basin.zig");
const fen = @import("../core/fen.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

const LIGHT_SQUARES: u64 = 0x55AA_55AA_55AA_55AA;

/// Table keys of the evaluation contexts the clock pressure creates, by root
/// side. Arbitrary constants with bits in both halves of the key (the table
/// takes its cluster from the low half and its tag from the high half).
const PRESSURE_CONTEXT = [2]u64{ 0x9E6C_63D0_676A_9A99, 0xD1B5_4A32_D192_ED03 };
/// Spreads a clock bucket's number over the key (an odd multiplier: every
/// bucket gets its own key).
const CLOCK_BUCKET_MIX: u64 = 0xC2B2_AE3D_27D4_EB4F;

/// The evaluation context of a search, as far as its table entries depend on
/// it (SearchContext.table_context). A searched score depends on it in three
/// ways: with the pressure on, what favours the root side beyond the decided
/// threshold is damped; which side that is depends on the root; and by how
/// much depends on the halfmove clock, which the position key does not hold.
/// `key` is added to the position key in every table access of the search:
/// 0 while the pressure is off; with it on, one key per root side and clock
/// bucket. A bound computed in one context is then never found from another:
/// not by a search of a game that is not ahead, not by a search for the
/// other side, not at a clock in another bucket. Within a bucket a bound is
/// reused as it is, as a table reuses a bound across paths everywhere else:
/// for one reuse at a clock up to bucket - 1 plies away the value differs by
/// about that many 150ths of what exceeds the floor (30 cp for 600 cp at
/// clocks 0 and 15); that is an estimate of size, not a guarantee, and a
/// bound built from other reused bounds can be further off. The network's
/// eval has no context; the raw-eval cache keeps position keys.
pub const TableContext = struct {
    /// 0 while the pressure is off, else the key of the root side's context.
    base: u64 = 0,
    /// basin.Params.progress_clock_bucket.
    clock_bucket: i32 = 16,

    pub inline fn of(pressure: bool, root_side: types.Color, clock_bucket: i32) TableContext {
        return .{ .base = if (pressure) PRESSURE_CONTEXT[@intFromEnum(root_side)] else 0, .clock_bucket = clock_bucket };
    }

    pub inline fn key(self: TableContext, halfmove_clock: u16) u64 {
        if (self.base == 0) return 0;
        const bucket: u64 = @intCast(@divTrunc(@min(@as(i32, halfmove_clock), MAX_CLOCK), self.clock_bucket));
        return self.base ^ (bucket *% CLOCK_BUCKET_MIX);
    }
};

/// The clock counts to the fifty-move limit; a search keeps one key per
/// clock up to it (SearchContext.table_keys).
pub const MAX_CLOCK = 100;
pub const CLOCK_KEYS = MAX_CLOCK + 1;

/// The halfmove clock after `mv` is made on `pos`, for the table key of a
/// child that is prefetched before the move is made.
pub inline fn clockAfter(pos: *const position.Position, mv: move_mod.Move) u16 {
    return if (mv.isCapture() or pos.pieceAt(mv.from).pieceType() == .pawn) 0 else pos.halfmove_clock + 1;
}

/// Whether a search runs under the pressure, decided before it starts from
/// the game's last search (predecessor.zig): on when that search ended at or
/// above the gate, and, when that search itself ran under the pressure, as
/// long as it did not end below the leave line (basin.Params
/// .progress_root_leave).
pub inline fn gateOpen(params: *const basin.Params, last_score: types.Score, last_pressure: bool) bool {
    const line = if (last_pressure) @min(params.progress_root_leave, params.progress_root_gate) else params.progress_root_gate;
    return last_score >= line;
}

/// The static eval as the search decides on it. Table and eval-cache slots
/// keep the network's eval; this is applied on every read. `root_side` is the
/// side to move at the root of the running search; `pressure` says whether
/// that search's root is ahead (SearchContext.progress_pressure).
pub inline fn searchEval(params: *const basin.Params, eval: types.Score, pos: *const position.Position, root_side: types.Color, pressure: bool) types.Score {
    if ((pos.pieceBitboard(.white, .pawn) | pos.pieceBitboard(.black, .pawn)) != 0) {
        return if (pressure) params.clockPressure(eval, pos.halfmove_clock, pos.side_to_move == root_side) else eval;
    }
    return score_mod.clampOrdinary(eval + bareKingBonus(pos, params.bare_king_unit));
}

/// From the side to move's view: `unit` centipawns for each step the bare
/// king is from the centre (twice) and for each step the kings are closer.
/// Zero unless one side has only its king and the other, without pawns, has
/// material that forces mate: a rook or queen, bishops on both colours, or
/// bishop and knight.
pub fn bareKingBonus(pos: *const position.Position, unit: i32) types.Score {
    inline for ([_]types.Color{ .white, .black }) |strong| {
        const weak = strong.other();
        const weak_men = pos.pieceBitboard(weak, .pawn) | pos.pieceBitboard(weak, .knight) | pos.pieceBitboard(weak, .bishop) |
            pos.pieceBitboard(weak, .rook) | pos.pieceBitboard(weak, .queen);
        if (weak_men == 0 and pos.pieceBitboard(strong, .pawn) == 0) {
            const heavy = pos.pieceBitboard(strong, .rook) | pos.pieceBitboard(strong, .queen);
            const bishops = pos.pieceBitboard(strong, .bishop);
            const bishop_pair = (bishops & LIGHT_SQUARES) != 0 and (bishops & ~LIGHT_SQUARES) != 0;
            const bishop_and_knight = bishops != 0 and pos.pieceBitboard(strong, .knight) != 0;
            if (heavy != 0 or bishop_pair or bishop_and_knight) {
                const weak_king: i32 = @intFromEnum(pos.kingSquare(weak) orelse return 0);
                const strong_king: i32 = @intFromEnum(pos.kingSquare(strong) orelse return 0);
                const file = @mod(weak_king, 8);
                const rank = @divTrunc(weak_king, 8);
                const file_gap: i32 = @intCast(@abs(file - @mod(strong_king, 8)));
                const rank_gap: i32 = @intCast(@abs(rank - @divTrunc(strong_king, 8)));
                const kings_apart = @max(file_gap, rank_gap);
                const toward_mate: i32 = if (heavy == 0 and !bishop_pair) blk: {
                    // Bishop and knight mate only in a corner of the bishop's
                    // colour (a1 and h8 are dark): 7 less the distance to the nearer one.
                    const dark = (bishops & ~LIGHT_SQUARES) != 0;
                    const first = if (dark) file + rank else file + (7 - rank);
                    const second = if (dark) (7 - file) + (7 - rank) else (7 - file) + rank;
                    break :blk 7 - @min(first, second);
                } else blk: {
                    // Steps from the four centre squares, 0 to 6.
                    const from_centre_file = if (file < 4) 3 - file else file - 4;
                    const from_centre_rank = if (rank < 4) 3 - rank else rank - 4;
                    break :blk from_centre_file + from_centre_rank;
                };
                const bonus = unit * (2 * toward_mate + (7 - kings_apart));
                return if (pos.side_to_move == strong) bonus else -bonus;
            }
        }
    }
    return 0;
}

test "the bare-king term grows as the bare king nears the edge and the kings close in" {
    const unit: i32 = 10;
    const centre = try fen.parse("8/8/8/3k4/8/8/8/R3K3 w - - 0 1");
    const edge = try fen.parse("3k4/8/8/8/8/8/8/R3K3 w - - 0 1");
    const edge_close = try fen.parse("3k4/8/3K4/8/8/8/8/R7 w - - 0 1");
    try std.testing.expect(bareKingBonus(&centre, unit) < bareKingBonus(&edge, unit));
    try std.testing.expect(bareKingBonus(&edge, unit) < bareKingBonus(&edge_close, unit));
    try std.testing.expectEqual(unit * (2 * 3 + (7 - 2)), bareKingBonus(&edge_close, unit));
    // The bare king's side sees the same amount with the other sign.
    const edge_close_black = try fen.parse("3k4/8/3K4/8/8/8/8/R7 b - - 0 1");
    try std.testing.expectEqual(-bareKingBonus(&edge_close, unit), bareKingBonus(&edge_close_black, unit));
    // Mirrored colours.
    const black_strong = try fen.parse("r7/8/8/8/8/3k4/8/3K4 b - - 0 1");
    try std.testing.expectEqual(bareKingBonus(&edge_close, unit), bareKingBonus(&black_strong, unit));
}

test "bishop and knight drive the bare king to a corner of the bishop's colour" {
    const unit: i32 = 10;
    // Dark-squared bishop: a1 and h8 are the mating corners.
    const right_corner = try fen.parse("7k/8/5K2/8/8/8/8/2B3N1 w - - 0 1");
    const wrong_corner = try fen.parse("k7/8/2K5/8/8/8/8/2B3N1 w - - 0 1");
    try std.testing.expect(bareKingBonus(&right_corner, unit) > bareKingBonus(&wrong_corner, unit));
    // Light-squared bishop: a8 and h1.
    const light_right = try fen.parse("k7/8/2K5/8/8/8/8/3B2N1 w - - 0 1");
    try std.testing.expectEqual(bareKingBonus(&right_corner, unit), bareKingBonus(&light_right, unit));
}

test "the bare-king term is zero without a bare king, with pawns, or without mating material" {
    const unit: i32 = 10;
    for ([_][]const u8{
        "4k3/8/8/8/8/8/8/4K3 w - - 0 1", // bare kings
        "3k4/8/3K4/8/8/8/8/N7 w - - 0 1", // one knight
        "3k4/8/3K4/8/8/8/8/NN6 w - - 0 1", // two knights
        "3k4/8/3K4/8/8/8/8/B7 w - - 0 1", // one bishop
        "3k4/8/3K4/8/8/8/8/B1B5 w - - 0 1", // bishops on one colour
        "3k4/8/3K4/8/8/8/P7/R7 w - - 0 1", // a pawn: the clock damping's case
        "3k4/7p/3K4/8/8/8/8/R7 w - - 0 1", // the weaker side has a pawn
        "3k4/7n/3K4/8/8/8/8/Q7 w - - 0 1", // the weaker side has a piece
        "r1bqkbnr/pppppppp/2n5/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    }) |text| {
        const pos = try fen.parse(text);
        try std.testing.expectEqual(@as(types.Score, 0), bareKingBonus(&pos, unit));
    }
    // Bishops on both colours and a queen do count.
    const pair = try fen.parse("3k4/8/3K4/8/8/8/8/BB6 w - - 0 1");
    try std.testing.expect(bareKingBonus(&pair, unit) > 0);
    const queen = try fen.parse("3k4/8/3K4/8/8/8/8/Q7 w - - 0 1");
    try std.testing.expect(bareKingBonus(&queen, unit) > 0);
}

test "the search eval presses the root side with pawns and adds the bare-king term without" {
    const params = basin.Params{};
    const with_pawn = try fen.parse("3k4/8/3K4/8/8/8/P7/R7 w - - 60 1");
    try std.testing.expectEqual(params.clockPressure(600, 60, true), searchEval(&params, 600, &with_pawn, .white, true));
    try std.testing.expectEqual(params.clockPressure(600, 60, false), searchEval(&params, 600, &with_pawn, .black, true));
    // A search whose root is not ahead leaves the eval alone.
    try std.testing.expectEqual(@as(types.Score, 600), searchEval(&params, 600, &with_pawn, .white, false));
    const bare = try fen.parse("3k4/8/3K4/8/8/8/8/R7 w - - 60 1");
    try std.testing.expectEqual(600 + bareKingBonus(&bare, params.bare_king_unit), searchEval(&params, 600, &bare, .white, true));
    try std.testing.expectEqual(600 + bareKingBonus(&bare, params.bare_king_unit), searchEval(&params, 600, &bare, .black, false));
    const neither = try fen.parse("3k4/7n/3K4/8/8/8/8/Q7 w - - 60 1");
    try std.testing.expectEqual(@as(types.Score, 600), searchEval(&params, 600, &neither, .white, true));
}

test "the gate opens at the gate and closes below the leave line" {
    var params = basin.Params{};
    params.progress_root_gate = 300;
    params.progress_root_leave = 200;
    try std.testing.expect(!gateOpen(&params, 299, false));
    try std.testing.expect(gateOpen(&params, 300, false));
    try std.testing.expect(gateOpen(&params, 299, true));
    try std.testing.expect(gateOpen(&params, 200, true));
    try std.testing.expect(!gateOpen(&params, 199, true));
    // One line: the leave line at the gate, or above it.
    params.progress_root_leave = 300;
    try std.testing.expect(!gateOpen(&params, 299, true));
    try std.testing.expect(gateOpen(&params, 300, true));
    params.progress_root_leave = 500;
    try std.testing.expect(gateOpen(&params, 300, true));
    try std.testing.expect(!gateOpen(&params, 299, true));
    try std.testing.expect(gateOpen(&params, 400, false));
}

test "the table context is zero without the pressure and one key per root side and clock bucket with it" {
    const off = TableContext.of(false, .black, 16);
    try std.testing.expectEqual(@as(u64, 0), off.key(0));
    try std.testing.expectEqual(@as(u64, 0), off.key(77));
    const white = TableContext.of(true, .white, 16);
    const black = TableContext.of(true, .black, 16);
    // Every key differs from every other and from 0, in both halves (the table's cluster and its tag).
    var keys: [14]u64 = undefined;
    for (0..7) |bucket| {
        keys[2 * bucket] = white.key(@intCast(16 * bucket));
        keys[2 * bucket + 1] = black.key(@intCast(16 * bucket));
    }
    for (keys, 0..) |a, i| {
        try std.testing.expect(@as(u32, @truncate(a)) != 0 and @as(u32, @truncate(a >> 32)) != 0);
        for (keys[i + 1 ..]) |b| {
            const diff = a ^ b;
            try std.testing.expect(@as(u32, @truncate(diff)) != 0 and @as(u32, @truncate(diff >> 32)) != 0);
        }
    }
    // One key within a bucket; the clock counts to 100 and no further.
    try std.testing.expectEqual(white.key(16), white.key(31));
    try std.testing.expect(white.key(15) != white.key(16));
    try std.testing.expectEqual(white.key(100), white.key(140));
    // One bucket for every clock at the widest setting.
    const one = TableContext.of(true, .white, 128);
    try std.testing.expectEqual(one.key(0), one.key(100));
}

test "the clock after a move is zero for captures and pawn moves" {
    const quiet_pos = try fen.parse("4k3/8/8/3p4/4P3/8/8/R3K3 w - - 7 1");
    try std.testing.expectEqual(@as(u16, 8), clockAfter(&quiet_pos, move_mod.Move.init(.a1, .a2, .quiet)));
    try std.testing.expectEqual(@as(u16, 0), clockAfter(&quiet_pos, move_mod.Move.init(.e4, .e5, .quiet)));
    try std.testing.expectEqual(@as(u16, 0), clockAfter(&quiet_pos, move_mod.Move.init(.e4, .d5, .capture)));
}
