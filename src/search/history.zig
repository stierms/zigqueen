const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
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

/// Correction history, drift-removed (A3c form): small per-thread tables that
/// learn, online during search, how the raw static eval's error in five
/// position classes per side to move (pawn structure, each colour's non-pawn
/// placement, minor-piece placement, major-piece placement) DIFFERS from the
/// running mean error of its side to move and pawn-count bucket. The mean
/// itself is never applied: the search's learning events are selected (RFP and
/// null move cut high-eval nodes before any update), so their mean is a shift
/// the pruning margins already price (A3 diagnosis and A3b premise, +18 to
/// +24 cp). Only class deviations reach the eval; an untrained class adds 0.
///
/// Entries are in 1/CORR_GRAIN cp, means in 1/CORR_MEAN_GRAIN cp (a slow mean
/// needs the finer grain or its small steps truncate). The applied correction is the
/// weighted average of the five class entries (basin.Params corr_*). Which
/// node results teach the tables is decided in root.zig (`corr_learn`).
pub const CORR_SIZE: usize = 16384; // entries per table (power of two)
const CORR_MASK: u64 = CORR_SIZE - 1;
const CORR_GRAIN: i32 = 64; // stored value = correction_cp * CORR_GRAIN
const CORR_MEAN_GRAIN: i32 = 4096;
pub const CORR_BUCKETS: usize = 4; // total pawns 0-4, 5-8, 9-12, 13-16
const CORR_DEVIATION_LIMIT: i32 = 32000;

const CorrRows = [2][CORR_SIZE]i16; // [stm][class key]

/// Learning events (build option `corr-learn`): bound-consistent scores or
/// exact scores only.
pub const CorrLearn = enum { bound, exact };
pub const corr_learn: CorrLearn = std.meta.stringToEnum(CorrLearn, build_options.corr_learn) orelse
    @compileError("-Dcorr-learn must be bound or exact");

/// Whether a node result teaches the tables. `estimate` is the learner's full
/// value estimate (raw + applied correction + bucket mean). Bound-consistent:
/// a fail high above it, a fail low below it, or any score inside the caller's
/// window; exact: only scores inside the caller's window.
pub inline fn correctionLearns(best: types.Score, alpha_orig: types.Score, beta: types.Score, estimate: i32) bool {
    const inside = best > alpha_orig and best < beta;
    return switch (comptime corr_learn) {
        .exact => inside,
        .bound => inside or (best >= beta and best > estimate) or (best <= alpha_orig and best < estimate),
    };
}

const CORR_CONT_KEYS: usize = 12 * 64; // piece-colour * 64 + destination
const CorrContRows = [2][CORR_CONT_KEYS]i16; // [stm][previous move key]

const CorrTables = struct {
    pawn: CorrRows,
    nonpawn_white: CorrRows,
    nonpawn_black: CorrRows,
    minor: CorrRows,
    major: CorrRows,
    /// Continuation classes: the move one ply back (the opponent's last move)
    /// and two plies back (our own last move), keyed by piece-colour and
    /// destination (`contKeyOfPiece`).
    cont1: CorrContRows,
    cont2: CorrContRows,
    /// Running mean learning target per [stm][pawn bucket]; never applied.
    mean: [2][CORR_BUCKETS]i32,
};

/// The previous-move keys of a node for the continuation classes; CONT_NONE
/// after a null move, at the root and in quiescence (which keeps no move
/// stack). Plain sentinel keys, not optionals: a `?u16` built in negamax's
/// frame was written as a 2-byte payload plus a 1-byte flag and read back as
/// one 4-byte word, a failed store-to-load forward on every static eval.
pub const CorrCont = struct {
    k1: u16 = CONT_NONE,
    k2: u16 = CONT_NONE,
};

/// Pawn-count bucket of a position (total pawns of both colours).
pub inline fn corrBucket(pos: *const position.Position) usize {
    const pawns = @popCount(pos.pieces[0][0] | pos.pieces[1][0]);
    return @min(@as(usize, @intCast(pawns)) -| 1, 15) / 4;
}

