const std = @import("std");
const engine_mod = @import("../search/engine.zig");
const score_mod = @import("../search/score.zig");
const search_info = @import("../search/search_info.zig");
const pv_mod = @import("../search/pv.zig");
const move_mod = @import("../core/move.zig");

// 192 bytes cover all fixed fields at their integer widths. Reserve a maximum
// five-character promotion plus a separator for every PV move and the root.
const LINE_CAPACITY = 1024;
comptime {
    std.debug.assert(LINE_CAPACITY >= 192 + 6 * (pv_mod.MAX_PV + 1));
}

/// Stream one `info depth ...` line. Used for every per-iteration line, the
/// aspiration-fail `lowerbound`/`upperbound` partials, and the final line.
/// Format locally first: one sink call holds the output lock for the whole line.
pub fn writeIterationLine(output: anytype, it: search_info.IterationInfo) !void {
    if (it.pv.len > pv_mod.MAX_PV) return error.PvTooLong;
    var buffer: [LINE_CAPACITY]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try formatIterationLine(&line, it);
    try output.writeAll(line.buffered());
}

fn formatIterationLine(output: anytype, it: search_info.IterationInfo) !void {
    const nps = computeNps(it.nodes, it.time_ms);

    try output.print("info depth {d} seldepth {d}", .{ it.depth, it.seldepth });
    try writeScore(output, it.score, it.bound);
    try output.print(" nodes {d} time {d} nps {d} hashfull {d}", .{ it.nodes, it.time_ms, nps, it.hashfull });
    if (it.best_move) |best_move| {
        try output.writeAll(" pv ");
        try best_move.writeUci(output);
        if (it.pv.len != 0 and it.pv[0] == best_move) {
            for (it.pv[1..]) |mv| {
                try output.writeByte(' ');
                try mv.writeUci(output);
            }
        }
    }
    try output.writeAll("\n");
}

/// `info depth ... currmove ... currmovenumber ...` search-progress line.
pub fn writeCurrMoveLine(output: anytype, cm: search_info.CurrMoveInfo) !void {
    var buffer: [128]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.print("info depth {d} currmove ", .{cm.depth});
    try cm.move.writeUci(&line);
    try line.print(" currmovenumber {d} time {d}\n", .{ cm.move_number, cm.time_ms });
    try output.writeAll(line.buffered());
}

pub fn writeBestMoveLine(output: anytype, mv: ?move_mod.Move) !void {
    var buffer: [16]u8 = undefined;
    var line = std.Io.Writer.fixed(&buffer);
    try line.writeAll("bestmove ");
    if (mv) |move| try move.writeUci(&line) else try line.writeAll("0000");
    try line.writeByte('\n');
    try output.writeAll(line.buffered());
}

pub fn writeFinalLine(
    output: anytype,
    result: *const engine_mod.SearchResult,
    depth: u16,
    elapsed_ms: u64,
    hashfull: u16,
) !void {
    try writeIterationLine(output, .{
        .depth = depth,
        .seldepth = @max(depth, result.seldepth),
        .score = result.score,
        .bound = .exact,
        .nodes = result.nodes,
        .time_ms = elapsed_ms,
        .hashfull = hashfull,
        .best_move = result.best_move,
        .pv = result.pv.slice(),
    });
}

pub fn computeNps(nodes: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0) return 0;
    return @intCast((@as(u128, nodes) * std.time.ms_per_s) / elapsed_ms);
}

fn writeScore(output: anytype, score: i32, bound: search_info.ScoreBound) !void {
    if (score_mod.isMateLike(score)) {
        try output.print(" score mate {d}", .{score_mod.scoreToMate(score)});
    } else {
        try output.print(" score cp {d}", .{score});
    }
    switch (bound) {
        .exact => {},
        .lower => try output.writeAll(" lowerbound"),
        .upper => try output.writeAll(" upperbound"),
    }
}

test "info formatting uses mate scores when appropriate" {
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    var result = engine_mod.SearchResult{
        .best_move = move_mod.Move.init(.f7, .g7, .quiet),
        .score = 28_999,
        .depth = 1,
        .seldepth = 1,
        .nodes = 66,
    };
    result.pv.push(result.best_move.?);

    try writeFinalLine(&sink.writer, &result, 1, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "score mate 1") != null);
}

// Supports the legacy fragment API too, so this contract test can be applied
// unchanged to the parent implementation and fail at its first partial write.
const CompleteLineSink = struct {
    buffer: [1024]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        try std.testing.expect(bytes.len != 0 and bytes[bytes.len - 1] == '\n');
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\n"));
        try std.testing.expect(bytes.len <= self.buffer.len);
        @memcpy(self.buffer[0..bytes.len], bytes);
        self.len = bytes.len;
        self.calls += 1;
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        var buffer: [256]u8 = undefined;
        try self.writeAll(try std.fmt.bufPrint(&buffer, fmt, args));
    }

    pub fn writeByte(self: *@This(), byte: u8) !void {
        try self.writeAll(&.{byte});
    }
};

