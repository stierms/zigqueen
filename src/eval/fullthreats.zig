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
// Incremental delta engine (docs/V6_INCREMENTAL_DESIGN.md r1, OWN design).
//
// Groups = attacker squares: group(sq, colored-type) is the contiguous index
// range of that piece's outgoing features for one perspective. After a move,
// recompute the CURRENT truth of every affected group and XOR it against the
// stored bitset — the XOR is the delta (never reconstruct old state). The
// caller guarantees both perspectives' mirror flips are UNCHANGED across the
// move (flip changes take the full-refresh path by design).
// ---------------------------------------------------------------------------

/// One changed square of a move (from/to/capture/castle-rook), old and new
/// occupants (piece.Piece.none for empty).
pub const SquareChange = struct { sq: u6, old: piece.Piece, new: piece.Piece };

/// Undo log of toggled feature bits. Bit 31 of an entry = black perspective.
pub const Delta = struct {
    pub const MAX_TOGGLES = 256;
    idx: [MAX_TOGGLES]u32 = undefined,
    n: u32 = 0,
    /// Affected groups recomputed (instrument; cost driver alongside n).
    groups: u32 = 0,
};

pub inline fn kingFlips(pos: *const position.Position) struct { w: u6, b: u6 } {
    return .{
        .w = if (pos.king_squares[0].?.file() > 3) 7 else 0,
        .b = if (pos.king_squares[1].?.file() > 3) 7 else 0,
    };
}

inline fn toggleLogged(bits: *PerspBits, idx: usize, persp_bit: u32, delta: *Delta) bool {
    if (delta.n >= Delta.MAX_TOGGLES) return false;
    bits[idx >> 6] ^= @as(u64, 1) << @as(u6, @intCast(idx & 63));
    delta.idx[delta.n] = @as(u32, @intCast(idx)) | persp_bit;
    delta.n += 1;
    return true;
}

/// Extract [base, base+len) from the bitset into range-local words.
/// Max group: queen 27 targets x 10 victim classes = 270 bits -> 5 words.
const MAX_GROUP_WORDS = 5;
fn extractRange(bits: *const PerspBits, base: usize, len: usize) [MAX_GROUP_WORDS]u64 {
    var out = [_]u64{0} ** MAX_GROUP_WORDS;
    var i: usize = 0;
    while (i < len) : (i += 64) {
        const g = base + i;
        const w = g >> 6;
        const off: u6 = @intCast(g & 63);
        var v = bits[w] >> off;
        if (off != 0 and w + 1 < WORDS)
            v |= bits[w + 1] << @intCast(64 - @as(u7, off));
        out[i >> 6] = v;
    }
    const tail: u6 = @intCast(len & 63);
    if (tail != 0) out[(len - 1) >> 6] &= (@as(u64, 1) << tail) - 1;
    return out;
}

