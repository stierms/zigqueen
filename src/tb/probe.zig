//! WDL, DTZ and root ranking over our Position and move generator
//! (docs/SYZYGY_FORMAT.md §5, §7-§9). Pure functions of (snapshot, position):
//! no global state, no locks, no heap. Move lists are fixed-capacity locals.
const std = @import("std");
const types = @import("types.zig");
const index = @import("index.zig");
const format = @import("format.zig");
const decode = @import("decode.zig");
const registry = @import("registry.zig");
const position = @import("../core/position.zig");
const move_mod = @import("../core/move.zig");
const piece = @import("../core/piece.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");

const Position = position.Position;
const Move = move_mod.Move;
const MoveList = move_mod.MoveList;
const ProbeError = types.ProbeError;
const Wdl5 = types.Wdl5;
const Dtz = types.Dtz;

const rank_1_8: u64 = 0xFF00_0000_0000_00FF;

/// Result of the full WDL (§7.3): the value and whether a zeroing move
/// achieves it.
const Full = struct {
    value: i8,
    zeroing: bool,
};

inline fn play(pos: *const Position, mv: Move) Position {
    var next = pos.*;
    var state: make_unmake.StateInfo = undefined;
    _ = make_unmake.makeMove(&next, mv, &state);
    return next;
}

inline fn isZeroing(pos: *const Position, mv: Move) bool {
    return mv.isCapture() or pos.pieceAt(mv.from).pieceType() == .pawn;
}

fn isMate(pos: *const Position) bool {
    if (!legal.isInCheck(pos, pos.side_to_move)) return false;
    var list = MoveList.init();
    legal.generate(pos, &list);
    return list.count == 0;
}

/// One move of the §8.3 loss search: the most negative value is the longest
/// resistance. A rounded candidate may be one ply longer than its value
/// (§6.5), so a tie with one leaves the result inexact; the first tied
/// candidate's exactness no longer decides (review round, Opus F-1).
fn foldLossCandidate(best: *i32, exact: *bool, v: i32, v_exact: bool) void {
    if (v < best.*) {
        best.* = v;
        exact.* = v_exact;
    } else if (v == best.* and !v_exact) {
        exact.* = false;
    }
}

/// Precondition of every public probe (§7.4).
fn checkScope(max_pieces: u8, pos: *const Position) ProbeError!void {
    if (pos.castling_rights.hasAny()) return error.OutOfScope;
    if (@popCount(pos.occupied) > max_pieces) return error.OutOfScope;
    if (@popCount(pos.pieces[0][5]) != 1 or @popCount(pos.pieces[1][5]) != 1) return error.OutOfScope;
    if ((pos.pieces[0][0] | pos.pieces[1][0]) & rank_1_8 != 0) return error.OutOfScope;
    if (legal.isInCheck(pos, pos.side_to_move.other())) return error.OutOfScope;
}

/// Fathom's move-generation order as a sort key (§9.3, Q4): king, queen, rook,
/// bishop, knight, pawn; origin ascending; a pawn's en-passant capture first;
/// destination ascending; promotions Q, N, R, B.
pub fn fathomOrderKey(pos: *const Position, mv: Move) u32 {
    const kind: u32 = switch (pos.pieceAt(mv.from).pieceType()) {
        .king => 0,
        .queen => 1,
        .rook => 2,
        .bishop => 3,
        .knight => 4,
        .pawn => 5,
        .none => 6,
    };
    const promo: u32 = if (mv.promotionPieceType()) |p| switch (p) {
        .queen => 0,
        .knight => 1,
        .rook => 2,
        .bishop => 3,
        else => 4,
    } else 0;
    const not_ep: u32 = @intFromBool(mv.flag != .en_passant);
    return (kind << 20) | (@as(u32, @intFromEnum(mv.from)) << 12) | (not_ep << 11) | (@as(u32, @intFromEnum(mv.to)) << 4) | promo;
}

