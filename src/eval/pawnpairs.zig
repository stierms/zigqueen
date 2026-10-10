//! Pawn-pair feature block PP1 (engine side): dictionary, index function, full
//! enumeration and the per-move pair delta.
//!
//! Implements docs/research/B3_PAWN_PAIRS_DESIGN_2026-09-30.md (frozen dba3741af)
//! bit for bit. The trainer's input type (our bullet fork, `pawn_pairs.rs`)
//! implements the same text independently; the two are cross-checked through
//! shared index vectors.
//!
//!   Perspective P, oriented square o(s) = s ^ (P==black ? 56 : 0) ^ flip_P,
//!   flip_P = own-king file > d ? 7 : 0 (the HalfKA / full-threat frame),
//!   rank rho = o>>3 in 1..6, file phi = o&7; own/opp relative to P.
//!   Every unordered pair of pawns (either colour) on the same or adjacent files:
//!     S (same file):     c = 2*[lo opp] + [hi opp];
//!                        idx = c*120 + phi*15 + R15(rho_lo, rho_hi)          [0, 480)
//!     A (adjacent files): c = 2*[left opp] + [right opp];
//!                        idx = 480 + c*252 + phi_left*36
//!                              + 6*(rho_left-1) + (rho_right-1)             [480, 1488)
//!   Exclusion: in A with |rho_left - rho_right| == 1 only the colouring
//!   "lower pawn opp, upper pawn own" is a feature; the other three are pawn
//!   attack/defence contacts that the full-threat block already encodes.
//!
//! The block is a pure function of (white pawns, black pawns, flips). Pawns on
//! ranks 1/8 are illegal but not rejected by the FEN loader, so every pawn set
//! is masked to ranks 2..7 first.
const std = @import("std");
const types = @import("../core/types.zig");
const position = @import("../core/position.zig");
const piece = @import("../core/piece.zig");

pub const NUM_FEATURES: usize = 1488;
/// C(16,2): every pawn pair of a legal position (the PSQT score bound).
pub const MAX_ACTIVE: usize = 120;
/// Every same- or adjacent-file square pair on ranks 2..7 (8*15 + 7*36): the
/// most rows any pawn placement can activate. The FEN loader does not bound
/// pawn counts, so fixed buffers use this, not MAX_ACTIVE.
pub const MAX_PAIRS: usize = 372;
/// ZQBA header `pawn_layout` value for PP1 (1 is the unimplemented PI/PR1 block).
pub const LAYOUT_ID: u32 = 2;
pub const WORDS: usize = (NUM_FEATURES + 63) / 64; // 24
pub const PairBits = [WORDS]u64;
/// Raw squares a pawn can legally occupy (ranks 2..7).
pub const LEGAL_PAWN_SQUARES: u64 = 0x00FF_FFFF_FFFF_FF00;

const ADJ_BASE: u16 = 480;
const FILE_A: u64 = 0x0101_0101_0101_0101;

/// R15[lo][hi] for ranks 1 <= lo < hi <= 6: row offsets 0, 5, 9, 12, 14.
const R15: [8][8]u8 = blk: {
    var t = [_][8]u8{[_]u8{0} ** 8} ** 8;
    for (1..7) |lo| {
        for (lo + 1..7) |hi| {
            const a = lo - 1;
            const b = hi - 1;
            t[lo][hi] = @intCast(a * (11 - a) / 2 + (b - a - 1));
        }
    }
    break :blk t;
};

/// Files f-1..f+1 as a raw-square mask, per file.
const NEIGHBOUR_FILES: [8]u64 = blk: {
    var t: [8]u64 = undefined;
    for (0..8) |f| {
        var m: u64 = FILE_A << f;
        if (f > 0) m |= FILE_A << (f - 1);
        if (f < 7) m |= FILE_A << (f + 1);
        t[f] = m;
    }
    break :blk t;
};