/// Recompute one (square, colored-type) group for BOTH perspectives in one pass
/// and XOR each against its stored bits. The physical work (attack set, target
/// occupants, victim-class filter) is perspective-independent — computing it
/// once and mapping each kept target into both index spaces halves the group
/// recompute's attack lookups and target-loop overhead vs two per-perspective
/// passes. Toggle order stays "all white toggles, then all black toggles" per
/// group — the exact log order of the former sequential calls. Returns false
/// on undo-log overflow.
fn recomputeGroupBoth(
    pos: *const position.Position,
    sq_idx: u6,
    color: types.Color,
    atype: usize,
    wflip: u6,
    bflip: u6,
    wbits: *PerspBits,
    bbits: *PerspBits,
    delta: *Delta,
) bool {
    const f_ow: usize = @as(usize, sq_idx ^ wflip);
    const f_ob: usize = @as(usize, (sq_idx ^ 56) ^ bflip);
    const ak_w: usize = (if (color == .white) @as(usize, 0) else 5) + atype;
    const ak_b: usize = (if (color == .black) @as(usize, 0) else 5) + atype;
    const npairs_w: usize = @popCount(T.empty_att[ak_w][f_ow]);
    const npairs_b: usize = @popCount(T.empty_att[ak_b][f_ob]);
    // Pawn table edge rows (no real piece ever sits there): the oriented rows
    // mirror rank-wise, so the two perspectives zero out together.
    if (npairs_w == 0 and npairs_b == 0) return true;
    const nv = NV[atype];
    const base_w: usize = T.ak_offset[ak_w] + @as(usize, T.pair_base[ak_w][f_ow]) * 2 * nv;
    const base_b: usize = T.ak_offset[ak_b] + @as(usize, T.pair_base[ak_b][f_ob]) * 2 * nv;

    // Current truth of the group, both perspectives, from ONE attack-set walk.
    var truth_w = [_]u64{0} ** MAX_GROUP_WORDS;
    var truth_b = [_]u64{0} ** MAX_GROUP_WORDS;
    const occupant = pos.mailbox[sq_idx];
    if (occupant != .none and occupant.color().? == color and
        @intFromEnum(occupant.pieceType()) == atype)
    {
        const from = square.Square.fromIndex(sq_idx);
        const pt: piece.PieceType = @enumFromInt(atype);
        var tb = attackSet(pt, color, from, pos.occupied) & pos.occupied;
        while (bitboard.popLsb(&tb)) |to| {
            const to_idx: usize = to.index();
            const tp = pos.mailbox[to_idx];
            const vtype_full: usize = @intFromEnum(tp.pieceType());
            if (vtype_full == 5) continue;
            const vr = VRANK[atype][vtype_full];
            if (vr < 0) continue;
            const vrank: usize = @intCast(vr);
            const tcolor = tp.color().?;
            {
                const t_o = to_idx ^ wflip;
                const rel = fullIndex(ak_w, f_ow, t_o, tcolor == .white, vrank) - base_w;
                truth_w[rel >> 6] |= @as(u64, 1) << @as(u6, @intCast(rel & 63));
            }
            {
                const t_o = (to_idx ^ 56) ^ bflip;
                const rel = fullIndex(ak_b, f_ob, t_o, tcolor == .black, vrank) - base_b;
                truth_b[rel >> 6] |= @as(u64, 1) << @as(u6, @intCast(rel & 63));
            }
        }
    }

    if (npairs_w != 0) {
        const stored = extractRange(wbits, base_w, npairs_w * 2 * nv);
        for (0..MAX_GROUP_WORDS) |w| {
            var x = truth_w[w] ^ stored[w];
            while (x != 0) : (x &= x - 1) {
                const rel = (w << 6) + @ctz(x);
                if (!toggleLogged(wbits, base_w + rel, 0, delta)) return false;
            }
        }
    }
    if (npairs_b != 0) {
        const stored = extractRange(bbits, base_b, npairs_b * 2 * nv);
        for (0..MAX_GROUP_WORDS) |w| {
            var x = truth_b[w] ^ stored[w];
            while (x != 0) : (x &= x - 1) {
                const rel = (w << 6) + @ctz(x);
                if (!toggleLogged(bbits, base_b + rel, 0x8000_0000, delta)) return false;
            }
        }
    }
    return true;
}

