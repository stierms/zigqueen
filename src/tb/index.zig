//! Position index of a Syzygy table (docs/SYZYGY_FORMAT.md §5). Every table
//! here is generated at comptime from the generating rules of §5.5-§5.6, so it
//! lives in .rodata and needs no runtime initialisation.
const std = @import("std");
const ProbeError = @import("types.zig").ProbeError;

/// Array capacity; v1 loads at most 6 pieces, but nothing here precludes 7.
pub const max_pieces = 7;

pub const LeadKind = enum(u8) { kk, three, pawn };

/// One (subtable, side) encoding, from the header descriptor (§4.2) plus the
/// digit order of §5.8.
pub const Descriptor = struct {
    n: u8 = 0,
    /// Piece codes in list order (§2: white 1-6, black 9-14), in the file frame.
    codes: [max_pieces]u8 = .{0} ** max_pieces,
    lead: LeadKind = .kk,
    /// Size of the leading group G0: 2 (KK), 3 (3-unique) or k leading pawns.
    lead_len: u8 = 0,
    /// Size of the second pawn group G1; 0 when only one colour has pawns.
    second_len: u8 = 0,
    /// Groups in descriptor order: G0, G1 (if any), then runs of equal codes.
    group_count: u8 = 0,
    group_start: [max_pieces]u8 = .{0} ** max_pieces,
    group_len: [max_pieces]u8 = .{0} ** max_pieces,
    factor: [max_pieces]u64 = .{0} ** max_pieces,
    /// Number of positions of the subtable (§5.8).
    size: u64 = 0,
};

pub const Squares = [max_pieces]u8;

// ---------------------------------------------------------------------------
// Comptime tables

/// binomial[k][n] = C(n, k) for k <= 7, n <= 64 (0 when k > n).
pub const binomial: [8][65]u64 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [8][65]u64 = undefined;
    for (0..8) |k| {
        for (0..65) |n| {
            table[k][n] = if (k == 0) 1 else if (n == 0) 0 else table[k - 1][n - 1] + table[k][n - 1];
        }
    }
    break :blk table;
};

inline fn fileOf(sq: u8) u8 {
    return sq & 7;
}
inline fn rankOf(sq: u8) u8 {
    return sq >> 3;
}
inline fn transpose(sq: u8) u8 {
    return (sq >> 3) | ((sq & 7) << 3);
}
fn adjacentOrSame(a: u8, b: u8) bool {
    const df = @as(i16, fileOf(a)) - fileOf(b);
    const dr = @as(i16, rankOf(a)) - rankOf(b);
    return @abs(df) <= 1 and @abs(dr) <= 1;
}

const none8: u8 = 0xFF;

/// T6 number (§5.5): b1, c1, d1, c2, d2, d3 -> 0..5; 0xFF elsewhere.
pub const tri6: [64]u8 = blk: {
    var table = [_]u8{none8} ** 64;
    var n: u8 = 0;
    for (0..64) |sq| {
        if (sq & 7 <= 3 and sq & 7 > sq >> 3) {
            table[sq] = n;
            n += 1;
        }
    }
    std.debug.assert(n == 6);
    break :blk table;
};

/// Below28 number (§5.5): squares with file > rank, ascending, b1 = 0 .. h7 = 27.
pub const below28: [64]u8 = blk: {
    var table = [_]u8{none8} ** 64;
    var n: u8 = 0;
    for (0..64) |sq| {
        if (sq & 7 > sq >> 3) {
            table[sq] = n;
            n += 1;
        }
    }
    std.debug.assert(n == 28);
    break :blk table;
};

/// KK enumeration (§5.5), 462 king pairs; 0xFFFF for pairs outside it.
pub const kk_index: [64][64]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var table = [_][64]u16{[_]u16{0xFFFF} ** 64} ** 64;
    var n: u16 = 0;
    const t6 = [_]u8{ 1, 2, 3, 10, 11, 19 };
    const d4 = [_]u8{ 0, 9, 18, 27 };
    for (t6) |k1| {
        for (0..64) |k2| {
            if (!adjacentOrSame(k1, k2)) {
                table[k1][k2] = n;
                n += 1;
            }
        }
    }
    for (d4) |k1| {
        for (0..64) |k2| {
            if (k2 & 7 > k2 >> 3 and !adjacentOrSame(k1, k2)) {
                table[k1][k2] = n;
                n += 1;
            }
        }
    }
    for (d4) |k1| {
        for (0..8) |r| {
            const k2 = 9 * r;
            if (!adjacentOrSame(k1, k2)) {
                table[k1][k2] = n;
                n += 1;
            }
        }
    }
    if (n != 462) @compileError("KK enumeration must have 462 entries");
    break :blk table;
};

pub const kk_size: u64 = 462;
pub const three_size: u64 = 31332;

