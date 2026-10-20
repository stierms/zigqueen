//! G0 tests that need installed tables (docs/SYZYGY_FORMAT.md §11.2). They are
//! opt-in: set ZQ_TB_CENSUS_PATH to a path list such as
//! `/path/to/syzygy/3-4-5:/path/to/syzygy/6`.
//! Without it they skip.
const std = @import("std");
const types = @import("types.zig");
const index = @import("index.zig");
const format = @import("format.zig");
const storage = @import("storage.zig");
const registry = @import("registry.zig");
const probe = @import("probe.zig");
const fen = @import("../core/fen.zig");
const position = @import("../core/position.zig");

const census_env = "ZQ_TB_CENSUS_PATH";

fn censusPath(a: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(a, census_env) catch return error.SkipZigTest;
}

fn hasSix(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/6") != null;
}

test "G0 census: every installed file parses and its headers check out" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    const snap = try registry.build(storage.Pread, a, path, .{});
    defer snap.destroy();
    const st = snap.stats;
    std.debug.print("\nG0 census: wdl={d} dtz={d} rejected={d} skipped_large={d} duplicates={d} header_bytes={d} build_ms={d}\n", .{
        st.wdl_files, st.dtz_files, st.rejected, st.skipped_large, st.duplicates, st.header_bytes, st.nanoseconds / std.time.ns_per_ms,
    });
    try std.testing.expectEqual(@as(u32, 0), st.rejected);
    try std.testing.expectEqual(st.wdl_files, st.dtz_files);
    try std.testing.expect(st.wdl_files >= 145);
    if (hasSix(path)) try std.testing.expectEqual(@as(u32, 510), st.wdl_files);
    var single_dtz: usize = 0;
    var symmetric_dtz: usize = 0;
    for (snap.entries) |e| {
        try std.testing.expect(e.wdl != null and e.dtz != null);
        for ([_]?registry.TableRef{ e.wdl, e.dtz }) |maybe| {
            const ref = maybe.?;
            const t = ref.table;
            // Header and name agree (§1.2): the frame is the name orientation.
            try std.testing.expect(!ref.frame_mirrored);
            try std.testing.expectEqual(e.pieces, t.pieces);
            const tables: usize = if (t.body == .pawn) 4 else 1;
            for (0..tables) |ti| for (0..t.sides) |s| {
                const sub = t.subtable(@intCast(ti), @intCast(s));
                if (t.metric == .dtz) {
                    if (sub.pairs == .single) {
                        // §10 item 1: every local single-valued DTZ subtable stores 0.
                        try std.testing.expectEqual(@as(u8, 0), sub.pairs.single);
                        try std.testing.expectEqual(@as(u8, 0x80), sub.flags);
                        single_dtz += 1;
                    }
                    if (t.symmetric) {
                        // §10 item 2: symmetric DTZ subtables store side 0.
                        try std.testing.expectEqual(@as(u8, 0), sub.flags & format.DtzFlag.stored_side);
                        symmetric_dtz += 1;
                    }
                    try std.testing.expectEqual(@as(u8, 0), sub.flags & format.DtzFlag.wide);
                }
            };
        }
    }
    std.debug.print("G0 census: single-valued DTZ subtables={d} symmetric DTZ subtables={d}\n", .{ single_dtz, symmetric_dtz });
}

const Vector = struct {
    fen: []const u8,
    wdl: i8,
    dtz: i32,
    six: bool = false,
};