pub fn Prober(comptime Backend: type) type {
    return struct {
        pub const Snap = registry.Snapshot(Backend);

        // -------------------------------------------------------------------
        // Public entry points

        /// Full WDL of `pos` (§7.3), as if the 50-move counter were 0.
        pub fn wdl(snap: *const Snap, pos: *const Position) ProbeError!Wdl5 {
            try checkScope(snap.max_pieces, pos);
            return Wdl5.fromInt((try wdlFull(snap, pos)).value);
        }

        /// Search entry: `pos` was reached by legal moves, so only the cheap
        /// scope checks run (castling, piece count, no pawn on rank 1 or 8,
        /// which a malformed GUI FEN can bring into the search and which no
        /// index may see). Same values as `wdl`.
        pub fn wdlLegal(snap: *const Snap, pos: *const Position) ProbeError!Wdl5 {
            if (pos.castling_rights.hasAny() or @popCount(pos.occupied) > snap.max_pieces) return error.OutOfScope;
            if ((pos.pieces[0][0] | pos.pieces[1][0]) & rank_1_8 != 0) return error.OutOfScope;
            return Wdl5.fromInt((try wdlFull(snap, pos)).value);
        }

        /// DTZ of `pos` (§8.2).
        pub fn dtz(snap: *const Snap, pos: *const Position) ProbeError!Dtz {
            try checkScope(snap.max_pieces, pos);
            return dtzFull(snap, pos, 0);
        }

        /// Root records for every legal move under root counter `c` (§9).
        pub fn rankRoot(snap: *const Snap, pos: *const Position, c: u32, out: *types.RootRanking) ProbeError!void {
            try checkScope(snap.max_pieces, pos);
            out.count = 0;
            out.suggested = null;
            out.terminal = .none;
            const root = try dtzFull(snap, pos, 0);
            out.root_dtz = root;
            out.root_state = types.rootState(root.plies, c);
            var list = MoveList.init();
            legal.generate(pos, &list);
            if (list.count == 0) {
                out.terminal = if (legal.isInCheck(pos, pos.side_to_move)) .checkmate else .stalemate;
                return;
            }
            for (list.slice()) |mv| {
                const child = play(pos, mv);
                const zeroing = isZeroing(pos, mv);
                var r: i32 = undefined;
                var exact = true;
                if (root.plies > 0 and isMate(&child)) {
                    r = 1;
                } else if (zeroing) {
                    const w = -(try wdlFull(snap, &child)).value;
                    r = switch (w) {
                        2 => 1,
                        1 => 101,
                        0 => 0,
                        -1 => -101,
                        else => -1,
                    };
                } else {
                    const d = try dtzFull(snap, &child, 0);
                    const v = -d.plies;
                    r = v + std.math.sign(v);
                    exact = d.exact;
                }
                out.records[out.count] = .{
                    .move = mv,
                    .r = r,
                    .state = types.rootState(r, c),
                    .exact = exact,
                    .zeroing = zeroing,
                    .en_passant = mv.flag == .en_passant,
                };
                out.count += 1;
            }
            out.suggested = suggest(pos, out);
        }

        /// Whether the DTZ file stores the side to move of `pos` (§5.1 step 5).
        /// Bookkeeping for the oracle's "other side stored" stratum.
        pub fn dtzStoresSideToMove(snap: *const Snap, pos: *const Position) ProbeError!bool {
            const hit = snap.find(types.materialKeyOf(pos)) orelse return error.MissingTable;
            const ref = hit.entry.dtz orelse return error.MissingTable;
            const loc = try locate(ref, hit.mirrored, pos);
            if (ref.table.symmetric and ref.table.body == .piece) return true;
            return (loc.sub.flags & format.DtzFlag.stored_side) == loc.side;
        }

        /// §9.3 item 4: D > 0 the smallest positive r, D < 0 the most negative
        /// r, ties to the first move in Fathom's generation order. For a draw
        /// we take the first drawing move in that order (Fathom's own choice
        /// there is pseudo-random and deliberately not replicated).
        fn suggest(pos: *const Position, out: *const types.RootRanking) ?u16 {
            const d = out.root_dtz.plies;
            var best: ?u16 = null;
            for (out.slice(), 0..) |rec, i| {
                const ok = if (d > 0) rec.r > 0 else if (d < 0) true else rec.r == 0;
                if (!ok) continue;
                if (best) |b| {
                    const cur = out.records[b];
                    const better = if (d > 0) rec.r < cur.r else if (d < 0) rec.r < cur.r else false;
                    const tie = rec.r == cur.r;
                    if (!better and !(tie and fathomOrderKey(pos, rec.move) < fathomOrderKey(pos, cur.move))) continue;
                }
                best = @intCast(i);
            }
            return best;
        }

        // -------------------------------------------------------------------
        // WDL (§7)

        /// Value of a position without en-passant rights, with alpha-beta
        /// pruning of the capture recursion (§7.2). Exact inside (alpha, beta).
        fn probeAb(snap: *const Snap, pos: *const Position, alpha_in: i8, beta: i8) ProbeError!i8 {
            var alpha = alpha_in;
            var list = MoveList.init();
            legal.generateCapturesAndPromotions(pos, &list);
            for (list.slice()) |mv| {
                if (!mv.isCapture()) continue;
                const child = play(pos, mv);
                const v = -(try probeAb(snap, &child, -beta, -alpha));
                if (v > alpha) {
                    if (v >= beta) return v;
                    alpha = v;
                }
            }
            const v = try tableWdl(snap, pos);
            return @max(alpha, v);
        }

        /// The full WDL (§7.3), the only entry point that may see en passant.
        fn wdlFull(snap: *const Snap, pos: *const Position) ProbeError!Full {
            var list = MoveList.init();
            legal.generateCapturesAndPromotions(pos, &list);
            var best_capture: i8 = -3;
            var best_ep: i8 = -3;
            for (list.slice()) |mv| {
                if (!mv.isCapture()) continue;
                const child = play(pos, mv);
                const ep = mv.flag == .en_passant;
                const alpha = if (ep) best_ep else best_capture;
                const v = -(try probeAb(snap, &child, -2, -alpha));
                if (v == 2) return .{ .value = 2, .zeroing = true };
                if (v > alpha) {
                    if (ep) best_ep = v else best_capture = v;
                }
            }
            const v = try tableWdl(snap, pos);
            if (best_ep > best_capture) {
                if (best_ep > v) return .{ .value = best_ep, .zeroing = true };
                best_capture = best_ep;
            }
            if (best_capture >= v) return .{ .value = best_capture, .zeroing = best_capture > 0 };
            if (best_ep > -3 and v == 0 and !legal.isInCheck(pos, pos.side_to_move)) {
                // Stalemate exception: the only legal moves are ep captures.
                var all = MoveList.init();
                legal.generate(pos, &all);
                var only_ep = true;
                for (all.slice()) |mv| only_ep = only_ep and mv.flag == .en_passant;
                if (only_ep) return .{ .value = best_ep, .zeroing = true };
            }
            return .{ .value = v, .zeroing = false };
        }

        // -------------------------------------------------------------------
        // DTZ (§8)

        fn dtzFull(snap: *const Snap, pos: *const Position, depth: u8) ProbeError!Dtz {
            const w = try wdlFull(snap, pos);
            if (w.value == 0) return .{ .plies = 0, .exact = true };
            if (w.zeroing) return .{ .plies = zeroingDtz(w.value), .exact = true };
            var list = MoveList.init();
            legal.generate(pos, &list);
            if (w.value > 0) {
                for (list.slice()) |mv| {
                    if (mv.isCapture() or pos.pieceAt(mv.from).pieceType() != .pawn) continue;
                    const child = play(pos, mv);
                    if (-(try wdlFull(snap, &child)).value == w.value) return .{ .plies = zeroingDtz(w.value), .exact = true };
                }
            }
            if (try tableDtz(snap, pos, w.value)) |d| return d;
            // The DTZ file stores the other side to move: one-ply search over
            // the non-zeroing moves, whose children use the stored side (§8.3).
            if (depth != 0) return error.CorruptTable;
            if (w.value > 0) {
                var best: i32 = std.math.maxInt(i32);
                var exact = true;
                for (list.slice()) |mv| {
                    if (isZeroing(pos, mv)) continue;
                    const child = play(pos, mv);
                    const d = try dtzFull(snap, &child, depth + 1);
                    const v = -d.plies;
                    if (v == 1 and isMate(&child)) return .{ .plies = 1, .exact = true };
                    if (v > 0 and v + 1 < best) {
                        best = v + 1;
                        exact = d.exact;
                    }
                }
                if (best == std.math.maxInt(i32)) return error.CorruptTable;
                return .{ .plies = best, .exact = exact };
            }
            var best: i32 = if (w.value == -2) -1 else -101;
            var exact = true;
            for (list.slice()) |mv| {
                if (isZeroing(pos, mv)) continue;
                const child = play(pos, mv);
                const d = try dtzFull(snap, &child, depth + 1);
                foldLossCandidate(&best, &exact, -d.plies - 1, d.exact);
            }
            return .{ .plies = best, .exact = exact };
        }

        inline fn zeroingDtz(w: i8) i32 {
            return switch (w) {
                2 => 1,
                1 => 101,
                -1 => -101,
                else => -1,
            };
        }

        // -------------------------------------------------------------------
        // Table access (§5, §6)

        const Located = struct {
            sub: *const format.Subtable,
            index: u64,
            /// Side index s of §3.4.
            side: u1,
        };

        /// Squares of every piece from descriptor slot `start` on, in list
        /// order (§5.2), in the file frame.
        fn fillSquares(d: *const index.Descriptor, pos: *const Position, flip: bool, pawnful: bool, p: *index.Squares, start: u8) ProbeError!void {
            var i = start;
            while (i < d.n) {
                const code = d.codes[i];
                const colour = (code >> 3) ^ @intFromBool(flip);
                var bb = pos.pieces[colour][(code & 7) - 1];
                while (bb != 0) {
                    if (i >= d.n) return error.CorruptTable;
                    var sq: u8 = @ctz(bb);
                    bb &= bb - 1;
                    if (flip and pawnful) sq ^= 56;
                    p[i] = sq;
                    i += 1;
                }
                if (i < d.n and d.codes[i] == code) return error.CorruptTable;
            }
        }

        fn locate(ref: registry.TableRef, mirrored_hit: bool, pos: *const Position) ProbeError!Located {
            const table = ref.table;
            const black = pos.side_to_move == .black;
            const flip = if (table.symmetric) black else mirrored_hit != ref.frame_mirrored;
            const side: u1 = @intFromBool(black != flip);
            var p: index.Squares = undefined;
            switch (table.body) {
                .piece => {
                    const sub = table.subtable(0, side);
                    try fillSquares(&sub.desc, pos, flip, false, &p, 0);
                    const idx = try index.encodePieceless(&sub.desc, &p);
                    if (idx >= sub.desc.size) return error.CorruptTable;
                    return .{ .sub = sub, .index = idx, .side = side };
                },
                .pawn => |*pt| {
                    const colour = pt.lead_colour ^ @intFromBool(flip);
                    var bb = pos.pieces[colour][0];
                    var leads: [index.max_lead + 1]u8 = undefined;
                    var k: usize = 0;
                    while (bb != 0) : (k += 1) {
                        if (k > index.max_lead) return error.CorruptTable;
                        var sq: u8 = @ctz(bb);
                        bb &= bb - 1;
                        if (flip) sq ^= 56;
                        leads[k] = sq;
                    }
                    if (k == 0) return error.CorruptTable;
                    const leader = index.leaderOf(leads[0..k]);
                    const sub = table.subtable(index.pawnFile(leads[leader]), side);
                    if (sub.desc.lead_len != k) return error.CorruptTable;
                    p[0] = leads[leader];
                    var j: usize = 1;
                    for (leads[0..k], 0..) |sq, i| {
                        if (i == leader) continue;
                        p[j] = sq;
                        j += 1;
                    }
                    try fillSquares(&sub.desc, pos, flip, true, &p, @intCast(k));
                    const idx = index.encodePawnful(&sub.desc, &p);
                    if (idx >= sub.desc.size) return error.CorruptTable;
                    return .{ .sub = sub, .index = idx, .side = side };
                },
            }
        }

        fn rawValue(snap: *const Snap, ref: registry.TableRef, loc: Located) ProbeError!u16 {
            return switch (loc.sub.pairs) {
                .single => |v| v,
                .compressed => |*c| decode.valueAt(&snap.io, ref.file, c, loc.index),
            };
        }

        /// Stored WDL of a position without en-passant rights (§6.5).
        fn tableWdl(snap: *const Snap, pos: *const Position) ProbeError!i8 {
            if (@popCount(pos.occupied) == 2) return 0;
            const hit = snap.find(types.materialKeyOf(pos)) orelse return error.MissingTable;
            const ref = hit.entry.wdl orelse return error.MissingTable;
            const loc = try locate(ref, hit.mirrored, pos);
            const raw = try rawValue(snap, ref, loc);
            if (raw > 4) return error.CorruptTable;
            return @as(i8, @intCast(raw)) - 2;
        }

        /// DTZ from the table when it stores this side to move (§8.2 step 4),
        /// null when it stores the other side.
        fn tableDtz(snap: *const Snap, pos: *const Position, w: i8) ProbeError!?Dtz {
            const hit = snap.find(types.materialKeyOf(pos)) orelse return error.MissingTable;
            const ref = hit.entry.dtz orelse return error.MissingTable;
            const loc = try locate(ref, hit.mirrored, pos);
            const sub = loc.sub;
            const flags = sub.flags;
            // §10 item 2: symmetric pawnless tables are never checked.
            const unchecked = ref.table.symmetric and ref.table.body == .piece;
            if (!unchecked and (flags & format.DtzFlag.stored_side) != loc.side) return null;
            var x: u32 = switch (sub.pairs) {
                .single => 0, // §10 item 1
                .compressed => |*c| try decode.valueAt(&snap.io, ref.file, c, loc.index),
            };
            if (flags & format.DtzFlag.mapped != 0) {
                const map = sub.maps[
                    switch (w) {
                        2 => 0,
                        -2 => 1,
                        1 => 2,
                        else => 3,
                    }
                ];
                if (x >= map.len) return error.CorruptTable;
                x = map[x];
            }
            const plies_stored = (w == 2 and flags & format.DtzFlag.win_plies != 0) or (w == -2 and flags & format.DtzFlag.loss_plies != 0);
            if (!plies_stored) x *= 2;
            const magnitude: i32 = @intCast(x);
            const plies: i32 = switch (w) {
                2 => 1 + magnitude,
                -2 => -(1 + magnitude),
                1 => 101 + magnitude,
                else => -(101 + magnitude),
            };
            return .{ .plies = plies, .exact = plies_stored };
        }
    };
}

