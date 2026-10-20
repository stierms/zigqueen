//! v6 FULL-THREATS feature enumeration (engine side, full-refresh path).
//!
//! Implements docs/V6_THREATS_SPEC.md (spec r2, FROZEN 2026-08-07) BIT-FOR-BIT
//! against the source-of-truth grader (bullet tools/fullthreats_grader.py).
//! Space: the field-converged 60,144-feature "SFNNv12-style" set — a feature is
//! (attacker colored-type, from-sq, victim colored-type, to-sq) with attackers
//! PNBRQ, king victims removed, subset-redundant combos removed (p->b, p->q,
//! b->q, r->q), to-sq restricted to the attacker's EMPTY-BOARD attack set;
//! ACTIVATION requires a real attack under current occupancy on an occupied
//! victim square (defends count). Index layout, orientation and the R1/R2
//! rulings are our own design (see the spec).
//!
//!   idx = AK_OFFSET[ak] + (PAIR_BASE[ak][f_o] + pairpos(ak, f_o, t_o)) * 2nv + v
//!     ak   in [0,10): (own?0:5) + {P,N,B,R,Q}   (own = attacker colour == persp)
//!     f_o, t_o oriented: (persp==white ? sq : sq^56) ^ flip, flip = own-king
//!              file > d ? 7 : 0 (same convention as threats.zig / HalfKA)
//!     pairpos = popcount(EMPTY_ATT[ak][f_o] & ((1<<t_o)-1))
//!     v in [0,2nv): (victim own ? 0 : nv) + rank of victim type in kept set
//!   spec r2: NO activation dedup — both directions of a mutual same-type
//!   pair activate (a per-perspective square-order rule breaks the trainer's
//!   paired stm/ntm feature emission; see V6_THREATS_SPEC.md).
//!
//! The comptime empty-board tables below use their OWN geometry derivation
//! (not movegen/attacks) so the runtime attack code and this module's index
//! space cross-validate each other through the grader vectors.
const std = @import("std");
const position = @import("../core/position.zig");
const types = @import("../core/types.zig");
const piece = @import("../core/piece.zig");
const square = @import("../core/square.zig");
const bitboard = @import("../core/bitboard.zig");
const attacks = @import("../movegen/attacks.zig");

pub const NUM_FULLTHREAT_FEATURES: usize = 60144;
pub const WORDS: usize = (NUM_FULLTHREAT_FEATURES + 63) / 64; // 940

/// Victim kept-set rank per attacker type: VRANK[atype][vtype], -1 = excluded.
/// Kept sets (spec r2): P->{P,N,R}, N->{P,N,B,R,Q}, B/R->{P,N,B,R}, Q->{P,N,B,R,Q}.
const VRANK = [5][6]i8{
    .{ 0, 1, -1, 2, -1, -1 }, // P
    .{ 0, 1, 2, 3, 4, -1 }, // N
    .{ 0, 1, 2, 3, -1, -1 }, // B
    .{ 0, 1, 2, 3, -1, -1 }, // R
    .{ 0, 1, 2, 3, 4, -1 }, // Q
};
const NV = [5]usize{ 3, 5, 4, 4, 5 };

// ---------------------------------------------------------------------------
// Comptime empty-board attack tables (own geometry; pawn direction by ak).
// ---------------------------------------------------------------------------
fn ctEmptyAttacks(atype: usize, own_dir: bool, f: usize) u64 {
    const r: i32 = @intCast(f / 8);
    const c: i32 = @intCast(f % 8);
    var bb: u64 = 0;
    switch (atype) {
        0 => { // pawn: own attacks north in the oriented frame, opp south
            if (r < 1 or r > 6) return 0; // pawns only on ranks 2..7
            const dr: i32 = if (own_dir) 1 else -1;
            for ([_]i32{ -1, 1 }) |dc| {
                const nr = r + dr;
                const nc = c + dc;
                if (nr >= 0 and nr < 8 and nc >= 0 and nc < 8)
                    bb |= @as(u64, 1) << @intCast(nr * 8 + nc);
            }
        },
        1 => { // knight
            const deltas = [8][2]i32{ .{ 1, 2 }, .{ 2, 1 }, .{ 2, -1 }, .{ 1, -2 }, .{ -1, -2 }, .{ -2, -1 }, .{ -2, 1 }, .{ -1, 2 } };
            for (deltas) |d| {
                const nr = r + d[1];
                const nc = c + d[0];
                if (nr >= 0 and nr < 8 and nc >= 0 and nc < 8)
                    bb |= @as(u64, 1) << @intCast(nr * 8 + nc);
            }
        },
        else => { // sliders: bishop dirs, rook dirs, queen both
            const diag = [4][2]i32{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } };
            const ortho = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
            const use_diag = atype == 2 or atype == 4;
            const use_ortho = atype == 3 or atype == 4;
            if (use_diag) for (diag) |d| {
                var nr = r + d[0];
                var nc = c + d[1];
                while (nr >= 0 and nr < 8 and nc >= 0 and nc < 8) : ({
                    nr += d[0];
                    nc += d[1];
                }) bb |= @as(u64, 1) << @intCast(nr * 8 + nc);
            };
            if (use_ortho) for (ortho) |d| {
                var nr = r + d[0];
                var nc = c + d[1];
                while (nr >= 0 and nr < 8 and nc >= 0 and nc < 8) : ({
                    nr += d[0];
                    nc += d[1];
                }) bb |= @as(u64, 1) << @intCast(nr * 8 + nc);
            };
        },
    }
    return bb;
}

const Tables = struct {
    ak_offset: [10]u32,
    pair_base: [10][64]u16,
    empty_att: [10][64]u64,
    total: u32,
};

const T: Tables = blk: {
    @setEvalBranchQuota(1_000_000);
    var t = Tables{
        .ak_offset = undefined,
        .pair_base = .{.{0} ** 64} ** 10,
        .empty_att = .{.{0} ** 64} ** 10,
        .total = 0,
    };
    var off: u32 = 0;
    for (0..10) |ak| {
        const own = ak < 5;
        const atype = ak % 5;
        t.ak_offset[ak] = off;
        var pairs: u32 = 0;
        for (0..64) |f| {
            t.pair_base[ak][f] = @intCast(pairs);
            const att = ctEmptyAttacks(atype, own, f);
            t.empty_att[ak][f] = att;
            pairs += @popCount(att);
        }
        off += pairs * 2 * @as(u32, @intCast(NV[atype]));
    }
    t.total = off;
    break :blk t;
};

comptime {
    // Spec r2 arithmetic, derived twice independently (grader + here).
    std.debug.assert(T.total == NUM_FULLTHREAT_FEATURES);
    std.debug.assert(T.ak_offset[5] == 30072);
}

/// Flat index of one feature. ak = attacker key, f_o/t_o oriented squares,
/// victim_own = victim colour == perspective, vrank = kept-set rank (>=0).
pub inline fn fullIndex(ak: usize, f_o: usize, t_o: usize, victim_own: bool, vrank: usize) usize {
    const atype = ak % 5;
    const att = T.empty_att[ak][f_o];
    std.debug.assert((att >> @as(u6, @intCast(t_o))) & 1 == 1);
    const below = att & ((@as(u64, 1) << @as(u6, @intCast(t_o))) - 1);
    const pairpos: usize = @popCount(below);
    const nv = NV[atype];
    const v: usize = (if (victim_own) 0 else nv) + vrank;
    return T.ak_offset[ak] + (T.pair_base[ak][f_o] + pairpos) * (2 * nv) + v;
}

/// One perspective's index frame for one attacker group (attacker key `ak` on
/// oriented square `f_o`): its empty-board attack set, the index of its first
/// feature and the index stride per target (2 * nv), so that fullIndex(ak, f_o,
/// t_o, own, vrank) = base + popcount(att below t_o) * stride + victim slot.
const GroupFrame = struct { att: u64, base: u32, stride: u32 };

