//! Syzygy tablebase probing via Fathom (deps/fathom, MIT). Disabled unless a
//! SyzygyPath is set — with no path, probeWdl always returns null and play is
//! bit-identical to a TB-less build.
const std = @import("std");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

extern fn zq_tb_init(path: [*:0]const u8) bool;
extern fn zq_tb_free() void;
extern fn zq_tb_largest() c_uint;
extern fn zq_tb_wdl(
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    ep: c_uint,
    turn: bool,
) c_uint;

extern fn zq_tb_root(
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    rule50: c_uint,
    ep: c_uint,
    turn: bool,
    results: ?[*]c_uint,
) c_uint;

const TB_LOSS: c_uint = 0;
const TB_BLESSED_LOSS: c_uint = 1;
const TB_DRAW: c_uint = 2;
const TB_CURSED_WIN: c_uint = 3;
const TB_WIN: c_uint = 4;
const TB_RESULT_FAILED: c_uint = 0xFFFFFFFF;

/// Clearly above any eval, clearly below the mate band (MATE_SCORE 29_000,
/// threshold 28_872): a proven TB win outranks judgment, never masquerades
/// as a concrete mate.
pub const TB_WIN_SCORE: types.Score = score_mod.TB_WIN_SCORE;

const Backend = struct {
    pub fn init(_: *@This(), path: [:0]const u8) bool {
        return zq_tb_init(path.ptr);
    }
    pub fn free(_: *@This()) void {
        zq_tb_free();
    }
    pub fn limit(_: *@This()) u32 {
        return zq_tb_largest();
    }
    pub fn wdl(_: *@This(), pos: *const position.Position) u32 {
        return callWdl(pos);
    }
    pub fn root(_: *@This(), pos: *const position.Position, results: ?[*]u32) u32 {
        return callRoot(pos, results);
    }
};
const TablebaseService = @import("tb_service.zig").Service(Backend);
// The C backend is a singleton, so there is exactly one process service.
var service: TablebaseService = .{};

pub fn init(path: [:0]const u8) bool {
    return service.init(path);
}
pub fn disable() void {
    service.disable();
}
pub fn enabled() bool {
    return service.pieceLimit() != 0;
}
pub fn pieceLimit() u32 {
    return service.pieceLimit();
}

/// Configuration is pinned for the job. The owner must outlive all borrowed
/// *const Job views and release only after every probe/helper has returned.
/// While holding a Job, use its methods, never the standalone convenience
/// probes (recursive lifetime admission could deadlock a queued writer).
pub const Job = struct {
    lease: TablebaseService.Lease = .{},
    pub fn deinit(self: *Job) void {
        self.lease.release();
    }
    pub fn enabled(self: *const Job) bool {
        return self.lease.largest != 0;
    }
    /// Per-node search gate: false for every position the lease would refuse
    /// for scope (clock, castling, piece count), so the caller skips the
    /// out-of-line probe and probe-phase admission. The lease rechecks the
    /// same predicate before touching Fathom, so results are unchanged.
    pub inline fn wdlInScope(self: *const Job, pos: *const position.Position) bool {
        return self.lease.wdlInScope(pos);
    }
    pub inline fn probeWdl(self: *const Job, pos: *const position.Position) ?Wdl {
        if (!self.wdlInScope(pos)) return null;
        return self.probeCoveredWdl(pos);
    }
    /// Out-of-line probe for a position that passed wdlInScope.
    pub noinline fn probeCoveredWdl(self: *const Job, pos: *const position.Position) ?Wdl {
        return decodeWdl(self.lease.wdl(pos) orelse return null);
    }
    pub fn probeRoot(self: *const Job, pos: *const position.Position) ?RootVerdict {
        return decodeRoot(self.lease.root(pos) orelse return null);
    }
    pub fn probeRootMoves(self: *const Job, pos: *const position.Position, allowed: ?*const MoveList) ?RootPolicy {
        // Only initialize/use the result buffer for an admitted TB root.
        if (!self.enabled() or @popCount(pos.occupied) > self.lease.largest) return null;
        var results: [MAX_ROOT_RESULTS]u32 = @splat(TB_RESULT_FAILED);
        const result = self.lease.rootWithMoves(pos, &results) orelse return null;
        const verdict = decodeRoot(result) orelse return null;
        return rootPolicy(pos, allowed, verdict, &results);
    }
};
pub fn beginJob() Job {
    return .{ .lease = service.acquire() };
}