/// Appendix A of docs/SYZYGY_FORMAT.md (final WDL and DTZ columns), plus the
/// §7.3 stalemate exception (checked against python-chess, 2026-10-14).
const vectors = [_]Vector{
    .{ .fen = "8/8/8/8/8/8/8/R3K2k w - - 0 1", .wdl = 2, .dtz = 5 },
    .{ .fen = "8/8/8/8/8/8/8/R3K2k b - - 0 1", .wdl = -2, .dtz = -10 },
    .{ .fen = "8/8/8/4k3/8/8/2Q4r/K7 w - - 0 1", .wdl = 2, .dtz = 1 },
    .{ .fen = "7k/8/8/8/3K4/8/8/R6R b - - 0 1", .wdl = -2, .dtz = -6 },
    .{ .fen = "8/8/8/8/8/8/5P2/K6k w - - 0 1", .wdl = 2, .dtz = 1 },
    .{ .fen = "8/8/2p5/8/8/5P2/8/K6k b - - 0 1", .wdl = -2, .dtz = -1 },
    .{ .fen = "7k/8/8/8/3B4/8/1K6/N7 b - - 0 1", .wdl = -2, .dtz = -49 },
    .{ .fen = "8/8/8/8/1p6/8/P7/K1k5 w - - 0 1", .wdl = -2, .dtz = -1 },
    .{ .fen = "8/2k3K1/8/8/3b4/2n5/1R6/7B w - - 0 1", .wdl = 1, .dtz = 125, .six = true },
    .{ .fen = "7b/3P4/2B2K2/8/N4k2/8/8/8 w - - 0 1", .wdl = 2, .dtz = 3, .six = true },
    .{ .fen = "8/8/4P3/8/1p1K4/8/2k4r/R7 w - - 0 1", .wdl = 2, .dtz = 3, .six = true },
    // §7.3 step 5, the stalemate exception: the only legal move is a losing
    // en-passant capture; without the ep right the position is stalemate.
    .{ .fen = "k7/8/4p3/3pP3/8/8/5q2/7K w - d6 0 1", .wdl = -2, .dtz = -1, .six = true },
    .{ .fen = "k7/8/4p3/3pP3/8/8/5q2/7K w - - 0 1", .wdl = 0, .dtz = 0, .six = true },
};

fn checkVectors(comptime B: type, path: []const u8) !void {
    const a = std.testing.allocator;
    const snap = try registry.build(B, a, path, .{});
    defer snap.destroy();
    const P = probe.Prober(B);
    for (vectors) |v| {
        if (v.six and !hasSix(path)) continue;
        const pos = try fen.parse(v.fen);
        const w = try P.wdl(snap, &pos);
        const d = try P.dtz(snap, &pos);
        if (w.int() != v.wdl or d.plies != v.dtz) {
            std.debug.print("vector mismatch {s}: wdl {d} (want {d}) dtz {d} (want {d})\n", .{ v.fen, w.int(), v.wdl, d.plies, v.dtz });
            return error.VectorMismatch;
        }
    }
}

test "G0 Appendix A vectors on every storage backend" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    try checkVectors(storage.MmapAll, path);
    try checkVectors(storage.MmapBudget, path);
    try checkVectors(storage.Pread, path);
}

test "G0 probes refuse out-of-scope positions and missing tables as errors" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    const snap = try registry.build(storage.Pread, a, path, .{});
    defer snap.destroy();
    const P = probe.Prober(storage.Pread);
    const castle = try fen.parse("4k3/8/8/8/8/8/8/4K2R w K - 0 1");
    try std.testing.expectError(error.OutOfScope, P.wdl(snap, &castle));
    const start = try fen.parse(fen.STARTPOS_FEN);
    try std.testing.expectError(error.OutOfScope, P.wdl(snap, &start));
    const kvk = try fen.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    try std.testing.expectEqual(types.Wdl5.draw, try P.wdl(snap, &kvk));
    // Review finding 1: the search entry read out of bounds on back-rank pawns.
    const back_rank = try fen.parse("PP6/8/8/8/8/8/1r6/K6k w - - 0 1");
    try std.testing.expectError(error.OutOfScope, P.wdlLegal(snap, &back_rank));
    try std.testing.expectError(error.OutOfScope, P.wdl(snap, &back_rank));
    // A snapshot of the 3-4-5 directory alone lacks every 6-man file.
    var only345 = std.mem.tokenizeScalar(u8, path, registry.path_separator);
    const first = only345.next() orelse return;
    const small = try registry.build(storage.Pread, a, first, .{});
    defer small.destroy();
    if (small.max_pieces == 5) {
        const six = try fen.parse("8/2k3K1/8/8/3b4/2n5/1R6/7B w - - 0 1");
        try std.testing.expectError(error.OutOfScope, P.wdl(small, &six));
    }
}