test "UCI iteration sink receives exactly one complete line" {
    var sink = CompleteLineSink{};
    const mv = move_mod.Move.init(.e2, .e4, .quiet);
    try writeIterationLine(&sink, .{
        .depth = 8,
        .seldepth = 9,
        .score = -42,
        .nodes = 123,
        .time_ms = 1000,
        .hashfull = 12,
        .best_move = mv,
        .pv = &.{mv},
    });
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqualStrings("info depth 8 seldepth 9 score cp -42 nodes 123 time 1000 nps 123 hashfull 12 pv e2e4\n", sink.buffer[0..sink.len]);
}

test "UCI complete lines preserve bounds mate promotion and null formatting" {
    const promo = move_mod.Move.init(.a7, .a8, .promo_queen);
    const reply = move_mod.Move.init(.e8, .d7, .quiet);
    const cases = .{
        .{ @as(i32, -42), search_info.ScoreBound.exact, "cp -42" },
        .{ @as(i32, 42), search_info.ScoreBound.lower, "cp 42 lowerbound" },
        .{ @as(i32, -42), search_info.ScoreBound.upper, "cp -42 upperbound" },
        .{ @as(i32, 28_999), search_info.ScoreBound.exact, "mate 1" },
        .{ @as(i32, -28_997), search_info.ScoreBound.upper, "mate -2 upperbound" },
    };
    inline for (cases) |case| {
        var sink = CompleteLineSink{};
        try writeIterationLine(&sink, .{
            .depth = 8,
            .seldepth = 9,
            .score = case[0],
            .bound = case[1],
            .nodes = 123,
            .time_ms = 1000,
            .hashfull = 12,
            .best_move = promo,
            .pv = &.{ promo, reply },
        });
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqualStrings("info depth 8 seldepth 9 score " ++ case[2] ++ " nodes 123 time 1000 nps 123 hashfull 12 pv a7a8q e8d7\n", sink.buffer[0..sink.len]);
    }
    var sink = CompleteLineSink{};
    try writeCurrMoveLine(&sink, .{ .depth = 8, .move = promo, .move_number = 1, .time_ms = 3000 });
    try std.testing.expectEqualStrings("info depth 8 currmove a7a8q currmovenumber 1 time 3000\n", sink.buffer[0..sink.len]);
    try writeBestMoveLine(&sink, promo);
    try std.testing.expectEqualStrings("bestmove a7a8q\n", sink.buffer[0..sink.len]);
    try writeBestMoveLine(&sink, null);
    try std.testing.expectEqualStrings("bestmove 0000\n", sink.buffer[0..sink.len]);
    try writeIterationLine(&sink, .{
        .depth = 0,
        .seldepth = 0,
        .score = 0,
        .nodes = 0,
        .time_ms = 0,
        .hashfull = 0,
        .best_move = null,
        .pv = &.{},
    });
    try std.testing.expectEqualStrings("info depth 0 seldepth 0 score cp 0 nodes 0 time 0 nps 0 hashfull 0\n", sink.buffer[0..sink.len]);
    try std.testing.expectEqual(@as(usize, 4), sink.calls);
}

test "UCI line buffer covers full PV and maximum field widths" {
    const promo = move_mod.Move.init(.a7, .a8, .promo_queen);
    const moves = [_]move_mod.Move{promo} ** pv_mod.MAX_PV;
    var sink = CompleteLineSink{};
    try writeIterationLine(&sink, .{
        .depth = std.math.maxInt(u16),
        .seldepth = std.math.maxInt(u16),
        .score = -28_871,
        .bound = .upper,
        .nodes = std.math.maxInt(u64),
        .time_ms = std.math.maxInt(u64),
        .hashfull = std.math.maxInt(u16),
        .best_move = promo,
        .pv = &moves,
    });
    const expected = "info depth 65535 seldepth 65535 score cp -28871 upperbound nodes 18446744073709551615 time 18446744073709551615 nps 1000 hashfull 65535 pv " ++
        ("a7a8q " ** (pv_mod.MAX_PV - 1)) ++ "a7a8q\n";
    try std.testing.expectEqualStrings(expected, sink.buffer[0..sink.len]);
    try writeCurrMoveLine(&sink, .{
        .depth = std.math.maxInt(u16),
        .move = promo,
        .move_number = std.math.maxInt(u16),
        .time_ms = std.math.maxInt(u64),
    });
    try std.testing.expectEqualStrings("info depth 65535 currmove a7a8q currmovenumber 65535 time 18446744073709551615\n", sink.buffer[0..sink.len]);
}

test "UCI formatting failure publishes no partial line and sink errors propagate" {
    const mv = move_mod.Move.init(.e2, .e4, .quiet);
    const oversized = [_]move_mod.Move{mv} ** (pv_mod.MAX_PV + 1);
    var sink = CompleteLineSink{};
    try std.testing.expectError(error.PvTooLong, writeIterationLine(&sink, .{
        .depth = 1,
        .seldepth = 1,
        .score = 0,
        .nodes = 1,
        .time_ms = 1,
        .hashfull = 0,
        .best_move = mv,
        .pv = &oversized,
    }));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    const FailingSink = struct {
        pub fn writeAll(_: @This(), _: []const u8) error{BrokenPipe}!void {
            return error.BrokenPipe;
        }
    };
    try std.testing.expectError(error.BrokenPipe, writeBestMoveLine(FailingSink{}, mv));
}
