//! Debug dump for NNUE inference validation. For each FEN (one per line in
//! `fen_file`) prints `eval;white_acc_csv;black_acc_csv`, where `eval` is the
//! engine eval at scale_percent=100 and the accumulators are the RAW i16 HalfKA
//! feature-transformer output (pre-activation) only. For a HalfKA-only net a
//! numpy reference can recompute the output stage from that accumulator and the
//! net file. For nets with threat inputs or a PSQT head (the deployed ZQB9
//! among them) `eval` also depends on the threat rows and the PSQT value, which
//! are not dumped, so these rows do not suffice to reconstruct it.
const std = @import("std");
const nnue = @import("../eval/nnue768.zig");
const fen = @import("../core/fen.zig");

pub fn run(out: *std.io.Writer, net_path: ?[]const u8, fen_file: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const net = if (net_path) |p| try nnue.loadFile(allocator, p) else try nnue.loadDefault(allocator);
    defer net.destroy(allocator);
    const h = net.hidden;

    const data = try std.fs.cwd().readFileAlloc(allocator, fen_file, 16 * 1024 * 1024);
    defer allocator.free(data);

    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const pos = fen.parse(line) catch continue;
        // Skipped like a malformed row (Position.hasBackRankPawn).
        if (pos.hasBackRankPawn()) continue;
        var acc: nnue.Accumulator = undefined;
        acc.refresh(net, &pos);
        // evaluate() dispatches to the threats refresh for ZQB5; for other nets it is
        // refresh + evaluateAcc (identical to the local acc above). The CSV dump is
        // the accumulator as maintained: HalfKA rows, plus the threat rows that
        // ZQB5 and ZQB9/ZQBA nets add into the same halves (debug-only).
        const eval = nnue.evaluate(net, &pos, 100);
        try out.print("{d};", .{eval});
        for (acc.white[0..h], 0..) |v, i| {
            if (i != 0) try out.writeByte(',');
            try out.print("{d}", .{v});
        }
        try out.writeByte(';');
        for (acc.black[0..h], 0..) |v, i| {
            if (i != 0) try out.writeByte(',');
            try out.print("{d}", .{v});
        }
        try out.writeByte('\n');
    }
    try out.flush();
}