/// PP1 index of the pair {a, b} in ONE perspective's oriented frame, or null when
/// the pair is not a feature (files more than one apart, or a threat duplicate).
/// `ao`/`bo`: oriented squares (ranks 1..6); `a_opp`/`b_opp`: the pawn belongs to
/// the perspective's opponent.
pub inline fn pairIndex(ao: u6, a_opp: bool, bo: u6, b_opp: bool) ?u16 {
    const fa: u16 = ao & 7;
    const fb: u16 = bo & 7;
    const ra: u16 = ao >> 3;
    const rb: u16 = bo >> 3;
    if (fa == fb) {
        const a_lo = ra < rb;
        const lo_r = if (a_lo) ra else rb;
        const hi_r = if (a_lo) rb else ra;
        const lo_opp = if (a_lo) a_opp else b_opp;
        const hi_opp = if (a_lo) b_opp else a_opp;
        const c: u16 = 2 * @as(u16, @intFromBool(lo_opp)) + @intFromBool(hi_opp);
        return c * 120 + fa * 15 + R15[lo_r][hi_r];
    }
    const a_left = fa < fb;
    const fl = if (a_left) fa else fb;
    const fr = if (a_left) fb else fa;
    if (fr - fl != 1) return null;
    const rl = if (a_left) ra else rb;
    const rr = if (a_left) rb else ra;
    const left_opp = if (a_left) a_opp else b_opp;
    const right_opp = if (a_left) b_opp else a_opp;
    if (rl + 1 == rr or rr + 1 == rl) {
        // Diagonal contact: keep only "lower opp, upper own" (passed each other).
        const lower_opp = if (rl < rr) left_opp else right_opp;
        const upper_opp = if (rl < rr) right_opp else left_opp;
        if (!(lower_opp and !upper_opp)) return null;
    }
    const c: u16 = 2 * @as(u16, @intFromBool(left_opp)) + @intFromBool(right_opp);
    return ADJ_BASE + c * 252 + fl * 36 + (rl - 1) * 6 + (rr - 1);
}

/// Live-row table: true for every index some legal pawn pair can produce.
/// Dead rows (the 210 threat duplicates) must be zero in every ZQBA file.
pub const LIVE: [NUM_FEATURES]bool = blk: {
    @setEvalBranchQuota(200_000);
    var t = [_]bool{false} ** NUM_FEATURES;
    for (8..56) |a| {
        for (8..56) |b| {
            if (a == b) continue;
            for ([_]bool{ false, true }) |ao| {
                for ([_]bool{ false, true }) |bo| {
                    if (pairIndex(@intCast(a), ao, @intCast(b), bo)) |i| t[i] = true;
                }
            }
        }
    }
    break :blk t;
};

/// Table form of `pairIndex` for the hot paths (no data-dependent branches): one
/// entry per oriented square a, file step to b (-1, 0, +1) and rank of b, and per
/// colour pair 2*[a opp] + [b opp]; NONE where `pairIndex` returns null. Only
/// valid for pairs whose files differ by at most one (every caller pairs a pawn
/// with its NEIGHBOUR_FILES partners, a property the mirror flip preserves).
pub const NONE: u16 = 0xFFFF;
const PAIR_SLOTS: usize = 64 * 3 * 8;
const PAIR_TABLE: [PAIR_SLOTS][4]u16 = blk: {
    @setEvalBranchQuota(400_000);
    var t: [PAIR_SLOTS][4]u16 = undefined;
    for (0..64) |a| {
        for (0..3) |d| {
            for (0..8) |rb| {
                for (0..4) |c| {
                    const fb = @as(i32, a & 7) + @as(i32, d) - 1;
                    const s = (a * 3 + d) * 8 + rb;
                    t[s][c] = NONE;
                    if (fb < 0 or fb > 7) continue;
                    const b = rb * 8 + @as(usize, @intCast(fb));
                    if (b == a or a >> 3 < 1 or a >> 3 > 6 or rb < 1 or rb > 6) continue;
                    if (pairIndex(@intCast(a), c >= 2, @intCast(b), c % 2 == 1)) |i| t[s][c] = i;
                }
            }
        }
    }
    break :blk t;
};

inline fn pairSlot(ao: u6, bo: u6) usize {
    return (@as(usize, ao) * 3 + ((@as(usize, bo & 7) + 1) - @as(usize, ao & 7))) * 8 + @as(usize, bo >> 3);
}

/// `pairIndex` through the table (NONE instead of null); files of ao and bo must
/// differ by at most one.
pub inline fn pairIndexFast(ao: u6, a_opp: bool, bo: u6, b_opp: bool) u16 {
    return PAIR_TABLE[pairSlot(ao, bo)][2 * @as(usize, @intFromBool(a_opp)) + @intFromBool(b_opp)];
}

inline fn frameXor(comptime persp: types.Color, flip: u6) u6 {
    return (if (persp == .black) @as(u6, 56) else 0) ^ flip;
}