/// Apply a move's threat-feature delta to both perspectives' bitsets.
/// `changes` = the move's changed squares (<=4, incl. EP capture square and
/// castle rook squares). Returns false on undo-log overflow — the caller must
/// then discard `delta` and fall back to full re-enumeration.
pub fn applyMoveDelta(
    pos: *const position.Position,
    changes: []const SquareChange,
    wbits: *PerspBits,
    bbits: *PerspBits,
    delta: *Delta,
) bool {
    const occ = pos.occupied;

    // Deduped affected-group collection: seen[color*5+pt] bitboards.
    var seen = [_]u64{0} ** 10;
    var entry_sq: [96]u6 = undefined;
    var entry_key: [96]u8 = undefined; // color*5 + pt
    var n_entries: usize = 0;

    const addEntry = struct {
        fn add(seen_: *[10]u64, sqs: *[96]u6, keys: *[96]u8, n: *usize, s: u6, key: u8) void {
            const m = @as(u64, 1) << s;
            if (seen_[key] & m != 0) return;
            seen_[key] |= m;
            if (n.* < 96) {
                sqs[n.*] = s;
                keys[n.*] = key;
                n.* += 1;
            }
        }
    }.add;

    // 1. Changed squares: old and new occupants' groups (kings have none).
    for (changes) |c| {
        inline for ([_]piece.Piece{ c.old, c.new }) |p| {
            if (p != .none) {
                const pt: usize = @intFromEnum(p.pieceType());
                if (pt < 5) {
                    const key: u8 = @intCast(@as(usize, @intFromEnum(p.color().?)) * 5 + pt);
                    addEntry(&seen, &entry_sq, &entry_key, &n_entries, c.sq, key);
                }
            }
        }
    }

    // 2. Attackers of every changed square under NEW occupancy. This single
    //    reverse-lookup rule covers BOTH cost centres (perf-r4, proof below):
    //      (a) victim changed: an attacker of a changed square must re-emit its
    //          feature to that square (pawn/knight attack sets are occupancy-
    //          independent; sliders are read back off the from-square rays);
    //      (b) attack set changed: a slider whose ray geometry moved is ALWAYS
    //          a new-occupancy attacker of some changed square, so the former
    //          "walk every slider, compare bishop/rook/queenAttacks(occ) vs
    //          (old_occ)" rule (2 magic lookups per slider on the board, every
    //          materialized move) is redundant and has been removed.
    //
    //    Proof of (b). Take a slider S whose attack set differs between old_occ
    //    and occ along some direction d, and let s_1, s_2, ... be d's ray from
    //    S. Some square on the ray changed (otherwise the first blocker, and
    //    hence the whole ray's attack set, is identical); let s_k be the FIRST
    //    changed one. Every s_j with j < k is unchanged. If any such s_j were
    //    occupied it would be occupied under BOTH occupancies and stop the ray
    //    before s_k in both, making d's attack set identical — contradiction.
    //    So s_1..s_{k-1} are empty under `occ`, i.e. S attacks s_k under `occ`
    //    (a magic attack set contains every empty square up to and including
    //    the first blocker). s_k is a changed square, so rule 2 adds S. ∎
    //    The same argument covers the old-occupancy victims rule 3 used to
    //    delegate to rule 2: if S attacked changed square c under old_occ but
    //    not under occ, a square between S and c became occupied; that square
    //    is changed and lies before c, so the first changed square s_k on the
    //    ray satisfies k <= index(c), and every s_j (j < k) was empty under
    //    old_occ (S reached c) and is unchanged, hence empty under occ too —
    //    so S attacks s_k under `occ` and is added. ∎
    //
    //    Removing rule 2 leaves the recomputed-group SET identical (only the
    //    collection ORDER changes), and group recomputes are order-independent
    //    (XOR against stored truth), so the maintained bitsets — and every
    //    accumulator/PSQT sum derived from them — are bit-identical.
    for (changes) |c| {
        const t = square.Square.fromIndex(c.sq);
        // Colour-independent: hoisted out of the two-colour body (one magic
        // lookup pair per changed square, not one per changed square per colour).
        const diag = attacks.bishopAttacksDirect(t, occ);
        const ortho = attacks.rookAttacksDirect(t, occ);
        const knight_att = attacks.knightAttacksDirect(t);
        inline for ([_]types.Color{ .white, .black }) |ac| {
            const ac_idx = @intFromEnum(ac);
            const enemy: types.Color = if (ac == .white) .black else .white;
            var pawns = attacks.pawnAttacksFrom(enemy, t) & pos.pieces[ac_idx][0];
            while (bitboard.popLsb(&pawns)) |s|
                addEntry(&seen, &entry_sq, &entry_key, &n_entries, s.index(), @intCast(@as(usize, ac_idx) * 5 + 0));
            var knights = knight_att & pos.pieces[ac_idx][1];
            while (bitboard.popLsb(&knights)) |s|
                addEntry(&seen, &entry_sq, &entry_key, &n_entries, s.index(), @intCast(@as(usize, ac_idx) * 5 + 1));
            var bishops = diag & pos.pieces[ac_idx][2];
            while (bitboard.popLsb(&bishops)) |s|
                addEntry(&seen, &entry_sq, &entry_key, &n_entries, s.index(), @intCast(@as(usize, ac_idx) * 5 + 2));
            var rooks = ortho & pos.pieces[ac_idx][3];
            while (bitboard.popLsb(&rooks)) |s|
                addEntry(&seen, &entry_sq, &entry_key, &n_entries, s.index(), @intCast(@as(usize, ac_idx) * 5 + 3));
            var queens = (diag | ortho) & pos.pieces[ac_idx][4];
            while (bitboard.popLsb(&queens)) |s|
                addEntry(&seen, &entry_sq, &entry_key, &n_entries, s.index(), @intCast(@as(usize, ac_idx) * 5 + 4));
        }
    }

    // Recompute every affected group, both perspectives in one fused pass each.
    delta.groups = @intCast(n_entries);
    const flips = kingFlips(pos);
    for (0..n_entries) |i| {
        const key = entry_key[i];
        const color: types.Color = if (key < 5) .white else .black;
        const atype: usize = key % 5;
        if (!recomputeGroupBoth(pos, entry_sq[i], color, atype, flips.w, flips.b, wbits, bbits, delta)) return false;
    }
    return true;
}