test "table file names match case-insensitively on Windows only" {
    // NTFS ignores case and Fathom finds e.g. KQVK.RTBW there; Linux is exact.
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    var dirs = std.mem.tokenizeScalar(u8, path, registry.path_separator);
    const first = dirs.next() orelse return error.SkipZigTest;
    var src = try std.fs.cwd().openDir(first, .{});
    defer src.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try src.copyFile("KQvK.rtbw", tmp.dir, "kqVk.RTBW", .{});
    try src.copyFile("KQvK.rtbz", tmp.dir, "KQVK.rtbZ", .{});
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const snap = try registry.build(storage.Pread, a, dir, .{});
    defer snap.destroy();
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 0), snap.stats.wdl_files + snap.stats.dtz_files);
        return;
    }
    try std.testing.expectEqual(@as(u32, 1), snap.stats.wdl_files);
    try std.testing.expectEqual(@as(u32, 1), snap.stats.dtz_files);
    const P = probe.Prober(storage.Pread);
    const kqvk = try fen.parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1");
    try std.testing.expectEqual(types.Wdl5.win, try P.wdl(snap, &kqvk));
    try std.testing.expect((try P.dtz(snap, &kqvk)).plies > 0);
}

// ---------------------------------------------------------------------------
// Index self-tests over real descriptors (§11.2)

const Sym = enum { id, flip_file, flip_rank, rot180, transpose, anti, rot90, rot270 };

fn applySym(sq: u8, s: Sym) u8 {
    const t = (sq >> 3) | ((sq & 7) << 3);
    return switch (s) {
        .id => sq,
        .flip_file => sq ^ 7,
        .flip_rank => sq ^ 56,
        .rot180 => sq ^ 63,
        .transpose => t,
        .anti => t ^ 63,
        .rot90 => t ^ 7,
        .rot270 => t ^ 56,
    };
}

fn adjacent(a: u8, b: u8) bool {
    const df = @as(i16, a & 7) - (b & 7);
    const dr = @as(i16, a >> 3) - (b >> 3);
    return @abs(df) <= 1 and @abs(dr) <= 1;
}

/// Every placement of a 3-piece pawnless descriptor: index in range, invariant
/// under the 8 board symmetries, and positions sharing an index are images.
fn exhaustivePieceless(d: *const index.Descriptor, a: std.mem.Allocator) !void {
    const seen = try a.alloc(u32, @intCast(d.size));
    defer a.free(seen);
    @memset(seen, std.math.maxInt(u32));
    for (0..64) |x| for (0..64) |y| for (0..64) |z| {
        const sq = [3]u8{ @intCast(x), @intCast(y), @intCast(z) };
        if (sq[0] == sq[1] or sq[0] == sq[2] or sq[1] == sq[2]) continue;
        // The two kings (codes 6 and 14) must not touch.
        var kings: [2]u8 = undefined;
        var nk: usize = 0;
        for (0..3) |i| if (d.codes[i] & 7 == 6) {
            kings[nk] = sq[i];
            nk += 1;
        };
        if (nk == 2 and adjacent(kings[0], kings[1])) continue;
        var canonical: u32 = std.math.maxInt(u32);
        var first: ?u64 = null;
        for (std.enums.values(Sym)) |s| {
            var p: index.Squares = undefined;
            for (0..3) |i| p[i] = applySym(sq[i], s);
            const code = @as(u32, applySym(sq[0], s)) << 12 | @as(u32, applySym(sq[1], s)) << 6 | applySym(sq[2], s);
            canonical = @min(canonical, code);
            const idx = try index.encodePieceless(d, &p);
            try std.testing.expect(idx < d.size);
            if (first) |f| try std.testing.expectEqual(f, idx) else first = idx;
        }
        const slot = &seen[@intCast(first.?)];
        if (slot.* == std.math.maxInt(u32)) slot.* = canonical else try std.testing.expectEqual(slot.*, canonical);
    };
}