/// Index of the raw-square pair {a (colour ac), b (colour bc)} for perspective
/// `persp` under mirror flip `flip`, or null if not a feature.
pub inline fn pairIndexRaw(comptime persp: types.Color, flip: u6, a: u6, a_black: bool, b: u6, b_black: bool) ?u16 {
    const x = frameXor(persp, flip);
    const persp_black = persp == .black;
    return pairIndex(a ^ x, a_black != persp_black, b ^ x, b_black != persp_black);
}

/// All active PP1 rows of perspective `persp` for raw pawn sets `white`/`black`
/// under flip `flip`. Returns the count written to `out` (each index unique).
pub fn enumerate(comptime persp: types.Color, white: u64, black: u64, flip: u6, out: *[MAX_PAIRS]u16) usize {
    const w = white & LEGAL_PAWN_SQUARES;
    const bl = black & LEGAL_PAWN_SQUARES;
    var n: usize = 0;
    var rest = w | bl;
    while (rest != 0) {
        const a: u6 = @intCast(@ctz(rest));
        rest &= rest - 1;
        const a_black = (bl >> a) & 1 == 1;
        // Partners above `a` in square order: each unordered pair once.
        var partners = rest & NEIGHBOUR_FILES[a & 7];
        const x = frameXor(persp, flip);
        const persp_black = persp == .black;
        const ao = a ^ x;
        const a_opp = a_black != persp_black;
        while (partners != 0) {
            const b: u6 = @intCast(@ctz(partners));
            partners &= partners - 1;
            const idx = pairIndexFast(ao, a_opp, b ^ x, ((bl >> b) & 1 == 1) != persp_black);
            out[n] = idx;
            n += @intFromBool(idx != NONE);
        }
    }
    return n;
}

/// Set bits for every active row (the flip-cache diff form of `enumerate`).
pub fn enumerateBits(comptime persp: types.Color, white: u64, black: u64, flip: u6, out: *PairBits) void {
    out.* = [_]u64{0} ** WORDS;
    var list: [MAX_PAIRS]u16 = undefined;
    const n = enumerate(persp, white, black, flip, &list);
    for (list[0..n]) |i| out[i >> 6] |= @as(u64, 1) << @as(u6, @intCast(i & 63));
}

/// Raw white/black pawn sets of a position, masked to legal ranks.
pub inline fn pawnSets(pos: *const position.Position) [2]u64 {
    return .{
        pos.pieceBitboard(.white, .pawn) & LEGAL_PAWN_SQUARES,
        pos.pieceBitboard(.black, .pawn) & LEGAL_PAWN_SQUARES,
    };
}

// ---------------------------------------------------------------------------
// Per-move delta: the pairs a move creates or destroys, in raw squares, shared by
// both perspectives (the index differs per perspective, the pair set does not).
// ---------------------------------------------------------------------------

/// One pawn that disappeared or appeared (raw square, colour).
pub const PawnChange = struct { sq: u6, black: bool };
/// Removed pawns <= 2 (en passant, pawn takes pawn), added <= 1; a pawn has at
/// most 17 partner squares (3 files x 6 ranks - 1), so 51 changed pairs is the
/// ceiling for any placement.
pub const MAX_PAIR_CHANGES: usize = 51;
pub const PairChange = struct { a: u6, a_black: bool, b: u6, b_black: bool, add: bool };

inline fn bit(sq: u6) u64 {
    return @as(u64, 1) << sq;
}

