const std = @import("std");
const corpus = @import("../tuning/corpus.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const time = @import("../search/time.zig");
const types = @import("../core/types.zig");

const SearchBudget = union(enum) {
    depth: u16,
    node_limit: u64,
};

pub fn run(
    writer: anytype,
    path: []const u8,
    depth: u16,
    hash_mb: u32,
    eval_options: search_engine.EvalOptions,
    emit_header: bool,
) !void {
    if (depth == 0) return error.InvalidDepth;
    return runWithBudget(writer, path, .{ .depth = depth }, hash_mb, eval_options, emit_header);
}

pub fn runNodes(
    writer: anytype,
    path: []const u8,
    node_limit: u64,
    hash_mb: u32,
    eval_options: search_engine.EvalOptions,
    emit_header: bool,
) !void {
    if (node_limit == 0) return error.InvalidNodeLimit;
    return runWithBudget(writer, path, .{ .node_limit = node_limit }, hash_mb, eval_options, emit_header);
}

fn runWithBudget(
    writer: anytype,
    path: []const u8,
    budget: SearchBudget,
    hash_mb: u32,
    eval_options: search_engine.EvalOptions,
    emit_header: bool,
) !void {
    var engine = try search_engine.Engine.initWithOptions(std.heap.page_allocator, hash_mb, eval_options);
    defer engine.deinit();

    const eval_file_text = eval_options.eval_file_path orelse "<builtin>";
    if (emit_header) {
        try writer.print("# zigqueen corpus_search_label\n", .{});
        try writer.print("# input_path {s}\n", .{path});
        switch (budget) {
            .depth => |depth| try writer.print("# depth {d}\n", .{depth}),
            .node_limit => |node_limit| try writer.print("# node_limit {d}\n", .{node_limit}),
        }
        try writer.print("# hash_mb {d}\n", .{hash_mb});
        try writer.print("# nnue_scale_percent {d}\n", .{eval_options.nnue_scale_percent});
        try writer.print("# eval_file {s}\n", .{eval_file_text});
    }

    const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 256 << 20);
    defer std.heap.page_allocator.free(data);

    const OutputRecord = struct {
        fen: []const u8,
        result: []const u8,
        source: ?[]const u8 = null,
        source_family: ?[]const u8 = null,
        game_id: ?[]const u8 = null,
        ply: ?u32 = null,
        target_slice: ?[]const u8 = null,
        search_white_pov_total: i32,
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            try writer.print("{s}\n", .{line});
            continue;
        }

        _ = arena.reset(.retain_capacity);
        const record = corpus.parseLine(arena.allocator(), line) catch |err| {
            std.debug.print("corpus search label parse failed at line {d}: {s}\n", .{ line_number, @errorName(err) });
            return err;
        };
        const pos = corpus.parsePosition(record) catch |err| {
            std.debug.print("corpus search label FEN parse failed at line {d}: {s}\n", .{ line_number, @errorName(err) });
            return err;
        };

        const search_white_pov_total = try labelPosition(&engine, &pos, budget);
        try writer.print("{f}\n", .{std.json.fmt(OutputRecord{
            .fen = record.fen,
            .result = record.result.text(),
            .source = record.source,
            .source_family = record.source_family,
            .game_id = record.game_id,
            .ply = record.ply,
            .target_slice = record.target_slice,
            .search_white_pov_total = search_white_pov_total,
        }, .{})});
    }
}

fn labelPosition(engine: *search_engine.Engine, pos: *const position.Position, budget: SearchBudget) !i32 {
    engine.reset();

    var history = repetition.History{};
    history.push(pos.zobrist_key);
    var stop_flag = std.atomic.Value(bool).init(false);
    const limits = switch (budget) {
        .depth => |depth| time.Limits{ .depth = depth },
        .node_limit => |node_limit| time.Limits{ .node_limit = node_limit },
    };
    const result = engine.search(pos, &history, limits, &stop_flag);
    const score_stm: i32 = result.score;
    return switch (pos.side_to_move) {
        .white => score_stm,
        .black => -score_stm,
    };
}

test "corpus search label annotates rows with search score" {
    const temp_name = "zigqueen-corpus-search-label-test.jsonl";
    const content =
        \\{"fen":"4k3/8/8/4P3/8/8/8/4K3 w - - 0 1","result":"1-0","source":"sample","source_family":"sample-family","game_id":"g1","ply":20,"target_slice":"label-smoke"}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_name, .data = content });
    defer std.fs.cwd().deleteFile(temp_name) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, temp_name, 1, 1, .{}, true);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "# zigqueen corpus_search_label") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"target_slice\":\"label-smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"search_white_pov_total\":") != null);
}

test "corpus search label can suppress generated header" {
    const temp_name = "zigqueen-corpus-search-label-test-no-header.jsonl";
    const content =
        \\{"fen":"4k3/8/8/4P3/8/8/8/4K3 w - - 0 1","result":"1-0","source":"sample","source_family":"sample-family","game_id":"g1","ply":20}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_name, .data = content });
    defer std.fs.cwd().deleteFile(temp_name) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, temp_name, 1, 1, .{}, false);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "# zigqueen corpus_search_label") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"search_white_pov_total\":") != null);
}

test "corpus search label can use a node budget" {
    const temp_name = "zigqueen-corpus-search-label-test-node-limit.jsonl";
    const content =
        \\{"fen":"4k3/8/8/4P3/8/8/8/4K3 w - - 0 1","result":"1-0","source":"sample","source_family":"sample-family","game_id":"g1","ply":20}
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_name, .data = content });
    defer std.fs.cwd().deleteFile(temp_name) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try runNodes(&sink.writer, temp_name, 64, 1, .{}, true);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "# node_limit 64") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"search_white_pov_total\":") != null);
}