/// One EMA step toward `target` (grain units): min(depth, 16) * step / 1024 of the gap.
inline fn corrStep(entry: *i16, target: i32, depth: u16, step: i32) void {
    const w: i32 = @min(@as(i32, depth), 16);
    const current: i32 = entry.*;
    entry.* = @intCast(current + @divTrunc((target - current) * w * step, 1024));
}

/// Without AVX-512DQ there is no vector 64-bit multiply: LLVM's SLP pass
/// still packs the five independent key chains of `corrKeys` into ymm lanes
/// and emulates every `*%` with three vpmuludq plus shifts and adds, which
/// made the key line ~8% of negamax's samples. Routing each product through
/// an empty register-constrained asm keeps the chains scalar (one imul each);
/// the value is untouched. With AVX-512DQ (vpmullq) the packed form stays.
const keep_mix_scalar = builtin.cpu.arch == .x86_64 and
    !std.Target.x86.featureSetHas(builtin.cpu.features, .avx512dq);

inline fn inGpr(x: u64) u64 {
    if (comptime keep_mix_scalar) return asm ("" : [ret] "=r" (-> u64) : [x] "0" (x));
    return x;
}

/// 64-bit finalizer (splitmix64/murmur3 style) — turns raw bitboards into table keys.
inline fn mix64(x_in: u64) u64 {
    var x = x_in;
    x ^= x >> 33;
    x = inGpr(x *% 0xff51afd7ed558ccd);
    x ^= x >> 33;
    x = inGpr(x *% 0xc4ceb9fe1a85ec53);
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

inline fn minorCorrKey(pos: *const position.Position) usize {
    var h = mix64(pos.pieces[0][@intFromEnum(piece.PieceType.knight)]);
    h ^= pos.pieces[0][@intFromEnum(piece.PieceType.bishop)];
    h = mix64(h) ^ pos.pieces[1][@intFromEnum(piece.PieceType.knight)];
    h = mix64(h) ^ pos.pieces[1][@intFromEnum(piece.PieceType.bishop)];
    return @intCast(mix64(h) & CORR_MASK);
}

inline fn majorCorrKey(pos: *const position.Position) usize {
    var h = mix64(pos.pieces[0][@intFromEnum(piece.PieceType.rook)]);
    h ^= pos.pieces[0][@intFromEnum(piece.PieceType.queen)];
    h = mix64(h) ^ pos.pieces[1][@intFromEnum(piece.PieceType.rook)];
    h = mix64(h) ^ pos.pieces[1][@intFromEnum(piece.PieceType.queen)];
    return @intCast(mix64(h) & CORR_MASK);
}

/// The five position-class table indices of a position (20 mix64 rounds).
/// A negamax node computes them once, before its static eval, and shares them
/// between the prefetch, the corrected eval and the learning step at the
/// node's end: the same indices the per-call key functions return.
pub const CorrKeys = struct {
    pawn: u16,
    nonpawn_white: u16,
    nonpawn_black: u16,
    minor: u16,
    major: u16,
};

comptime {
    std.debug.assert(CORR_SIZE - 1 <= std.math.maxInt(u16));
}

pub inline fn corrKeys(pos: *const position.Position) CorrKeys {
    return .{
        .pawn = @intCast(pawnCorrKey(pos)),
        .nonpawn_white = @intCast(nonPawnCorrKey(pos, 0)),
        .nonpawn_black = @intCast(nonPawnCorrKey(pos, 1)),
        .minor = @intCast(minorCorrKey(pos)),
        .major = @intCast(majorCorrKey(pos)),
    };
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
    /// Heap-owned correction-history tables (~320 KB). Null when disabled — all
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

    /// Static eval corrected by the learned class deviations, clamped out of the
    /// mate band (a static eval must never look like a mate score).
    pub fn correctedEval(self: *const HistoryTable, pos: *const position.Position, raw: types.Score, cont: CorrCont, params: *const basin.Params) types.Score {
        if (self.correction == null) return raw;
        return self.correctedEvalKeyed(pos.side_to_move, corrKeys(pos), raw, cont, params);
    }

    /// Prefetch the five class entries of `keys` (row `stm`), so the corrected
    /// eval that follows the raw eval finds them in L1 instead of stalling on
    /// L2/L3 (the tables total 320 KB per thread). No effect on values.
    pub inline fn prefetchCorrection(self: *const HistoryTable, stm: types.Color, keys: CorrKeys) void {
        const tables = self.correction orelse return;
        const s = @intFromEnum(stm);
        const pawn_row: *const [CORR_SIZE]i16 = &tables.pawn[s];
        const npw_row: *const [CORR_SIZE]i16 = &tables.nonpawn_white[s];
        const npb_row: *const [CORR_SIZE]i16 = &tables.nonpawn_black[s];
        const minor_row: *const [CORR_SIZE]i16 = &tables.minor[s];
        const major_row: *const [CORR_SIZE]i16 = &tables.major[s];
        @prefetch(&pawn_row[keys.pawn], .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(&npw_row[keys.nonpawn_white], .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(&npb_row[keys.nonpawn_black], .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(&minor_row[keys.minor], .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(&major_row[keys.major], .{ .rw = .read, .locality = 3, .cache = .data });
    }

    /// `correctedEval` with the position's class keys already computed
    /// (`corrKeys` of the same position, `stm` its side to move).
    pub noinline fn correctedEvalKeyed(self: *const HistoryTable, side_to_move: types.Color, keys: CorrKeys, raw: types.Score, cont: CorrCont, params: *const basin.Params) types.Score {
        const tables = self.correction orelse return raw;
        const stm = @intFromEnum(side_to_move);
        // Index via explicit row pointers: `tables.pawn[stm][k]` through the
        // pointer field can materialise a stack COPY of the whole row before the
        // runtime-index lookup (the parked form's memcpy was 61% of runtime);
        // `&...[stm]` forces in-place addressing.
        const pawn_row: *const [CORR_SIZE]i16 = &tables.pawn[stm];
        const npw_row: *const [CORR_SIZE]i16 = &tables.nonpawn_white[stm];
        const npb_row: *const [CORR_SIZE]i16 = &tables.nonpawn_black[stm];
        const minor_row: *const [CORR_SIZE]i16 = &tables.minor[stm];
        const major_row: *const [CORR_SIZE]i16 = &tables.major[stm];
        var weight_sum = params.corr_weight_pawn + 2 * params.corr_weight_nonpawn + params.corr_weight_minor + params.corr_weight_major;
        var weighted = params.corr_weight_pawn * @as(i32, pawn_row[keys.pawn]) +
            params.corr_weight_nonpawn * (@as(i32, npw_row[keys.nonpawn_white]) + @as(i32, npb_row[keys.nonpawn_black])) +
            params.corr_weight_minor * @as(i32, minor_row[keys.minor]) +
            params.corr_weight_major * @as(i32, major_row[keys.major]);
        // A missing continuation key drops that class from the average.
        if (cont.k1 != CONT_NONE) {
            const row: *const [CORR_CONT_KEYS]i16 = &tables.cont1[stm];
            weighted += params.corr_weight_cont1 * @as(i32, row[cont.k1]);
            weight_sum += params.corr_weight_cont1;
        }
        if (cont.k2 != CONT_NONE) {
            const row: *const [CORR_CONT_KEYS]i16 = &tables.cont2[stm];
            weighted += params.corr_weight_cont2 * @as(i32, row[cont.k2]);
            weight_sum += params.corr_weight_cont2;
        }
        if (weight_sum <= 0) return raw;
        const correction = @divTrunc(@as(i64, weighted) * params.corr_apply_scale, @as(i64, weight_sum) * CORR_GRAIN * 64);
        const corrected = @as(i64, raw) + correction;
        return @intCast(std.math.clamp(corrected, -(score_mod.MATE_THRESHOLD - 1), score_mod.MATE_THRESHOLD - 1));
    }

    /// The running mean learning target (cp) of the position's side to move and
    /// pawn bucket: part of the learner's estimate, never applied.
    pub inline fn correctionMean(self: *const HistoryTable, pos: *const position.Position) i32 {
        const tables = self.correction orelse return 0;
        return @divTrunc(tables.mean[@intFromEnum(pos.side_to_move)][corrBucket(pos)], CORR_MEAN_GRAIN);
    }

    /// One learning step toward `diff_cp` (= search score - RAW static eval),
    /// clamped to +/-corr_target_cap: the bucket mean moves toward it, then every
    /// class entry toward its deviation from the updated mean.
    pub fn updateCorrection(self: *HistoryTable, pos: *const position.Position, cont: CorrCont, diff_cp: i32, depth: u16, params: *const basin.Params) void {
        if (self.correction == null) return;
        self.updateCorrectionKeyed(pos, corrKeys(pos), cont, diff_cp, depth, params);
    }

    /// `updateCorrection` with the position's class keys already computed
    /// (`corrKeys` of the same position).
    pub fn updateCorrectionKeyed(self: *HistoryTable, pos: *const position.Position, keys: CorrKeys, cont: CorrCont, diff_cp: i32, depth: u16, params: *const basin.Params) void {
        const tables = self.correction orelse return;
        const stm = @intFromEnum(pos.side_to_move);
        const target_cp = std.math.clamp(diff_cp, -params.corr_target_cap, params.corr_target_cap);
        const mean = &tables.mean[stm][corrBucket(pos)];
        mean.* += @divTrunc((target_cp * CORR_MEAN_GRAIN - mean.*) * params.corr_mean_step, 4096);
        const deviation = std.math.clamp(target_cp * CORR_GRAIN - @divTrunc(mean.*, CORR_MEAN_GRAIN / CORR_GRAIN), -CORR_DEVIATION_LIMIT, CORR_DEVIATION_LIMIT);
        const step = params.corr_step;
        corrStep(&tables.pawn[stm][keys.pawn], deviation, depth, step);
        corrStep(&tables.nonpawn_white[stm][keys.nonpawn_white], deviation, depth, step);
        corrStep(&tables.nonpawn_black[stm][keys.nonpawn_black], deviation, depth, step);
        corrStep(&tables.minor[stm][keys.minor], deviation, depth, step);
        corrStep(&tables.major[stm][keys.major], deviation, depth, step);
        if (cont.k1 != CONT_NONE) corrStep(&tables.cont1[stm][cont.k1], deviation, depth, step);
        if (cont.k2 != CONT_NONE) corrStep(&tables.cont2[stm][cont.k2], deviation, depth, step);
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

test "correction history is inert until allocated, then learns a class deviation" {
    const fen = @import("../core/fen.zig");
    const params = basin.Params{};
    var history = HistoryTable{};
    const pos = try fen.startpos();
    history.updateCorrection(&pos, .{}, 100, 8, &params);
    try std.testing.expectEqual(@as(types.Score, 37), history.correctedEval(&pos, 37, .{}, &params));

    try history.initCorrection(std.testing.allocator);
    defer history.deinitCorrection(std.testing.allocator);
    try std.testing.expectEqual(@as(types.Score, 37), history.correctedEval(&pos, 37, .{}, &params));

    history.updateCorrection(&pos, .{}, 40, 16, &params);
    try std.testing.expect(history.correctedEval(&pos, 37, .{}, &params) > 37);
    // The other side to move has its own tables and means.
    var black = pos;
    black.side_to_move = .black;
    try std.testing.expectEqual(@as(types.Score, 37), history.correctedEval(&black, 37, .{}, &params));
    try std.testing.expectEqual(@as(i32, 0), history.correctionMean(&black));

    history.clear();
    try std.testing.expectEqual(@as(types.Score, 37), history.correctedEval(&pos, 37, .{}, &params));
    try std.testing.expectEqual(@as(i32, 0), history.correctionMean(&pos));
    try std.testing.expect(history.correction != null);
}

test "correction history never applies the mean, only class deviations" {
    const fen = @import("../core/fen.zig");
    const params = basin.Params{};
    var history = HistoryTable{};
    try history.initCorrection(std.testing.allocator);
    defer history.deinitCorrection(std.testing.allocator);
    // A uniform residual everywhere is a mean, not a deviation: it fades out.
    const pos = try fen.startpos();
    for (0..4000) |_| history.updateCorrection(&pos, .{}, 40, 16, &params);
    try std.testing.expect(history.correctionMean(&pos) >= 38);
    try std.testing.expect(@abs(history.correctedEval(&pos, 0, .{}, &params)) <= 1);

    // Two pawn structures in one bucket (same pieces otherwise) with residuals
    // +60 and -20: the mean settles near +20 and each structure keeps its
    // deviation, with opposite signs (the shared classes see both and stay small).
    history.clear();
    const a = try fen.parse("4k3/pppp4/8/8/8/8/PPPP4/4K3 w - - 0 1");
    const b = try fen.parse("4k3/4pppp/8/8/8/8/4PPPP/4K3 w - - 0 1");
    try std.testing.expectEqual(corrBucket(&a), corrBucket(&b));
    for (0..4000) |_| {
        history.updateCorrection(&a, .{}, 60, 16, &params);
        history.updateCorrection(&b, .{}, -20, 16, &params);
    }
    const ca = history.correctedEval(&a, 0, .{}, &params);
    const cb = history.correctedEval(&b, 0, .{}, &params);
    try std.testing.expect(ca > 0 and cb < 0);
    try std.testing.expect(ca - cb >= 10);
    try std.testing.expect(history.correctionMean(&a) >= 18 and history.correctionMean(&a) <= 22);
}

test "correction history caps the target and never reaches the mate band" {
    const fen = @import("../core/fen.zig");
    var params = basin.Params{};
    params.corr_mean_step = 4; // keep the mean slow so the deviation stays visible
    var history = HistoryTable{};
    try history.initCorrection(std.testing.allocator);
    defer history.deinitCorrection(std.testing.allocator);
    const pos = try fen.startpos();
    for (0..50) |_| history.updateCorrection(&pos, .{}, 5000, 16, &params);
    // Entries are capped at the target cap; the applied correction scales them by
    // corr_apply_scale / 64, so its bound is the cap times that factor.
    const applied_cap = @divTrunc(params.corr_target_cap * @max(params.corr_apply_scale, 64), 64);
    try std.testing.expect(history.correctedEval(&pos, 0, .{}, &params) <= applied_cap);
    try std.testing.expect(history.correctionMean(&pos) <= params.corr_target_cap);
    const near_mate: types.Score = score_mod.MATE_THRESHOLD - 2;
    try std.testing.expect(history.correctedEval(&pos, near_mate, .{}, &params) < score_mod.MATE_THRESHOLD);
    for (0..200) |_| history.updateCorrection(&pos, .{}, -5000, 16, &params);
    try std.testing.expect(history.correctedEval(&pos, -near_mate, .{}, &params) > -score_mod.MATE_THRESHOLD);
}

test "continuation correction applies only with its key" {
    const fen = @import("../core/fen.zig");
    const params = basin.Params{};
    var history = HistoryTable{};
    try history.initCorrection(std.testing.allocator);
    defer history.deinitCorrection(std.testing.allocator);
    const pos = try fen.startpos();
    const cont = CorrCont{ .k1 = contKeyOfPiece(.black_knight, .f6) };
    // Train the continuation class against a mean that moves slowly.
    var slow = params;
    slow.corr_mean_step = 4;
    for (0..20) |_| history.updateCorrection(&pos, cont, 60, 16, &slow);
    // Later evidence without the key moves only the position classes.
    for (0..40) |_| history.updateCorrection(&pos, .{}, -20, 16, &slow);
    const with_key = history.correctedEval(&pos, 0, cont, &params);
    const without = history.correctedEval(&pos, 0, .{}, &params);
    try std.testing.expect(with_key > without);
}

test "pawn buckets split by total pawn count" {
    const fen = @import("../core/fen.zig");
    try std.testing.expectEqual(@as(usize, 3), corrBucket(&(try fen.startpos())));
    try std.testing.expectEqual(@as(usize, 0), corrBucket(&(try fen.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))));
    try std.testing.expectEqual(@as(usize, 1), corrBucket(&(try fen.parse("4k3/pppp4/8/8/8/8/P7/4K3 w - - 0 1"))));
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