/// Pairs that change when the pawns in `removed` leave and those in `added`
/// arrive, ending at the post-move sets `w1`/`b1` (raw, any ranks). Removed
/// pairs: each removed pawn is deleted from a working copy of the pre-move set
/// and paired with what remains there; added pairs: the working set starts at
/// the post-move set minus every added pawn and each added pawn is paired with
/// it, then inserted. Every changed pair appears exactly once; unchanged pairs
/// never appear. Returns the count written to `out`.
pub fn pairChanges(
    w1_raw: u64,
    b1_raw: u64,
    removed: []const PawnChange,
    added: []const PawnChange,
    out: *[MAX_PAIR_CHANGES]PairChange,
) usize {
    const w1 = w1_raw & LEGAL_PAWN_SQUARES;
    const b1 = b1_raw & LEGAL_PAWN_SQUARES;
    var add_w: u64 = 0;
    var add_b: u64 = 0;
    for (added) |c| {
        if (c.black) add_b |= bit(c.sq) else add_w |= bit(c.sq);
    }
    var rem_w: u64 = 0;
    var rem_b: u64 = 0;
    for (removed) |c| {
        if (c.black) rem_b |= bit(c.sq) else rem_w |= bit(c.sq);
    }
    add_w &= LEGAL_PAWN_SQUARES;
    add_b &= LEGAL_PAWN_SQUARES;
    rem_w &= LEGAL_PAWN_SQUARES;
    rem_b &= LEGAL_PAWN_SQUARES;
    var n: usize = 0;

    // Removed pairs, against the pre-move set.
    var ww = (w1 & ~add_w) | rem_w;
    var wb = (b1 & ~add_b) | rem_b;
    for (removed) |c| {
        if (bit(c.sq) & LEGAL_PAWN_SQUARES == 0) continue;
        if (c.black) wb &= ~bit(c.sq) else ww &= ~bit(c.sq);
        var partners = (ww | wb) & NEIGHBOUR_FILES[c.sq & 7];
        while (partners != 0) {
            const p: u6 = @intCast(@ctz(partners));
            partners &= partners - 1;
            out[n] = .{ .a = c.sq, .a_black = c.black, .b = p, .b_black = (wb >> p) & 1 == 1, .add = false };
            n += 1;
        }
    }

    // Added pairs, against the post-move set.
    ww = w1 & ~add_w;
    wb = b1 & ~add_b;
    for (added) |c| {
        if (bit(c.sq) & LEGAL_PAWN_SQUARES == 0) continue;
        var partners = (ww | wb) & NEIGHBOUR_FILES[c.sq & 7];
        while (partners != 0) {
            const p: u6 = @intCast(@ctz(partners));
            partners &= partners - 1;
            out[n] = .{ .a = c.sq, .a_black = c.black, .b = p, .b_black = (wb >> p) & 1 == 1, .add = true };
            n += 1;
        }
        if (c.black) wb |= bit(c.sq) else ww |= bit(c.sq);
    }
    return n;
}

/// The per-move delta as PP1 rows, per perspective ([0] white, [1] black): equal to
/// mapping `pairChanges` through `pairIndexRaw` and dropping the non-features (tested),
/// but in one pass with table indices and branch-free appends — the hot form.
/// One slot of slack per list takes the unconditional store of a dropped pair.
pub const RowDelta = struct {
    idx: [2][MAX_PAIR_CHANGES + 1]u16,
    add: [2][MAX_PAIR_CHANGES + 1]bool,
    n: [2]usize,

    pub inline fn rows_n(self: *const RowDelta, pi: usize) usize {
        return self.n[pi];
    }
};

inline fn emitPairs(out: *RowDelta, a: u6, a_black: bool, partners: u64, black_set: u64, add: bool, xw: u6, xb: u6) void {
    var ps = partners;
    var n0 = out.n[0];
    var n1 = out.n[1];
    const aw = a ^ xw;
    const ab = a ^ xb;
    const cw: usize = 2 * @as(usize, @intFromBool(a_black)); // white perspective: opp = black
    const cb: usize = 2 * @as(usize, @intFromBool(!a_black));
    while (ps != 0) {
        const p: u6 = @intCast(@ctz(ps));
        ps &= ps - 1;
        const p_black = (black_set >> p) & 1;
        const iw = PAIR_TABLE[pairSlot(aw, p ^ xw)][cw + p_black];
        const ib = PAIR_TABLE[pairSlot(ab, p ^ xb)][cb + (1 - p_black)];
        out.idx[0][n0] = iw;
        out.add[0][n0] = add;
        n0 += @intFromBool(iw != NONE);
        out.idx[1][n1] = ib;
        out.add[1][n1] = add;
        n1 += @intFromBool(ib != NONE);
    }
    out.n = .{ n0, n1 };
}

