//! Lean SFNNv10-style THREAT feature enumeration (engine side, full-refresh path).
//!
//! Mirrors bullet `LeanThreatInputs` (crates/bullet_lib/src/game/inputs/halfka_threats.rs)
//! and the net-sanity grader (tools/net_sanity_leanthreats.py) BIT-FOR-BIT. A threat feature
//! encodes an attack relation (attacker piece) -> (occupied target piece): for every non-king
//! piece, every OCCUPIED square in its occupancy-aware attack set (own target = defend, enemy =
//! attack; both count). Kings are threat TARGETS but never SOURCES (SF numValidTargets[king]=0).
//!
//! Lean index (attacker from-square DROPPED, deduped):
//!   idx = (attacker_key*64 + target_oriented) * 12 + attacked_rel,   idx in [0, 7680)
//!     attacker_key in [0,10): (own?0:5) + {P,N,B,R,Q}   (own = attacker colour == perspective)
//!     attacked_rel in [0,12): (own?0:6) + {P,N,B,R,Q,K}  (own = target colour == perspective)
//!     target_oriented = (persp==white ? to : to^56) ^ flip,  flip = file(persp king) > 3 ? 7 : 0
//!   Per perspective; stm = side to move, ntm = other side (bullet dual-perspective). `s` (stm idx)
//!   determines `n` (ntm idx), so deduping each perspective's BITSET == bullet's dedup-on-(s,n).
//!   The whole-board attack geometry is frame-invariant; only the index is oriented per perspective
//!   (verified vs the grader's stm-relative frame for both stm colours + the horizontal mirror).
const std = @import("std");
const position = @import("../core/position.zig");
const types = @import("../core/types.zig");
const piece = @import("../core/piece.zig");
const square = @import("../core/square.zig");
const bitboard = @import("../core/bitboard.zig");
const attacks = @import("../movegen/attacks.zig");

pub const NUM_ATTACKER_KEYS: usize = 10; // {own,opp} x {P,N,B,R,Q}
pub const NUM_ATTACKED_REL: usize = 12; // {own,opp} x {P,N,B,R,Q,K}
pub const NUM_THREAT_FEATURES: usize = NUM_ATTACKER_KEYS * 64 * NUM_ATTACKED_REL; // 7680

pub inline fn leanIndex(attacker_key: usize, to_o: usize, attacked_rel: usize) usize {
    return (attacker_key * 64 + to_o) * NUM_ATTACKED_REL + attacked_rel;
}

pub const WORDS: usize = (NUM_THREAT_FEATURES + 63) / 64; // 120

/// One perspective's deduped active threat features as a 7680-bit set.
pub const PerspBits = [WORDS]u64;

/// Active threat features for both perspectives (stm = side to move, ntm = other).
pub const ThreatFeatures = struct {
    stm: PerspBits = [_]u64{0} ** WORDS,
    ntm: PerspBits = [_]u64{0} ** WORDS,
};

inline fn setBit(bits: *PerspBits, idx: usize) void {
    bits[idx >> 6] |= @as(u64, 1) << @as(u6, @intCast(idx & 63));
}

/// Occupancy-aware attack set of a non-king piece (physical, absolute frame).
inline fn attackSet(pt: piece.PieceType, color: types.Color, from: square.Square, occ: bitboard.Bitboard) bitboard.Bitboard {
    return switch (pt) {
        .pawn => attacks.pawnAttacksFrom(color, from),
        .knight => attacks.knightAttacks(from),
        .bishop => attacks.bishopAttacks(from, occ),
        .rook => attacks.rookAttacks(from, occ),
        .queen => attacks.queenAttacks(from, occ),
        else => unreachable, // king is not a threat source
    };
}