pub const Wdl = enum { loss, draw, win };

/// WDL probe. Null when disabled, position out of TB scope, or probing is
/// unsound (castling rights, nonzero halfmove clock — Fathom's WDL tables
/// assume a fresh rule-50 counter). Cursed wins / blessed losses collapse to
/// draw (the 50-move rule saves/dooms them).
pub fn probeWdl(pos: *const position.Position) ?Wdl {
    var job = beginJob();
    defer job.deinit();
    return job.probeWdl(pos);
}

fn callWdl(pos: *const position.Position) u32 {
    const ep: c_uint = if (pos.en_passant) |sq| @intFromEnum(sq) else 0;
    return zq_tb_wdl(
        pos.occupancyFor(.white),
        pos.occupancyFor(.black),
        pos.pieceBitboard(.white, .king) | pos.pieceBitboard(.black, .king),
        pos.pieceBitboard(.white, .queen) | pos.pieceBitboard(.black, .queen),
        pos.pieceBitboard(.white, .rook) | pos.pieceBitboard(.black, .rook),
        pos.pieceBitboard(.white, .bishop) | pos.pieceBitboard(.black, .bishop),
        pos.pieceBitboard(.white, .knight) | pos.pieceBitboard(.black, .knight),
        pos.pieceBitboard(.white, .pawn) | pos.pieceBitboard(.black, .pawn),
        ep,
        pos.side_to_move == .white,
    );
}

fn decodeWdl(result: u32) ?Wdl {
    return switch (result) {
        TB_WIN => .win,
        TB_LOSS => .loss,
        TB_DRAW, TB_CURSED_WIN, TB_BLESSED_LOSS => .draw,
        else => null,
    };
}

/// Root DTZ verdict: Fathom's suggested move for a TB-covered root position.
/// `promo` uses Fathom's encoding (0 none, 1 Q, 2 R, 3 B, 4 N). Unlike the
/// in-search WDL probe this is rule-50-AWARE (the clock is passed through),
/// so it works in pawnless endings where no move can ever zero the clock —
/// exactly the class (e.g. KBN vs K) the WDL gate can never reach.
pub const RootVerdict = struct {
    from: u6,
    to: u6,
    promo: u3,
    win: bool, // true only for a genuine win (cursed wins collapse to non-win)
    dtz: u32,
    wdl: Wdl,
    ep: bool,
};

/// Root probe. Null when disabled, out of scope (piece count/castling), the
/// probe fails, or the position is already checkmate/stalemate (those return
/// sentinel "moves" with from == to that a legal-move match would reject
/// anyway; the normal search handles terminal roots).
pub fn probeRoot(pos: *const position.Position) ?RootVerdict {
    var job = beginJob();
    defer job.deinit();
    return job.probeRoot(pos);
}

fn callRoot(pos: *const position.Position, results: ?[*]u32) u32 {
    const ep: c_uint = if (pos.en_passant) |sq| @intFromEnum(sq) else 0;
    return zq_tb_root(
        pos.occupancyFor(.white),
        pos.occupancyFor(.black),
        pos.pieceBitboard(.white, .king) | pos.pieceBitboard(.black, .king),
        pos.pieceBitboard(.white, .queen) | pos.pieceBitboard(.black, .queen),
        pos.pieceBitboard(.white, .rook) | pos.pieceBitboard(.black, .rook),
        pos.pieceBitboard(.white, .bishop) | pos.pieceBitboard(.black, .bishop),
        pos.pieceBitboard(.white, .knight) | pos.pieceBitboard(.black, .knight),
        pos.pieceBitboard(.white, .pawn) | pos.pieceBitboard(.black, .pawn),
        pos.halfmove_clock,
        ep,
        pos.side_to_move == .white,
        results,
    );
}

fn decodeRoot(result: u32) ?RootVerdict {
    if (result == TB_RESULT_FAILED) return null;
    const wdl: c_uint = result & 0xF;
    const to: u6 = @intCast((result >> 4) & 0x3F);
    const from: u6 = @intCast((result >> 10) & 0x3F);
    if (from == to) return null; // checkmate/stalemate sentinels
    return .{
        .from = from,
        .to = to,
        .promo = @intCast((result >> 16) & 0x7),
        .win = wdl == TB_WIN,
        .dtz = (result >> 20) & 0xFFF,
        .wdl = decodeWdl(wdl) orelse return null,
        .ep = (result & (1 << 19)) != 0,
    };
}