const GROUP_FRAMES: [10][64]GroupFrame = blk: {
    @setEvalBranchQuota(100_000);
    var g: [10][64]GroupFrame = undefined;
    for (0..10) |ak| for (0..64) |f| {
        const nv = NV[ak % 5];
        g[ak][f] = .{ .att = T.empty_att[ak][f], .base = T.ak_offset[ak] + @as(u32, T.pair_base[ak][f]) * 2 * @as(u32, nv), .stride = 2 * @as(u32, nv) };
    };
    break :blk g;
};

/// ATTACKER_KEY[persp][piece]: the piece's attacker key in that perspective
/// (0..4 own PNBRQ, 5..9 the opponent's); kings and `none` never attack.
const ATTACKER_KEY: [2][13]u8 = blk: {
    var k: [2][13]u8 = .{.{0} ** 13} ** 2;
    for (0..2) |persp| for (0..12) |pi| {
        const atype = pi % 6;
        if (atype == 5) continue;
        k[persp][pi] = (if (pi / 6 == persp) 0 else 5) + atype;
    };
    break :blk k;
};

/// VICTIM_SLOT[persp][ak][piece]: a victim's slot within one target's 2 * nv
/// feature block (own victims first, then the opponent's, by kept-set rank), or
/// -1 when that victim is no feature for attacker key `ak` (king, subset-
/// redundant pair, `none`).
const VICTIM_SLOT: [2][10][13]i8 = blk: {
    @setEvalBranchQuota(100_000);
    var v: [2][10][13]i8 = .{.{.{-1} ** 13} ** 10} ** 2;
    for (0..2) |persp| for (0..10) |ak| for (0..12) |pi| {
        const vr = VRANK[ak % 5][pi % 6];
        if (vr < 0) continue;
        v[persp][ak][pi] = @as(i8, @intCast(if (pi / 6 == persp) 0 else NV[ak % 5])) + vr;
    };
    break :blk v;
};

/// One attacker group (piece on one square) in both perspectives.
const GroupPair = struct {
    w: GroupFrame,
    b: GroupFrame,
    vw: *const [13]i8,
    vb: *const [13]i8,

    inline fn of(p: piece.Piece, sq: u6, wflip: u6, bflip: u6) GroupPair {
        const akw = ATTACKER_KEY[0][@intFromEnum(p)];
        const akb = ATTACKER_KEY[1][@intFromEnum(p)];
        return .{
            .w = GROUP_FRAMES[akw][sq ^ wflip],
            .b = GROUP_FRAMES[akb][(sq ^ 56) ^ bflip],
            .vw = &VICTIM_SLOT[0][akw],
            .vb = &VICTIM_SLOT[1][akb],
        };
    }

    /// Victim `v` on square `t` is a feature of this group.
    inline fn isFeature(g: GroupPair, v: piece.Piece) bool {
        return g.vw[@intFromEnum(v)] >= 0;
    }

    /// Emit (this group -> `v` on `t`) in both perspectives as `add`; `v` must be
    /// a feature victim (isFeature).
    inline fn emit(g: GroupPair, comptime add: bool, t: u6, v: piece.Piece, wflip: u6, bflip: u6, sink: anytype) void {
        const vi = @intFromEnum(v);
        const sw: u32 = @intCast(g.vw[vi]);
        const sb: u32 = @intCast(g.vb[vi]);
        const tw: u6 = t ^ wflip;
        const tb: u6 = (t ^ 56) ^ bflip;
        std.debug.assert((g.w.att >> tw) & 1 == 1 and (g.b.att >> tb) & 1 == 1);
        const iw = g.w.base + @as(u32, @popCount(g.w.att & ((@as(u64, 1) << tw) - 1))) * g.w.stride + sw;
        const ib = g.b.base + @as(u32, @popCount(g.b.att & ((@as(u64, 1) << tb) - 1))) * g.b.stride + sb;
        sink.emitPair(add, iw, ib);
    }
};

/// One perspective's active full-threat features as a 60,144-bit set.
pub const PerspBits = [WORDS]u64;

inline fn setBit(bits: *PerspBits, idx: usize) void {
    bits[idx >> 6] |= @as(u64, 1) << @as(u6, @intCast(idx & 63));
}

/// Occupancy-aware attack set (physical, absolute frame). Kings excluded.
inline fn attackSet(pt: piece.PieceType, color: types.Color, from: square.Square, occ: bitboard.Bitboard) bitboard.Bitboard {
    return switch (pt) {
        .pawn => attacks.pawnAttacksFrom(color, from),
        .knight => attacks.knightAttacksFrom(from),
        .bishop => attacks.bishopAttacksDirect(from, occ),
        .rook => attacks.rookAttacksDirect(from, occ),
        .queen => attacks.queenAttacksDirect(from, occ),
        else => unreachable,
    };
}

/// Full-refresh enumeration per COLOUR perspective (white/black), cleared first.
pub fn enumerateColors(pos: *const position.Position, out_white: *PerspBits, out_black: *PerspBits) void {
    out_white.* = [_]u64{0} ** WORDS;
    out_black.* = [_]u64{0} ** WORDS;
    const occ = pos.occupied;
    const wflip: u6 = if (pos.king_squares[0].?.file() > 3) 7 else 0;
    const bflip: u6 = if (pos.king_squares[1].?.file() > 3) 7 else 0;

    inline for ([_]types.Color{ .white, .black }) |ac| {
        const ac_idx = @intFromEnum(ac);
        inline for ([_]piece.PieceType{ .pawn, .knight, .bishop, .rook, .queen }) |pt| {
            const atype: usize = @intFromEnum(pt); // 0..4
            var bb = pos.pieces[ac_idx][atype];
            while (bb != 0) {
                const from = bitboard.popLsbUnchecked(&bb);
                const from_idx: usize = @intFromEnum(from);
                var tb = attackSet(pt, ac, from, occ) & occ;
                while (tb != 0) {
                    const to = bitboard.popLsbUnchecked(&tb);
                    const to_idx: usize = @intFromEnum(to);
                    const tp = pos.mailbox[to_idx];
                    const vtype_full: usize = @intFromEnum(tp.pieceType()); // 0..5
                    if (vtype_full == 5) continue; // king victims excluded
                    const vr = VRANK[atype][vtype_full];
                    if (vr < 0) continue; // subset-redundant combo
                    const vrank: usize = @intCast(vr);
                    const tcolor = tp.color().?;
                    // white perspective
                    {
                        const f_o = from_idx ^ wflip;
                        const t_o = to_idx ^ wflip;
                        const ak: usize = (if (ac == .white) @as(usize, 0) else 5) + atype;
                        setBit(out_white, fullIndex(ak, f_o, t_o, tcolor == .white, vrank));
                    }
                    // black perspective
                    {
                        const f_o = (from_idx ^ 56) ^ bflip;
                        const t_o = (to_idx ^ 56) ^ bflip;
                        const ak: usize = (if (ac == .black) @as(usize, 0) else 5) + atype;
                        setBit(out_black, fullIndex(ak, f_o, t_o, tcolor == .black, vrank));
                    }
                }
            }
        }
    }
}

/// Most active features of one perspective: each (non-king attacker, occupied
/// target) pair is at most one feature, so 30 attackers x 31 targets bound it.
pub const MAX_ACTIVE: usize = 30 * 31;