/// Pawn twist (§5.6): sort the 48 pawn squares by (e(file), rank, file > d);
/// twist = 47 - position. 0xFF on ranks 1 and 8.
pub const twist: [64]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var order: [48]u8 = undefined;
    var count: usize = 0;
    for (8..56) |sq| {
        order[count] = sq;
        count += 1;
    }
    const keyOf = struct {
        fn f(sq: u8) u16 {
            const file = sq & 7;
            const edge = @min(file, 7 - file);
            return @as(u16, edge) * 64 + @as(u16, sq >> 3) * 2 + @intFromBool(file > 3);
        }
    }.f;
    // Selection sort; 48 entries at comptime.
    for (0..48) |i| {
        var best = i;
        for (i + 1..48) |j| {
            if (keyOf(order[j]) < keyOf(order[best])) best = j;
        }
        const tmp = order[i];
        order[i] = order[best];
        order[best] = tmp;
    }
    var table = [_]u8{none8} ** 64;
    for (order, 0..) |sq, pos| table[sq] = 47 - pos;
    break :blk table;
};

/// Largest leading-pawn count of a table up to 7 pieces.
pub const max_lead = 5;

/// lead_base[k][sq] = sum over ranks r' below sq's rank on sq's file of
/// C(twist(file, r'), k - 1): the first term of §5.6, for squares on files a-d.
pub const lead_base: [max_lead + 1][64]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var table = [_][64]u64{[_]u64{0} ** 64} ** (max_lead + 1);
    for (1..max_lead + 1) |k| {
        for (0..4) |file| {
            var acc: u64 = 0;
            for (1..7) |rank| {
                const sq = 8 * rank + file;
                table[k][sq] = acc;
                acc += binomial[k - 1][twist[sq]];
            }
        }
    }
    break :blk table;
};

/// lead_size[k][t] (§5.6): number of leading-group placements with the leader
/// on file t.
pub const lead_size: [max_lead + 1][4]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var table = [_][4]u64{[_]u64{0} ** 4} ** (max_lead + 1);
    for (1..max_lead + 1) |k| {
        for (0..4) |file| {
            var acc: u64 = 0;
            for (1..7) |rank| acc += binomial[k - 1][twist[8 * rank + file]];
            table[k][file] = acc;
        }
    }
    break :blk table;
};

// ---------------------------------------------------------------------------
// Index computation

fn sortAscending(s: []u8) void {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const v = s[i];
        var j = i;
        while (j > 0 and s[j - 1] > v) : (j -= 1) s[j] = s[j - 1];
        s[j] = v;
    }
}

fn sortByTwistDescending(s: []u8) void {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const v = s[i];
        var j = i;
        while (j > 0 and twist[s[j - 1]] < twist[v]) : (j -= 1) s[j] = s[j - 1];
        s[j] = v;
    }
}

/// §5.7 "every other group": colex rank of the group's squares among the
/// squares not taken by any earlier group.
fn groupIndex(p: *Squares, start: u8, len: u8) u64 {
    sortAscending(p[start .. start + len]);
    var idx: u64 = 0;
    for (0..len) |j| {
        const sq = p[start + j];
        var adj: u8 = 0;
        for (p[0..start]) |q| adj += @intFromBool(q < sq);
        idx += binomial[j + 1][sq - adj];
    }
    return idx;
}

fn restIndex(d: *const Descriptor, p: *Squares, first_group: u8) u64 {
    var idx: u64 = 0;
    var g = first_group;
    while (g < d.group_count) : (g += 1) {
        idx += groupIndex(p, d.group_start[g], d.group_len[g]) * d.factor[g];
    }
    return idx;
}

/// Pawnless index (§5.4, §5.5, §5.7, §5.8). `p` holds `d.n` squares in
/// descriptor order and is normalised in place.
pub fn encodePieceless(d: *const Descriptor, p: *Squares) ProbeError!u64 {
    std.debug.assert(d.lead != .pawn);
    const n = d.n;
    if (fileOf(p[0]) >= 4) {
        for (p[0..n]) |*sq| sq.* ^= 7;
    }
    if (rankOf(p[0]) >= 4) {
        for (p[0..n]) |*sq| sq.* ^= 56;
    }
    for (p[0..d.lead_len]) |sq| {
        if (fileOf(sq) == rankOf(sq)) continue;
        if (fileOf(sq) < rankOf(sq)) {
            for (p[0..n]) |*q| q.* = transpose(q.*);
        }
        break;
    }
    const lead: u64 = switch (d.lead) {
        .kk => blk: {
            const v = kk_index[p[0]][p[1]];
            if (v == 0xFFFF) return error.CorruptTable;
            break :blk v;
        },
        .three => threeUnique(p[0], p[1], p[2]),
        .pawn => unreachable,
    };
    return lead * d.factor[0] + restIndex(d, p, 1);
}