/// `pairChanges` + per-perspective indexing in one pass; `wflip`/`bflip` are the
/// perspectives' mirror flips (both perspectives must keep their flip across the move).
pub fn rowDelta(
    w1_raw: u64,
    b1_raw: u64,
    removed: []const PawnChange,
    added: []const PawnChange,
    wflip: u6,
    bflip: u6,
    out: *RowDelta,
) void {
    out.n = .{ 0, 0 };
    const xw: u6 = wflip;
    const xb: u6 = 56 ^ bflip;
    const w1 = w1_raw & LEGAL_PAWN_SQUARES;
    const b1 = b1_raw & LEGAL_PAWN_SQUARES;
    var add_w: u64 = 0;
    var add_b: u64 = 0;
    for (added) |c| {
        if (c.black) add_b |= bit(c.sq) else add_w |= bit(c.sq);
    }
    var rem_w: u64 = 0;
    var rem_b: u64 = 0;
    for (removed) |c| {
        if (c.black) rem_b |= bit(c.sq) else rem_w |= bit(c.sq);
    }
    add_w &= LEGAL_PAWN_SQUARES;
    add_b &= LEGAL_PAWN_SQUARES;
    rem_w &= LEGAL_PAWN_SQUARES;
    rem_b &= LEGAL_PAWN_SQUARES;
    var ww = (w1 & ~add_w) | rem_w;
    var wb = (b1 & ~add_b) | rem_b;
    for (removed) |c| {
        if (bit(c.sq) & LEGAL_PAWN_SQUARES == 0) continue;
        if (c.black) wb &= ~bit(c.sq) else ww &= ~bit(c.sq);
        emitPairs(out, c.sq, c.black, (ww | wb) & NEIGHBOUR_FILES[c.sq & 7], wb, false, xw, xb);
    }
    ww = w1 & ~add_w;
    wb = b1 & ~add_b;
    for (added) |c| {
        if (bit(c.sq) & LEGAL_PAWN_SQUARES == 0) continue;
        emitPairs(out, c.sq, c.black, (ww | wb) & NEIGHBOUR_FILES[c.sq & 7], wb, true, xw, xb);
        if (c.black) wb |= bit(c.sq) else ww |= bit(c.sq);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const fen = @import("../core/fen.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");
const fullthreats = @import("fullthreats.zig");

fn enumerateSorted(comptime persp: types.Color, pos: *const position.Position, out: *[MAX_PAIRS]u16) []u16 {
    const sets = pawnSets(pos);
    const flips = fullthreats.kingFlips(pos);
    const flip = if (persp == .white) flips.w else flips.b;
    const n = enumerate(persp, sets[0], sets[1], flip, out);
    std.mem.sort(u16, out[0..n], {}, std.sort.asc(u16));
    return out[0..n];
}

test "PP1 dictionary: 1,488 rows, 1,278 live, 210 dead threat duplicates" {
    var live: usize = 0;
    for (LIVE) |l| live += @intFromBool(l);
    try std.testing.expectEqual(@as(usize, 1278), live);
    // Every same-file row is live; the dead rows are exactly A-family rows with
    // |rho_left - rho_right| == 1 and one of the three contact colourings.
    for (0..480) |i| try std.testing.expect(LIVE[i]);
    var dead: usize = 0;
    for (480..NUM_FEATURES) |i| {
        const r = i - 480;
        const c = r / 252;
        const rl = (r % 36) / 6 + 1;
        const rr = r % 6 + 1;
        const left_opp = c >= 2;
        const right_opp = c % 2 == 1;
        const diag = rl + 1 == rr or rr + 1 == rl;
        const lower_opp = if (rl < rr) left_opp else right_opp;
        const upper_opp = if (rl < rr) right_opp else left_opp;
        const expect_dead = diag and !(lower_opp and !upper_opp);
        try std.testing.expectEqual(!expect_dead, LIVE[i]);
        dead += @intFromBool(expect_dead);
    }
    try std.testing.expectEqual(@as(usize, 210), dead);
}

test "PP1 hand-checked indices" {
    // White perspective, white king e1 -> flip 7. White pawns d2,d4 (oriented
    // files e: d^7 = e(4)), black pawn e5 (oriented file d(3)).
    // d2 = 11 -> 11^7 = 12 (e2: rank 1, file 4); d4 = 27 -> 28 (e4: rank 3, file 4);
    // e5 = 36 -> 35 (d5: rank 4, file 3).
    // Same file e: lo e2 own, hi e4 own -> c 0; R15(1,3) = 1 -> 0 + 4*15 + 1 = 61.
    try std.testing.expectEqual(@as(?u16, 61), pairIndexRaw(.white, 7, 11, false, 27, false));
    // d4 (own, oriented e4 r3 f4) and e5 (opp, oriented d5 r4 f3): adjacent, diag,
    // lower own -> threat duplicate (d4 attacks e5): null.
    try std.testing.expectEqual(@as(?u16, null), pairIndexRaw(.white, 7, 27, false, 36, true));
    // d2 (own, e2 r1 f4) and e5 (opp, d5 r4 f3): left = d5 (opp, r4), right = e2 (own, r1);
    // c = 2*1 + 0 = 2 -> 480 + 2*252 + 3*36 + 3*6 + 0 = 1110.
    try std.testing.expectEqual(@as(?u16, 1110), pairIndexRaw(.white, 7, 11, false, 36, true));
    // Passed each other: white pawn e4 (28) and black pawn d3 (19), no flip, white
    // perspective: lower = d3 opp (r2 f3), upper = e4 own (r3 f4): kept.
    // left = d3 (opp, r2), right = e4 (own, r3): c = 2 -> 480 + 504 + 3*36 + 1*6 + 2 = 1100.
    try std.testing.expectEqual(@as(?u16, 1100), pairIndexRaw(.white, 0, 28, false, 19, true));
    // Same pair from black's perspective (black king e8 -> flip 7): e4 -> 28^56^7 = 35
    // (d5 r4 f3, opp), d3 -> 19^63 = 44 (e6 r5 f4, own). lower d5 opp, upper e6 own:
    // kept. left = d5 (opp r4), right = e6 (own r5): c = 2 -> 480+504+108+18+4 = 1114.
    try std.testing.expectEqual(@as(?u16, 1114), pairIndexRaw(.black, 7, 28, false, 19, true));
    // Files two apart never pair.
    try std.testing.expectEqual(@as(?u16, null), pairIndexRaw(.white, 0, 8, false, 10, false));
}

test "PP1 enumeration is colour-symmetric, unique and bounded" {
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        "4k3/pppppppp/PPPPPPPP/8/8/pppppppp/PPPPPPPP/4K3 w - - 0 1",
        "6k1/8/8/3pP3/8/8/8/1K6 w - d6 0 2",
    };
    for (fens) |f| {
        const pos = try fen.parse(f);
        var wl: [MAX_PAIRS]u16 = undefined;
        var bl: [MAX_PAIRS]u16 = undefined;
        const ws = enumerateSorted(.white, &pos, &wl);
        const bs = enumerateSorted(.black, &pos, &bl);
        try std.testing.expectEqual(ws.len, bs.len); // paired stm/ntm emission
        for (ws, 0..) |v, i| {
            try std.testing.expect(LIVE[v]);
            if (i > 0) try std.testing.expect(ws[i - 1] < v);
        }
        for (bs, 0..) |v, i| {
            try std.testing.expect(LIVE[v]);
            if (i > 0) try std.testing.expect(bs[i - 1] < v);
        }
        // Colour mirror: the black perspective of `pos` equals the white
        // perspective of the colour-flipped board (ranks mirrored, colours swapped).
        const sets = pawnSets(&pos);
        const flips = fullthreats.kingFlips(&pos);
        var mirrored: [MAX_PAIRS]u16 = undefined;
        const n = enumerate(.white, @byteSwap(sets[1]), @byteSwap(sets[0]), flips.b, &mirrored);
        std.mem.sort(u16, mirrored[0..n], {}, std.sort.asc(u16));
        try std.testing.expectEqualSlices(u16, bs, mirrored[0..n]);
    }
    // All 16 pawns face to face: the legal bound holds.
    const dense = try fen.parse("4k3/8/pppppppp/PPPPPPPP/8/8/8/4K3 w - - 0 1");
    var out: [MAX_PAIRS]u16 = undefined;
    try std.testing.expect(enumerateSorted(.white, &dense, &out).len <= MAX_ACTIVE);
    // An illegal but parseable board with every rank-2..7 square a pawn fills
    // the buffer exactly and stays memory-safe.
    const full = try fen.parse("4k3/pppppppp/pppppppp/pppppppp/PPPPPPPP/PPPPPPPP/PPPPPPPP/4K3 w - - 0 1");
    var full_live: usize = 0;
    for (LIVE) |l| full_live += @intFromBool(l);
    const nfull = enumerateSorted(.white, &full, &out).len;
    try std.testing.expect(nfull <= MAX_PAIRS and nfull <= full_live);
}

test "PP1 back-rank pawns are ignored" {
    const pos = try fen.parse("P3k3/8/8/8/8/8/1P6/4K2p w - - 0 1");
    var out: [MAX_PAIRS]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 0), enumerateSorted(.white, &pos, &out).len);
    try std.testing.expectEqual(@as(usize, 0), enumerateSorted(.black, &pos, &out).len);
}

