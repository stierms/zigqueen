//! Test-only Syzygy oracle tool (docs/SYZYGY_FORMAT.md §11). Links vendored
//! Fathom next to our prober in one process; never linked into the engine.
//!
//!   zigqueen-tb-oracle census <paths> [lengths=1] [storage=mmap|budget|pread]
//!   zigqueen-tb-oracle g1 <paths> [seed=N] [tables=all|345|6|sample:P|list:A,B]
//!                       [uniform=N] [ep=N] [promo=N] [diag=N] [tie=N] [root=N]
//!                       [shard=I/N] [pc_every=N] [out=DIR] [storage=...]
//!   zigqueen-tb-oracle bench <paths> [tables=...] [positions=N] [repeat=N] [storage=...]
//!   zigqueen-tb-oracle walk <paths> [tables=...] [positions=N per table] [storage=...]
//!   zigqueen-tb-oracle fens <paths> tables='<fen>|<fen>...' [storage=...]
//!   zigqueen-tb-oracle tail <paths> arm=ours|fathom [tables=...] [storage=...]
//!
//! `<paths>` is a SyzygyPath list. g1 compares WDL, DTZ and root records with
//! Fathom (zero mismatches to pass) and writes a python-chess subsample. Root
//! records are compared for every en-passant, promotion and pawn-tie position
//! and, within the `root` budget, for uniform and diagonal ones. g1 and fens
//! log, per file, the furthest byte read (proof that reads cross 2 GiB).
const std = @import("std");
const tb = @import("tb/tb.zig");
const fen = @import("core/fen.zig");
const position = @import("core/position.zig");
const move_mod = @import("core/move.zig");
const piece_mod = @import("core/piece.zig");
const square = @import("core/square.zig");
const legal = @import("movegen/legal.zig");
const Color = @import("core/types.zig").Color;

const Position = position.Position;
const Move = move_mod.Move;

// ---------------------------------------------------------------------------
// Fathom through the oracle's public-API bridge (src/tb_oracle_fathom.c)

extern fn zq_tb_init(path: [*:0]const u8) bool;
extern fn zq_tb_free() void;
extern fn zq_tb_largest() c_uint;
extern fn zq_tb_wdl(white: u64, black: u64, kings: u64, queens: u64, rooks: u64, bishops: u64, knights: u64, pawns: u64, ep: c_uint, turn: bool) c_uint;
extern fn zq_tb_root(white: u64, black: u64, kings: u64, queens: u64, rooks: u64, bishops: u64, knights: u64, pawns: u64, rule50: c_uint, ep: c_uint, turn: bool, results: ?[*]c_uint) c_uint;

const FAILED: u32 = 0xFFFFFFFF;
const FATHOM_MAX_MOVES = 193;

fn bb(pos: *const Position, t: piece_mod.PieceType) u64 {
    return pos.pieceBitboard(.white, t) | pos.pieceBitboard(.black, t);
}

fn fathomWdl(pos: *const Position) u32 {
    const ep: c_uint = if (pos.en_passant) |sq| @intFromEnum(sq) else 0;
    return zq_tb_wdl(pos.occupancyFor(.white), pos.occupancyFor(.black), bb(pos, .king), bb(pos, .queen), bb(pos, .rook), bb(pos, .bishop), bb(pos, .knight), bb(pos, .pawn), ep, pos.side_to_move == .white);
}

fn fathomRoot(pos: *const Position, rule50: u32, results: ?[*]u32) u32 {
    const ep: c_uint = if (pos.en_passant) |sq| @intFromEnum(sq) else 0;
    return zq_tb_root(pos.occupancyFor(.white), pos.occupancyFor(.black), bb(pos, .king), bb(pos, .queen), bb(pos, .rook), bb(pos, .bishop), bb(pos, .knight), bb(pos, .pawn), rule50, ep, pos.side_to_move == .white, results);
}

/// Storage wrapper that records, per file, the furthest byte any probe read.
fn Tracked(comptime B: type) type {
    return struct {
        const Self = @This();
        inner: B,
        max_end: []std.atomic.Value(u64),

        pub fn init(gpa: std.mem.Allocator, files: tb.storage.FileSet, options: tb.storage.Options) !Self {
            const max_end = try gpa.alloc(std.atomic.Value(u64), files.paths.len);
            errdefer gpa.free(max_end);
            for (max_end) |*m| m.* = .init(0);
            return .{ .inner = try B.init(gpa, files, options), .max_end = max_end };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.inner.deinit(gpa);
            gpa.free(self.max_end);
        }
        pub fn view(self: *const Self, file: u32, offset: u64, len: usize, scratch: []u8) tb.ProbeError![]const u8 {
            _ = self.max_end[file].fetchMax(offset + len, .monotonic);
            return self.inner.view(file, offset, len, scratch);
        }
        pub fn stats(self: *const Self) tb.storage.Stats {
            return self.inner.stats();
        }
    };
}

const two_gib: u64 = 2 << 30;

const TB_RESULT_CHECKMATE: u32 = 4; // TB_SET_WDL(0, TB_WIN)
const TB_RESULT_STALEMATE: u32 = 2; // TB_SET_WDL(0, TB_DRAW)

/// Fathom's root D (§11.1): signed DTZ, null when the probe failed.
fn fathomDtz(result: u32) ?i32 {
    if (result == FAILED) return null;
    if (result == TB_RESULT_CHECKMATE) return -1;
    if (result == TB_RESULT_STALEMATE) return 0;
    const wdl = result & 0xF;
    const dtz: i32 = @intCast(result >> 20);
    return switch (wdl) {
        3, 4 => dtz,
        0, 1 => -dtz,
        else => 0,
    };
}

fn stateCode(w: tb.Wdl5) u32 {
    return @intCast(@as(i32, w.int()) + 2);
}

fn fathomPromo(mv: Move) u32 {
    return if (mv.promotionPieceType()) |p| switch (p) {
        .queen => 1,
        .rook => 2,
        .bishop => 3,
        .knight => 4,
        else => 7,
    } else 0;
}

fn moveKey(from: u32, to: u32, promo: u32) u32 {
    return (from << 9) | (to << 3) | promo;
}

// ---------------------------------------------------------------------------
// Options