/// Full-refresh enumeration of the deduped threat features per COLOUR (white-/black-
/// perspective), written directly into the two bitsets (cleared first). Side-to-move
/// independent — the hot incremental path uses this to fill per-ply bitsets with no temp.
pub fn enumerateColors(pos: *const position.Position, out_white: *PerspBits, out_black: *PerspBits) void {
    out_white.* = [_]u64{0} ** WORDS;
    out_black.* = [_]u64{0} ** WORDS;
    const occ = pos.occupied;
    const wflip: u6 = if (pos.king_squares[0].?.file() > 3) 7 else 0;
    const bflip: u6 = if (pos.king_squares[1].?.file() > 3) 7 else 0;

    inline for ([_]types.Color{ .white, .black }) |ac| {
        const ac_idx = @intFromEnum(ac);
        inline for ([_]piece.PieceType{ .pawn, .knight, .bishop, .rook, .queen }) |pt| {
            const pt_lean: usize = @intFromEnum(pt); // 0..4
            var bb = pos.pieces[ac_idx][pt_lean];
            while (bitboard.popLsb(&bb)) |from| {
                var tb = attackSet(pt, ac, from, occ) & occ;
                while (bitboard.popLsb(&tb)) |to| {
                    const to_idx: u6 = to.index();
                    const tp = pos.mailbox[to_idx];
                    const tcolor = tp.color().?;
                    const tpt: usize = @intFromEnum(tp.pieceType()); // 0..5

                    // white perspective (own = white; relsq = sq)
                    const w_att: usize = if (ac == .white) 0 else 5;
                    const w_tgt: usize = if (tcolor == .white) 0 else 6;
                    setBit(out_white, leanIndex(w_att + pt_lean, @as(usize, to_idx ^ wflip), w_tgt + tpt));

                    // black perspective (own = black; relsq = sq ^ 56)
                    const b_att: usize = if (ac == .black) 0 else 5;
                    const b_tgt: usize = if (tcolor == .black) 0 else 6;
                    setBit(out_black, leanIndex(b_att + pt_lean, @as(usize, (to_idx ^ 56) ^ bflip), b_tgt + tpt));
                }
            }
        }
    }
}

/// stm/ntm view (side-to-move relative) for the refresh reference + the bit-exact test.
pub fn enumerate(pos: *const position.Position, out: *ThreatFeatures) void {
    if (pos.side_to_move == .white) {
        enumerateColors(pos, &out.stm, &out.ntm);
    } else {
        enumerateColors(pos, &out.ntm, &out.stm);
    }
}

// ---------------------------------------------------------------------------
// Bit-exactness test vs the grader reference (tools/net_sanity_leanthreats.py,
// lean_threat_features). Vectors generated from the grader; covers flip=0,
// stm=black orientation, the horizontal mirror, rook ray-blocking, and a dense
// startpos. Set equality = exact popcount (no extras) + every expected bit set.
const fen = @import("../core/fen.zig");

fn popcount(bits: PerspBits) usize {
    var t: usize = 0;
    for (bits) |w| t += @popCount(w);
    return t;
}
fn getBit(bits: PerspBits, idx: usize) bool {
    return (bits[idx >> 6] >> @as(u6, @intCast(idx & 63))) & 1 == 1;
}

test "lean threat enumeration matches grader reference vectors" {
    const Case = struct { fen: []const u8, s: []const u16, n: []const u16 };
    const cases = [_]Case{
        // white pawn e4 attacks black knight d5; kings d-file (flip 0)
        .{ .fen = "3k4/8/8/3n4/4P3/8/8/3K4 w - - 0 1", .s = &[_]u16{427}, .n = &[_]u16{4165} },
        // same, black to move -> stm/ntm swap (tests stm=black orientation)
        .{ .fen = "3k4/8/8/3n4/4P3/8/8/3K4 b - - 0 1", .s = &[_]u16{4165}, .n = &[_]u16{427} },
        // same edge, kings g-file (file 6 > 3 -> horizontal flip 7)
        .{ .fen = "6k1/8/8/3n4/4P3/8/8/6K1 w - - 0 1", .s = &[_]u16{439}, .n = &[_]u16{4177} },
        // ray-block: black rook d5 / white pawn d4 / white rook d3 (pawn blocks both rooks)
        .{ .fen = "3k4/8/8/3r4/3P4/3R4/8/3K4 w - - 0 1", .s = &[_]u16{ 2345, 2628, 6468, 6863 }, .n = &[_]u16{ 6863, 6570, 2730, 2345 } },
        // dense startpos (30 defend edges); kings e-file -> flip 7
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .s = &[_]u16{ 900, 912, 1644, 1668, 1680, 1704, 2317, 2377, 2400, 2484, 3113, 3134, 3204, 3216, 3228, 5226, 5238, 5970, 5994, 6006, 6030, 6726, 6810, 6835, 6895, 7530, 7542, 7554, 7631, 7652 }, .n = &[_]u16{ 5226, 5238, 5970, 5994, 6006, 6030, 6835, 6895, 6726, 6810, 7631, 7652, 7530, 7542, 7554, 900, 912, 1644, 1668, 1680, 1704, 2400, 2484, 2317, 2377, 3204, 3216, 3228, 3113, 3134 } },
    };
    for (cases) |c| {
        var pos = try fen.parse(c.fen);
        var tf = ThreatFeatures{};
        enumerate(&pos, &tf);
        try std.testing.expectEqual(c.s.len, popcount(tf.stm));
        try std.testing.expectEqual(c.n.len, popcount(tf.ntm));
        for (c.s) |idx| try std.testing.expect(getBit(tf.stm, idx));
        for (c.n) |idx| try std.testing.expect(getBit(tf.ntm, idx));
    }
}
