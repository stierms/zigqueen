//! Shared value types of the own Syzygy prober (docs/SYZYGY_FORMAT.md §12).
//! Failure is an error union everywhere; a draw is a value, never a failure.
const std = @import("std");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");

/// Five-state WDL from the side to move's point of view, as if the 50-move
/// counter were 0 (§2, §7.4).
pub const Wdl5 = enum(i8) {
    loss = -2,
    blessed_loss = -1,
    draw = 0,
    cursed_win = 1,
    win = 2,

    pub inline fn fromInt(v: i8) Wdl5 {
        std.debug.assert(v >= -2 and v <= 2);
        return @enumFromInt(v);
    }
    pub inline fn int(self: Wdl5) i8 {
        return @intFromEnum(self);
    }
};

/// Signed DTZ in plies (§8.1); 0 for draws. `exact` is false when the value
/// was read from a table that stores moves, so the true distance may be one
/// ply longer. v1 policy does not use it.
pub const Dtz = struct {
    plies: i32,
    exact: bool,
};

pub const ProbeError = error{
    /// Castling rights, too many pieces, or an invalid position (§7.4).
    OutOfScope,
    /// A needed WDL or DTZ file is absent from the snapshot.
    MissingTable,
    /// Load-time validation (§4.6) or a probe-time bound failed.
    CorruptTable,
    /// A positioned read failed or came back short. (A mapping that fails is
    /// never an error: the file falls back to positioned reads.)
    Io,
};

pub const Metric = enum(u1) { wdl, dtz };

/// Root record of one legal move (§9.1, §9.2).
pub const RootRecord = struct {
    move: move_mod.Move,
    /// Root-relative DTZ of the move, counting the move itself.
    r: i32,
    /// §9.2 state of `r` under the root counter.
    state: Wdl5,
    exact: bool,
    zeroing: bool,
    en_passant: bool,
};

pub const Terminal = enum { none, checkmate, stalemate };

/// Caller-owned, fixed capacity (MoveList.MAX_MOVES). Records follow the
/// order of `legal.generate`; `suggested` indexes into them (§9.3).
pub const RootRanking = struct {
    records: [move_mod.MAX_MOVES]RootRecord = undefined,
    count: u16 = 0,
    root_dtz: Dtz = .{ .plies = 0, .exact = true },
    root_state: Wdl5 = .draw,
    suggested: ?u16 = null,
    terminal: Terminal = .none,

    pub fn slice(self: *const RootRanking) []const RootRecord {
        return self.records[0..self.count];
    }
};

/// §9.2: the five states of a root-relative value `r` under counter `c`
/// (Fathom's boundary: `r + c == 100` is still a win, Q6).
pub fn rootState(r: i32, c: u32) Wdl5 {
    const counter: i64 = c;
    if (r > 0) return if (@as(i64, r) + counter <= 100) .win else .cursed_win;
    if (r < 0) return if (-@as(i64, r) + counter <= 100) .loss else .blessed_loss;
    return .draw;
}

/// Material key (§3.3): 4 bits per count, white Q..P in the low 20 bits and
/// black in the high 20 bits, indexed by our PieceType (pawn = 0 .. queen = 4).
/// Collision-free; kings are implicit.
pub const MaterialKey = u64;

pub const Material = struct {
    /// counts[colour][piece type], pawn = 0, knight, bishop, rook, queen = 4.
    counts: [2][5]u8 = .{ .{0} ** 5, .{0} ** 5 },

    pub fn key(self: *const Material) MaterialKey {
        var k: MaterialKey = 0;
        for (0..2) |c| for (0..5) |t| {
            k |= @as(MaterialKey, self.counts[c][t] & 0xF) << @intCast(20 * c + 4 * t);
        };
        return k;
    }
    pub fn pieces(self: *const Material) u8 {
        var n: u8 = 2;
        for (self.counts) |side| for (side) |v| {
            n += v;
        };
        return n;
    }
    pub fn hasPawns(self: *const Material) bool {
        return self.counts[0][0] + self.counts[1][0] != 0;
    }
    pub fn bothHavePawns(self: *const Material) bool {
        return self.counts[0][0] != 0 and self.counts[1][0] != 0;
    }
    pub fn symmetric(self: *const Material) bool {
        return std.mem.eql(u8, &self.counts[0], &self.counts[1]);
    }
    pub fn mirrored(self: *const Material) Material {
        return .{ .counts = .{ self.counts[1], self.counts[0] } };
    }
};

pub inline fn mirrorKey(k: MaterialKey) MaterialKey {
    return (k >> 20) | ((k & 0xFFFFF) << 20);
}

pub fn materialOf(pos: *const position.Position) Material {
    var m = Material{};
    for (0..2) |c| {
        const row = &pos.pieces[c];
        for (0..5) |t| m.counts[c][t] = @popCount(row[t]);
    }
    return m;
}

pub inline fn materialKeyOf(pos: *const position.Position) MaterialKey {
    var k: MaterialKey = 0;
    inline for (0..2) |c| {
        const row = &pos.pieces[c];
        inline for (0..5) |t| k |= @as(MaterialKey, @popCount(row[t])) << (20 * c + 4 * t);
    }
    return k;
}

test "material keys mirror and count" {
    var m = Material{};
    m.counts[0][3] = 1; // white rook
    m.counts[1][0] = 2; // two black pawns
    try std.testing.expectEqual(@as(u8, 5), m.pieces());
    try std.testing.expect(!m.symmetric());
    try std.testing.expectEqual(m.mirrored().key(), mirrorKey(m.key()));
    try std.testing.expectEqual(m.key(), mirrorKey(mirrorKey(m.key())));
}

test "root states follow the Fathom boundary" {
    try std.testing.expectEqual(Wdl5.win, rootState(100, 0));
    try std.testing.expectEqual(Wdl5.win, rootState(50, 50));
    try std.testing.expectEqual(Wdl5.cursed_win, rootState(51, 50));
    try std.testing.expectEqual(Wdl5.cursed_win, rootState(101, 0));
    try std.testing.expectEqual(Wdl5.draw, rootState(0, 99));
    try std.testing.expectEqual(Wdl5.loss, rootState(-1, 99));
    try std.testing.expectEqual(Wdl5.blessed_loss, rootState(-2, 99));
}