const Options = struct {
    paths: []const u8 = "",
    seed: u64 = 20261014,
    tables: []const u8 = "all",
    uniform: u32 = 200,
    ep: u32 = 40,
    promo: u32 = 40,
    diag: u32 = 40,
    tie: u32 = 40,
    root: u32 = 40,
    shard_index: u32 = 0,
    shard_count: u32 = 1,
    pc_every: u32 = 10,
    out: []const u8 = "",
    storage: tb.storage.Mode = .mmap_all,
    lengths: bool = false,
    positions: u32 = 2000,
    repeat: u32 = 5,
    fathom_arm: bool = false,
};

fn parseOptions(args: []const []const u8) !Options {
    var o = Options{};
    if (args.len < 1) return error.MissingPaths;
    o.paths = args[0];
    for (args[1..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadOption;
        const k = arg[0..eq];
        const v = arg[eq + 1 ..];
        if (std.mem.eql(u8, k, "seed")) o.seed = try std.fmt.parseInt(u64, v, 0) else if (std.mem.eql(u8, k, "tables")) o.tables = v else if (std.mem.eql(u8, k, "uniform")) o.uniform = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "ep")) o.ep = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "promo")) o.promo = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "diag")) o.diag = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "tie")) o.tie = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "root")) o.root = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "pc_every")) o.pc_every = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "out")) o.out = v else if (std.mem.eql(u8, k, "lengths")) o.lengths = std.mem.eql(u8, v, "1") else if (std.mem.eql(u8, k, "positions")) o.positions = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "repeat")) o.repeat = try std.fmt.parseInt(u32, v, 10) else if (std.mem.eql(u8, k, "shard")) {
            const slash = std.mem.indexOfScalar(u8, v, '/') orelse return error.BadOption;
            o.shard_index = try std.fmt.parseInt(u32, v[0..slash], 10);
            o.shard_count = try std.fmt.parseInt(u32, v[slash + 1 ..], 10);
        } else if (std.mem.eql(u8, k, "arm")) {
            o.fathom_arm = if (std.mem.eql(u8, v, "fathom")) true else if (std.mem.eql(u8, v, "ours")) false else return error.BadOption;
        } else if (std.mem.eql(u8, k, "storage")) {
            o.storage = if (std.mem.eql(u8, v, "mmap")) .mmap_all else if (std.mem.eql(u8, v, "budget")) .mmap_budget else if (std.mem.eql(u8, v, "pread")) .pread else return error.BadOption;
        } else return error.BadOption;
    }
    return o;
}

// ---------------------------------------------------------------------------
// Table naming and selection

fn countsOf(key: tb.types.MaterialKey) [2][5]u8 {
    var c: [2][5]u8 = undefined;
    for (0..2) |side| for (0..5) |t| {
        c[side][t] = @intCast((key >> @intCast(20 * side + 4 * t)) & 0xF);
    };
    return c;
}

fn tableName(key: tb.types.MaterialKey, buf: *[16]u8) []const u8 {
    const c = countsOf(key);
    var n: usize = 0;
    const order = [_]struct { u8, usize }{ .{ 'Q', 4 }, .{ 'R', 3 }, .{ 'B', 2 }, .{ 'N', 1 }, .{ 'P', 0 } };
    for (0..2) |side| {
        if (side == 1) {
            buf[n] = 'v';
            n += 1;
        }
        buf[n] = 'K';
        n += 1;
        for (order) |o| for (0..c[side][o[1]]) |_| {
            buf[n] = o[0];
            n += 1;
        };
    }
    return buf[0..n];
}