/// enumerateColors for ONE perspective, as the list of its active feature
/// indices (enumerateColors' attacker order) instead of a cleared 940-word set:
/// the sparse form for the flip-cache rebuild (nnue768 FullThreatState). Every
/// feature appears once (one per attacker-target pair). Returns the count.
pub fn enumeratePerspList(pos: *const position.Position, comptime persp: types.Color, out: *[MAX_ACTIVE]u16) usize {
    const occ = pos.occupied;
    const flip: u6 = if (pos.king_squares[@intFromEnum(persp)].?.file() > 3) 7 else 0;
    const orient: u6 = (if (persp == .black) 56 else 0) ^ flip;
    var n: usize = 0;
    inline for ([_]types.Color{ .white, .black }) |ac| {
        const ac_idx = @intFromEnum(ac);
        inline for ([_]piece.PieceType{ .pawn, .knight, .bishop, .rook, .queen }) |pt| {
            const atype: usize = @intFromEnum(pt); // 0..4
            const ak: usize = (if (ac == persp) @as(usize, 0) else 5) + atype;
            var bb = pos.pieces[ac_idx][atype];
            while (bb != 0) {
                const from = bitboard.popLsbUnchecked(&bb);
                const f_o: usize = @intFromEnum(from) ^ orient;
                var tb = attackSet(pt, ac, from, occ) & occ;
                while (tb != 0) {
                    const to = bitboard.popLsbUnchecked(&tb);
                    const to_idx: usize = @intFromEnum(to);
                    const tp = pos.mailbox[to_idx];
                    const vtype_full: usize = @intFromEnum(tp.pieceType()); // 0..5
                    if (vtype_full == 5) continue; // king victims excluded
                    const vr = VRANK[atype][vtype_full];
                    if (vr < 0) continue; // subset-redundant combo
                    out[n] = @intCast(fullIndex(ak, f_o, to_idx ^ orient, tp.color().? == persp, @intCast(vr)));
                    n += 1;
                }
            }
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Per-move delta (docs/V6_INCREMENTAL_DESIGN.md r1 groups; direct form, lane 2
// #4). Groups = attacker squares: group(sq, colored-type) is the contiguous
// index range of that piece's outgoing features for one perspective.
// ---------------------------------------------------------------------------

/// One changed square of a move (from/to/capture/castle-rook), old and new
/// occupants (piece.Piece.none for empty).
pub const SquareChange = struct { sq: u6, old: piece.Piece, new: piece.Piece };

/// Bytes of each emitted threat row prefetched at emission (4 cache lines);
/// the flush walk (nnue768 PendingThreatRowsT(i8)) prefetches from here on.
pub const ROW_PREFETCH_BYTES: usize = 256;

/// Bound on one move's changed features per direction. Adds: one (A) group
/// with an attacker (<= 8 features: one per queen ray, knight target) plus, per
/// changed square (<= 4), <= 12 leapers (4 pawns, 8 knights) and <= 8 slider
/// rays: 88. Removes: <= 2 (R) groups (16) + the same 80 (T) features: 96.
pub const MAX_MOVE_FEATURES: usize = 128;

pub inline fn kingFlips(pos: *const position.Position) struct { w: u6, b: u6 } {
    return .{
        .w = if (pos.king_squares[0].?.file() > 3) 7 else 0,
        .b = if (pos.king_squares[1].?.file() > 3) 7 else 0,
    };
}

// ---------------------------------------------------------------------------
// Direct delta (lane 2 #4, artifacts/research/perf-lane2-20261007/
// SPEC-direct-threat-delta.md): a move's changed features (old truth XOR new
// truth), each with its direction, generated from the post-move board and the
// change list alone — no stored feature bitsets, no undo log. It replaces the
// former bitset-XOR delta engine (applyMoveDelta). For changed squares C:
//   (R) every feature of each changed square's OLD occupant group, read off the
//       OLD board (occupancy occ_old, old victims), is REMOVED;
//   (A) every feature of each changed square's NEW occupant group is ADDED;
//   (T) attackers on unchanged squares emit their changed features, read off
//       each changed square: a pawn's or knight's victim there, a slider's
//       first blocker on the ray through it (see emitMoveDelta).
// A feature belongs to exactly one group (its attacker's square and coloured
// type); (R)/(A) groups sit on changed squares, (T) groups on unchanged ones,
// and an old and a new occupant of one square never share a key. An (R) group
// has no feature after the move (its piece left the square) and an (A) group
// had none before it, so (R) emits exactly that group's old-truth \ new-truth
// and (A) its new-truth \ old-truth; (T) emits exactly the XOR of its group.
// Row adds/subs wrap and PSQT sums are integers, so emission order is free.
// `sink.emitPair(comptime add: bool, iw: usize, ib: usize)` receives every
// changed feature once, with its direction and its white- and black-
// perspective indices. At most MAX_MOVE_FEATURES features per direction.
// ---------------------------------------------------------------------------

/// Old occupant of square `t` (post-move occupant unless `t` changed).
inline fn oldOccupant(pos: *const position.Position, changes: []const SquareChange, changed_mask: u64, t: usize) piece.Piece {
    var p = pos.mailbox[t];
    if (changed_mask & (@as(u64, 1) << @intCast(t)) != 0) {
        for (changes) |c| {
            if (c.sq == t) p = c.old;
        }
    }
    return p;
}

/// Emit every feature of the group of attacker `att` (of type `atype`) on
/// `sq_idx` on one board as `add`. `occ_use`/`kept` describe that board;
/// `old_board` selects old victims.
inline fn emitWholeGroup(
    comptime add: bool,
    comptime old_board: bool,
    pos: *const position.Position,
    changes: []const SquareChange,
    changed_mask: u64,
    sq_idx: u6,
    att: piece.Piece,
    atype: usize,
    occ_use: u64,
    kept: u64,
    wflip: u6,
    bflip: u6,
    sink: anytype,
) void {
    const g = GroupPair.of(att, sq_idx, wflip, bflip);
    const pt: piece.PieceType = @enumFromInt(atype);
    var tb = attackSet(pt, att.color().?, square.Square.fromIndex(sq_idx), occ_use) & kept;
    while (tb != 0) {
        const to = bitboard.popLsbUnchecked(&tb);
        const t: u6 = @intFromEnum(to);
        const p = if (old_board) oldOccupant(pos, changes, changed_mask, t) else pos.mailbox[t];
        g.emit(add, t, p, wflip, bflip, sink);
    }
}

/// RAYS[s][d]: the squares beyond `s` (exclusive) in direction d = (dr + 1) * 3
/// + (df + 1), dr/df in {-1, 0, 1} the rank/file step; d = 4 is empty. A
/// direction with d > 4 walks to higher square indices.
const RAYS: [64][9]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var r: [64][9]u64 = .{.{0} ** 9} ** 64;
    for (0..64) |s| for (0..9) |d| {
        if (d == 4) continue;
        const dr: i32 = @as(i32, @intCast(d / 3)) - 1;
        const df: i32 = @as(i32, @intCast(d % 3)) - 1;
        var nr: i32 = @as(i32, @intCast(s / 8)) + dr;
        var nf: i32 = @as(i32, @intCast(s % 8)) + df;
        while (nr >= 0 and nr < 8 and nf >= 0 and nf < 8) : ({
            nr += dr;
            nf += df;
        }) r[s][d] |= @as(u64, 1) << @intCast(nr * 8 + nf);
    };
    break :blk r;
};

/// First occupied square of `ray` (a RAYS entry, walking up or down); >= 64
/// when the ray holds none.
inline fn firstOn(ray: u64, occ: u64, up: bool) u7 {
    const b = ray & occ;
    return if (up) @ctz(b) else 63 ^ @clz(b);
}

/// (T), slider: `x` (unchanged square) sees changed square `s` with no changed
/// square in between, so on the ray x -> s -> beyond only the first blocker can
/// differ: s itself when occupied, else the first occupied square beyond it,
/// under each occupancy. Remove the old first-blocker feature, add the new one.
inline fn emitSliderRay(
    pos: *const position.Position,
    changes: []const SquareChange,
    changed_mask: u64,
    occ_old: u64,
    x: u6,
    s: u6,
    s_old: piece.Piece,
    s_new: piece.Piece,
    wflip: u6,
    bflip: u6,
    sink: anytype,
) void {
    const dr = @as(i32, s >> 3) - @as(i32, x >> 3);
    const df = @as(i32, s & 7) - @as(i32, x & 7);
    const d: usize = @intCast((@as(i32, @intFromBool(dr > 0)) - @intFromBool(dr < 0) + 1) * 3 + (@as(i32, @intFromBool(df > 0)) - @intFromBool(df < 0) + 1));
    const ray = RAYS[s][d];
    const up = d > 4;
    const vo: u7 = if (s_old != .none) s else firstOn(ray, occ_old, up);
    const vn: u7 = if (s_new != .none) s else firstOn(ray, pos.occupied, up);
    const po: piece.Piece = if (vo < 64) oldOccupant(pos, changes, changed_mask, vo) else .none;
    const pn: piece.Piece = if (vn < 64) pos.mailbox[vn] else .none;
    if (vo == vn and po == pn) return;
    const g = GroupPair.of(pos.mailbox[x], x, wflip, bflip);
    if (g.isFeature(po)) g.emit(false, @intCast(vo), po, wflip, bflip, sink);
    if (g.isFeature(pn)) g.emit(true, @intCast(vn), pn, wflip, bflip, sink);
}

/// (T), pawn or knight on unchanged square `x` attacking changed square `s`:
/// its attack set ignores occupancy, so only the victim on `s` changes.
inline fn emitLeaperTarget(pos: *const position.Position, x: u6, s: u6, s_old: piece.Piece, s_new: piece.Piece, wflip: u6, bflip: u6, sink: anytype) void {
    const g = GroupPair.of(pos.mailbox[x], x, wflip, bflip);
    if (g.isFeature(s_old)) g.emit(false, s, s_old, wflip, bflip, sink);
    if (g.isFeature(s_new)) g.emit(true, s, s_new, wflip, bflip, sink);
}

/// Emit a move's threat-feature delta (both perspectives, with directions) to
/// `sink`. `pos` is the POST-move board, `changes` the move's changed squares
/// (<= 4); both perspectives' mirror flips must be unchanged across the move
/// (a flip-changed perspective's emissions are meaningless and must be ignored
/// by the sink).
pub fn emitMoveDelta(pos: *const position.Position, changes: []const SquareChange, sink: anytype) void {
    const occ = pos.occupied;
    const flips = kingFlips(pos);
    var changed_mask: u64 = 0;
    var occ_old: u64 = occ;
    // Old-board piece-type unions (both colours): new unions with the changed
    // squares' new occupants removed and their old occupants restored.
    var u = [5]u64{
        pos.pieces[0][0] | pos.pieces[1][0],
        pos.pieces[0][1] | pos.pieces[1][1],
        pos.pieces[0][2] | pos.pieces[1][2],
        pos.pieces[0][3] | pos.pieces[1][3],
        pos.pieces[0][4] | pos.pieces[1][4],
    };
    const kept_new = keptVictimMasksFrom(u);
    for (changes) |c| {
        const bit = @as(u64, 1) << c.sq;
        changed_mask |= bit;
        if (c.old != .none) occ_old |= bit else occ_old &= ~bit;
        if (c.new != .none) {
            const t: usize = @intFromEnum(c.new.pieceType());
            if (t < 5) u[t] &= ~bit;
        }
    }
    for (changes) |c| {
        if (c.old != .none) {
            const t: usize = @intFromEnum(c.old.pieceType());
            if (t < 5) u[t] |= @as(u64, 1) << c.sq;
        }
    }
    const kept_old = keptVictimMasksFrom(u);

    // (R) and (A): the changed squares' old and new occupant groups.
    for (changes) |c| {
        if (c.old != .none) {
            const at: usize = @intFromEnum(c.old.pieceType());
            if (at < 5) emitWholeGroup(false, true, pos, changes, changed_mask, c.sq, c.old, at, occ_old, kept_old[at], flips.w, flips.b, sink);
        }
        if (c.new != .none) {
            const at: usize = @intFromEnum(c.new.pieceType());
            if (at < 5) emitWholeGroup(true, false, pos, changes, changed_mask, c.sq, c.new, at, occ, kept_new[at], flips.w, flips.b, sink);
        }
    }

    // (T): attackers on UNCHANGED squares (a changed square's piece is its (R)/(A)
    // group above), per changed square s with old/new occupants O/N.
    //  - Pawns and knights attacking s: their attack sets ignore occupancy, so
    //    exactly their features on s change: remove (X -> O), add (X -> N).
    //  - Sliders: a slider's features are the first blockers of its rays, and a
    //    ray's first blocker can only change if the ray holds a changed square.
    //    Collect sliders attacking s under occ2 = occ | changed (changed squares
    //    block): x is collected at s iff x sees s under `occ` with no changed
    //    square strictly between (the squares between are unchanged and empty,
    //    so x sees s under occ_old too). Each ray holding a changed square is
    //    thus processed exactly once, at its FIRST changed square s: on it the
    //    old/new first blocker is s if s is occupied on that board, else the
    //    first occupied square beyond s (emitSliderRay). Rays without a changed
    //    square keep their blocker, so nothing else of x changes.
    // No feature is emitted twice: leaper features are distinct per (x, s) and
    // slider features per (x, ray); a remove/add of the same feature is skipped.
    const occ2 = occ | changed_mask;
    const bq = pos.pieces[0][2] | pos.pieces[1][2] | pos.pieces[0][4] | pos.pieces[1][4];
    const rq = pos.pieces[0][3] | pos.pieces[1][3] | pos.pieces[0][4] | pos.pieces[1][4];
    const knights = pos.pieces[0][1] | pos.pieces[1][1];
    for (changes) |c| {
        const t = square.Square.fromIndex(c.sq);
        var leapers = ((attacks.pawnAttacksFrom(.black, t) & pos.pieces[0][0]) |
            (attacks.pawnAttacksFrom(.white, t) & pos.pieces[1][0]) |
            (attacks.knightAttacksDirect(t) & knights)) & ~changed_mask;
        while (leapers != 0) {
            const x = bitboard.popLsbUnchecked(&leapers);
            emitLeaperTarget(pos, @intFromEnum(x), c.sq, c.old, c.new, flips.w, flips.b, sink);
        }
        var sliders = ((attacks.bishopAttacksDirect(t, occ2) & bq) | (attacks.rookAttacksDirect(t, occ2) & rq)) & ~changed_mask;
        while (sliders != 0) {
            const x = bitboard.popLsbUnchecked(&sliders);
            emitSliderRay(pos, changes, changed_mask, occ_old, @intFromEnum(x), c.sq, c.old, c.new, flips.w, flips.b, sink);
        }
    }
}

inline fn keptVictimMasksFrom(u: [5]u64) [5]u64 {
    const pnbr = u[0] | u[1] | u[2] | u[3];
    return .{ u[0] | u[1] | u[3], pnbr | u[4], pnbr, pnbr, pnbr | u[4] };
}

// ---------------------------------------------------------------------------
// Ray-slot emission (docs/research/RAY_PERMUTATION_EMISSION_SPEC.md §1.1-1.4,
// §2.2-2.4; implemented from that spec only). Every square s gets a fixed row
// of 64 slots: 8 directions in rotational order (N, NE, E, SE, S, SW, W, NW, so
// d + 4 is the opposite of d), each one byte of slots: slot 8d + 0 is a knight
// square, slots 8d + k (k = 1..7) the squares k steps along d. A board seen
// from s is its 64 class bytes permuted into that order; occupancy, attackers
// and nearest blockers per ray are then bit operations on 64-bit slot masks.
// ---------------------------------------------------------------------------

pub const has_avx2 = blk: {
    if (@import("builtin").cpu.arch != .x86_64) break :blk false;
    break :blk std.Target.x86.featureSetHas(@import("builtin").cpu.features, .avx2);
};

/// Direction steps (rank, file) in rotational order, and the knight jump each
/// direction owns: the jump half a step clockwise of it (our assignment).
const RAY_STEP = [8][2]i32{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ -1, 1 }, .{ -1, 0 }, .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 } };
const RAY_KNIGHT = [8][2]i32{ .{ 2, 1 }, .{ 1, 2 }, .{ -1, 2 }, .{ -2, 1 }, .{ -2, -1 }, .{ -1, -2 }, .{ 1, -2 }, .{ 2, -1 } };

/// Off-board slot: its top bit makes a byte shuffle return 0 for it.
const SLOT_OFF: u8 = 0x80;
const SLOT_NONE: u8 = 0xFF;

/// SLOT_SQ[s][slot]: the square in that slot of s's row, or SLOT_OFF.
/// SLOT_OF[s][t]: the slot of square t in s's row, or SLOT_NONE.
const SlotTables = struct { sq: [64][64]u8 align(64), of: [64][64]u8 align(64) };
const SLOTS: SlotTables = blk: {
    @setEvalBranchQuota(1_000_000);
    var st: SlotTables = .{ .sq = .{.{SLOT_OFF} ** 64} ** 64, .of = .{.{SLOT_NONE} ** 64} ** 64 };
    for (0..64) |s| {
        const r: i32 = @intCast(s / 8);
        const f: i32 = @intCast(s % 8);
        for (0..8) |d| {
            const kr = r + RAY_KNIGHT[d][0];
            const kf = f + RAY_KNIGHT[d][1];
            if (kr >= 0 and kr < 8 and kf >= 0 and kf < 8) st.sq[s][8 * d] = @intCast(kr * 8 + kf);
            for (1..8) |k| {
                const nr = r + RAY_STEP[d][0] * @as(i32, @intCast(k));
                const nf = f + RAY_STEP[d][1] * @as(i32, @intCast(k));
                if (nr >= 0 and nr < 8 and nf >= 0 and nf < 8) st.sq[s][8 * d + k] = @intCast(nr * 8 + nf);
            }
        }
        for (0..64) |i| {
            if (st.sq[s][i] != SLOT_OFF) st.of[s][st.sq[s][i]] = @intCast(i);
        }
    }
    break :blk st;
};

/// Class bytes (bit per class; bit 7 = black, ignored by every test mask).
const CL_WP: u8 = 1;
const CL_BP: u8 = 2;
const CL_N: u8 = 4;
const CL_B: u8 = 8;
const CL_R: u8 = 16;
const CL_Q: u8 = 32;
const CL_K: u8 = 64;
const CL_BLACK: u8 = 128;

/// Class byte of each piece code (index = piece.Piece; `none` and the unused
/// codes 13..15 are empty).
const PIECE_CLASS = [16]u8{
    CL_WP,            CL_N,            CL_B,            CL_R,            CL_Q,            CL_K,
    CL_BP | CL_BLACK, CL_N | CL_BLACK, CL_B | CL_BLACK, CL_R | CL_BLACK, CL_Q | CL_BLACK, CL_K | CL_BLACK,
    0,                0,               0,               0,
};

/// Byte b of a 64-bit slot mask = direction b.
const KNIGHT_SLOTS: u64 = 0x0101_0101_0101_0101;
const STEP_SLOTS: u64 = 0xFEFE_FEFE_FEFE_FEFE;
const ORTHO_STEPS: u64 = 0x00FE_00FE_00FE_00FE; // bytes 0, 2, 4, 6
const DIAG_STEPS: u64 = 0xFE00_FE00_FE00_FE00; // bytes 1, 3, 5, 7

/// Outgoing slots of each attacker piece code (kings and `none`: none).
const OUT_SLOTS = blk: {
    var o = [_]u64{0} ** 16;
    o[0] = (1 << (8 * 1 + 1)) | (1 << (8 * 7 + 1)); // white pawn: NE, NW step 1
    o[6] = (1 << (8 * 3 + 1)) | (1 << (8 * 5 + 1)); // black pawn: SE, SW step 1
    for ([_]usize{ 1, 7 }) |p| o[p] = KNIGHT_SLOTS;
    for ([_]usize{ 2, 8 }) |p| o[p] = DIAG_STEPS;
    for ([_]usize{ 3, 9 }) |p| o[p] = ORTHO_STEPS;
    for ([_]usize{ 4, 10 }) |p| o[p] = STEP_SLOTS;
    break :blk o;
};

/// Victim classes an attacker piece code keeps (spec r2 kept sets).
const KEPT_CLASS = blk: {
    const pawns = CL_WP | CL_BP;
    var k = [_]u8{0} ** 16;
    for ([_]usize{ 0, 6 }) |p| k[p] = pawns | CL_N | CL_R;
    for ([_]usize{ 1, 7, 4, 10 }) |p| k[p] = pawns | CL_N | CL_B | CL_R | CL_Q;
    for ([_]usize{ 2, 8, 3, 9 }) |p| k[p] = pawns | CL_N | CL_B | CL_R;
    break :blk k;
};

/// Per slot: the attacker classes that attack the focus square from it.
/// Knight slots: knights; orthogonal steps: rooks, queens; diagonal steps:
/// bishops, queens, and at step 1 the pawn colour attacking from that side
/// (black pawns from NE/NW, white pawns from SE/SW).
fn attackerClassAt(slot: usize, comptime sliders_only: bool) u8 {
    const d = slot / 8;
    const k = slot % 8;
    if (k == 0) return if (sliders_only) 0 else CL_N;
    if (d % 2 == 0) return CL_R | CL_Q;
    var c: u8 = CL_B | CL_Q;
    if (!sliders_only and k == 1) c |= if (d == 1 or d == 7) CL_BP else CL_WP;
    return c;
}

/// INCOMING[t]: per slot, the attacker classes that attack the focus from it
/// AND keep a victim of type t (pieceType order; king: none).
const INCOMING: [6][64]u8 align(64) = blk: {
    @setEvalBranchQuota(100_000);
    const all = CL_WP | CL_BP | CL_N | CL_B | CL_R | CL_Q;
    const keepers = [6]u8{ all, all, CL_N | CL_B | CL_R | CL_Q, all, CL_N | CL_Q, 0 };
    var m: [6][64]u8 = undefined;
    for (0..6) |t| for (0..64) |i| {
        m[t][i] = attackerClassAt(i, false) & keepers[t];
    };
    break :blk m;
};
const SLIDERS_AT: [64]u8 align(64) = blk: {
    var m: [64]u8 = undefined;
    for (0..64) |i| m[i] = attackerClassAt(i, true);
    break :blk m;
};

const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);

