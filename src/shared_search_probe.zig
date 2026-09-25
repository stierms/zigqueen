//! Fixed-work serial/shared integration probe, not a multiworker engine.
const std = @import("std");
const engine_mod = @import("search/engine.zig");
const shared = @import("search/shared_tt.zig");
const fen_mod = @import("core/fen.zig");
const repetition = @import("search/repetition.zig");
const limits = @import("search/time.zig");
const syzygy = @import("search/syzygy.zig");

const fens = [_][]const u8{
    fen_mod.STARTPOS_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    "8/8/8/2k5/2p5/2K5/8/8 w - - 0 1",
    "4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1",
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.UsageSerialSharedOrCompare;
    const compare = std.mem.eql(u8, args[1], "compare");
    const use_shared = std.mem.eql(u8, args[1], "shared");
    if (!compare and !use_shared and !std.mem.eql(u8, args[1], "serial")) return error.InvalidMode;
    const hash: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 64;
    const nodes: u64 = if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 100000;
    const reps: u32 = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 1;
    if (args.len > 5 and !syzygy.init(args[5])) return error.TablebaseInitFailed;
    defer syzygy.disable();
    var engine = try engine_mod.Engine.init(allocator, hash);
    defer engine.deinit();
    var table = try shared.SharedTable.init(allocator, hash);
    defer table.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const history = repetition.History{};
    std.debug.print("capacity serial_entries={d} shared_entries={d} serial_bytes={d} shared_bytes={d}\n", .{
        engine.tt.entryCount(), table.entryCount(), engine.tt.entries.len * @sizeOf(@import("search/tt.zig").Cluster), table.allocatedBytes(),
    });
    if (compare and engine.tt.entryCount() != table.entryCount()) return error.CapacityMismatch;
    for (0..reps) |rep| {
        for (fens, 0..) |fen, i| {
            const pos = try fen_mod.parse(fen);
            const limit = limits.Limits{ .node_limit = nodes };
            engine.reset();
            try table.clear();
            var view = try table.beginSearch();
            defer table.endSearch();
            const result = if (use_shared)
                engine.searchWithSharedTable(&pos, &history, limit, &stop, null, &view)
            else
                engine.search(&pos, &history, limit, &stop);
            const actual_nodes = engine.ctx.nodes;
            const hashfull = if (use_shared) view.hashfullPermille() else engine.tt.hashfullPermille();
            if (compare) {
                engine.reset();
                const actual = engine.searchWithSharedTable(&pos, &history, limit, &stop, null, &view);
                try std.testing.expectEqual(actual_nodes, engine.ctx.nodes);
                try std.testing.expectEqual(hashfull, view.hashfullPermille());
                try std.testing.expectEqual(result.best_move, actual.best_move);
                try std.testing.expectEqual(result.score, actual.score);
                try std.testing.expectEqual(result.depth, actual.depth);
                try std.testing.expectEqual(result.seldepth, actual.seldepth);
                try std.testing.expectEqual(result.nodes, actual.nodes);
                try std.testing.expectEqualSlices(@import("core/move.zig").Move, result.pv.slice(), actual.pv.slice());
                try std.testing.expectEqual(result.diagnostics.trace_len, actual.diagnostics.trace_len);
                for (result.diagnostics.trace[0..result.diagnostics.trace_len], actual.diagnostics.trace[0..actual.diagnostics.trace_len]) |a, b| {
                    try std.testing.expectEqual(a.depth, b.depth);
                    try std.testing.expectEqual(a.seldepth, b.seldepth);
                    try std.testing.expectEqual(a.score, b.score);
                    try std.testing.expectEqual(a.nodes, b.nodes);
                    try std.testing.expectEqual(a.best_move, b.best_move);
                    try std.testing.expectEqualDeep(a.root_order, b.root_order);
                    try std.testing.expectEqualSlices(@import("core/move.zig").Move, a.pv.slice(), b.pv.slice());
                }
            }
            std.debug.print("rep={d} case={d} score={d} depth={d} seldepth={d} nodes={d} move={d} pv=", .{
                rep,                                                              i, result.score, result.depth, result.seldepth, result.nodes,
                if (result.best_move) |m| @as(u16, @bitCast(m)) else @as(u16, 0),
            });
            for (result.pv.slice()) |m| std.debug.print("{d},", .{@as(u16, @bitCast(m))});
            std.debug.print("\n", .{});
        }
    }
    if (compare) std.debug.print("SHARED_SEARCH_PARITY_PASS\n", .{});
}

test {
    _ = @import("search/shared_tt.zig");
}
