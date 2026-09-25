const std = @import("std");
const attacks = @import("../movegen/attacks.zig");
const basin = @import("basin.zig");
const hugealloc = @import("../util/hugealloc.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const square = @import("../core/square.zig");
const types = @import("../core/types.zig");

pub const HISTORY_LIMIT: i32 = 32_000;

/// Bits describe attacks in the unchanged node position, including occupied squares.
pub inline fn quietBucket(attacked: u64, mv: move_mod.Move) u2 {
    const from: u2 = @intCast((attacked >> mv.from.index()) & 1);
    const to: u2 = @intCast((attacked >> mv.to.index()) & 1);
    return (from << 1) | to;
}

/// Hash-move-first path: obtain the same key without constructing an attack map.
pub inline fn ttQuietBucket(pos: *const position.Position, mv: move_mod.Move) u2 {
    const by = pos.side_to_move.other();
    const from: u2 = @intFromBool(attacks.isSquareAttacked(pos, mv.from, by));
    const to: u2 = @intFromBool(attacks.isSquareAttacked(pos, mv.to, by));
    return (from << 1) | to;
}

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

/// The same key straight from the MOVER's mailbox piece. `Piece` is encoded as
/// `side * 6 + piece_type`, so the `(side, piece_type)` half of the flat key IS
/// the piece index: for any move by the side that owns the piece this returns
/// exactly `contKey(moved.color().?, moved.pieceType(), to)`.
///
/// The point is what it removes: `pieceType()` is a PIECE_TYPES table load, and
/// it sat in the middle of the per-move `mailbox load -> piece type -> row
/// address -> history load` chain, i.e. one extra dependent L1 access in front
/// of the continuation-history miss that dominates scoreMoves.
pub inline fn contKeyOfPiece(moved: piece.Piece, to: square.Square) u16 {
    std.debug.assert(@intFromEnum(moved) < 12);
    return @as(u16, @intFromEnum(moved)) * 64 + to.index();
}

/// Stand-in row for a continuation ply with no usable predecessor. Reading it
/// contributes exactly the 0 the absent ply contributed before, so `ContRows`
/// can hold two plain pointers instead of two optionals: the per-move scoring
/// loop then does two unconditional loads rather than re-testing two
/// node-invariant conditions (and keeping the pair spilled) on every move.
const ZERO_CONT_ROW: [CONT_KEYS]i16 = [_]i16{0} ** CONT_KEYS;

/// Per-node pre-resolved conthist rows (see HistoryTable.contRows).
pub const ContRows = struct {
    rows: [CONT_PLIES]*const [CONT_KEYS]i16 = .{ &ZERO_CONT_ROW, &ZERO_CONT_ROW },

    /// Summed continuation-history score for `cur_key` — same result as
    /// HistoryTable.contTotal with the ContContext the rows were resolved from.
    pub inline fn total(self: *const ContRows, cur_key: u16) i32 {
        var sum: i32 = 0;
        inline for (0..CONT_PLIES) |off| {
            sum += self.rows[off][cur_key];
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
    quiet: [2][4][6][64]i16 = std.mem.zeroes([2][4][6][64]i16),
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
        // implementations); total applied correction capped at ~+/-32 cp — v1's
        // +/-72 cp ceiling let half-trained tables poison pruning decisions
        // (self-SPRT -17.4).
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

    pub fn score(self: *const HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, bucket: u2) i32 {
        // Explicit row pointer: `self.quiet[side][bucket][piece][to]` with runtime
        // indices materialises a 128-byte stack copy of the [64]i16 row and the
        // following 2-byte read stalls on failed store-to-load forwarding (same
        // defect class as correctedEval's 64KB copy above; ~50% of scoreMoves
        // self time in endgame profiles). `&...[piece]` forces in-place
        // addressing.
        const row: *const [64]i16 = &self.quiet[@intFromEnum(side)][bucket][@intFromEnum(moved_piece)];
        return row[to.index()];
    }

    /// Live [bucket][piece][to] rows for the side to move; never copied.
    pub inline fn quietPlane(self: *const HistoryTable, side: types.Color) *const [4][6][64]i16 {
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

    pub fn bonus(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16, bucket: u2) void {
        const bonus_value: i32 = if (basin.ENABLED) basin.historyBonus(depth) else @as(i32, depth) * @as(i32, depth) + 8;
        adjust(self, side, moved_piece, to, bonus_value, bucket);
    }

    pub fn bonusWithPolicy(self: *HistoryTable, policy: *const basin.Params, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16, bucket: u2) void {
        adjust(self, side, moved_piece, to, policy.historyBonus(depth), bucket);
    }

    pub fn penalize(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16, bucket: u2) void {
        const penalty: i32 = if (basin.ENABLED) basin.historyMalus(depth) else @as(i32, depth) * @as(i32, depth) + 8;
        adjust(self, side, moved_piece, to, -penalty, bucket);
    }

    pub fn penalizeWithPolicy(self: *HistoryTable, policy: *const basin.Params, side: types.Color, moved_piece: piece.PieceType, to: square.Square, depth: u16, bucket: u2) void {
        adjust(self, side, moved_piece, to, -policy.historyMalus(depth), bucket);
    }

    /// Apply an already-calibrated signed update to MAIN quiet history only.
    /// Used by the tuning-only eval-policy arm; continuation history is
    /// intentionally untouched.
    pub fn adjustMain(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, delta: i32, bucket: u2) void {
        adjust(self, side, moved_piece, to, delta, bucket);
    }

    /// Summed continuation-history score for a candidate move (`cur_key`) given
    /// the node's previous-move context. Zero when conthist is disabled.
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
        self.contAdjust(cont, cur_key, if (basin.ENABLED) basin.historyBonus(depth) else @as(i32, depth) * @as(i32, depth) + 8);
    }

    pub fn contBonusWithPolicy(self: *HistoryTable, policy: *const basin.Params, cont: *const ContContext, cur_key: u16, depth: u16) void {
        self.contAdjust(cont, cur_key, policy.historyBonus(depth));
    }

    pub fn contPenalize(self: *HistoryTable, cont: *const ContContext, cur_key: u16, depth: u16) void {
        self.contAdjust(cont, cur_key, -(if (basin.ENABLED) basin.historyMalus(depth) else @as(i32, depth) * @as(i32, depth) + 8));
    }

    pub fn contPenalizeWithPolicy(self: *HistoryTable, policy: *const basin.Params, cont: *const ContContext, cur_key: u16, depth: u16) void {
        self.contAdjust(cont, cur_key, -policy.historyMalus(depth));
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
            for (0..4) |bucket| {
                for (0..6) |piece_index| {
                    for (0..64) |square_index| {
                        const value: i32 = self.quiet[side_index][bucket][piece_index][square_index];
                        recordHistoryValue(&result, &result.side_piece_stats[side_index][piece_index], value);
                    }
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

fn adjust(self: *HistoryTable, side: types.Color, moved_piece: piece.PieceType, to: square.Square, delta: i32, bucket: u2) void {
    // Slot pointer instead of value indexing: the read through
    // `self.quiet[side][bucket][piece][to]` copied the whole 128-byte row to the stack
    // first (store-forwarding stall; the bulk of applyQuietCutoffLearning's
    // self time in endgame profiles).
    const slot = &self.quiet[@intFromEnum(side)][bucket][@intFromEnum(moved_piece)][to.index()];
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
    history.bonus(.white, .knight, .f3, 8, 0);
    history.penalize(.black, .bishop, .g4, 10, 0);

    const snap = history.snapshot();
    try std.testing.expectEqual(@as(u16, 3072), snap.total_entries);
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
    history.bonus(.white, .pawn, .e4, 4, 0);
    try std.testing.expect(history.score(.white, .pawn, .e4, 0) > 0);
    try std.testing.expectEqual(@as(i32, 0), history.score(.white, .knight, .e4, 0));
    history.penalize(.white, .pawn, .e4, 8, 0);
    try std.testing.expect(history.score(.white, .pawn, .e4, 0) < 0);
}

test "history gravity updates avoid immediate saturation" {
    var history = HistoryTable{};
    for (0..256) |_| {
        history.bonus(.white, .knight, .f3, 12, 0);
    }
    const saturated = history.score(.white, .knight, .f3, 0);
    try std.testing.expect(saturated > 0);
    try std.testing.expect(saturated <= HISTORY_LIMIT);

    history.penalize(.white, .knight, .f3, 4, 0);
    try std.testing.expect(history.score(.white, .knight, .f3, 0) < saturated);
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

test "bucketed quiet plane matches direct reads for every key" {
    var history = HistoryTable{};
    var seed: i16 = 0;
    for (0..2) |side_index| {
        const side: types.Color = @enumFromInt(side_index);
        const rows = history.quietPlane(side);
        for (0..4) |bucket_index| {
            const bucket: u2 = @intCast(bucket_index);
            for (0..6) |piece_index| {
                const pt: piece.PieceType = @enumFromInt(piece_index);
                const p = piece.Piece.make(side, pt);
                for (0..64) |sq_index| {
                    const sq: square.Square = @enumFromInt(sq_index);
                    seed +%= 37;
                    history.quiet[side_index][bucket][piece_index][sq_index] = seed;
                    try std.testing.expectEqual(history.score(side, pt, sq, bucket), @as(i32, rows[bucket][piece_index][sq_index]));
                    try std.testing.expectEqual(contKey(side, pt, sq), contKeyOfPiece(p, sq));
                }
            }
        }
    }
}

test "resolved conthist rows total the same as the direct table read" {
    var history = HistoryTable{};
    try history.initContinuation(std.testing.allocator);
    defer history.deinitContinuation(std.testing.allocator);

    const contexts = [_]ContContext{
        .{ .prev = .{ CONT_NONE, CONT_NONE } },
        .{ .prev = .{ contKey(.black, .pawn, .e5), CONT_NONE } },
        .{ .prev = .{ CONT_NONE, contKey(.white, .knight, .f3) } },
        .{ .prev = .{ contKey(.black, .rook, .d8), contKey(.white, .queen, .h5) } },
    };
    for (contexts) |cont| {
        history.contBonus(&cont, contKey(.white, .bishop, .c4), 9);
        history.contPenalize(&cont, contKey(.white, .knight, .g5), 7);
    }
    for (contexts) |cont| {
        const rows = history.contRows(&cont);
        var key: u16 = 0;
        while (key < CONT_KEYS) : (key += 1) {
            try std.testing.expectEqual(history.contTotal(&cont, key), rows.total(key));
        }
    }

    // Disabled table: both plies fall back to the zero stand-in row.
    const empty = HistoryTable{};
    for (contexts) |cont| {
        const rows = empty.contRows(&cont);
        try std.testing.expectEqual(@as(i32, 0), rows.total(contKey(.white, .bishop, .c4)));
    }
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

test "quiet history has four fixed threat buckets" {
    const table = HistoryTable{};
    try std.testing.expectEqual(@as(usize, 6144), @sizeOf(@TypeOf(table.quiet)));
}

test "quiet threat bucket bits and updates stay independent" {
    const mv = move_mod.Move.init(.g1, .f3, .quiet);
    const from = @as(u64, 1) << mv.from.index();
    const to = @as(u64, 1) << mv.to.index();
    const maps = [_]u64{ 0, to, from, from | to };
    const policy = basin.Params{};
    for (maps, 0..) |map, i| {
        const bucket: u2 = @intCast(i);
        try std.testing.expectEqual(bucket, quietBucket(map, mv));
        var history = HistoryTable{};
        history.bonus(.white, .knight, mv.to, 4, bucket);
        const bonus = history.score(.white, .knight, mv.to, bucket);
        try std.testing.expectEqual(if (basin.ENABLED) basin.historyBonus(4) else 24, bonus);
        history.penalize(.white, .knight, mv.to, 8, bucket);
        try std.testing.expect(history.score(.white, .knight, mv.to, bucket) < bonus);
        history.bonusWithPolicy(&policy, .white, .knight, mv.to, 4, bucket);
        history.penalizeWithPolicy(&policy, .white, .knight, mv.to, 8, bucket);
        for (0..4) |other| {
            if (other == i) continue;
            try std.testing.expectEqual(@as(i32, 0), history.score(.white, .knight, mv.to, @intCast(other)));
        }
        try std.testing.expectEqual(@as(i32, 0), history.score(.black, .knight, mv.to, bucket));
        try std.testing.expectEqual(@as(i32, 0), history.score(.white, .bishop, mv.to, bucket));
        history.clear();
        try std.testing.expectEqual(@as(u16, 3072), history.snapshot().zero_entries);
    }
}

test "TT square queries agree with map buckets for both sides and every square pair" {
    const fen = @import("../core/fen.zig");
    const cases = [_][]const u8{
        fen.STARTPOS_FEN,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "4k3/4n3/8/8/8/8/4R3/4K3 w - - 0 1",
        "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
    };
    var seen: [4]bool = .{ false, false, false, false };
    for (cases) |text| {
        var pos = try fen.parse(text);
        for ([_]types.Color{ .white, .black }) |side| {
            pos.side_to_move = side;
            const map = attacks.attackedSquares(&pos, side.other());
            for (0..64) |from| {
                for (0..64) |to| {
                    const mv = move_mod.Move.init(@enumFromInt(from), @enumFromInt(to), .quiet);
                    const bucket = ttQuietBucket(&pos, mv);
                    try std.testing.expectEqual(quietBucket(map, mv), bucket);
                    seen[bucket] = true;
                }
            }
        }
    }
    for (seen) |present| try std.testing.expect(present);
}