inline fn pshufb(tbl: V32, idx: V32) V32 {
    return asm ("vpshufb %[idx], %[tbl], %[out]"
        : [out] "=v" (-> V32),
        : [tbl] "v" (tbl),
          [idx] "v" (idx),
    );
}

/// Slot-mask of the bytes of `v` that share a bit with `m`.
inline fn slotsWith(v: V64, m: V64) u64 {
    return ~@as(u64, @bitCast((v & m) == @as(V64, @splat(0))));
}

/// Per direction byte: the knight bit if set, and the nearest occupied step.
inline fn nearestPerRay(occ: u64) u64 {
    const o = occ | 0x8181_8181_8181_8181;
    return (o ^ (o -% 0x0303_0303_0303_0303)) & occ;
}

/// For a mask with bit 0 clear and at most one other bit per byte: bits 0..6 of
/// every byte that holds a bit.
inline fn raySpan(x: u64) u64 {
    const hi = (x +% 0x7E7E_7E7E_7E7E_7E7E) & 0x8080_8080_8080_8080;
    return hi -% (hi >> 7);
}

/// The board in class bytes, and its four 16-byte quarters in both lanes.
const ClassBoard = struct {
    q: [4]V32,

    inline fn of(pos: *const position.Position) ClassBoard {
        const lut16: @Vector(16, u8) = PIECE_CLASS;
        const lut: V32 = @shuffle(u8, lut16, undefined, [32]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 });
        const mb: *const [64]u8 = @ptrCast(&pos.mailbox);
        const lo = pshufb(lut, mb[0..32].*);
        const hi = pshufb(lut, mb[32..64].*);
        return .{ .q = .{
            @shuffle(u8, lo, undefined, [32]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }),
            @shuffle(u8, lo, undefined, [32]i32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 }),
            @shuffle(u8, hi, undefined, [32]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }),
            @shuffle(u8, hi, undefined, [32]i32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 }),
        } };
    }

    /// 32 class bytes at the squares `idx` (each < 64, or with its top bit set
    /// for 0): a byte shuffle per quarter, then blends on index bits 4 and 5.
    inline fn gather32(cb: *const ClassBoard, idx: V32) V32 {
        const zero: @Vector(32, i8) = @splat(0);
        const w: @Vector(16, u16) = @bitCast(idx);
        const b4: @Vector(32, i8) = @bitCast(w << @splat(3)); // bit 4 -> bit 7
        const b5: @Vector(32, i8) = @bitCast(w << @splat(2)); // bit 5 -> bit 7
        const lo = @select(u8, b4 < zero, pshufb(cb.q[1], idx), pshufb(cb.q[0], idx));
        const hi = @select(u8, b4 < zero, pshufb(cb.q[3], idx), pshufb(cb.q[2], idx));
        return @select(u8, b5 < zero, hi, lo);
    }

    /// The board seen from `s`: class byte per slot (off-board slots empty).
    inline fn view(cb: *const ClassBoard, s: u6) V64 {
        const row: *const [64]u8 = &SLOTS.sq[s];
        const a = cb.gather32(row[0..32].*);
        const b = cb.gather32(row[32..64].*);
        return std.simd.join(a, b);
    }
};