fn threeUnique(p0: u8, p1: u8, p2: u8) u64 {
    const a: u64 = @intFromBool(p1 > p0);
    const b: u64 = @as(u64, @intFromBool(p2 > p0)) + @intFromBool(p2 > p1);
    const on0 = fileOf(p0) == rankOf(p0);
    const on1 = fileOf(p1) == rankOf(p1);
    const on2 = fileOf(p2) == rankOf(p2);
    if (!on0) return @as(u64, tri6[p0]) * 3906 + (p1 - a) * 62 + (p2 - b);
    const dia0: u64 = rankOf(p0);
    if (!on1) return 23436 + dia0 * 1736 + @as(u64, below28[p1]) * 62 + (p2 - b);
    const dia1: u64 = rankOf(p1);
    if (!on2) return 30380 + dia0 * 196 + (dia1 - a) * 28 + below28[p2];
    return 31164 + dia0 * 42 + (dia1 - a) * 6 + (rankOf(p2) - b);
}

/// Edge distance of the leader's file: the pawnful subtable t (§5.3).
pub inline fn pawnFile(sq: u8) u2 {
    const f = fileOf(sq);
    return @intCast(@min(f, 7 - f));
}

/// Index of the leading pawn among `squares`: the largest twist, i.e. the
/// smallest (e(file), rank), ties broken towards files a-d (§5.3).
pub fn leaderOf(squares: []const u8) usize {
    var best: usize = 0;
    for (squares[1..], 1..) |sq, i| {
        if (twist[sq] > twist[squares[best]]) best = i;
    }
    return best;
}

/// Pawnful index (§5.3, §5.6-§5.8). `p[0]` is the leading pawn, `p[1..k)` the
/// other leading pawns, then the rest in descriptor order. Normalised in place.
pub fn encodePawnful(d: *const Descriptor, p: *Squares) u64 {
    std.debug.assert(d.lead == .pawn);
    const n = d.n;
    if (fileOf(p[0]) >= 4) {
        for (p[0..n]) |*sq| sq.* ^= 7;
    }
    const k = d.lead_len;
    sortByTwistDescending(p[1..k]);
    var lead: u64 = lead_base[k][p[0]];
    for (1..k) |i| lead += binomial[k - i][twist[p[i]]];
    var idx = lead * d.factor[0];
    var first_rest: u8 = 1;
    if (d.second_len != 0) {
        const m = d.second_len;
        sortAscending(p[k .. k + m]);
        var second: u64 = 0;
        for (0..m) |j| {
            const sq = p[k + j];
            var adj: u8 = 0;
            for (p[0..k]) |q| adj += @intFromBool(q < sq);
            second += binomial[j + 1][sq - 8 - adj];
        }
        idx += second * d.factor[1];
        first_rest = 2;
    }
    return idx + restIndex(d, p, first_rest);
}

test "comptime index tables match the published forms" {
    // Spot values stated in the spec (§5.5, §5.6).
    try std.testing.expectEqual(@as(u8, 47), twist[8]); // a2
    try std.testing.expectEqual(@as(u8, 46), twist[15]); // h2
    try std.testing.expectEqual(@as(u8, 45), twist[16]); // a3
    try std.testing.expectEqual(@as(u8, 37), twist[48]); // a7
    try std.testing.expectEqual(@as(u8, 36), twist[55]); // h7
    try std.testing.expectEqual(@as(u8, 35), twist[9]); // b2
    try std.testing.expectEqual(@as(u8, 0), twist[52]); // e7
    try std.testing.expectEqual(@as(u16, 0xFFFF), kk_index[1][0]); // b1-a1 adjacent
    try std.testing.expectEqual(@as(u16, 0), kk_index[1][3]); // b1-d1: first pair
    try std.testing.expectEqual(@as(u64, 6), lead_size[1][0]);
    try std.testing.expectEqual(@as(u64, 120), binomial[3][10]);
    try std.testing.expectEqual(@as(u64, 0), binomial[3][2]);
    var counts = [_]u16{0} ** 462;
    var seen: usize = 0;
    for (kk_index) |row| for (row) |v| {
        if (v != 0xFFFF) {
            counts[v] += 1;
            seen += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 462), seen);
    for (counts) |c| try std.testing.expectEqual(@as(u16, 1), c);
}

test "three-unique index covers 31332 values exactly once on normalised triples" {
    var hit = try std.testing.allocator.alloc(bool, three_size);
    defer std.testing.allocator.free(hit);
    @memset(hit, false);
    var distinct: usize = 0;
    // Enumerate normalised triples: p0 in the a1-d1-d4 triangle, the first
    // off-diagonal piece below the diagonal.
    for (0..64) |a| for (0..64) |b| for (0..64) |c| {
        const p0: u8 = @intCast(a);
        const p1: u8 = @intCast(b);
        const p2: u8 = @intCast(c);
        if (p0 == p1 or p0 == p2 or p1 == p2) continue;
        if (fileOf(p0) > 3 or rankOf(p0) > fileOf(p0)) continue;
        var above = false;
        for ([_]u8{ p0, p1, p2 }) |sq| {
            if (fileOf(sq) == rankOf(sq)) continue;
            above = fileOf(sq) < rankOf(sq);
            break;
        }
        if (above) continue;
        const v = threeUnique(p0, p1, p2);
        try std.testing.expect(v < three_size);
        if (!hit[v]) distinct += 1;
        hit[v] = true;
    };
    try std.testing.expectEqual(@as(usize, three_size), distinct);
}