const move_mod = @import("../core/move.zig");
const MoveList = move_mod.MoveList;
// Vendored Fathom TB_MAX_MOVES: 192 legal results and the FAILED terminator.
const MAX_ROOT_RESULTS = 193;

/// Immutable once the coordinator publishes helpers. All moves preserve the
/// best rule-50 outcome available inside the caller's searchmoves restriction.
/// Cursed wins and blessed losses are draws, retaining practical alternatives.
pub const RootPolicy = struct {
    moves: MoveList,
    wdl: Wdl,
    suggested: RootVerdict,
};

fn outcomeRank(wdl: Wdl) u2 {
    return switch (wdl) {
        .loss => 0,
        .draw => 1,
        .win => 2,
    };
}

fn verdictMatches(mv: move_mod.Move, v: RootVerdict) bool {
    if (mv.from.index() != v.from or mv.to.index() != v.to) return false;
    const promo: ?@import("../core/piece.zig").PieceType = switch (v.promo) {
        0 => null,
        1 => .queen,
        2 => .rook,
        3 => .bishop,
        4 => .knight,
        else => return false,
    };
    return mv.promotionPieceType() == promo and (mv.flag == .en_passant) == v.ep;
}

fn rootPolicy(pos: *const position.Position, allowed: ?*const MoveList, suggested: RootVerdict, results: *const [MAX_ROOT_RESULTS]u32) ?RootPolicy {
    var legal = MoveList.init();
    @import("../movegen/legal.zig").generate(pos, &legal);
    if (legal.count == 0 or legal.count >= MAX_ROOT_RESULTS) return null;
    // Require exactly one matching record for every legal move before trusting
    // any restriction. No partial result may silently erase a holding move.
    var outcomes: [MAX_ROOT_RESULTS - 1]RootVerdict = undefined;
    var seen = [_]bool{false} ** (MAX_ROOT_RESULTS - 1);
    var count: usize = 0;
    for (results) |raw| {
        if (raw == TB_RESULT_FAILED) break;
        if (count >= legal.count) return null;
        const v = decodeRoot(raw) orelse return null;
        var index: ?usize = null;
        for (legal.slice(), 0..) |mv, i| {
            if (verdictMatches(mv, v)) {
                index = i;
                break;
            }
        }
        const i = index orelse return null;
        if (seen[i]) return null;
        seen[i] = true;
        outcomes[i] = v;
        count += 1;
    }
    if (count != legal.count) return null;
    var chosen = MoveList.init();
    var best_rank: ?u2 = null;
    var best_verdict = suggested;
    for (legal.slice(), 0..) |mv, i| {
        if (allowed) |list| {
            var present = false;
            for (list.slice()) |a| {
                if (a == mv) {
                    present = true;
                    break;
                }
            }
            if (!present) continue;
        }
        const rank = outcomeRank(outcomes[i].wdl);
        if (best_rank == null or rank > best_rank.?) {
            chosen.clear();
            best_rank = rank;
            best_verdict = outcomes[i];
        }
        if (rank == best_rank.?) {
            chosen.add(mv);
            if (verdictMatches(mv, suggested)) best_verdict = suggested;
        }
    }
    if (chosen.count == 0) return null;
    return .{ .moves = chosen, .wdl = best_verdict.wdl, .suggested = best_verdict };
}

/// Side-to-move-relative score for a TB verdict, ply-adjusted so nearer
/// conversions rank higher, mirroring mate-score conventions.
pub fn wdlScore(wdl: Wdl, ply: usize) types.Score {
    return switch (wdl) {
        .win => TB_WIN_SCORE - @as(types.Score, @intCast(ply)),
        .loss => -TB_WIN_SCORE + @as(types.Score, @intCast(ply)),
        .draw => 0,
    };
}

test "syzygy init smoke (opt-in via ZQ_TB_PATH)" {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return;
    defer std.testing.allocator.free(path);
    const pathz = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(pathz);
    const ok = init(pathz);
    std.debug.print("\nsyzygy init ok={} largest={}\n", .{ ok, pieceLimit() });
    try std.testing.expect(ok);
    try std.testing.expect(pieceLimit() >= 5);
    disable();
}

