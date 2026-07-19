const std = @import("std");
const hugealloc = @import("../util/hugealloc.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

pub const HISTORY_LIMIT: i32 = 32_000;

/// Continuation history: how good a (piece, to) move is given the recent move
/// history. We key on the 1-ply previous move (the opponent's last move) and
/// the 2-ply previous move (our own last move). Both prev and current moves are
/// indexed by a 12-value piece-colour and the destination square, so the table
/// stays side-specific like the main quiet history.
pub const CONT_PLIES: usize = 2;
const CONT_KEYS: usize = 12 * 64; // piece-colour (0..11) * 64 + square
pub const CONT_NONE: u16 = std.math.maxInt(u16);

/// Flat key for a (side, piece, to) triple: `(side*6 + piece)*64 + to`.
pub inline fn contKey(side: types.Color, moved_piece: piece.PieceType, to: square.Square) u16 {
    const pc: u16 = @as(u16, @intFromEnum(side)) * 6 + @intFromEnum(moved_piece);
    return pc * 64 + to.index();
}

/// Per-node pre-resolved conthist rows (see HistoryTable.contRows).
pub const ContRows = struct {
    rows: [CONT_PLIES]?*const [CONT_KEYS]i16 = .{ null, null },

    /// Summed continuation-history score for `cur_key` — same result as
    /// HistoryTable.contTotal with the ContContext the rows were resolved from.
    pub inline fn total(self: *const ContRows, cur_key: u16) i32 {
        var sum: i32 = 0;
        inline for (0..CONT_PLIES) |off| {
            if (self.rows[off]) |row| sum += row[cur_key];
        }
        return sum;
    }
};

/// The previous-move keys at a node, one per continuation ply (CONT_NONE when
/// that offset has no usable predecessor, e.g. after a null move or at the root).
pub const ContContext = struct {
    prev: [CONT_PLIES]u16 = .{ CONT_NONE, CONT_NONE },
};

const ContTable = [CONT_PLIES][CONT_KEYS][CONT_KEYS]i16;

/// Correction history: small per-thread tables that learn, ONLINE during search,
/// the systematic error of the static eval in position classes (keyed by pawn
/// structure and by each colour's non-pawn piece placement), and nudge the static
/// eval used for pruning/improving/stand-pat decisions toward the search truth.
/// Entries are a depth-weighted EMA of (search score - raw static eval), stored
/// at CORR_GRAIN x centipawns. Distilled from the SF-family corrhist.
pub const CORR_SIZE: usize = 16384; // entries per table (power of two)
const CORR_MASK: u64 = CORR_SIZE - 1;
const CORR_GRAIN: i32 = 256; // stored value = correction_cp * CORR_GRAIN
const CORR_LIMIT: i32 = 32 * CORR_GRAIN; // per-table clamp (~+/-32 cp)

const CorrTables = struct {
    pawn: [2][CORR_SIZE]i32, // [stm][pawn-structure key]
    nonpawn: [2][2][CORR_SIZE]i32, // [piece colour][stm][that colour's non-pawn key]
};

/// 64-bit finalizer (splitmix64/murmur3 style) — turns raw bitboards into table keys.
inline fn mix64(x_in: u64) u64 {
    var x = x_in;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

inline fn pawnCorrKey(pos: *const position.Position) usize {
    return @intCast(mix64(pos.pieces[0][0] ^ mix64(pos.pieces[1][0])) & CORR_MASK);
}

inline fn nonPawnCorrKey(pos: *const position.Position, color_index: usize) usize {
    var h: u64 = pos.pieces[color_index][1]; // N
    h = mix64(h) ^ pos.pieces[color_index][2]; // B
    h = mix64(h) ^ pos.pieces[color_index][3]; // R
    h = mix64(h) ^ pos.pieces[color_index][4]; // Q
    h = mix64(h) ^ pos.pieces[color_index][5]; // K
    return @intCast(mix64(h) & CORR_MASK);
}
pub const HISTORY_SNAPSHOT_BUCKET_NAMES = [_][]const u8{
    "negative_saturated_90p",
    "negative_high_50_90",
    "negative_mid_10_50",
    "negative_low_1_10",
    "zero",
    "positive_low_1_10",
    "positive_mid_10_50",
    "positive_high_50_90",
    "positive_saturated_90p",
};
pub const HISTORY_SNAPSHOT_BUCKET_COUNT: usize = HISTORY_SNAPSHOT_BUCKET_NAMES.len;
pub const HISTORY_SNAPSHOT_SIDE_NAMES = [_][]const u8{ "white", "black" };
pub const HISTORY_SNAPSHOT_PIECE_NAMES = [_][]const u8{ "pawn", "knight", "bishop", "rook", "queen", "king" };

pub const HistoryPieceSnapshot = struct {
    positive_entries: u16 = 0,
    negative_entries: u16 = 0,
    zero_entries: u16 = 0,
    max_positive: i32 = 0,
    min_negative: i32 = 0,
    max_abs: i32 = 0,
    abs_sum: u64 = 0,
};

pub const HistoryTableSnapshot = struct {
    total_entries: u16 = 0,
    positive_entries: u16 = 0,
    negative_entries: u16 = 0,
    zero_entries: u16 = 0,
    max_positive: i32 = 0,
    min_negative: i32 = 0,
    max_abs: i32 = 0,
    abs_sum: u64 = 0,
    bucket_counts: [HISTORY_SNAPSHOT_BUCKET_COUNT]u16 = [_]u16{0} ** HISTORY_SNAPSHOT_BUCKET_COUNT,
    side_piece_stats: [2][6]HistoryPieceSnapshot = [_][6]HistoryPieceSnapshot{[_]HistoryPieceSnapshot{.{}} ** 6} ** 2,
};

pub const CountermovePieceSnapshot = struct {
    occupied_entries: u16 = 0,
};

pub const CountermoveTableSnapshot = struct {
    total_slots: u16 = 0,
    occupied_slots: u16 = 0,
    empty_slots: u16 = 0,
    remember_calls: u64 = 0,
    overwrite_same: u64 = 0,
    overwrite_different: u64 = 0,
    side_piece_stats: [2][6]CountermovePieceSnapshot = [_][6]CountermovePieceSnapshot{[_]CountermovePieceSnapshot{.{}} ** 6} ** 2,
};

pub const HistoryTable = struct {
    quiet: [2][6][64]i16 = std.mem.zeroes([2][6][64]i16),
    countermove: [2][6][64]?move_mod.Move = std.mem.zeroes([2][6][64]?move_mod.Move),
    countermove_remember_calls: u64 = 0,
    countermove_overwrite_same: u64 = 0,
    countermove_overwrite_different: u64 = 0,
    /// Heap-owned continuation-history table (~2.25 MB). Null when disabled, in
    /// which case all conthist queries/updates are no-ops -- this keeps the
    /// default `.{}` value cheap for tests and for the `Engine` field default;
    /// the live engine allocates it via `initContinuation`.
    continuation: ?*ContTable = null,
    /// How the continuation table is backed (2MB huge pages when the OS grants
    /// them — 2.25MB of random (prev,cur)-keyed access). Frees must go through
    /// hugealloc with this.
    continuation_method: hugealloc.Method = .heap,
    /// Heap-owned correction-history tables (~384 KB). Null when disabled — all
    /// corrhist reads return 0 and updates are no-ops (same pattern as conthist).
    correction: ?*CorrTables = null,

    /// Allocate the continuation table on the heap (idempotent).
    pub fn initContinuation(self: *HistoryTable, allocator: std.mem.Allocator) !void {
        if (self.continuation != null) return;
        const backed = try hugealloc.alloc(ContTable, allocator, 1);
        @memset(std.mem.asBytes(&backed.items[0]), 0);
        self.continuation = &backed.items[0];
        self.continuation_method = backed.method;
    }

    pub fn deinitContinuation(self: *HistoryTable, allocator: std.mem.Allocator) void {
        if (self.continuation) |table| {
            const items: []ContTable = @as([*]ContTable, @ptrCast(table))[0..1];
            hugealloc.free(ContTable, allocator, .{ .items = items, .method = self.continuation_method });
            self.continuation = null;
            self.continuation_method = .heap;
        }
    }

    /// Allocate the correction-history tables on the heap (idempotent).
    pub fn initCorrection(self: *HistoryTable, allocator: std.mem.Allocator) !void {
        if (self.correction != null) return;
        const tables = try allocator.create(CorrTables);
        @memset(std.mem.asBytes(tables), 0);
        self.correction = tables;
    }

    pub fn deinitCorrection(self: *HistoryTable, allocator: std.mem.Allocator) void {
        if (self.correction) |tables| {
            allocator.destroy(tables);
            self.correction = null;
        }
    }

    pub fn clear(self: *HistoryTable) void {
        const saved = self.continuation;
        const saved_method = self.continuation_method;
        const saved_corr = self.correction;
        self.* = .{ .continuation = saved, .continuation_method = saved_method, .correction = saved_corr };
        if (saved) |table| @memset(std.mem.asBytes(table), 0);
        if (saved_corr) |tables| @memset(std.mem.asBytes(tables), 0);
    }

    /// Static eval corrected by the learned per-position-class error, clamped out
    /// of the mate band (a static eval must never look like a mate score).
    pub fn correctedEval(self: *const HistoryTable, pos: *const position.Position, raw: types.Score) types.Score {
        const tables = self.correction orelse return raw;
        const stm = @intFromEnum(pos.side_to_move);
        // Index via explicit sub-array pointers: `tables.pawn[stm][k]` through the
        // pointer field materialises a 64KB stack COPY of the sub-array before the
        // runtime-index lookup (memcpy was 61% of runtime); `&...[stm]` forces
        // in-place addressing.
        const pawn_row: *const [CORR_SIZE]i32 = &tables.pawn[stm];
        const npw_row: *const [CORR_SIZE]i32 = &tables.nonpawn[0][stm];
        const npb_row: *const [CORR_SIZE]i32 = &tables.nonpawn[1][stm];
        // Pawn structure weighted double (the strongest signal in reference
        // implementations); total applied correction capped at ~+/-32 cp — a
        // looser ceiling lets half-trained tables poison pruning decisions.
        const v = 2 * pawn_row[pawnCorrKey(pos)] +
            npw_row[nonPawnCorrKey(pos, 0)] +
            npb_row[nonPawnCorrKey(pos, 1)];
        const corrected = @as(i32, raw) + @divTrunc(v, 4 * CORR_GRAIN);
        return @intCast(std.math.clamp(corrected, -(score_mod.MATE_THRESHOLD - 1), score_mod.MATE_THRESHOLD - 1));
    }

    /// Depth-weighted EMA update of every corrhist table toward `diff_cp`
    /// (= search score - RAW static eval at a bound-consistent node).
    pub fn updateCorrection(self: *HistoryTable, pos: *const position.Position, diff_cp: i32, depth: u16) void {
        const tables = self.correction orelse return;
        const stm = @intFromEnum(pos.side_to_move);
        const w: i32 = @min(@as(i32, depth) + 1, 16);
        const scaled = std.math.clamp(diff_cp * CORR_GRAIN, -CORR_LIMIT, CORR_LIMIT);
        const slots = [_]*i32{
            &tables.pawn[stm][pawnCorrKey(pos)],
            &tables.nonpawn[0][stm][nonPawnCorrKey(pos, 0)],
            &tables.nonpawn[1][stm][nonPawnCorrKey(pos, 1)],
        };
        for (slots) |entry| {
            const updated = @divTrunc(entry.* * (256 - w) + scaled * w, 256);
            entry.* = std.math.clamp(updated, -CORR_LIMIT, CORR_LIMIT);
        }
    }

    pub fn score(self: *const HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square) i32 {
        // Explicit row pointer: `self.quiet[side][piece][to]` with runtime
        // indices materialises a 128-byte stack copy of the [64]i16 row and the
        // following 2-byte read stalls on failed store-to-load forwarding (same
        // defect class as correctedEval's 64KB copy above; ~50% of scoreMoves
        // self time in endgame profiles). `&...[piece]` forces in-place
        // addressing.
        const row: *const [64]i16 = &self.quiet[@intFromEnum(side)][@intFromEnum(moved_piece)];
        return row[to.index()];
    }

    /// Per-side quiet-history plane, resolved once per scored move list (see
    /// ordering.scoreMoves): every move in a node's list is by the side to
    /// move, so the side half of the row address is node-invariant. Reads
    /// through the plane see the live table values; `plane[piece][to]` equals
    /// `score(side, piece, to)` exactly.
    pub inline fn quietPlane(self: *const HistoryTable, side: types.Color) *const [6][64]i16 {
        return &self.quiet[@intFromEnum(side)];
    }

    pub fn counterMove(self: *const HistoryTable, previous_side: types.Color, previous_piece: piece.PieceType, to: square.Square) ?move_mod.Move {
        // Row pointer for the same reason as `score` (the [64]?Move row copy is
        // 256 bytes; it dominated previousQuietCountermove's self time).
        const row: *const [64]?move_mod.Move = &self.countermove[@intFromEnum(previous_side)][@intFromEnum(previous_piece)];
        return row[to.index()];
    }

    pub fn rememberCounterMove(self: *HistoryTable, previous_side: types.Color, previous_piece: piece.PieceType, to: square.Square, response: move_mod.Move) void {
        const side_index = @intFromEnum(previous_side);
        const piece_index = @intFromEnum(previous_piece);
        const square_index = to.index();
        const slot = &self.countermove[side_index][piece_index][square_index];
        if (slot.*) |existing| {
            if (existing == response) {
                self.countermove_overwrite_same += 1;
            } else {
                self.countermove_overwrite_different += 1;
            }
        }
        self.countermove_remember_calls += 1;
        slot.* = response;
    }

    pub fn bonus(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16) void {
        const bonus_value: i32 = @as(i32, depth) * @as(i32, depth) + 8;
        adjust(self, side, moved_piece, to, bonus_value);
    }

    pub fn penalize(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16) void {
        const penalty: i32 = @as(i32, depth) * @as(i32, depth) + 8;
        adjust(self, side, moved_piece, to, -penalty);
    }

    /// Summed continuation-history score for a candidate move (`cur_key`) given
    /// the node's previous-move context. Zero when conthist is disabled.
    /// The search reads via the hoisted contRows path; this per-move form is the
    /// value-identical reference the unit tests exercise. // test seam
    pub fn contTotal(self: *const HistoryTable, cont: *const ContContext, cur_key: u16) i32 {
        const table = self.continuation orelse return 0;
        var total: i32 = 0;
        inline for (0..CONT_PLIES) |off| {
            const prev = cont.prev[off];
            if (prev != CONT_NONE) total += table[off][prev][cur_key];
        }
        return total;
    }

    /// Resolve the node's conthist row base pointers once. Row addresses depend
    /// only on the table base and the node's prev keys — both fixed for the
    /// node — so hoisting this out of the per-move scoring loop is value-
    /// identical to calling contTotal per move (reads still deref the LIVE
    /// table; only the address computation and null/none checks are hoisted).
    pub fn contRows(self: *const HistoryTable, cont: *const ContContext) ContRows {
        var result = ContRows{};
        const table = self.continuation orelse return result;
        inline for (0..CONT_PLIES) |off| {
            const prev = cont.prev[off];
            if (prev != CONT_NONE) result.rows[off] = &table[off][prev];
        }
        return result;
    }

    pub fn contBonus(self: *HistoryTable, cont: *const ContContext, cur_key: u16, depth: u16) void {
        self.contAdjust(cont, cur_key, @as(i32, depth) * @as(i32, depth) + 8);
    }

    pub fn contPenalize(self: *HistoryTable, cont: *const ContContext, cur_key: u16, depth: u16) void {
        self.contAdjust(cont, cur_key, -(@as(i32, depth) * @as(i32, depth) + 8));
    }

    fn contAdjust(self: *HistoryTable, cont: *const ContContext, cur_key: u16, delta: i32) void {
        const table = self.continuation orelse return;
        inline for (0..CONT_PLIES) |off| {
            const prev = cont.prev[off];
            if (prev != CONT_NONE) {
                const slot = &table[off][prev][cur_key];
                slot.* = @intCast(applyGravity(@as(i32, slot.*), delta));
            }
        }
    }

    pub fn snapshot(self: *const HistoryTable) HistoryTableSnapshot {
        var result = HistoryTableSnapshot{};
        for (0..2) |side_index| {
            for (0..6) |piece_index| {
                for (0..64) |square_index| {
                    const value: i32 = self.quiet[side_index][piece_index][square_index];
                    recordHistoryValue(&result, &result.side_piece_stats[side_index][piece_index], value);
                }
            }
        }
        return result;
    }

    pub fn countermoveSnapshot(self: *const HistoryTable) CountermoveTableSnapshot {
        var result = CountermoveTableSnapshot{
            .total_slots = 2 * 6 * 64,
            .remember_calls = self.countermove_remember_calls,
            .overwrite_same = self.countermove_overwrite_same,
            .overwrite_different = self.countermove_overwrite_different,
        };
        for (0..2) |side_index| {
            for (0..6) |piece_index| {
                for (0..64) |square_index| {
                    if (self.countermove[side_index][piece_index][square_index] != null) {
                        result.occupied_slots += 1;
                        result.side_piece_stats[side_index][piece_index].occupied_entries += 1;
                    }
                }
            }
        }
        result.empty_slots = result.total_slots - result.occupied_slots;
        return result;
    }
};

fn recordHistoryValue(snapshot: *HistoryTableSnapshot, piece_snapshot: *HistoryPieceSnapshot, value: i32) void {
    snapshot.total_entries += 1;
    const abs_value: u32 = @abs(value);
    const abs_i32: i32 = @intCast(abs_value);
    snapshot.abs_sum += abs_value;
    piece_snapshot.abs_sum += abs_value;
    snapshot.max_abs = @max(snapshot.max_abs, abs_i32);
    piece_snapshot.max_abs = @max(piece_snapshot.max_abs, abs_i32);

    if (value > 0) {
        snapshot.positive_entries += 1;
        piece_snapshot.positive_entries += 1;
        snapshot.max_positive = @max(snapshot.max_positive, value);
        piece_snapshot.max_positive = @max(piece_snapshot.max_positive, value);
    } else if (value < 0) {
        snapshot.negative_entries += 1;
        piece_snapshot.negative_entries += 1;
        snapshot.min_negative = @min(snapshot.min_negative, value);
        piece_snapshot.min_negative = @min(piece_snapshot.min_negative, value);
    } else {
        snapshot.zero_entries += 1;
        piece_snapshot.zero_entries += 1;
    }
    snapshot.bucket_counts[historyBucketIndex(value)] += 1;
}

fn historyBucketIndex(value: i32) usize {
    const ten_percent = @divTrunc(HISTORY_LIMIT, 10);
    const half_limit = @divTrunc(HISTORY_LIMIT, 2);
    const saturation_band = @divTrunc(HISTORY_LIMIT * 9, 10);
    if (value <= -saturation_band) return 0;
    if (value <= -half_limit) return 1;
    if (value <= -ten_percent) return 2;
    if (value < 0) return 3;
    if (value == 0) return 4;
    if (value < ten_percent) return 5;
    if (value < half_limit) return 6;
    if (value < saturation_band) return 7;
    return 8;
}

fn adjust(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, delta: i32) void {
    // Slot pointer instead of value indexing: the read through
    // `self.quiet[side][piece][to]` copied the whole 128-byte row to the stack
    // first (store-forwarding stall; the bulk of applyQuietCutoffLearning's
    // self time in endgame profiles).
    const slot = &self.quiet[@intFromEnum(side)][@intFromEnum(moved_piece)][to.index()];
    const next = applyGravity(@as(i32, slot.*), delta);
    slot.* = @intCast(next);
}

/// Gravity update shared by quiet and continuation history: move toward the
/// signed limit by `delta`, decayed proportionally to the current magnitude so
/// repeated bonuses saturate smoothly rather than pinning at the limit.
fn applyGravity(current: i32, delta: i32) i32 {
    const magnitude = @min(@abs(delta), HISTORY_LIMIT);
    const decay = @divTrunc(current * magnitude, HISTORY_LIMIT);
    return std.math.clamp(current + delta - decay, -HISTORY_LIMIT, HISTORY_LIMIT);
}

test "history snapshot buckets quiet move scores" {
    var history = HistoryTable{};
    history.bonus(.white, .knight, .f3, 8);
    history.penalize(.black, .bishop, .g4, 10);

    const snap = history.snapshot();
    try std.testing.expectEqual(@as(u16, 768), snap.total_entries);
    try std.testing.expect(snap.positive_entries > 0);
    try std.testing.expect(snap.negative_entries > 0);
    try std.testing.expect(snap.zero_entries < snap.total_entries);
    try std.testing.expect(snap.max_positive > 0);
    try std.testing.expect(snap.min_negative < 0);
    try std.testing.expect(snap.max_abs > 0);
    try std.testing.expect(snap.side_piece_stats[@intFromEnum(types.Color.white)][@intFromEnum(piece.PieceType.knight)].positive_entries > 0);
    try std.testing.expect(snap.side_piece_stats[@intFromEnum(types.Color.black)][@intFromEnum(piece.PieceType.bishop)].negative_entries > 0);
}

test "history table stores signed piece-to quiet move scores" {
    var history = HistoryTable{};
    history.bonus(.white, .pawn, .e4, 4);
    try std.testing.expect(history.score(.white, .pawn, .e4) > 0);
    try std.testing.expectEqual(@as(i32, 0), history.score(.white, .knight, .e4));
    history.penalize(.white, .pawn, .e4, 8);
    try std.testing.expect(history.score(.white, .pawn, .e4) < 0);
}

test "history gravity updates avoid immediate saturation" {
    var history = HistoryTable{};
    for (0..256) |_| {
        history.bonus(.white, .knight, .f3, 12);
    }
    const saturated = history.score(.white, .knight, .f3);
    try std.testing.expect(saturated > 0);
    try std.testing.expect(saturated < HISTORY_LIMIT);

    history.penalize(.white, .knight, .f3, 4);
    try std.testing.expect(history.score(.white, .knight, .f3) < saturated);
}

test "continuation history is a no-op until allocated, then bonuses/penalties move the score" {
    var history = HistoryTable{};
    const cur = contKey(.white, .knight, .f3);
    var cont = ContContext{ .prev = .{ contKey(.black, .pawn, .e5), CONT_NONE } };

    // Disabled (null table): every query is zero and updates do nothing.
    try std.testing.expectEqual(@as(i32, 0), history.contTotal(&cont, cur));
    history.contBonus(&cont, cur, 6);
    try std.testing.expectEqual(@as(i32, 0), history.contTotal(&cont, cur));

    try history.initContinuation(std.testing.allocator);
    defer history.deinitContinuation(std.testing.allocator);

    history.contBonus(&cont, cur, 6);
    const after_bonus = history.contTotal(&cont, cur);
    try std.testing.expect(after_bonus > 0);

    // A different predecessor keys a different slot (still zero).
    var other = ContContext{ .prev = .{ contKey(.black, .knight, .e5), CONT_NONE } };
    try std.testing.expectEqual(@as(i32, 0), history.contTotal(&other, cur));

    history.contPenalize(&cont, cur, 6);
    try std.testing.expect(history.contTotal(&cont, cur) < after_bonus);

    history.clear();
    try std.testing.expectEqual(@as(i32, 0), history.contTotal(&cont, cur));
    try std.testing.expect(history.continuation != null); // clear keeps the allocation
}

test "history table stores piece-to countermoves" {
    var history = HistoryTable{};
    const response = move_mod.Move.init(.g8, .f6, .quiet);
    history.rememberCounterMove(.white, .pawn, .e4, response);

    try std.testing.expectEqual(response, history.counterMove(.white, .pawn, .e4).?);
    try std.testing.expect(history.counterMove(.white, .knight, .e4) == null);
    const snap = history.countermoveSnapshot();
    try std.testing.expectEqual(@as(u16, 768), snap.total_slots);
    try std.testing.expectEqual(@as(u16, 1), snap.occupied_slots);
    try std.testing.expectEqual(@as(u16, 767), snap.empty_slots);
    try std.testing.expectEqual(@as(u64, 1), snap.remember_calls);
    try std.testing.expectEqual(@as(u16, 1), snap.side_piece_stats[@intFromEnum(types.Color.white)][@intFromEnum(piece.PieceType.pawn)].occupied_entries);
}
