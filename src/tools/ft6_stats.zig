//! ft6_stats — feature-churn instrument for the v6 full-threats delta engine
//! (docs/V6_INCREMENTAL_DESIGN.md cost model). COUNTING only, no timing —
//! counts are deterministic and contention-immune; wall-clock belongs to the
//! dummy-net speed rehearsal on a quiet box.
//!
//! Walks legal-move trees over a mixed-phase FEN set, generating each move's
//! full-threats delta with fullthreats.emitMoveDelta (flip crossings ->
//! refresh, counted separately), and per move records:
//!   full  : changed full-threat features (both perspectives, = row add/subs)
//!   lean  : lean-threats churn on the same move (XOR of fresh enumerations)
//!           -- the shipped v5.8.x cost anchor
//! Usage: zigqueen ft6_stats [depth]

const std = @import("std");
const position = @import("../core/position.zig");
const fen = @import("../core/fen.zig");
const piece = @import("../core/piece.zig");
const fullthreats = @import("../eval/fullthreats.zig");
const threats = @import("../eval/threats.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");

const FENS = [_][]const u8{
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
    "r1bq1rk1/pp2bppp/2n2n2/2pp4/3P4/2N1PN2/PP2BPPP/R1BQ1RK1 w - - 0 8",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "4k3/8/3KP3/8/8/8/8/8 w - - 0 1",
    "8/5pk1/6p1/8/5PK1/6P1/8/3r3R w - - 0 1",
    "2r3k1/5ppp/p3p3/1p6/3P4/P3P1P1/1P3P1P/2R3K1 w - - 0 1",
};

const MAX_SAMPLES = 400_000;
var g_full: [MAX_SAMPLES]u32 = undefined;
var g_lean: [MAX_SAMPLES]u32 = undefined;

const Ctx = struct {
    n: usize = 0,
    refreshes: u32 = 0,

    fn record(self: *Ctx, full_toggles: u32, lean_toggles: u32) void {
        if (self.n >= MAX_SAMPLES) return;
        g_full[self.n] = full_toggles;
        g_lean[self.n] = lean_toggles;
        self.n += 1;
    }
};

/// emitMoveDelta sink that only counts the changed features.
const CountSink = struct {
    n: u32 = 0,
    pub fn emitPair(self: *CountSink, comptime add: bool, iw: usize, ib: usize) void {
        _ = add;
        _ = iw;
        _ = ib;
        self.n += 2;
    }
};

fn xorPop(a: *const threats.PerspBits, b: *const threats.PerspBits) u32 {
    var t: u32 = 0;
    for (a, b) |x, y| t += @popCount(x ^ y);
    return t;
}

fn walk(
    pos: *position.Position,
    lw: *const threats.PerspBits,
    lb: *const threats.PerspBits,
    depth: u8,
    ctx: *Ctx,
) void {
    if (depth == 0) return;
    const pre_flips = fullthreats.kingFlips(pos);
    var premail: [64]piece.Piece = undefined;
    for (0..64) |i| premail[i] = pos.mailbox[i];

    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        var st: make_unmake.StateInfo = .{};
        _ = make_unmake.makeMove(pos, mv, &st);

        var clw: threats.PerspBits = undefined;
        var clb: threats.PerspBits = undefined;
        threats.enumerateColors(pos, &clw, &clb);
        const lean_toggles = xorPop(lw, &clw) + xorPop(lb, &clb);

        const post_flips = fullthreats.kingFlips(pos);
        if (post_flips.w != pre_flips.w or post_flips.b != pre_flips.b) {
            ctx.refreshes += 1;
            walk(pos, &clw, &clb, depth - 1, ctx);
        } else {
            var changes: [4]fullthreats.SquareChange = undefined;
            var nc: usize = 0;
            for (0..64) |i| {
                if (pos.mailbox[i] != premail[i]) {
                    changes[nc] = .{ .sq = @intCast(i), .old = premail[i], .new = pos.mailbox[i] };
                    nc += 1;
                }
            }
            var sink = CountSink{};
            fullthreats.emitMoveDelta(pos, changes[0..nc], &sink);
            ctx.record(sink.n, lean_toggles);
            walk(pos, &clw, &clb, depth - 1, ctx);
        }
        make_unmake.unmakeMove(pos, mv, &st);
    }
}

fn pct(sorted: []const u32, p: usize) u32 {
    if (sorted.len == 0) return 0;
    return sorted[@min(sorted.len - 1, sorted.len * p / 100)];
}

pub fn run(stdout: anytype, depth: u8) !void {
    // Depth 0 walks no move, and the statistics below need at least one sample.
    if (depth == 0) return error.InvalidDepth;
    var ctx = Ctx{};
    for (FENS) |f| {
        var pos = fen.parse(f) catch continue;
        var lw: threats.PerspBits = undefined;
        var lb: threats.PerspBits = undefined;
        threats.enumerateColors(&pos, &lw, &lb);
        const before = ctx.n;
        walk(&pos, &lw, &lb, depth, &ctx);
        try stdout.print("fen[{d} moves] {s}\n", .{ ctx.n - before, f });
    }

    const n = ctx.n;
    var sum_full: u64 = 0;
    var sum_lean: u64 = 0;
    for (0..n) |i| {
        sum_full += g_full[i];
        sum_lean += g_lean[i];
    }
    std.mem.sort(u32, g_full[0..n], {}, std.sort.asc(u32));
    std.mem.sort(u32, g_lean[0..n], {}, std.sort.asc(u32));

    const mf = @as(f64, @floatFromInt(sum_full)) / @as(f64, @floatFromInt(n));
    const ml = @as(f64, @floatFromInt(sum_lean)) / @as(f64, @floatFromInt(n));
    try stdout.print(
        "\nmoves sampled: {d}   flip-refreshes: {d}\n" ++
            "full toggles/move : mean {d:.2}  p50 {d}  p95 {d}  p99 {d}  max {d}\n" ++
            "lean toggles/move : mean {d:.2}  p50 {d}  p95 {d}  p99 {d}  max {d}\n" ++
            "churn ratio (full/lean means): {d:.2}\n",
        .{
            n,                     ctx.refreshes,
            mf,                    pct(g_full[0..n], 50),
            pct(g_full[0..n], 95), pct(g_full[0..n], 99),
            g_full[n - 1],         ml,
            pct(g_lean[0..n], 50), pct(g_lean[0..n], 95),
            pct(g_lean[0..n], 99), g_lean[n - 1],
            mf / ml,
        },
    );
}