/// One changed square's slot-space state (spec §2.2-2.3): the board after the
/// move seen from `s` (the view), and the occupancies of both boards with the
/// other changed square `c` patched in. `cbit` is c's slot bit (0 when c is not
/// in s's row); the union occupancy treats c as a blocker.
const RayFocus = struct {
    s: u6,
    view: V64,
    sc: u8,
    cbit: u64,
    near0: u64,
    near1: u64,
    nearu: u64,

    inline fn of(cb: *const ClassBoard, f: SquareChange, o: SquareChange) RayFocus {
        const v1 = cb.view(f.sq);
        const occ1 = ~@as(u64, @bitCast(v1 == @as(V64, @splat(0))));
        const sc = SLOTS.of[f.sq][o.sq];
        const cbit: u64 = if (sc != SLOT_NONE) @as(u64, 1) << @intCast(sc & 63) else 0;
        const occ0 = (occ1 & ~cbit) | (if (o.old != .none) cbit else 0);
        return .{
            .s = f.sq,
            .view = v1,
            .sc = sc,
            .cbit = cbit,
            .near0 = nearestPerRay(occ0),
            .near1 = nearestPerRay(occ1),
            .nearu = nearestPerRay(occ1 | cbit),
        };
    }
};

/// emitMoveDelta for exactly two changed squares, in slot space (spec §2.2):
/// each changed square s (old/new occupants O/N) is processed against both
/// boards at once, the other changed square c acting as a blocker in the union
/// occupancy. Per s:
///  - (R) O's outgoing slots AND B0's nearest blockers AND O's kept classes
///    (B0 bytes: c re-patched with its old occupant): remove;
///  - (A) the same for N on B1: add;
///  - (T) incoming: attackers of s that keep O's (N's) type, nearest on the
///    union occupancy and not c: remove (x -> O on s) / add (x -> N on s);
///  - (T) x-ray, only when s's occupancy changes: each slider seeing s (union
///    nearest, not c) is paired with the nearest blocker beyond s on the
///    opposite ray, of B0 when a piece arrives on s (remove) and of B1 when s
///    is vacated (add); a pair is emitted when that victim is kept.
/// That is S2's rule: an unchanged attacker is collected exactly at the first
/// changed square of each ray that holds one, so every changed feature is
/// emitted once with its direction (the walk-equality test checks this against
/// emitMoveDelta move by move).
pub fn emitMoveDeltaRay2(pos: *const position.Position, changes: []const SquareChange, sink: anytype) void {
    std.debug.assert(changes.len == 2);
    const flips = kingFlips(pos);
    const cb = ClassBoard.of(pos);
    for (0..2) |i| emitRayFocus(pos, &cb, changes[i], changes[1 - i], flips.w, flips.b, sink);
}