/// Apply a pair delta to a sorted-set representation (as bits) for one perspective.
fn applyChangesToBits(comptime persp: types.Color, flip: u6, changes: []const PairChange, bits: *PairBits) !void {
    for (changes) |c| {
        const idx = pairIndexRaw(persp, flip, c.a, c.a_black, c.b, c.b_black) orelse continue;
        const m = @as(u64, 1) << @as(u6, @intCast(idx & 63));
        const set = bits[idx >> 6] & m != 0;
        // A removal must hit a present row, an addition an absent one.
        try std.testing.expectEqual(!c.add, set);
        bits[idx >> 6] ^= m;
    }
}

fn pawnChangesOf(mv: move_mod.Move, pos_before: *const position.Position, pos_after: *const position.Position, removed: *[4]PawnChange, added: *[4]PawnChange) struct { nr: usize, na: usize } {
    _ = mv;
    var nr: usize = 0;
    var na: usize = 0;
    inline for (.{ types.Color.white, types.Color.black }) |c| {
        const before = pos_before.pieceBitboard(c, .pawn);
        const after = pos_after.pieceBitboard(c, .pawn);
        var gone = before & ~after;
        while (gone != 0) {
            const s: u6 = @intCast(@ctz(gone));
            gone &= gone - 1;
            removed[nr] = .{ .sq = s, .black = c == .black };
            nr += 1;
        }
        var came = after & ~before;
        while (came != 0) {
            const s: u6 = @intCast(@ctz(came));
            came &= came - 1;
            added[na] = .{ .sq = s, .black = c == .black };
            na += 1;
        }
    }
    return .{ .nr = nr, .na = na };
}