test "G0 index self-test: all 3-piece pawnless tables, every placement" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    const snap = try registry.build(storage.Pread, a, path, .{});
    defer snap.destroy();
    var tested: usize = 0;
    for (snap.entries) |e| {
        if (e.pieces != 3) continue;
        for ([_]?registry.TableRef{ e.wdl, e.dtz }) |maybe| {
            const t = maybe.?.table;
            if (t.body != .piece) continue;
            for (0..t.sides) |s| {
                try exhaustivePieceless(&t.subtable(0, @intCast(s)).desc, a);
                tested += 1;
            }
        }
    }
    try std.testing.expect(tested >= 8);
}

test "G0 index self-test: 4-piece pawnless symmetry and pawnful file mirror (sampled)" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    const snap = try registry.build(storage.Pread, a, path, .{});
    defer snap.destroy();
    var prng = std.Random.DefaultPrng.init(0x5eed_7ab1e);
    const rnd = prng.random();
    var residual: usize = 0;
    var ties: usize = 0;
    defer std.debug.print("\nG0 4-piece: residual diagonal transposes {d}, skipped leading-pawn ties {d}\n", .{ residual, ties });
    for (snap.entries) |e| {
        if (e.pieces != 4) continue;
        const t = e.wdl.?.table;
        for (0..t.sides) |s| {
            var samples: usize = 0;
            while (samples < 2000) {
                if (t.body == .piece) {
                    const d = &t.subtable(0, @intCast(s)).desc;
                    var sq: [4]u8 = undefined;
                    for (&sq) |*x| x.* = rnd.uintLessThan(u8, 64);
                    if (!distinct(&sq) or kingsTouch(d, &sq)) continue;
                    // Images share one index, except that a leading group lying
                    // wholly on the a1-h8 diagonal leaves the transpose
                    // unnormalised (§5.4), so at most two indices then occur.
                    var first: ?u64 = null;
                    for (std.enums.values(Sym)) |sym| {
                        var p: index.Squares = undefined;
                        for (0..4) |i| p[i] = applySym(sq[i], sym);
                        const idx = try index.encodePieceless(d, &p);
                        try std.testing.expect(idx < d.size);
                        if (first) |f| {
                            if (f != idx) {
                                for (p[0..d.lead_len]) |x| try std.testing.expectEqual(x & 7, x >> 3);
                                residual += 1;
                            }
                        } else first = idx;
                    }
                } else {
                    // Pawns on ranks 2-7; leader chosen per §5.3 on both mirrors.
                    var sq: [4]u8 = undefined;
                    for (&sq) |*x| x.* = rnd.uintLessThan(u8, 64);
                    if (!distinct(&sq)) continue;
                    var ok = true;
                    for (0..4) |i| if (t.subtable(0, @intCast(s)).desc.codes[i] & 7 == 1 and (sq[i] < 8 or sq[i] >= 56)) {
                        ok = false;
                    };
                    if (!ok) continue;
                    // Leading pawns on mirror files of one rank keep a residual
                    // file symmetry (§5.3 breaks the tie towards files a-d).
                    if (leadTie(t.subtable(0, @intCast(s)).desc.lead_len, &sq)) {
                        ties += 1;
                        continue;
                    }
                    var results: [2]u64 = undefined;
                    for ([_]u8{ 0, 7 }, 0..) |m, which| {
                        var mirrored: [4]u8 = undefined;
                        for (0..4) |i| mirrored[i] = sq[i] ^ m;
                        results[which] = try pawnfulIndex(t, @intCast(s), &mirrored);
                    }
                    try std.testing.expectEqual(results[0], results[1]);
                }
                samples += 1;
            }
        }
    }
}