inline fn emitRayFocus(pos: *const position.Position, cb: *const ClassBoard, f: SquareChange, o: SquareChange, wflip: u6, bflip: u6, sink: anytype) void {
    const rf = RayFocus.of(cb, f, o);
    const s = rf.s;
    const row = &SLOTS.sq[s];
    const mb = &pos.mailbox;
    const old_c_class = PIECE_CLASS[@intFromEnum(o.old)];
    // (R): the old occupant's features on the old board.
    if (@intFromEnum(f.old.pieceType()) < 5) {
        const kc = KEPT_CLASS[@intFromEnum(f.old)];
        const k1 = ~@as(u64, @bitCast((rf.view & @as(V64, @splat(kc))) == @as(V64, @splat(0))));
        const k0 = (k1 & ~rf.cbit) | (if (old_c_class & kc != 0) rf.cbit else 0);
        var tg = OUT_SLOTS[@intFromEnum(f.old)] & rf.near0 & k0;
        const g = GroupPair.of(f.old, s, wflip, bflip);
        while (tg != 0) : (tg &= tg - 1) {
            const slot: u8 = @ctz(tg);
            const t: u6 = @intCast(row[slot]);
            g.emit(false, t, if (slot == rf.sc) o.old else mb[t], wflip, bflip, sink);
        }
    }
    // (A): the new occupant's features on the new board.
    if (@intFromEnum(f.new.pieceType()) < 5) {
        const kc = KEPT_CLASS[@intFromEnum(f.new)];
        var tg = OUT_SLOTS[@intFromEnum(f.new)] & rf.near1 & slotsWith(rf.view, @splat(kc));
        const g = GroupPair.of(f.new, s, wflip, bflip);
        while (tg != 0) : (tg &= tg - 1) {
            const t: u6 = @intCast(row[@ctz(tg)]);
            g.emit(true, t, mb[t], wflip, bflip, sink);
        }
    }
    // (T): unchanged attackers, nearest on the union occupancy, not c.
    const seen = rf.nearu & ~rf.cbit;
    if (f.old != .none) {
        var att = slotsWith(rf.view, INCOMING[@intFromEnum(f.old.pieceType())]) & seen;
        while (att != 0) : (att &= att - 1) {
            const x: u6 = @intCast(row[@ctz(att)]);
            GroupPair.of(mb[x], x, wflip, bflip).emit(false, s, f.old, wflip, bflip, sink);
        }
    }
    if (f.new != .none) {
        var att = slotsWith(rf.view, INCOMING[@intFromEnum(f.new.pieceType())]) & seen;
        while (att != 0) : (att &= att - 1) {
            const x: u6 = @intCast(row[@ctz(att)]);
            GroupPair.of(mb[x], x, wflip, bflip).emit(true, s, f.new, wflip, bflip, sink);
        }
    }
    // (T) x-ray: a piece arriving on s blocks what sliders saw beyond it on the
    // old board; a vacated s opens the new board's blockers beyond it.
    if (f.old == .none) {
        emitRayXray(false, pos, &rf, rf.near0, o.old, seen, wflip, bflip, sink);
    } else if (f.new == .none) {
        emitRayXray(true, pos, &rf, rf.near1, o.old, seen, wflip, bflip, sink);
    }
}

/// The x-ray pairs of one focus: each slider seeing s (`seen` restricts to the
/// union-nearest, unchanged slots) and the nearest blocker `near` beyond s on
/// the opposite ray (rotating the mask by 32 bits maps each ray onto its
/// opposite); raySpan pairs them by direction byte. Removes read the old board
/// (`c_old` on the other changed square), adds the new one.
inline fn emitRayXray(comptime add: bool, pos: *const position.Position, rf: *const RayFocus, near: u64, c_old: piece.Piece, seen: u64, wflip: u6, bflip: u6, sink: anytype) void {
    const sl = slotsWith(rf.view, SLIDERS_AT) & seen;
    if (sl == 0) return;
    const row = &SLOTS.sq[rf.s];
    const mb = &pos.mailbox;
    const beyond = std.math.rotr(u64, near & ~KNIGHT_SLOTS, 32);
    const valid = raySpan(sl) & raySpan(beyond);
    var a = sl & valid;
    var v = beyond & valid;
    while (a != 0) : ({
        a &= a - 1;
        v &= v - 1;
    }) {
        const x: u6 = @intCast(row[@ctz(a)]);
        const vslot: u8 = (@as(u8, @ctz(v)) + 32) & 63;
        const vt: u6 = @intCast(row[vslot]);
        const vp = if (!add and vslot == rf.sc) c_old else mb[vt];
        const g = GroupPair.of(mb[x], x, wflip, bflip);
        if (g.isFeature(vp)) g.emit(add, vt, vp, wflip, bflip, sink);
    }
}

// ---------------------------------------------------------------------------
// Bit-exactness tests vs the source-of-truth grader (fullthreats_grader.py,
// spec r1). Vectors cover: symmetric startpos (persp-identical), kiwipete
// (dense, both kings e-file -> flip), mixed-flip endgame, a colour-symmetric
// middlegame, and a promotion tactics position. Set equality = exact popcount
// + every expected bit.
const fen = @import("../core/fen.zig");