test "fathom order key ranks pieces, origins, ep and promotions" {
    const fen = @import("../core/fen.zig");
    const pos = try fen.parse("7k/P7/8/3pP3/8/8/8/K6R w - d6 0 1");
    const king = Move.init(.a1, .b1, .quiet);
    const rook = Move.init(.h1, .h2, .quiet);
    const ep = Move.init(.e5, .d6, .en_passant);
    const push = Move.init(.e5, .e6, .quiet);
    const promo_q = Move.init(.a7, .a8, .promo_queen);
    const promo_n = Move.init(.a7, .a8, .promo_knight);
    const promo_b = Move.init(.a7, .a8, .promo_bishop);
    try std.testing.expect(fathomOrderKey(&pos, king) < fathomOrderKey(&pos, rook));
    try std.testing.expect(fathomOrderKey(&pos, rook) < fathomOrderKey(&pos, promo_q));
    try std.testing.expect(fathomOrderKey(&pos, promo_q) < fathomOrderKey(&pos, promo_n));
    try std.testing.expect(fathomOrderKey(&pos, promo_n) < fathomOrderKey(&pos, promo_b));
    try std.testing.expect(fathomOrderKey(&pos, ep) < fathomOrderKey(&pos, push));
}

test "the loss search's result is inexact when a rounded candidate ties the longest resistance" {
    // Review round (Opus F-1): an exact d = 1 and a rounded d = 1 (stored 0,
    // true 1 or 2) both give -2; the first kept exact = true although the
    // true value may be -3.
    var best: i32 = -1;
    var exact = true;
    foldLossCandidate(&best, &exact, -2, true);
    foldLossCandidate(&best, &exact, -2, false);
    try std.testing.expectEqual(@as(i32, -2), best);
    try std.testing.expect(!exact);
    // Either order.
    best = -1;
    exact = true;
    foldLossCandidate(&best, &exact, -2, false);
    foldLossCandidate(&best, &exact, -2, true);
    try std.testing.expect(!exact);
    // A rounded candidate one ply shorter cannot pass the exact longest one.
    best = -1;
    exact = true;
    foldLossCandidate(&best, &exact, -3, true);
    foldLossCandidate(&best, &exact, -2, false);
    try std.testing.expectEqual(@as(i32, -3), best);
    try std.testing.expect(exact);
    // A strictly longer exact candidate replaces a rounded one.
    foldLossCandidate(&best, &exact, -4, false);
    foldLossCandidate(&best, &exact, -5, true);
    try std.testing.expectEqual(@as(i32, -5), best);
    try std.testing.expect(exact);
}

test "search probe refuses pawns on the back ranks (illegal FEN, review finding 1)" {
    const fen = @import("../core/fen.zig");
    const storage = @import("storage.zig");
    const B = storage.Pread;
    // No tables are needed: the guard must reject before any table access.
    const snap = try registry.build(B, std.testing.allocator, "", .{});
    defer snap.destroy();
    snap.max_pieces = 5;
    for ([_][]const u8{
        "PP6/8/8/8/8/8/1r6/K6k w - - 0 1", // the reproducer: index 255 out of bounds
        "8/8/8/8/8/8/1r6/K5pk b - - 0 1",
    }) |text| {
        const pos = try fen.parse(text);
        try std.testing.expectError(error.OutOfScope, Prober(B).wdlLegal(snap, &pos));
        try std.testing.expectError(error.OutOfScope, Prober(B).wdl(snap, &pos));
    }
}