fn leadTie(k: u8, sq: []const u8) bool {
    for (sq[0..k], 0..) |x, i| for (sq[i + 1 .. k]) |y| {
        if (x >> 3 == y >> 3 and (x & 7) == 7 - (y & 7)) return true;
    };
    return false;
}

fn kingsTouch(d: *const index.Descriptor, sq: []const u8) bool {
    var kings: [2]u8 = undefined;
    var n: usize = 0;
    for (sq, 0..) |x, i| if (d.codes[i] & 7 == 6) {
        kings[n] = x;
        n += 1;
    };
    return n == 2 and adjacent(kings[0], kings[1]);
}

fn distinct(sq: []const u8) bool {
    for (sq, 0..) |x, i| for (sq[i + 1 ..]) |y| if (x == y) return false;
    return true;
}

/// `sq[i]` is the square of the piece with code `d0.codes[i]` of file 0's
/// descriptor. Each file's descriptor may list the non-leading codes in its
/// own order, so squares are matched by code.
fn pawnfulIndex(t: *const format.Table, s: u1, sq: []const u8) !u64 {
    const d0 = &t.subtable(0, s).desc;
    const k = d0.lead_len;
    const leader = index.leaderOf(sq[0..k]);
    const d = &t.subtable(index.pawnFile(sq[leader]), s).desc;
    var p: index.Squares = undefined;
    p[0] = sq[leader];
    var j: usize = 1;
    for (0..k) |i| if (i != leader) {
        p[j] = sq[i];
        j += 1;
    };
    var used = [_]bool{false} ** index.max_pieces;
    for (k..d.n) |i| {
        const slot = for (k..d0.n) |m| {
            if (!used[m] and d0.codes[m] == d.codes[i]) break m;
        } else return error.DescriptorMismatch;
        used[slot] = true;
        p[i] = sq[slot];
    }
    const idx = index.encodePawnful(d, &p);
    try std.testing.expect(idx < d.size);
    return idx;
}

test "G0 colour-mirrored twins probe identically (sampled, real tables)" {
    const a = std.testing.allocator;
    const path = try censusPath(a);
    defer a.free(path);
    const snap = try registry.build(storage.MmapAll, a, path, .{});
    defer snap.destroy();
    const P = probe.Prober(storage.MmapAll);
    const fens = [_][]const u8{
        "8/8/8/8/8/8/8/R3K2k w - - 0 1",
        "8/8/8/4k3/8/8/2Q4r/K7 w - - 0 1",
        "8/8/2p5/8/8/5P2/8/K6k b - - 0 1",
        "8/8/8/8/1p6/8/P7/K1k5 w - - 0 1",
        "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "7k/P7/2K5/8/8/8/8/8 w - - 0 1",
    };
    for (fens) |text| {
        const pos = try fen.parse(text);
        const twin = mirrorColours(&pos);
        try std.testing.expectEqual(try P.wdl(snap, &pos), try P.wdl(snap, &twin));
        try std.testing.expectEqual((try P.dtz(snap, &pos)).plies, (try P.dtz(snap, &twin)).plies);
    }
}

/// Colour-mirrored twin: swap colours, mirror ranks (and the ep square), swap
/// the side to move.
pub fn mirrorColours(pos: *const position.Position) position.Position {
    var out = position.Position.empty();
    for (0..64) |i| {
        const p = pos.mailbox[i];
        if (p == .none) continue;
        const flipped = @import("../core/piece.zig").Piece.make(p.color().?.other(), p.pieceType());
        out.setPiece(@enumFromInt(i ^ 56), flipped);
    }
    out.side_to_move = pos.side_to_move.other();
    out.en_passant = if (pos.en_passant) |ep| @enumFromInt(@intFromEnum(ep) ^ 56) else null;
    out.halfmove_clock = pos.halfmove_clock;
    out.fullmove_number = pos.fullmove_number;
    return out;
}
