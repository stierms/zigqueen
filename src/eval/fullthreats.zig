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
/// oriented square `f_o`), hoisted out of the per-target loops: fullIndex is
/// `base + rel(...)` with the same table reads done once per group.
const GroupIdx = struct {
    att: u64,
    base: usize,
    nv: usize,

    inline fn of(ak: usize, f_o: usize) GroupIdx {
        const nv = NV[ak % 5];
        return .{
            .att = T.empty_att[ak][f_o],
            .base = T.ak_offset[ak] + @as(usize, T.pair_base[ak][f_o]) * 2 * nv,
            .nv = nv,
        };
    }

    /// fullIndex(ak, f_o, t_o, victim_own, vrank) - base.
    inline fn rel(g: GroupIdx, t_o: usize, victim_own: bool, vrank: usize) usize {
        std.debug.assert((g.att >> @as(u6, @intCast(t_o))) & 1 == 1);
        const pairpos: usize = @popCount(g.att & ((@as(u64, 1) << @as(u6, @intCast(t_o))) - 1));
        return pairpos * (2 * g.nv) + (if (victim_own) 0 else g.nv) + vrank;
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
            while (bitboard.popLsb(&bb)) |from| {
                const from_idx: usize = from.index();
                var tb = attackSet(pt, ac, from, occ) & occ;
                while (bitboard.popLsb(&tb)) |to| {
                    const to_idx: usize = to.index();
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
//   (T) attackers on unchanged squares take the targeted update (the same
//       target rule and proof as updateAttackerGroupBoth), old_on -> REMOVE,
//       new_on -> ADD.
// A feature belongs to exactly one group (its attacker's square and coloured
// type); (R)/(A) groups sit on changed squares, (T) groups on unchanged ones,
// and an old and a new occupant of one square never share a key. An (R) group
// has no feature after the move (its piece left the square) and an (A) group
// had none before it, so (R) emits exactly that group's old-truth \ new-truth
// and (A) its new-truth \ old-truth; (T) emits exactly the XOR of its group.
// Row adds/subs wrap and PSQT sums are integers, so emission order is free.
// `sink.emit(comptime black: bool, comptime add: bool, idx: usize)` receives
// every (perspective, direction, feature index).
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

/// Emit every feature of the group (sq, color, atype) on one board as `add`.
/// `occ_use`/`kept` describe that board; `old_board` selects old victims.
inline fn emitWholeGroup(
    comptime add: bool,
    comptime old_board: bool,
    pos: *const position.Position,
    changes: []const SquareChange,
    changed_mask: u64,
    sq_idx: u6,
    color: types.Color,
    atype: usize,
    occ_use: u64,
    kept: u64,
    wflip: u6,
    bflip: u6,
    sink: anytype,
) void {
    const f_ow: usize = @as(usize, sq_idx ^ wflip);
    const f_ob: usize = @as(usize, (sq_idx ^ 56) ^ bflip);
    const gw = GroupIdx.of((if (color == .white) @as(usize, 0) else 5) + atype, f_ow);
    const gb = GroupIdx.of((if (color == .black) @as(usize, 0) else 5) + atype, f_ob);
    const pt: piece.PieceType = @enumFromInt(atype);
    var tb = attackSet(pt, color, square.Square.fromIndex(sq_idx), occ_use) & kept;
    while (bitboard.popLsb(&tb)) |to| {
        const t: usize = to.index();
        const p = if (old_board) oldOccupant(pos, changes, changed_mask, t) else pos.mailbox[t];
        const vrank: usize = @intCast(VRANK[atype][@intFromEnum(p.pieceType())]);
        const t_black = p.color().? == .black;
        sink.emit(false, add, gw.base + gw.rel(t ^ wflip, !t_black, vrank));
        sink.emit(true, add, gb.base + gb.rel((t ^ 56) ^ bflip, t_black, vrank));
    }
}

/// One (attacker group, target, victim) feature in both perspectives as `add`,
/// if the victim is a kept class for `atype`.
inline fn emitTargetBoth(comptime add: bool, atype: usize, gw: GroupIdx, gb: GroupIdx, wflip: u6, bflip: u6, t: usize, p: piece.Piece, sink: anytype) void {
    const vtype_full: usize = @intFromEnum(p.pieceType());
    if (vtype_full == 5) return; // king victims excluded
    const vr = VRANK[atype][vtype_full];
    if (vr < 0) return; // subset-redundant combo
    const vrank: usize = @intCast(vr);
    const t_black = p.color().? == .black;
    sink.emit(false, add, gw.base + gw.rel(t ^ wflip, !t_black, vrank));
    sink.emit(true, add, gb.base + gb.rel((t ^ 56) ^ bflip, t_black, vrank));
}

/// (T): updateAttackerGroupBoth's target rule with directed emission.
inline fn emitAttackerGroup(
    pos: *const position.Position,
    changes: []const SquareChange,
    changed_mask: u64,
    occ_old: u64,
    sq_idx: u6,
    color: types.Color,
    atype: usize,
    wflip: u6,
    bflip: u6,
    sink: anytype,
) void {
    const pt: piece.PieceType = @enumFromInt(atype);
    const from = square.Square.fromIndex(sq_idx);
    const a_new = attackSet(pt, color, from, pos.occupied);
    // Pawn and knight attack sets do not depend on occupancy.
    const a_old = if (atype <= 1) a_new else attackSet(pt, color, from, occ_old);
    var targets = ((a_old ^ a_new) | changed_mask) & (a_old | a_new);
    if (targets == 0) return;
    const gw = GroupIdx.of((if (color == .white) @as(usize, 0) else 5) + atype, @as(usize, sq_idx ^ wflip));
    const gb = GroupIdx.of((if (color == .black) @as(usize, 0) else 5) + atype, @as(usize, (sq_idx ^ 56) ^ bflip));
    while (bitboard.popLsb(&targets)) |to| {
        const t: usize = to.index();
        const bit = @as(u64, 1) << @intCast(t);
        const new_piece = pos.mailbox[t];
        const old_piece = if (changed_mask & bit != 0) oldOccupant(pos, changes, changed_mask, t) else new_piece;
        const old_on = (a_old & bit) != 0 and old_piece != .none;
        const new_on = (a_new & bit) != 0 and new_piece != .none;
        if (old_on and new_on and old_piece == new_piece) continue;
        if (old_on) emitTargetBoth(false, atype, gw, gb, wflip, bflip, t, old_piece, sink);
        if (new_on) emitTargetBoth(true, atype, gw, gb, wflip, bflip, t, new_piece, sink);
    }
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
            if (at < 5) emitWholeGroup(false, true, pos, changes, changed_mask, c.sq, c.old.color().?, at, occ_old, kept_old[at], flips.w, flips.b, sink);
        }
        if (c.new != .none) {
            const at: usize = @intFromEnum(c.new.pieceType());
            if (at < 5) emitWholeGroup(true, false, pos, changes, changed_mask, c.sq, c.new.color().?, at, occ, kept_new[at], flips.w, flips.b, sink);
        }
    }

    // (T): attackers of every changed square under NEW occupancy on UNCHANGED
    // squares (a candidate on a changed square is its new occupant, done above),
    // collected per coloured type as bitboards (the union dedupes). This single
    // reverse-lookup rule covers both reasons an unchanged attacker's features
    // can change: (a) a victim changed (pawn/knight attack sets are occupancy-
    // independent; sliders are read back off the changed square's rays), and
    // (b) a slider's attack set changed, which always makes it a new-occupancy
    // attacker of some changed square:
    //    Proof of (b). Take a slider S whose attack set differs between old_occ
    //    and occ along some direction d, and let s_1, s_2, ... be d's ray from
    //    S. Some square on the ray changed (otherwise the first blocker, and
    //    hence the whole ray's attack set, is identical); let s_k be the FIRST
    //    changed one. Every s_j with j < k is unchanged. If any such s_j were
    //    occupied it would be occupied under BOTH occupancies and stop the ray
    //    before s_k in both, making d's attack set identical — contradiction.
    //    So s_1..s_{k-1} are empty under `occ`, i.e. S attacks s_k under `occ`
    //    (a magic attack set contains every empty square up to and including
    //    the first blocker). s_k is a changed square, so (T) collects S. ∎
    //    The same argument covers old-occupancy victims: if S attacked changed square c under old_occ but
    //    not under occ, a square between S and c became occupied; that square
    //    is changed and lies before c, so the first changed square s_k on the
    //    ray satisfies k <= index(c), and every s_j (j < k) was empty under
    //    old_occ (S reached c) and is unchanged, hence empty under occ too —
    //    so S attacks s_k under `occ` and is collected. ∎
    var cand = [_]u64{0} ** 10;
    for (changes) |c| {
        const t = square.Square.fromIndex(c.sq);
        const diag = attacks.bishopAttacksDirect(t, occ);
        const ortho = attacks.rookAttacksDirect(t, occ);
        const knight_att = attacks.knightAttacksDirect(t);
        inline for ([_]types.Color{ .white, .black }) |ac| {
            const ci: usize = @intFromEnum(ac);
            const enemy: types.Color = if (ac == .white) .black else .white;
            cand[ci * 5 + 0] |= attacks.pawnAttacksFrom(enemy, t) & pos.pieces[ci][0];
            cand[ci * 5 + 1] |= knight_att & pos.pieces[ci][1];
            cand[ci * 5 + 2] |= diag & pos.pieces[ci][2];
            cand[ci * 5 + 3] |= ortho & pos.pieces[ci][3];
            cand[ci * 5 + 4] |= (diag | ortho) & pos.pieces[ci][4];
        }
    }
    inline for (0..10) |key| {
        const color: types.Color = if (key < 5) .white else .black;
        var bb = cand[key] & ~changed_mask;
        while (bitboard.popLsb(&bb)) |s|
            emitAttackerGroup(pos, changes, changed_mask, occ_old, s.index(), color, key % 5, flips.w, flips.b, sink);
    }
}

inline fn keptVictimMasksFrom(u: [5]u64) [5]u64 {
    const pnbr = u[0] | u[1] | u[2] | u[3];
    return .{ u[0] | u[1] | u[3], pnbr | u[4], pnbr, pnbr, pnbr | u[4] };
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

    pub fn emit(self: *CheckSink, comptime black: bool, comptime add: bool, idx: usize) void {
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