fn sets1_raw(pos: *const position.Position) [2]u64 {
    return .{ pos.pieceBitboard(.white, .pawn), pos.pieceBitboard(.black, .pawn) };
}

test "PP1 index table equals pairIndex for every same- or adjacent-file pair" {
    var checked: usize = 0;
    for (0..64) |a| {
        for (0..64) |b| {
            const fa: i32 = @intCast(a & 7);
            const fb: i32 = @intCast(b & 7);
            if (@abs(fa - fb) > 1) continue;
            for (0..4) |c| {
                const a_opp = c >= 2;
                const b_opp = c % 2 == 1;
                const on_board = a != b and a >> 3 >= 1 and a >> 3 <= 6 and b >> 3 >= 1 and b >> 3 <= 6;
                const want: u16 = if (on_board) (pairIndex(@intCast(a), a_opp, @intCast(b), b_opp) orelse NONE) else NONE;
                try std.testing.expectEqual(want, pairIndexFast(@intCast(a), a_opp, @intCast(b), b_opp));
                checked += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, (8 * 3 - 2) * 8 * 8 * 4), checked);
}

fn deltaWalk(pos: *position.Position, depth: u8) !void {
    if (depth == 0) return;
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        const before = pos.*;
        var st: make_unmake.StateInfo = undefined;
        _ = make_unmake.makeMove(pos, mv, &st);
        var removed: [4]PawnChange = undefined;
        var added: [4]PawnChange = undefined;
        const cnt = pawnChangesOf(mv, &before, pos, &removed, &added);
        const sets1 = pawnSets(pos);
        var changes: [MAX_PAIR_CHANGES]PairChange = undefined;
        const n = pairChanges(sets1[0], sets1[1], removed[0..cnt.nr], added[0..cnt.na], &changes);
        // Parent flips: the delta is only used when the perspective's flip is unchanged.
        const f0 = fullthreats.kingFlips(&before);
        const f1 = fullthreats.kingFlips(pos);
        // The hot form (table indices, one pass) equals the reference mapping, in order.
        var fast: RowDelta = undefined;
        rowDelta(sets1_raw(pos)[0], sets1_raw(pos)[1], removed[0..cnt.nr], added[0..cnt.na], f1.w, f1.b, &fast);
        inline for (.{ types.Color.white, types.Color.black }, 0..) |persp, pi| {
            var want: [MAX_PAIR_CHANGES]u16 = undefined;
            var want_add: [MAX_PAIR_CHANGES]bool = undefined;
            var k: usize = 0;
            for (changes[0..n]) |c| {
                if (pairIndexRaw(persp, if (persp == .white) f1.w else f1.b, c.a, c.a_black, c.b, c.b_black)) |i| {
                    want[k] = i;
                    want_add[k] = c.add;
                    k += 1;
                }
            }
            try std.testing.expectEqualSlices(u16, want[0..k], fast.idx[pi][0..fast.rows_n(pi)]);
            try std.testing.expectEqualSlices(bool, want_add[0..k], fast.add[pi][0..fast.rows_n(pi)]);
        }
        const sets0 = pawnSets(&before);
        inline for (.{ types.Color.white, types.Color.black }) |persp| {
            const flip0 = if (persp == .white) f0.w else f0.b;
            const flip1 = if (persp == .white) f1.w else f1.b;
            if (flip0 == flip1) {
                var bits: PairBits = undefined;
                enumerateBits(persp, sets0[0], sets0[1], flip0, &bits);
                try applyChangesToBits(persp, flip0, changes[0..n], &bits);
                var truth: PairBits = undefined;
                enumerateBits(persp, sets1[0], sets1[1], flip1, &truth);
                try std.testing.expectEqualSlices(u64, &truth, &bits);
            }
        }
        try deltaWalk(pos, depth - 1);
        make_unmake.unmakeMove(pos, mv, &st);
    }
}