fn selected(o: *const Options, name: []const u8, pieces: u8, ordinal: usize) bool {
    if (ordinal % o.shard_count != o.shard_index) return false;
    const t = o.tables;
    if (std.mem.eql(u8, t, "all")) return true;
    if (std.mem.eql(u8, t, "345")) return pieces <= 5;
    if (std.mem.eql(u8, t, "6")) return pieces == 6;
    if (std.mem.startsWith(u8, t, "sample:")) {
        // All of 3-4-5 plus every k-th 6-man table, k = 100 / percent.
        const pct = std.fmt.parseInt(u32, t[7..], 10) catch return false;
        if (pieces <= 5) return true;
        const step = @max(1, 100 / @max(pct, 1));
        var h: u32 = 2166136261;
        for (name) |ch| h = (h ^ ch) *% 16777619;
        return h % step == 0;
    }
    if (std.mem.startsWith(u8, t, "list:")) {
        var it = std.mem.tokenizeScalar(u8, t[5..], ',');
        while (it.next()) |want| if (std.mem.eql(u8, want, name)) return true;
        return false;
    }
    if (std.mem.startsWith(u8, t, "pieces:")) {
        const want = std.fmt.parseInt(u8, t[7..], 10) catch return false;
        return pieces == want;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Position generation (§11.3)

const Stratum = enum { uniform, ep, promo, diag, tie };

const pawn_mask: u64 = 0x00FF_FFFF_FFFF_FF00;
const diag_mask: u64 = 0x8040_2010_0804_0201 | 0x0102_0408_1020_4080;

fn sqOf(file: u8, rank: u8) square.Square {
    return @enumFromInt(rank * 8 + file);
}

fn randomFrom(rnd: std.Random, mask: u64) ?square.Square {
    const n = @popCount(mask);
    if (n == 0) return null;
    var m = mask;
    var k = rnd.uintLessThan(u32, n);
    while (k > 0) : (k -= 1) m &= m - 1;
    return @enumFromInt(@ctz(m));
}

fn kingZone(sq: square.Square) u64 {
    const s = @intFromEnum(sq);
    var z: u64 = 0;
    const f: i32 = s & 7;
    const r: i32 = s >> 3;
    var df: i32 = -1;
    while (df <= 1) : (df += 1) {
        var dr: i32 = -1;
        while (dr <= 1) : (dr += 1) {
            const nf = f + df;
            const nr = r + dr;
            if (nf >= 0 and nf < 8 and nr >= 0 and nr < 8) z |= @as(u64, 1) << @intCast(nr * 8 + nf);
        }
    }
    return z;
}

/// One position of `counts` (position colours) with `stm` to move in the
/// stratum, or null when the material cannot express it.
fn generate(rnd: std.Random, counts: [2][5]u8, stm: Color, stratum: Stratum) ?Position {
    attempt: for (0..200) |_| {
        var pos = Position.empty();
        var left = counts;
        var forbidden: u64 = 0;
        var ep_square: ?square.Square = null;
        const us: usize = @intFromEnum(stm);
        const them = 1 - us;
        switch (stratum) {
            .uniform, .diag => {},
            .ep => {
                if (left[us][0] == 0 or left[them][0] == 0) return null;
                const f: u8 = rnd.uintLessThan(u8, 8);
                const dir: i8 = if (rnd.boolean()) 1 else -1;
                const cf: i16 = @as(i16, f) + dir;
                if (cf < 0 or cf > 7) continue :attempt;
                // White to move: black just played f7-f5; black to move: white f2-f4.
                const pushed_rank: u8 = if (stm == .white) 4 else 3;
                const ep_rank: u8 = if (stm == .white) 5 else 2;
                const origin_rank: u8 = if (stm == .white) 6 else 1;
                pos.setPiece(sqOf(f, pushed_rank), piece_mod.Piece.make(@enumFromInt(them), .pawn));
                pos.setPiece(sqOf(@intCast(cf), pushed_rank), piece_mod.Piece.make(stm, .pawn));
                left[us][0] -= 1;
                left[them][0] -= 1;
                forbidden = (@as(u64, 1) << @intCast(ep_rank * 8 + f)) | (@as(u64, 1) << @intCast(origin_rank * 8 + f));
                ep_square = sqOf(f, ep_rank);
            },
            .promo => {
                if (left[us][0] == 0) return null;
                const rank: u8 = if (stm == .white) 6 else 1;
                pos.setPiece(sqOf(rnd.uintLessThan(u8, 8), rank), piece_mod.Piece.make(stm, .pawn));
                left[us][0] -= 1;
            },
            .tie => {
                const c: usize = if (left[0][0] >= 2 and (left[1][0] < 2 or rnd.boolean())) 0 else if (left[1][0] >= 2) 1 else return null;
                const f: u8 = rnd.uintLessThan(u8, 4);
                const r: u8 = 1 + rnd.uintLessThan(u8, 6);
                pos.setPiece(sqOf(f, r), piece_mod.Piece.make(@enumFromInt(c), .pawn));
                pos.setPiece(sqOf(7 - f, r), piece_mod.Piece.make(@enumFromInt(c), .pawn));
                left[c][0] -= 2;
            },
        }
        const wk = randomFrom(rnd, ~pos.occupied & ~forbidden & placeMask(rnd, stratum, false)) orelse continue :attempt;
        pos.setPiece(wk, .white_king);
        const bk = randomFrom(rnd, ~pos.occupied & ~forbidden & ~kingZone(wk) & placeMask(rnd, stratum, false)) orelse continue :attempt;
        pos.setPiece(bk, .black_king);
        for (0..2) |side| for (0..5) |t| for (0..left[side][t]) |_| {
            const mask = if (t == 0) pawn_mask else placeMask(rnd, stratum, true);
            const sq = randomFrom(rnd, mask & ~pos.occupied & ~forbidden) orelse randomFrom(rnd, (if (t == 0) pawn_mask else ~@as(u64, 0)) & ~pos.occupied & ~forbidden) orelse continue :attempt;
            pos.setPiece(sq, piece_mod.Piece.make(@enumFromInt(side), @enumFromInt(t)));
        };
        pos.side_to_move = stm;
        pos.en_passant = ep_square;
        if (legal.isInCheck(&pos, stm.other())) continue :attempt;
        return pos;
    }
    return null;
}

fn placeMask(rnd: std.Random, stratum: Stratum, _: bool) u64 {
    if (stratum == .diag and rnd.uintLessThan(u8, 10) < 6) return diag_mask;
    return ~@as(u64, 0);
}

// ---------------------------------------------------------------------------
// Output helpers

const Out = struct {
    file: ?std.fs.File = null,
    buf: [64 * 1024]u8 = undefined,
    writer: std.fs.File.Writer = undefined,

    fn open(self: *Out, dir: []const u8, name: []const u8) !void {
        if (dir.len == 0) return;
        var path_buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
        self.file = try std.fs.cwd().createFile(path, .{});
        self.writer = self.file.?.writer(&self.buf);
    }
    fn w(self: *Out) ?*std.Io.Writer {
        return if (self.file != null) &self.writer.interface else null;
    }
    fn close(self: *Out) void {
        if (self.file) |f| {
            self.writer.interface.flush() catch {};
            f.close();
        }
    }
};

fn writeFen(pos: *const Position, writer: *std.Io.Writer) !void {
    try fen.write(pos, writer);
}

// ---------------------------------------------------------------------------
// G1

const TableStats = struct {
    positions: u64 = 0,
    wdl_mismatch: u64 = 0,
    dtz_mismatch: u64 = 0,
    root_checked: u64 = 0,
    root_mismatch: u64 = 0,
    suggest_checked: u64 = 0,
    suggest_mismatch: u64 = 0,
    both_failed: u64 = 0,
    strata: [5]u64 = .{0} ** 5,
    ep_legal: u64 = 0,
    other_side: u64 = 0,
    mate: u64 = 0,
    stalemate: u64 = 0,
    wdl_hist: [5]u64 = .{0} ** 5,
    ns_ours: u64 = 0,
    ns_fathom: u64 = 0,

    fn add(self: *TableStats, o: TableStats) void {
        inline for (std.meta.fields(TableStats)) |f| {
            switch (@typeInfo(f.type)) {
                .array => for (&@field(self, f.name), @field(o, f.name)) |*a, b| {
                    a.* += b;
                },
                else => @field(self, f.name) += @field(o, f.name),
            }
        }
    }
};

const root_clocks = [_]u32{ 0, 1, 2, 50, 98, 99, 100 };

fn G1(comptime B: type) type {
    return struct {
        const P = tb.Prober(B);
        const Snap = P.Snap;

        fn mismatch(out: *Out, kind: []const u8, pos: *const Position, ours: anytype, theirs: anytype) void {
            const w = out.w() orelse return;
            w.print("{s}\t", .{kind}) catch return;
            writeFen(pos, w) catch return;
            w.print("\t{any}\t{any}\n", .{ ours, theirs }) catch return;
        }

        fn compareRoot(snap: *const Snap, pos: *const Position, c: u32, st: *TableStats, out: *Out, pc: ?*std.Io.Writer) void {
            var results: [FATHOM_MAX_MOVES]u32 = @splat(FAILED);
            const t0 = std.time.nanoTimestamp();
            const fres = fathomRoot(pos, c, &results);
            const t1 = std.time.nanoTimestamp();
            var ranking: tb.RootRanking = .{};
            const ok = if (P.rankRoot(snap, pos, c, &ranking)) true else |_| false;
            const t2 = std.time.nanoTimestamp();
            st.ns_fathom += @intCast(t1 - t0);
            st.ns_ours += @intCast(t2 - t1);
            st.root_checked += 1;
            if (fres == FAILED or !ok) {
                if (fres != FAILED or ok) {
                    st.root_mismatch += 1;
                    mismatch(out, "root-fail", pos, ok, fres);
                }
                return;
            }
            const fathom_terminal = fres == TB_RESULT_CHECKMATE or fres == TB_RESULT_STALEMATE;
            if (fathom_terminal or ranking.terminal != .none) {
                const same = (fres == TB_RESULT_CHECKMATE and ranking.terminal == .checkmate) or (fres == TB_RESULT_STALEMATE and ranking.terminal == .stalemate);
                if (!same) {
                    st.root_mismatch += 1;
                    mismatch(out, "root-terminal", pos, @tagName(ranking.terminal), fres);
                }
                return;
            }
            // Root state and |D|.
            if ((fres & 0xF) != stateCode(ranking.root_state) or (fres >> 20) != @min(@abs(ranking.root_dtz.plies), 0xFFF)) {
                st.root_mismatch += 1;
                mismatch(out, "root-value", pos, .{ stateCode(ranking.root_state), ranking.root_dtz.plies }, .{ fres & 0xF, fres >> 20 });
                return;
            }
            // Per-move records as a set keyed by (from, to, promotion).
            var count: usize = 0;
            while (count < results.len and results[count] != FAILED) count += 1;
            var bad = count != ranking.count;
            if (!bad) {
                for (ranking.slice()) |rec| {
                    const key = moveKey(@intFromEnum(rec.move.from), @intFromEnum(rec.move.to), fathomPromo(rec.move));
                    const found = for (results[0..count]) |r| {
                        if (moveKey((r >> 10) & 0x3F, (r >> 4) & 0x3F, (r >> 16) & 7) == key) break r;
                    } else null;
                    const r = found orelse {
                        bad = true;
                        break;
                    };
                    if ((r & 0xF) != stateCode(rec.state) or (r >> 20) != @min(@abs(rec.r), 0xFFF) or ((r >> 19) & 1) != @intFromBool(rec.en_passant)) {
                        bad = true;
                        break;
                    }
                }
            }
            if (bad) {
                st.root_mismatch += 1;
                mismatch(out, "root-records", pos, ranking.count, count);
                return;
            }
            // python-chess row: R, FEN with the root clock, then uci:r per move.
            if (pc) |w| {
                w.writeAll("R\t") catch return;
                writeFen(pos, w) catch return;
                for (ranking.slice(), 0..) |rec, i| {
                    var a: [5]u8 = undefined;
                    w.print("{s}{s}:{d}", .{ if (i == 0) "\t" else " ", rec.move.toUci(&a), rec.r }) catch return;
                }
                w.writeAll("\n") catch return;
            }
            // Suggested move identity whenever D != 0 (Q4: Fathom's order).
            if (ranking.root_dtz.plies != 0) {
                st.suggest_checked += 1;
                const rec = ranking.records[ranking.suggested.?];
                if (moveKey(@intFromEnum(rec.move.from), @intFromEnum(rec.move.to), fathomPromo(rec.move)) != moveKey((fres >> 10) & 0x3F, (fres >> 4) & 0x3F, (fres >> 16) & 7)) {
                    st.suggest_mismatch += 1;
                    var a: [5]u8 = undefined;
                    mismatch(out, "suggest", pos, rec.move.toUci(&a), .{ (fres >> 10) & 0x3F, (fres >> 4) & 0x3F, (fres >> 16) & 7 });
                }
            }
        }

        fn checkPosition(snap: *const Snap, pos: *const Position, st: *TableStats, out: *Out, pc: *Out, root_c: ?u32, pc_row: bool) void {
            st.positions += 1;
            const t0 = std.time.nanoTimestamp();
            const fw = fathomWdl(pos);
            const fres = fathomRoot(pos, 0, null);
            const t1 = std.time.nanoTimestamp();
            const ow = P.wdl(snap, pos);
            const od = P.dtz(snap, pos);
            const t2 = std.time.nanoTimestamp();
            st.ns_fathom += @intCast(t1 - t0);
            st.ns_ours += @intCast(t2 - t1);
            const fd = fathomDtz(fres);
            // WDL
            if (ow) |w| {
                st.wdl_hist[stateCode(w)] += 1;
                if (fw == FAILED or fw != stateCode(w)) {
                    st.wdl_mismatch += 1;
                    mismatch(out, "wdl", pos, w.int(), fw);
                }
            } else |err| {
                if (fw != FAILED) {
                    st.wdl_mismatch += 1;
                    mismatch(out, "wdl", pos, err, fw);
                } else st.both_failed += 1;
            }
            // DTZ
            if (od) |d| {
                if (fd == null or fd.? != d.plies) {
                    st.dtz_mismatch += 1;
                    mismatch(out, "dtz", pos, d.plies, fd);
                }
            } else |err| {
                if (fd != null) {
                    st.dtz_mismatch += 1;
                    mismatch(out, "dtz", pos, err, fd);
                }
            }
            if (fres == TB_RESULT_CHECKMATE) st.mate += 1;
            if (fres == TB_RESULT_STALEMATE) st.stalemate += 1;
            if (P.dtzStoresSideToMove(snap, pos)) |stored| {
                if (!stored) st.other_side += 1;
            } else |_| {}
            if (pos.en_passant != null) {
                var list = move_mod.MoveList.init();
                legal.generate(pos, &list);
                for (list.slice()) |mv| if (mv.flag == .en_passant) {
                    st.ep_legal += 1;
                    break;
                };
            }
            if (root_c) |c| {
                var clocked = pos.*;
                clocked.halfmove_clock = @intCast(c);
                compareRoot(snap, &clocked, c, st, out, if (pc_row) pc.w() else null);
            }
            // python-chess subsample: FEN, our WDL and DTZ.
            if (pc_row) if (pc.w()) |w| {
                w.writeAll("P\t") catch return;
                writeFen(pos, w) catch return;
                if (ow) |x| w.print("\t{d}", .{x.int()}) catch return else |_| w.writeAll("\tE") catch return;
                if (od) |x| w.print("\t{d}\n", .{x.plies}) catch return else |_| w.writeAll("\tE\n") catch return;
            };
        }

        /// Compare named positions (FENs separated by '|' in tables=...).
        fn runFens(o: *const Options, gpa: std.mem.Allocator) !void {
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            var pathz_buf: [4096]u8 = undefined;
            const pathz = try std.fmt.bufPrintZ(&pathz_buf, "{s}", .{o.paths});
            if (!zq_tb_init(pathz.ptr)) return error.FathomInitFailed;
            defer zq_tb_free();
            var st = TableStats{};
            var out = Out{};
            var it = std.mem.tokenizeScalar(u8, o.tables, '|');
            while (it.next()) |text| {
                const pos = try fen.parse(text);
                const before = st.wdl_mismatch + st.dtz_mismatch + st.root_mismatch + st.suggest_mismatch;
                checkPosition(snap, &pos, &st, &out, &out, pos.halfmove_clock, false);
                const ow = P.wdl(snap, &pos) catch null;
                const od = P.dtz(snap, &pos) catch null;
                std.debug.print("{s}: ours wdl={any} dtz={any} fathom wdl={d} dtz={any} {s}\n", .{
                    text,                                                                                                              ow, if (od) |d| d.plies else null, fathomWdl(&pos), fathomDtz(fathomRoot(&pos, 0, null)),
                    if (st.wdl_mismatch + st.dtz_mismatch + st.root_mismatch + st.suggest_mismatch == before) "MATCH" else "MISMATCH",
                });
            }
            if (st.wdl_mismatch + st.dtz_mismatch + st.root_mismatch + st.suggest_mismatch != 0) return error.Mismatch;
        }

        fn run(o: *const Options, gpa: std.mem.Allocator) !void {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_w.interface;
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            var pathz_buf: [4096]u8 = undefined;
            const pathz = try std.fmt.bufPrintZ(&pathz_buf, "{s}", .{o.paths});
            if (!zq_tb_init(pathz.ptr)) return error.FathomInitFailed;
            defer zq_tb_free();
            if (zq_tb_largest() != snap.max_pieces) {
                try stdout.print("{{\"error\":\"largest differs\",\"fathom\":{d},\"ours\":{d}}}\n", .{ zq_tb_largest(), snap.max_pieces });
                try stdout.flush();
                return error.LargestMismatch;
            }
            if (o.out.len != 0) try std.fs.cwd().makePath(o.out);
            var shard_name_buf: [64]u8 = undefined;
            const suffix = try std.fmt.bufPrint(&shard_name_buf, "{d}of{d}", .{ o.shard_index, o.shard_count });
            var out = Out{};
            var pc = Out{};
            var names_buf: [3][96]u8 = undefined;
            try out.open(o.out, try std.fmt.bufPrint(&names_buf[0], "mismatches-{s}.tsv", .{suffix}));
            defer out.close();
            try pc.open(o.out, try std.fmt.bufPrint(&names_buf[1], "pc-sample-{s}.tsv", .{suffix}));
            defer pc.close();
            var tables = Out{};
            try tables.open(o.out, try std.fmt.bufPrint(&names_buf[2], "tables-{s}.jsonl", .{suffix}));
            defer tables.close();

            // Tables in name order for determinism.
            const Item = struct { name: [16]u8, len: u8, key: tb.types.MaterialKey, pieces: u8, entry: *const tb.registry.Entry };
            var items: std.ArrayList(Item) = .empty;
            defer items.deinit(gpa);
            for (snap.entries) |*e| {
                var it = Item{ .name = undefined, .len = 0, .key = e.key, .pieces = e.pieces, .entry = e };
                it.len = @intCast(tableName(e.key, &it.name).len);
                try items.append(gpa, it);
            }
            std.mem.sort(Item, items.items, {}, struct {
                fn lt(_: void, a: Item, b: Item) bool {
                    if (a.pieces != b.pieces) return a.pieces < b.pieces;
                    return std.mem.order(u8, a.name[0..a.len], b.name[0..b.len]) == .lt;
                }
            }.lt);

            var total = TableStats{};
            var row: u64 = 0;
            var timer = try std.time.Timer.start();
            for (items.items, 0..) |it, ordinal| {
                const name = it.name[0..it.len];
                if (!selected(o, name, it.pieces, ordinal)) continue;
                var st = TableStats{};
                const t_start = timer.read();
                var h: u64 = o.seed;
                for (name) |ch| h = (h ^ ch) *% 0x100000001b3;
                var prng = std.Random.DefaultPrng.init(h);
                const rnd = prng.random();
                const base = countsOf(it.key);
                for (0..2) |orient| {
                    const counts = if (orient == 0) base else [2][5]u8{ base[1], base[0] };
                    for ([_]Color{ .white, .black }) |stm| {
                        const plan = [_]struct { Stratum, u32 }{ .{ .uniform, o.uniform }, .{ .ep, o.ep }, .{ .promo, o.promo }, .{ .diag, o.diag }, .{ .tie, o.tie } };
                        var root_left = o.root;
                        for (plan) |p| {
                            for (0..p[1]) |_| {
                                const pos = generate(rnd, counts, stm, p[0]) orelse break;
                                st.strata[@intFromEnum(p[0])] += 1;
                                // Every ep, promotion and pawn-tie root is compared; uniform
                                // and diagonal roots share the `root` budget (review-v1 finding 4).
                                const special = p[0] == .ep or p[0] == .promo or p[0] == .tie;
                                const root_c: ?u32 = if (special) root_clocks[rnd.uintLessThan(usize, root_clocks.len)] else if (root_left > 0 and (p[0] != .uniform or rnd.uintLessThan(u32, 4) == 0)) blk: {
                                    root_left -= 1;
                                    break :blk root_clocks[rnd.uintLessThan(usize, root_clocks.len)];
                                } else null;
                                row += 1;
                                checkPosition(snap, &pos, &st, &out, &pc, root_c, o.pc_every != 0 and row % o.pc_every == 0);
                            }
                        }
                    }
                }
                const ms = (timer.read() - t_start) / std.time.ns_per_ms;
                // Furthest byte read so far in this table's own two files.
                const wdl_file = it.entry.wdl.?.file;
                const dtz_file: ?u32 = if (it.entry.dtz) |d| d.file else null;
                const wdl_end = snap.io.max_end[wdl_file].load(.monotonic);
                const dtz_end = if (dtz_file) |f| snap.io.max_end[f].load(.monotonic) else 0;
                const dtz_size = if (dtz_file) |f| snap.files.sizes[f] else 0;
                if (tables.w()) |w| {
                    try w.print("{{\"table\":\"{s}\",\"ms\":{d},\"positions\":{d},\"wdl_mismatch\":{d},\"dtz_mismatch\":{d},\"root_checked\":{d},\"root_mismatch\":{d},\"suggest_checked\":{d},\"suggest_mismatch\":{d},\"both_failed\":{d},\"strata\":[{d},{d},{d},{d},{d}],\"ep_legal\":{d},\"other_side\":{d},\"mate\":{d},\"stalemate\":{d},\"wdl_hist\":[{d},{d},{d},{d},{d}],\"ns_ours\":{d},\"ns_fathom\":{d},\"wdl_max_end\":{d},\"wdl_size\":{d},\"dtz_max_end\":{d},\"dtz_size\":{d}}}\n", .{
                        name,           ms,             st.positions,   st.wdl_mismatch, st.dtz_mismatch, st.root_checked, st.root_mismatch, st.suggest_checked,         st.suggest_mismatch, st.both_failed,
                        st.strata[0],   st.strata[1],   st.strata[2],   st.strata[3],    st.strata[4],    st.ep_legal,     st.other_side,    st.mate,                    st.stalemate,        st.wdl_hist[0],
                        st.wdl_hist[1], st.wdl_hist[2], st.wdl_hist[3], st.wdl_hist[4],  st.ns_ours,      st.ns_fathom,    wdl_end,          snap.files.sizes[wdl_file], dtz_end,             dtz_size,
                    });
                }
                total.add(st);
                try stdout.print("{s} {d}ms pos={d} mism wdl={d} dtz={d} root={d}/{d} suggest={d}/{d} max_end wdl={d}/{d} dtz={d}/{d}\n", .{ name, ms, st.positions, st.wdl_mismatch, st.dtz_mismatch, st.root_mismatch, st.root_checked, st.suggest_mismatch, st.suggest_checked, wdl_end, snap.files.sizes[wdl_file], dtz_end, dtz_size });
                try stdout.flush();
            }
            try printBeyond2GiB(stdout, snap);
            // How every file this run touched was read (mapped, or positioned reads).
            try stdout.print("io {any}\n", .{snap.ioStats()});
            const s = total;
            try stdout.print("TOTAL ms={d} positions={d} wdl_mismatch={d} dtz_mismatch={d} root_checked={d} root_mismatch={d} suggest_checked={d} suggest_mismatch={d} both_failed={d} strata={any} ep_legal={d} other_side={d} mate={d} stalemate={d} wdl_hist={any} ns_ours={d} ns_fathom={d}\n", .{
                timer.read() / std.time.ns_per_ms, s.positions, s.wdl_mismatch, s.dtz_mismatch, s.root_checked, s.root_mismatch, s.suggest_checked, s.suggest_mismatch, s.both_failed, s.strata, s.ep_legal, s.other_side, s.mate, s.stalemate, s.wdl_hist, s.ns_ours, s.ns_fathom,
            });
            try stdout.flush();
            if (s.wdl_mismatch + s.dtz_mismatch + s.root_mismatch + s.suggest_mismatch != 0) return error.Mismatch;
        }
    };
}

/// Every file larger than 2 GiB with the furthest byte read in it.
fn printBeyond2GiB(stdout: *std.Io.Writer, snap: anytype) !void {
    var large: u32 = 0;
    var crossed: u32 = 0;
    for (snap.files.paths, snap.files.sizes, snap.io.max_end) |path, size, *end| {
        if (size <= two_gib) continue;
        large += 1;
        const e = end.load(.monotonic);
        if (e > two_gib) crossed += 1;
        try stdout.print("large_file {s} size={d} max_end={d} beyond_2gib={}\n", .{ path, size, e, e > two_gib });
    }
    try stdout.print("large_files={d} read_beyond_2gib={d}\n", .{ large, crossed });
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Census (G0 extras: block-length sums, build cost)

fn Census(comptime B: type) type {
    return struct {
        fn run(o: *const Options, gpa: std.mem.Allocator) !void {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_w.interface;
            const rss_before = rssKiB();
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            const rss_after = rssKiB();
            const st = snap.stats;
            try stdout.print("census wdl={d} dtz={d} rejected={d} skipped_large={d} duplicates={d} header_bytes={d} build_ms={d} arena_bytes={d} rss_delta_kib={d} max_pieces={d}\n", .{
                st.wdl_files, st.dtz_files, st.rejected, st.skipped_large, st.duplicates, st.header_bytes, st.nanoseconds / std.time.ns_per_ms, snap.arena.queryCapacity(), rss_after -| rss_before, snap.max_pieces,
            });
            try stdout.flush();
            if (!o.lengths) return;
            var checked: u64 = 0;
            var bad: u64 = 0;
            var buf: [8192]u8 = undefined;
            for (snap.entries) |e| for ([_]?tb.registry.TableRef{ e.wdl, e.dtz }) |maybe| {
                const ref = maybe orelse continue;
                const t = ref.table;
                const subtables: usize = if (t.body == .pawn) 4 else 1;
                for (0..subtables) |ti| for (0..t.sides) |s| {
                    const sub = t.subtable(@intCast(ti), @intCast(s));
                    const c = switch (sub.pairs) {
                        .single => continue,
                        .compressed => |*c| c,
                    };
                    var sum: u64 = 0;
                    var b: u64 = 0;
                    while (b < c.real_blocks) {
                        const n: u64 = @min(c.real_blocks - b, buf.len / 2);
                        const bytes = try snap.io.view(ref.file, c.lengths_off + 2 * b, @intCast(2 * n), &buf);
                        for (0..n) |i| sum += @as(u64, std.mem.readInt(u16, bytes[2 * i ..][0..2], .little)) + 1;
                        b += n;
                    }
                    checked += 1;
                    if (sum != sub.desc.size) {
                        bad += 1;
                        var nb: [16]u8 = undefined;
                        try stdout.print("length-sum mismatch {s} {s} t={d} s={d}: {d} != {d}\n", .{ tableName(e.key, &nb), @tagName(t.metric), ti, s, sum, sub.desc.size });
                    }
                };
            };
            try stdout.print("block-length sums: subtables={d} mismatches={d}\n", .{ checked, bad });
            try stdout.flush();
            if (bad != 0) return error.LengthSumMismatch;
        }
    };
}

fn rssKiB() u64 {
    var buf: [4096]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
    defer f.close();
    const n = f.readAll(&buf) catch return 0;
    const at = std.mem.indexOf(u8, buf[0..n], "VmRSS:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, buf[at + 6 .. n], " \t\n");
    return std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch 0;
}

// ---------------------------------------------------------------------------
// G3 micro-benchmark (prepared; run only when scheduled)

fn wdlSink(r: tb.ProbeError!tb.Wdl5) u64 {
    const w: tb.Wdl5 = r catch return 7;
    return @intCast(@as(i32, w.int()) + 2);
}

fn Bench(comptime B: type) type {
    return struct {
        const P = tb.Prober(B);

        fn run(o: *const Options, gpa: std.mem.Allocator) !void {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_w.interface;
            var pathz_buf: [4096]u8 = undefined;
            const pathz = try std.fmt.bufPrintZ(&pathz_buf, "{s}", .{o.paths});
            var build_timer = try std.time.Timer.start();
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            const build_ns = build_timer.read();
            build_timer.reset();
            if (!zq_tb_init(pathz.ptr)) return error.FathomInitFailed;
            defer zq_tb_free();
            const fathom_init_ns = build_timer.read();
            // Positions: uniform over the selected tables, legal, WDL-probeable.
            var positions: std.ArrayList(Position) = .empty;
            defer positions.deinit(gpa);
            var prng = std.Random.DefaultPrng.init(o.seed);
            const rnd = prng.random();
            var tables: usize = 0;
            for (snap.entries, 0..) |e, ordinal| {
                var nb: [16]u8 = undefined;
                if (!selected(o, tableName(e.key, &nb), e.pieces, ordinal)) continue;
                tables += 1;
            }
            if (tables == 0) return error.NoTables;
            const per = @max(1, o.positions / tables);
            for (snap.entries, 0..) |e, ordinal| {
                var nb: [16]u8 = undefined;
                if (!selected(o, tableName(e.key, &nb), e.pieces, ordinal)) continue;
                for (0..per) |_| {
                    const stm: Color = if (rnd.boolean()) .white else .black;
                    const pos = generate(rnd, countsOf(e.key), stm, .uniform) orelse continue;
                    try positions.append(gpa, pos);
                }
            }
            rnd.shuffle(Position, positions.items);
            const ps = positions.items;
            // First pass ("cold": fresh mappings; the page cache may be warm).
            var sink: u64 = 0;
            var t = try std.time.Timer.start();
            for (ps) |*p| sink +%= wdlSink(P.wdlLegal(snap, p));
            const ours_cold = t.read();
            t.reset();
            for (ps) |*p| sink +%= fathomWdl(p);
            const fathom_cold = t.read();
            // Hot passes, interleaved per repeat.
            var ours_hot: u64 = 0;
            var fathom_hot: u64 = 0;
            for (0..o.repeat) |_| {
                t.reset();
                for (ps) |*p| sink +%= wdlSink(P.wdlLegal(snap, p));
                ours_hot += t.read();
                t.reset();
                for (ps) |*p| sink +%= fathomWdl(p);
                fathom_hot += t.read();
            }
            // Root probes (one pass each).
            var ranking: tb.RootRanking = .{};
            var results: [FATHOM_MAX_MOVES]u32 = undefined;
            const roots = @min(ps.len, 500);
            t.reset();
            for (ps[0..roots]) |*p| sink +%= if (P.rankRoot(snap, p, 0, &ranking)) ranking.count else |_| 0;
            const ours_root = t.read();
            t.reset();
            for (ps[0..roots]) |*p| sink +%= fathomRoot(p, 0, &results);
            const fathom_root = t.read();
            const n = @max(ps.len, 1);
            const reps = @max(o.repeat, 1);
            try stdout.print("bench storage={s} tables={d} positions={d} repeat={d} build_ms={d} fathom_init_ms={d}\n", .{ @tagName(o.storage), tables, ps.len, o.repeat, build_ns / std.time.ns_per_ms, fathom_init_ns / std.time.ns_per_ms });
            try stdout.print("wdl_cold_ns_per_probe ours={d} fathom={d}\n", .{ ours_cold / n, fathom_cold / n });
            try stdout.print("wdl_hot_ns_per_probe ours={d} fathom={d}\n", .{ ours_hot / (n * reps), fathom_hot / (n * reps) });
            try stdout.print("root_ns_per_probe ours={d} fathom={d} roots={d}\n", .{ ours_root / @max(roots, 1), fathom_root / @max(roots, 1), roots });
            try stdout.print("io {any} sink={d}\n", .{ snap.ioStats(), sink });
            try stdout.flush();
        }
    };
}

// ---------------------------------------------------------------------------
// G3 cold-mapping tail latency (prepared; design note §6 item 4). One prober
// per process (`arm=`), so the other prober's mappings cannot warm the cache.
// Per selected table, in name order: evict the table's WDL file from the page
// cache (posix_fadvise DONTNEED, Linux), then time the first WDL probe of a
// random position of that table, the probe search threads make. It maps the
// file (mapping modes) or opens it (Pread) and faults in cold pages: latency a
// search thread cannot answer `stop` in. Captures may also touch smaller,
// already warm tables, alike for both arms.

fn evict(path: [:0]const u8) bool {
    if (comptime @import("builtin").os.tag != .linux) return false;
    const file = std.fs.cwd().openFileZ(path, .{}) catch return false;
    defer file.close();
    return std.os.linux.fadvise(file.handle, 0, 0, std.os.linux.POSIX_FADV.DONTNEED) == 0;
}

fn Tail(comptime B: type) type {
    return struct {
        const P = tb.Prober(B);

        fn run(o: *const Options, gpa: std.mem.Allocator) !void {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_w.interface;
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            var pathz_buf: [4096]u8 = undefined;
            const pathz = try std.fmt.bufPrintZ(&pathz_buf, "{s}", .{o.paths});
            if (o.fathom_arm and !zq_tb_init(pathz.ptr)) return error.FathomInitFailed;
            defer if (o.fathom_arm) zq_tb_free();
            var samples: std.ArrayList(u64) = .empty;
            defer samples.deinit(gpa);
            var prng = std.Random.DefaultPrng.init(o.seed);
            const rnd = prng.random();
            var evicted_all = true;
            var sink: u64 = 0;
            for (snap.entries, 0..) |*e, ordinal| {
                var nb: [16]u8 = undefined;
                const name = tableName(e.key, &nb);
                if (!selected(o, name, e.pieces, ordinal)) continue;
                const stm: Color = if (rnd.boolean()) .white else .black;
                const pos = generate(rnd, countsOf(e.key), stm, .uniform) orelse continue;
                const wdl = e.wdl orelse continue;
                evicted_all = evict(snap.files.paths[wdl.file]) and evicted_all;
                var t = try std.time.Timer.start();
                sink +%= if (o.fathom_arm) fathomWdl(&pos) else wdlSink(P.wdlLegal(snap, &pos));
                const ns = t.read();
                try samples.append(gpa, ns);
                try stdout.print("tail table={s} ns={d}\n", .{ name, ns });
            }
            std.mem.sort(u64, samples.items, {}, std.sort.asc(u64));
            const n = samples.items.len;
            if (n == 0) return error.NoTables;
            const pct = struct {
                fn at(xs: []const u64, q: u64) u64 {
                    return xs[@min(xs.len - 1, (xs.len * q) / 100)];
                }
            };
            try stdout.print("tail_summary arm={s} storage={s} tables={d} evicted={} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d} io={any} sink={d}\n", .{
                if (o.fathom_arm) "fathom" else "ours", @tagName(o.storage), n, evicted_all, pct.at(samples.items, 50), pct.at(samples.items, 90), pct.at(samples.items, 99), samples.items[n - 1], snap.ioStats(), sink,
            });
            try stdout.flush();
        }
    };
}

// ---------------------------------------------------------------------------
// G4 tool-level walk: probe every table under the active backend (run it under
// an RLIMIT_AS) and report errors by kind plus mapping statistics.

fn Walk(comptime B: type) type {
    return struct {
        const P = tb.Prober(B);

        fn run(o: *const Options, gpa: std.mem.Allocator) !void {
            var stdout_buf: [8192]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_w.interface;
            const snap = try tb.registry.build(B, gpa, o.paths, .{});
            defer snap.destroy();
            var prng = std.Random.DefaultPrng.init(o.seed);
            const rnd = prng.random();
            var probes: u64 = 0;
            var errors = [_]u64{0} ** 4;
            var tables: u64 = 0;
            var timer = try std.time.Timer.start();
            for (snap.entries, 0..) |e, ordinal| {
                var nb: [16]u8 = undefined;
                if (!selected(o, tableName(e.key, &nb), e.pieces, ordinal)) continue;
                tables += 1;
                const base = countsOf(e.key);
                for (0..o.positions) |i| {
                    const counts = if (i % 2 == 0) base else [2][5]u8{ base[1], base[0] };
                    const stm: Color = if (i % 4 < 2) .white else .black;
                    const pos = generate(rnd, counts, stm, .uniform) orelse continue;
                    inline for (0..2) |which| {
                        probes += 1;
                        const r = if (which == 0) (if (P.wdl(snap, &pos)) |_| {} else |err| err) else (if (P.dtz(snap, &pos)) |_| {} else |err| err);
                        r catch |err| {
                            errors[
                                switch (err) {
                                    error.OutOfScope => 0,
                                    error.MissingTable => 1,
                                    error.CorruptTable => 2,
                                    error.Io => 3,
                                }
                            ] += 1;
                        };
                    }
                }
            }
            const io = snap.ioStats();
            const budget: u64 = if (@hasField(B, "budget")) snap.io.budget else 0;
            try stdout.print("walk storage={s} tables={d} probes={d} errors(out_of_scope,missing,corrupt,io)=[{d},{d},{d},{d}] mapped_files={d} mapped_bytes={d} pread_files={d} map_failures={d} budget={d} ms={d}\n", .{
                @tagName(o.storage), tables, probes, errors[0], errors[1], errors[2], errors[3], io.mapped_files, io.mapped_bytes, io.pread_files, io.map_failures, budget, timer.read() / std.time.ns_per_ms,
            });
            try stdout.flush();
            for (errors) |n| if (n != 0) return error.ProbeErrors;
        }
    };
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) {
        std.debug.print("usage: zigqueen-tb-oracle census|g1|bench <paths> [key=value...]\n", .{});
        return error.Usage;
    }
    const o = try parseOptions(args[2..]);
    const cmd = args[1];
    switch (o.storage) {
        inline else => |mode| {
            const B = tb.storage.Backend(mode);
            if (std.mem.eql(u8, cmd, "census")) return Census(B).run(&o, gpa);
            if (std.mem.eql(u8, cmd, "g1")) return G1(Tracked(B)).run(&o, gpa);
            if (std.mem.eql(u8, cmd, "bench")) return Bench(B).run(&o, gpa);
            if (std.mem.eql(u8, cmd, "walk")) return Walk(B).run(&o, gpa);
            if (std.mem.eql(u8, cmd, "fens")) return G1(Tracked(B)).runFens(&o, gpa);
            if (std.mem.eql(u8, cmd, "tail")) return Tail(B).run(&o, gpa);
        },
    }
    return error.Usage;
}