fn popcount(bits: PerspBits) usize {
    var t: usize = 0;
    for (bits) |w| t += @popCount(w);
    return t;
}
fn getBit(bits: PerspBits, idx: usize) bool {
    return (bits[idx >> 6] >> @as(u6, @intCast(idx & 63))) & 1 == 1;
}

test "full-threats enumeration matches grader reference vectors (spec r2)" {
    const Case = struct { fen: []const u8, w: []const u16, b: []const u16 };
    const cases = [_]Case{
        .{
            .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            .w = &[_]u16{ 524, 714, 3976, 3984, 4144, 4152, 8345, 8400, 9177, 9184, 16394, 16422, 16432, 16442, 33721, 33911, 38124, 38132, 38292, 38300, 44740, 44749, 45524, 45581, 59419, 59429, 59439, 59491 },
            .b = &[_]u16{ 524, 714, 3976, 3984, 4144, 4152, 8345, 8400, 9177, 9184, 16394, 16422, 16432, 16442, 33721, 33911, 38124, 38132, 38292, 38300, 44740, 44749, 45524, 45581, 59419, 59429, 59439, 59491 },
        },
        .{
            .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            .w = &[_]u16{ 9, 67, 204, 297, 1506, 1514, 1524, 1544, 2368, 2409, 2429, 2439, 4582, 4609, 8400, 9184, 19462, 19472, 19484, 19497, 19533, 19582, 19628, 30156, 30307, 30444, 30513, 30519, 30537, 30556, 30574, 32886, 32906, 32931, 33216, 33231, 33254, 37378, 37533, 37543, 44708, 45524, 57399, 57440, 57449, 57489, 57499 },
            .b = &[_]u16{ 18, 24, 42, 61, 79, 123, 322, 339, 1274, 1299, 1319, 1577, 1584, 1599, 4371, 4393, 5454, 8432, 9184, 17912, 17922, 17963, 17972, 18042, 30282, 30363, 30498, 30562, 31916, 31926, 31936, 31985, 33121, 33141, 33163, 33171, 37626, 37749, 44740, 45524, 55265, 55339, 55344, 55390, 55419, 55429, 55441 },
        },
        .{
            .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            .w = &[_]u16{ 11204, 11224, 30519, 42824 },
            .b = &[_]u16{ 54, 11100, 42700, 42720 },
        },
        .{
            .fen = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
            .w = &[_]u16{ 13, 54, 67, 72, 126, 1264, 1306, 1319, 1508, 1524, 5912, 5956, 5964, 6213, 8619, 8624, 9147, 9192, 17865, 17912, 17932, 17963, 17982, 18002, 30453, 30508, 30549, 30562, 30567, 32883, 32886, 32921, 33141, 33165, 35617, 36608, 36624, 36652, 44964, 45023, 45516, 45551, 57419, 57440, 57459, 57489, 57509, 57542 },
            .b = &[_]u16{ 13, 54, 67, 72, 126, 1264, 1306, 1319, 1508, 1524, 5912, 5956, 5964, 6213, 8619, 8624, 9147, 9192, 17865, 17912, 17932, 17963, 17982, 18002, 30453, 30508, 30549, 30562, 30567, 32883, 32886, 32921, 33141, 33165, 35617, 36608, 36624, 36652, 44964, 45023, 45516, 45551, 57419, 57440, 57459, 57489, 57509, 57542 },
        },
        .{
            .fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
            .w = &[_]u16{ 906, 4152, 5897, 5904, 5964, 8400, 9177, 9184, 16394, 16423, 16442, 16542, 30561, 30909, 30920, 33891, 33906, 38288, 38300, 44740, 45524, 45581, 59421, 59424, 59491 },
            .b = &[_]u16{ 66, 719, 724, 3342, 3353, 4148, 4152, 8400, 9177, 9184, 16394, 16424, 16437, 33483, 36608, 36669, 36676, 38300, 44740, 45524, 45581, 59319, 59420, 59439, 59491 },
        },
    };
    for (cases) |c| {
        var pos = try fen.parse(c.fen);
        var wbits: PerspBits = undefined;
        var bbits: PerspBits = undefined;
        enumerateColors(&pos, &wbits, &bbits);
        try std.testing.expectEqual(c.w.len, popcount(wbits));
        try std.testing.expectEqual(c.b.len, popcount(bbits));
        for (c.w) |idx| try std.testing.expect(getBit(wbits, idx));
        for (c.b) |idx| try std.testing.expect(getBit(bbits, idx));
    }
}

const make_unmake = @import("../movegen/make_unmake.zig");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");

// ---------------------------------------------------------------------------
// Direct-delta differential check (lane 2 #4): at every move of legal-move
// trees and of long random legal sequences (captures, promotions, en passant,
// castling, king walks across d/e = flip crossings, null moves), the directed
// emissions of emitMoveDelta, applied to the PRE-move enumeration with strict
// direction checks (an ADD must find its bit clear, a REMOVE set — so no
// feature is emitted twice or with the wrong direction), must reproduce the
// POST-move enumeration exactly, per flip-unchanged perspective.
const CheckSink = struct {
    w: *PerspBits,
    b: *PerspBits,
    use_w: bool,
    use_b: bool,
    bad: u32 = 0,
    count: u32 = 0,

    pub fn emitPair(self: *CheckSink, comptime add: bool, iw: usize, ib: usize) void {
        self.emit(false, add, iw);
        self.emit(true, add, ib);
    }

    fn emit(self: *CheckSink, comptime black: bool, comptime add: bool, idx: usize) void {
        if (black and !self.use_b) return;
        if (!black and !self.use_w) return;
        self.count += 1;
        const bits = if (black) self.b else self.w;
        const m = @as(u64, 1) << @as(u6, @intCast(idx & 63));
        const was = bits[idx >> 6] & m != 0;
        if (was == add) self.bad += 1;
        bits[idx >> 6] ^= m;
    }
};

fn checkDirectMove(pos: *position.Position, mv: move_mod.Move) !void {
    var pre_w: PerspBits = undefined;
    var pre_b: PerspBits = undefined;
    enumerateColors(pos, &pre_w, &pre_b);
    const pre_flips = kingFlips(pos);
    var premail: [64]piece.Piece = undefined;
    for (0..64) |i| premail[i] = pos.mailbox[i];
    var st: make_unmake.StateInfo = .{};
    _ = make_unmake.makeMove(pos, mv, &st);
    defer make_unmake.unmakeMove(pos, mv, &st);
    var post_w: PerspBits = undefined;
    var post_b: PerspBits = undefined;
    enumerateColors(pos, &post_w, &post_b);
    const post_flips = kingFlips(pos);
    var changes: [4]SquareChange = undefined;
    var nc: usize = 0;
    for (0..64) |i| {
        if (pos.mailbox[i] != premail[i]) {
            changes[nc] = .{ .sq = @intCast(i), .old = premail[i], .new = pos.mailbox[i] };
            nc += 1;
        }
    }
    var sink = CheckSink{ .w = &pre_w, .b = &pre_b, .use_w = pre_flips.w == post_flips.w, .use_b = pre_flips.b == post_flips.b };
    emitMoveDelta(pos, changes[0..nc], &sink);
    try std.testing.expectEqual(@as(u32, 0), sink.bad);
    if (sink.use_w) try std.testing.expect(std.mem.eql(u64, &pre_w, &post_w));
    if (sink.use_b) try std.testing.expect(std.mem.eql(u64, &pre_b, &post_b));
}

fn directTreeWalk(pos: *position.Position, depth: u8) !void {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        try checkDirectMove(pos, mv);
        if (depth > 1) {
            var st: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(pos, mv, &st);
            try directTreeWalk(pos, depth - 1);
            make_unmake.unmakeMove(pos, mv, &st);
        }
    }
}