test "PP1 per-move pair delta equals re-enumeration over move trees" {
    // Pushes, double pushes, captures of and by pawns, en passant, promotions,
    // capture-promotions and king captures of pawns.
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "8/8/3p4/2pPp3/2PkP3/8/8/4K3 b - - 0 1",
        "4k3/1P4p1/8/2pP4/8/8/6p1/4K2R w K c6 0 2",
    };
    for (fens) |f| {
        var pos = try fen.parse(f);
        try deltaWalk(&pos, 3);
    }
}

fn parseIndexList(field: []const u8, out: *[MAX_PAIRS]u16) !usize {
    var n: usize = 0;
    // "-" marks an empty list in the trainer's vector files.
    var it = std.mem.tokenizeAny(u8, field, " ,;[]-");
    while (it.next()) |tok| {
        if (n == MAX_PAIRS) return error.TooManyIndices;
        out[n] = try std.fmt.parseInt(u16, tok, 10);
        n += 1;
    }
    std.mem.sort(u16, out[0..n], {}, std.sort.asc(u16));
    return n;
}

test "PP1 matches the trainer's index vectors (optional: ZQ_PP1_VECTORS=<tsv>)" {
    // Cross-implementation parity with the trainer's input type: each line is
    // FEN <tab> white-perspective indices <tab> black-perspective indices.
    // Skipped unless the environment names a vector file.
    const allocator = std.testing.allocator;
    const path = std.process.getEnvVarOwned(allocator, "ZQ_PP1_VECTORS") catch return;
    defer allocator.free(path);
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 256 << 20);
    defer allocator.free(data);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var checked: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#' or std.ascii.startsWithIgnoreCase(line, "fen\t")) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const f = fields.next() orelse return error.BadVectorLine;
        const wf = fields.next() orelse return error.BadVectorLine;
        const bf = fields.next() orelse return error.BadVectorLine;
        var ew: [MAX_PAIRS]u16 = undefined;
        var eb: [MAX_PAIRS]u16 = undefined;
        const nw = try parseIndexList(wf, &ew);
        const nb = try parseIndexList(bf, &eb);
        const pos = try fen.parse(f);
        var gw: [MAX_PAIRS]u16 = undefined;
        var gb: [MAX_PAIRS]u16 = undefined;
        const ws = enumerateSorted(.white, &pos, &gw);
        const bs = enumerateSorted(.black, &pos, &gb);
        std.testing.expectEqualSlices(u16, ew[0..nw], ws) catch |e| {
            std.debug.print("white mismatch: {s}\n", .{f});
            return e;
        };
        std.testing.expectEqualSlices(u16, eb[0..nb], bs) catch |e| {
            std.debug.print("black mismatch: {s}\n", .{f});
            return e;
        };
        checked += 1;
    }
    std.debug.print("PP1 vectors: {d} positions identical\n", .{checked});
    try std.testing.expect(checked > 0);
}
