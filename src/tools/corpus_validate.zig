const std = @import("std");
const corpus = @import("../tuning/corpus.zig");
const fen = @import("../core/fen.zig");

pub fn run(writer: anytype, path: []const u8, validation_permille: u16, test_permille: u16, seed: u64, split_mode: corpus.SplitMode) !void {
    try corpus.validateSplitPermille(validation_permille, test_permille);

    const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 << 20);
    defer std.heap.page_allocator.free(data);

    var line_number: usize = 0;
    var positions: usize = 0;
    var white_wins: usize = 0;
    var draws: usize = 0;
    var black_wins: usize = 0;
    var unknown_results: usize = 0;
    var train_positions: usize = 0;
    var validation_positions: usize = 0;
    var test_positions: usize = 0;
    var search_labeled_positions: usize = 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if ((positions & 1023) == 0) _ = arena.reset(.retain_capacity);
        const record = corpus.parseLine(arena.allocator(), line) catch |err| {
            std.debug.print("corpus validation failed at line {d}: {s}\n", .{ line_number, @errorName(err) });
            return err;
        };
        _ = fen.parseNoHash(record.fen) catch |err| {
            std.debug.print("invalid FEN at line {d}: {s}\n", .{ line_number, @errorName(err) });
            return err;
        };

        positions += 1;
        switch (record.result) {
            .white_win => white_wins += 1,
            .draw => draws += 1,
            .black_win => black_wins += 1,
            .unknown => unknown_results += 1,
        }
        if (record.search_white_pov_total != null) search_labeled_positions += 1;
        switch (corpus.assignSplit(record, validation_permille, test_permille, seed, split_mode)) {
            .train => train_positions += 1,
            .validation => validation_positions += 1,
            .@"test" => test_positions += 1,
        }
    }

    try writer.print("schema {s}\n", .{corpus.schema_name});
    try writer.print("path {s}\n", .{path});
    try writer.print("positions {d}\n", .{positions});
    try writer.print("white_wins {d}\n", .{white_wins});
    try writer.print("draws {d}\n", .{draws});
    try writer.print("black_wins {d}\n", .{black_wins});
    try writer.print("unknown_results {d}\n", .{unknown_results});
    try writer.print("search_labeled_positions {d}\n", .{search_labeled_positions});
    try writer.print("validation_permille {d}\n", .{validation_permille});
    try writer.print("test_permille {d}\n", .{test_permille});
    try writer.print("seed {d}\n", .{seed});
    try writer.print("split_mode {s}\n", .{split_mode.text()});
    try writer.print("train_positions {d}\n", .{train_positions});
    try writer.print("validation_positions {d}\n", .{validation_positions});
    try writer.print("test_positions {d}\n", .{test_positions});
}

test "corpus validator summarizes a small corpus" {
    const temp_name = "zigqueen-corpus-validate-test.jsonl";
    const content =
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 w - - 0 1","result":"1/2-1/2"}
        \\
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 b - - 0 1","result":"0-1"}
        \\
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 w - - 0 1","result":"result_unknown","search_white_pov_total":12}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_name, .data = content });
    defer std.fs.cwd().deleteFile(temp_name) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, temp_name, corpus.default_validation_permille, corpus.default_test_permille, corpus.default_split_seed, .fen);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "positions 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "draws 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "black_wins 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "unknown_results 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "search_labeled_positions 1") != null);
}