/// Reverse a delta (XOR toggles are self-inverse; reversed for hygiene).
pub fn undoDelta(wbits: *PerspBits, bbits: *PerspBits, delta: *const Delta) void {
    var i = delta.n;
    while (i > 0) {
        i -= 1;
        const e = delta.idx[i];
        const idx: usize = e & 0x7FFF_FFFF;
        const bits = if (e & 0x8000_0000 != 0) bbits else wbits;
        bits[idx >> 6] ^= @as(u64, 1) << @as(u6, @intCast(idx & 63));
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

// ---------------------------------------------------------------------------
// Delta-engine tree test: walk legal move trees maintaining the bitsets via
// applyMoveDelta (flip changes -> full-refresh path, as in the real design),
// asserting delta-maintained == full enumeration at EVERY node, and that the
// undo log restores the parent exactly. Covers castling, EP, promotions,
// captures, discovered rays and king moves.
const make_unmake = @import("../movegen/make_unmake.zig");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");

fn deltaWalk(pos: *position.Position, wbits: *PerspBits, bbits: *PerspBits, depth: u8) !void {
    var rw: PerspBits = undefined;
    var rb: PerspBits = undefined;
    enumerateColors(pos, &rw, &rb);
    try std.testing.expect(std.mem.eql(u64, wbits, &rw));
    try std.testing.expect(std.mem.eql(u64, bbits, &rb));
    if (depth == 0) return;

    const pre_flips = kingFlips(pos);
    var premail: [64]piece.Piece = undefined;
    for (0..64) |i| premail[i] = pos.mailbox[i];

    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        var st: make_unmake.StateInfo = .{};
        _ = make_unmake.makeMove(pos, mv, &st);
        const post_flips = kingFlips(pos);
        if (post_flips.w != pre_flips.w or post_flips.b != pre_flips.b) {
            // Mirror-flip crossing: full-refresh path with snapshot restore.
            const save_w = wbits.*;
            const save_b = bbits.*;
            enumerateColors(pos, wbits, bbits);
            try deltaWalk(pos, wbits, bbits, depth - 1);
            wbits.* = save_w;
            bbits.* = save_b;
        } else {
            var changes: [4]SquareChange = undefined;
            var nc: usize = 0;
            for (0..64) |i| {
                if (pos.mailbox[i] != premail[i]) {
                    changes[nc] = .{ .sq = @intCast(i), .old = premail[i], .new = pos.mailbox[i] };
                    nc += 1;
                }
            }
            var d = Delta{};
            try std.testing.expect(applyMoveDelta(pos, changes[0..nc], wbits, bbits, &d));
            try deltaWalk(pos, wbits, bbits, depth - 1);
            undoDelta(wbits, bbits, &d);
        }
        make_unmake.unmakeMove(pos, mv, &st);
    }
}

test "full-threats delta maintains both perspectives over game trees" {
    const cases = [_]struct { fen: []const u8, depth: u8 }{
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 3 },
        // kiwipete: castling both sides, dense tactics, EP after double pushes
        .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 2 },
        // promotions (d7 pawn) + underpromotion captures
        .{ .fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", .depth = 2 },
        // EP-rich endgame with rook rays + king activity (mixed flips)
        .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 3 },
    };
    for (cases) |c| {
        var pos = try fen.parse(c.fen);
        var wbits: PerspBits = undefined;
        var bbits: PerspBits = undefined;
        enumerateColors(&pos, &wbits, &bbits);
        try deltaWalk(&pos, &wbits, &bbits, c.depth);
    }
}