fn testEncoding(mv: move_mod.Move, wdl: u32) u32 {
    const promotion: u32 = if (mv.promotionPieceType()) |p| switch (p) {
        .queen => 1,
        .rook => 2,
        .bishop => 3,
        .knight => 4,
        else => unreachable,
    } else 0;
    return wdl | (@as(u32, mv.to.index()) << 4) | (@as(u32, mv.from.index()) << 10) |
        (promotion << 16) | (if (mv.flag == .en_passant) @as(u32, 1) << 19 else 0);
}

test "root policy validates full coverage and ranks inside searchmoves" {
    const pos = try @import("../core/fen.zig").parse("8/3q3k/7P/6P1/7K/2Q5/8/8 b - - 10 161");
    var moves = MoveList.init();
    @import("../movegen/legal.zig").generate(&pos, &moves);
    var raw: [MAX_ROOT_RESULTS]u32 = @splat(TB_RESULT_FAILED);
    for (moves.slice(), 0..) |mv, i| raw[i] = testEncoding(mv, if (i == 0) TB_LOSS else if (i == 1) TB_CURSED_WIN else TB_DRAW);
    const suggested = decodeRoot(raw[1]).?;
    const policy = rootPolicy(&pos, null, suggested, &raw).?;
    try std.testing.expectEqual(Wdl.draw, policy.wdl);
    try std.testing.expectEqual(moves.count - 1, policy.moves.count);
    for (policy.moves.slice()) |mv| try std.testing.expect(mv != moves.moves[0]);
    var restricted = MoveList.init();
    restricted.add(moves.moves[0]);
    const losing = rootPolicy(&pos, &restricted, suggested, &raw).?;
    try std.testing.expectEqual(Wdl.loss, losing.wdl);
    try std.testing.expectEqual(@as(usize, 1), losing.moves.count);
    restricted.clear();
    try std.testing.expect(rootPolicy(&pos, &restricted, suggested, &raw) == null);
    var broken = raw;
    broken[1] = broken[0];
    try std.testing.expect(rootPolicy(&pos, null, suggested, &broken) == null);
    broken = raw;
    broken[moves.count - 1] = TB_RESULT_FAILED;
    try std.testing.expect(rootPolicy(&pos, null, suggested, &broken) == null);
    broken = raw;
    broken[moves.count] = raw[0];
    try std.testing.expect(rootPolicy(&pos, null, suggested, &broken) == null);
}

test "root policy matches promotion and en passant encodings" {
    for ([_][]const u8{
        "7k/P7/8/8/8/8/8/K7 w - - 0 1",
        "7k/8/8/3pP3/8/8/8/K7 w - d6 0 1",
    }) |text| {
        const pos = try @import("../core/fen.zig").parse(text);
        var moves = MoveList.init();
        @import("../movegen/legal.zig").generate(&pos, &moves);
        var raw: [MAX_ROOT_RESULTS]u32 = @splat(TB_RESULT_FAILED);
        for (moves.slice(), 0..) |mv, i| raw[i] = testEncoding(mv, TB_DRAW);
        const policy = rootPolicy(&pos, null, decodeRoot(raw[0]).?, &raw).?;
        try std.testing.expectEqual(moves.count, policy.moves.count);
    }
}

test "real root policy excludes the two gauntlet losing moves" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_ROOT_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try std.testing.expect(init(path_z));
    defer disable();
    var job = beginJob();
    defer job.deinit();
    const cases = .{
        .{ "8/3q3k/7P/6P1/7K/2Q5/8/8 b - - 10 161", move_mod.Move.init(.d7, .f7, .quiet), @as(usize, 3) },
        .{ "7k/1q6/7P/6P1/2Q3K1/8/8/8 b - - 54 170", move_mod.Move.init(.b7, .g2, .quiet), @as(usize, 2) },
    };
    inline for (cases) |c| {
        const pos = try @import("../core/fen.zig").parse(c[0]);
        const policy = job.probeRootMoves(&pos, null) orelse return error.MissingRootTables;
        try std.testing.expectEqual(Wdl.draw, policy.wdl);
        try std.testing.expectEqual(c[2], policy.moves.count);
        for (policy.moves.slice()) |mv| try std.testing.expect(mv != c[1]);
        var only_loser = MoveList.init();
        only_loser.add(c[1]);
        const restricted = job.probeRootMoves(&pos, &only_loser).?;
        try std.testing.expectEqual(Wdl.loss, restricted.wdl);
        try std.testing.expectEqual(c[1], restricted.moves.moves[0]);
    }
}