test "full-threats direct delta equals the enumeration XOR over game trees and random games" {
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "8/8/2pp4/8/3p4/4K3/4P3/k7 w - - 0 1",
        "4k3/8/8/2pP1p2/8/8/5P2/4K3 w - c6 0 2",
        "r1bq1rk1/pp2nppp/2n1p3/3pP3/2PP4/P1PB1N2/5PPP/R1BQK2R w KQ - 0 10",
        "1k6/1P6/8/8/8/8/6p1/K6R w - - 0 1",
    };
    for (fens, 0..) |f, fi| {
        var pos = try fen.parse(f);
        try directTreeWalk(&pos, if (fi < 2) 2 else 3);
    }
    // Random legal games (fixed seed): long sequences through middlegames into
    // endgames; every move checked, null moves interleaved (no change -> no
    // emission, the post board must equal the pre board's features).
    var rng: u64 = 0x9E37_79B9_7F4A_7C15;
    var games: usize = 0;
    while (games < 300) : (games += 1) {
        var pos = try fen.parse(fens[games % fens.len]);
        var ply: usize = 0;
        while (ply < 160) : (ply += 1) {
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            if (moves.slice().len == 0) break;
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const mv = moves.slice()[@intCast((rng >> 33) % moves.slice().len)];
            try checkDirectMove(&pos, mv);
            var st: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(&pos, mv, &st);
            if ((rng >> 20) % 16 == 0 and !legal.isInCheck(&pos, pos.side_to_move)) {
                var nst: make_unmake.StateInfo = .{};
                make_unmake.makeNullMove(&pos, &nst);
                var w: PerspBits = undefined;
                var b: PerspBits = undefined;
                enumerateColors(&pos, &w, &b);
                var sink = CheckSink{ .w = &w, .b = &b, .use_w = true, .use_b = true };
                emitMoveDelta(&pos, &[_]SquareChange{}, &sink);
                try std.testing.expectEqual(@as(u32, 0), sink.count);
            }
        }
    }
}

test "full-threats perspective list equals the enumerated bitset over random games" {
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "1k6/1P6/8/8/8/8/6p1/K6R w - - 0 1",
    };
    var rng: u64 = 0xD1B5_4A32_D192_ED03;
    var games: usize = 0;
    while (games < 100) : (games += 1) {
        var pos = try fen.parse(fens[games % fens.len]);
        var ply: usize = 0;
        while (ply < 160) : (ply += 1) {
            var w: PerspBits = undefined;
            var b: PerspBits = undefined;
            enumerateColors(&pos, &w, &b);
            inline for (.{ types.Color.white, types.Color.black }, 0..) |persp, pi| {
                var list: [MAX_ACTIVE]u16 = undefined;
                const n = enumeratePerspList(&pos, persp, &list);
                var got: PerspBits = [_]u64{0} ** WORDS;
                for (list[0..n]) |f| {
                    // Each feature once: the sparse flip-cache diff relies on it.
                    try std.testing.expect((got[f >> 6] >> @as(u6, @intCast(f & 63))) & 1 == 0);
                    setBit(&got, f);
                }
                try std.testing.expectEqualSlices(u64, if (pi == 0) &w else &b, &got);
            }
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            if (moves.slice().len == 0) break;
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const mv = moves.slice()[@intCast((rng >> 33) % moves.slice().len)];
            var st: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(&pos, mv, &st);
        }
    }
}

// ---------------------------------------------------------------------------
// Ray-slot walk gates (spec §2.6.1): for every move with two changed squares of
// legal-move trees and random games, (1) emitMoveDeltaRay2 applied with strict
// direction checks to the pre-move enumeration reproduces the post-move one,
// and (2) its (direction, white index, black index) multiset equals
// emitMoveDelta's.
const CollectSink = struct {
    n: usize = 0,
    e: [512]u64 = undefined,

    pub fn emitPair(self: *CollectSink, comptime add: bool, iw: usize, ib: usize) void {
        self.e[self.n] = (@as(u64, @intFromBool(add)) << 40) | (@as(u64, iw) << 20) | ib;
        self.n += 1;
    }

    fn sorted(self: *CollectSink) []u64 {
        std.mem.sort(u64, self.e[0..self.n], {}, std.sort.asc(u64));
        return self.e[0..self.n];
    }
};

fn checkRayMove(pos: *position.Position, mv: move_mod.Move) !void {
    var pre_w: PerspBits = undefined;
    var pre_b: PerspBits = undefined;
    enumerateColors(pos, &pre_w, &pre_b);
    const pre_flips = kingFlips(pos);
    var premail: [64]piece.Piece = undefined;
    for (0..64) |i| premail[i] = pos.mailbox[i];
    var st: make_unmake.StateInfo = .{};
    _ = make_unmake.makeMove(pos, mv, &st);
    defer make_unmake.unmakeMove(pos, mv, &st);
    var changes: [4]SquareChange = undefined;
    var nc: usize = 0;
    for (0..64) |i| {
        if (pos.mailbox[i] != premail[i]) {
            changes[nc] = .{ .sq = @intCast(i), .old = premail[i], .new = pos.mailbox[i] };
            nc += 1;
        }
    }
    if (nc != 2) return;
    var post_w: PerspBits = undefined;
    var post_b: PerspBits = undefined;
    enumerateColors(pos, &post_w, &post_b);
    const post_flips = kingFlips(pos);
    var sink = CheckSink{ .w = &pre_w, .b = &pre_b, .use_w = pre_flips.w == post_flips.w, .use_b = pre_flips.b == post_flips.b };
    emitMoveDeltaRay2(pos, changes[0..2], &sink);
    try std.testing.expectEqual(@as(u32, 0), sink.bad);
    if (sink.use_w) try std.testing.expect(std.mem.eql(u64, &pre_w, &post_w));
    if (sink.use_b) try std.testing.expect(std.mem.eql(u64, &pre_b, &post_b));
    var a: CollectSink = .{};
    var b: CollectSink = .{};
    emitMoveDelta(pos, changes[0..2], &a);
    emitMoveDeltaRay2(pos, changes[0..2], &b);
    // The changed squares in either order.
    var c: CollectSink = .{};
    const swapped = [2]SquareChange{ changes[1], changes[0] };
    emitMoveDeltaRay2(pos, &swapped, &c);
    try std.testing.expectEqualSlices(u64, a.sorted(), b.sorted());
    try std.testing.expectEqualSlices(u64, a.sorted(), c.sorted());
}

fn rayTreeWalk(pos: *position.Position, depth: u8) !void {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        try checkRayMove(pos, mv);
        if (depth > 1) {
            var st: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(pos, mv, &st);
            try rayTreeWalk(pos, depth - 1);
            make_unmake.unmakeMove(pos, mv, &st);
        }
    }
}

test "full-threats ray-slot walk equals the direct delta over game trees and random games" {
    if (comptime !has_avx2) return error.SkipZigTest;
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "8/8/2pp4/8/3p4/4K3/4P3/k7 w - - 0 1",
        "4k3/8/8/2pP1p2/8/8/5P2/4K3 w - c6 0 2",
        "r1bq1rk1/pp2nppp/2n1p3/3pP3/2PP4/P1PB1N2/5PPP/R1BQK2R w KQ - 0 10",
        "1k6/1P6/8/8/8/8/6p1/K6R w - - 0 1",
        "4r1k1/1q3pp1/p2b3p/1p1P4/2pQ4/P1B2N1P/1P3PP1/4R1K1 b - - 0 1",
        "2rq1rk1/pb1nbppp/1p2pn2/2pp4/2PP4/1P1BPN2/PB1N1PPP/R2Q1RK1 w - - 0 1",
    };
    for (fens, 0..) |f, fi| {
        var pos = try fen.parse(f);
        try rayTreeWalk(&pos, if (fi < 2) 2 else 3);
    }
    var rng: u64 = 0x2545_F491_4F6C_DD1D;
    var games: usize = 0;
    while (games < 400) : (games += 1) {
        var pos = try fen.parse(fens[games % fens.len]);
        var ply: usize = 0;
        while (ply < 160) : (ply += 1) {
            var moves = move_mod.MoveList.init();
            legal.generate(&pos, &moves);
            if (moves.slice().len == 0) break;
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const mv = moves.slice()[@intCast((rng >> 33) % moves.slice().len)];
            try checkRayMove(&pos, mv);
            var st: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(&pos, mv, &st);
        }
    }
}
