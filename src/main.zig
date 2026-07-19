const std = @import("std");
const build_options = @import("build_options");
const attacks = @import("movegen/attacks.zig");
const bench = @import("tools/bench.zig");
const bitboard = @import("core/bitboard.zig");
const fen = @import("core/fen.zig");
const legal = @import("movegen/legal.zig");
const make_unmake = @import("movegen/make_unmake.zig");
const move = @import("core/move.zig");
const perft = @import("movegen/perft.zig");
const piece = @import("core/piece.zig");
const position = @import("core/position.zig");
const pseudo = @import("movegen/pseudo_legal.zig");
const search_engine = @import("search/engine.zig");
const square = @import("core/square.zig");
const stability = @import("tools/stability.zig");
const threats = @import("eval/threats.zig");
const types = @import("core/types.zig");
const uci = @import("uci/protocol.zig");
const zobrist = @import("core/zobrist.zig");

/// Diagnostic/tooling subcommands (profilers, corpus pipeline, dumps) are only
/// compiled into -Dsearch-stats builds (the zigqueen-stats twin). The release
/// binary ships the UCI loop plus perft/bench/stability.
const dev_tools = build_options.search_stats;

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next();
    const mode = args.next() orelse {
        try uci.run();
        return;
    };

    var stdout_buffer: [512 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, mode, "perft")) {
        const depth_text = args.next() orelse return error.InvalidCommand;
        const depth = try std.fmt.parseInt(u32, depth_text, 10);
        const pos = try parsePositionArg(args.next());
        try stdout.print("nodes {d}\n", .{perft.perft(&pos, depth)});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, mode, "bench")) {
        const depth = if (args.next()) |depth_text| try std.fmt.parseInt(u16, depth_text, 10) else 5;
        const pos = try parsePositionArg(args.next());
        const eval_options = try parseEvalOptions(args.next(), args.next());
        try bench.runWithOptions(stdout, &pos, depth, eval_options);
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, mode, "stability")) {
        const iterations = if (args.next()) |count_text| try std.fmt.parseInt(u8, count_text, 10) else 3;
        try stability.run(stdout, iterations);
        try stdout.flush();
        return;
    }

    if (dev_tools) {
        if (std.mem.eql(u8, mode, "corpus_from_pgn")) {
            const path = args.next() orelse return error.InvalidCommand;
            const min_ply = if (args.next()) |text| try std.fmt.parseInt(u32, text, 10) else 8;
            const stride = if (args.next()) |text| try std.fmt.parseInt(u32, text, 10) else 2;
            try @import("tools/corpus_from_pgn.zig").run(stdout, path, min_ply, stride);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "corpus_validate")) {
            const path = args.next() orelse return error.InvalidCommand;
            const tuning_corpus = @import("tuning/corpus.zig");
            const validation_permille = if (args.next()) |text| try std.fmt.parseInt(u16, text, 10) else tuning_corpus.default_validation_permille;
            const seed = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else tuning_corpus.default_split_seed;
            const split_mode = if (args.next()) |text| try tuning_corpus.SplitMode.parse(text) else .fen;
            const test_permille = if (args.next()) |text| try std.fmt.parseInt(u16, text, 10) else tuning_corpus.default_test_permille;
            try @import("tools/corpus_validate.zig").run(stdout, path, validation_permille, test_permille, seed, split_mode);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "corpus_search_label")) {
            const path = args.next() orelse return error.InvalidCommand;
            const depth = if (args.next()) |text| try std.fmt.parseInt(u16, text, 10) else return error.InvalidCommand;
            const eval_options = try parseEvalOptions(args.next(), args.next());
            const default_hash_mb = @import("search/tt.zig").DEFAULT_HASH_MB;
            const hash_mb = if (args.next()) |text| try std.fmt.parseInt(u32, text, 10) else default_hash_mb;
            const emit_header = if (args.next()) |text|
                if (std.mem.eql(u8, text, "true"))
                    true
                else if (std.mem.eql(u8, text, "false"))
                    false
                else
                    return error.InvalidCommand
            else
                true;
            try @import("tools/corpus_search_label.zig").run(stdout, path, depth, hash_mb, eval_options, emit_header);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "corpus_search_label_nodes")) {
            const path = args.next() orelse return error.InvalidCommand;
            const node_limit = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else return error.InvalidCommand;
            const eval_options = try parseEvalOptions(args.next(), args.next());
            const default_hash_mb = @import("search/tt.zig").DEFAULT_HASH_MB;
            const hash_mb = if (args.next()) |text| try std.fmt.parseInt(u32, text, 10) else default_hash_mb;
            const emit_header = if (args.next()) |text|
                if (std.mem.eql(u8, text, "true"))
                    true
                else if (std.mem.eql(u8, text, "false"))
                    false
                else
                    return error.InvalidCommand
            else
                true;
            try @import("tools/corpus_search_label.zig").runNodes(stdout, path, node_limit, hash_mb, eval_options, emit_header);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "move_diag")) {
            const pos = try parsePositionArg(args.next());
            try @import("tools/move_diag.zig").run(stdout, &pos);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "nnue_dump")) {
            const net_arg = args.next() orelse return error.InvalidCommand;
            const fen_file = args.next() orelse return error.InvalidCommand;
            const net_path: ?[]const u8 = if (std.mem.eql(u8, net_arg, "<default>") or std.mem.eql(u8, net_arg, "<builtin>")) null else net_arg;
            try @import("tools/nnue_dump.zig").run(stdout, net_path, fen_file);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "root_trace")) {
            const depth = if (args.next()) |depth_text| try std.fmt.parseInt(u16, depth_text, 10) else 3;
            const pos = try parsePositionArg(args.next());
            try @import("tools/root_trace.zig").run(stdout, &pos, depth);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "search_profile")) {
            const depth = if (args.next()) |depth_text| try std.fmt.parseInt(u16, depth_text, 10) else 3;
            const pos = try parsePositionArg(args.next());
            const eval_options = try parseEvalOptions(args.next(), args.next());
            try @import("tools/search_profile.zig").runWithOptions(stdout, &pos, depth, eval_options);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "raw_search_probe")) {
            const depth = if (args.next()) |depth_text| try std.fmt.parseInt(u16, depth_text, 10) else 3;
            const pos = try parsePositionArg(args.next());
            const eval_options = try parseEvalOptions(args.next(), args.next());
            try @import("tools/raw_search_probe.zig").runWithOptions(stdout, &pos, depth, eval_options);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "search_profile_sequence")) {
            const depth = if (args.next()) |depth_text| try std.fmt.parseInt(u16, depth_text, 10) else 3;
            const fen_file = args.next() orelse return error.InvalidFen;
            const eval_options = try parseEvalOptions(args.next(), args.next());
            try @import("tools/search_profile_sequence.zig").runFileWithOptions(stdout, fen_file, depth, eval_options);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "time_profile")) {
            const movetime_ms = if (args.next()) |movetime_text| try std.fmt.parseInt(u64, movetime_text, 10) else 500;
            const pos = try parsePositionArg(args.next());
            const eval_options = try parseEvalOptions(args.next(), args.next());
            try @import("tools/time_profile.zig").runWithOptions(stdout, &pos, movetime_ms, eval_options);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, mode, "time_profile_tc")) {
            const wtime_ms = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else 3000;
            const btime_ms = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else wtime_ms;
            const winc_ms = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else 0;
            const binc_ms = if (args.next()) |text| try std.fmt.parseInt(u64, text, 10) else winc_ms;
            const pos = try parsePositionArg(args.next());
            const eval_options = try parseEvalOptions(args.next(), args.next());
            try @import("tools/time_profile.zig").runSuddenDeathWithOptions(stdout, &pos, wtime_ms, btime_ms, winc_ms, binc_ms, eval_options);
            try stdout.flush();
            return;
        }
    }

    return error.InvalidCommand;
}

fn parsePositionArg(arg: ?[]const u8) !position.Position {
    const text = arg orelse return fen.startpos();
    if (std.mem.eql(u8, text, "startpos")) return fen.startpos();
    return fen.parse(text);
}

fn parseEvalOptions(eval_file_path_text: ?[]const u8, nnue_scale_text: ?[]const u8) !search_engine.EvalOptions {
    const eval_file_path = if (eval_file_path_text) |text| blk: {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "<default>") or std.mem.eql(u8, trimmed, "<none>")) {
            break :blk null;
        }
        break :blk trimmed;
    } else null;
    const nnue_scale_percent = if (nnue_scale_text) |text|
        try std.fmt.parseInt(u16, text, 10)
    else
        search_engine.default_nnue_scale_percent;
    return .{
        .nnue_scale_percent = nnue_scale_percent,
        .eval_file_path = eval_file_path,
    };
}

test "parse eval options defaults to the builtin net at the default scale" {
    const options = try parseEvalOptions(null, null);
    // Reference the single-source constant, not a literal — the default is
    // calibrated per shipped net and changes across releases.
    try std.testing.expectEqual(search_engine.default_nnue_scale_percent, options.nnue_scale_percent);
    try std.testing.expectEqual(@as(?[]const u8, null), options.eval_file_path);
}

test "parse eval options reads scale and eval file" {
    const options = try parseEvalOptions("<builtin>", "50");
    try std.testing.expectEqual(@as(u16, 50), options.nnue_scale_percent);
    try std.testing.expectEqualStrings("<builtin>", options.eval_file_path.?);
}

test "parse eval options treats default sentinel as no override" {
    const options = try parseEvalOptions("<default>", "100");
    try std.testing.expectEqual(@as(u16, 100), options.nnue_scale_percent);
    try std.testing.expectEqual(@as(?[]const u8, null), options.eval_file_path);
}

test "root modules compile" {
    _ = attacks;
    _ = bench;
    _ = bitboard;
    _ = fen;
    _ = legal;
    _ = make_unmake;
    _ = move;
    _ = perft;
    _ = piece;
    _ = position;
    _ = pseudo;
    _ = square;
    _ = stability;
    _ = threats;
    _ = types;
    _ = uci;
    _ = zobrist;
    if (dev_tools) {
        _ = @import("tools/corpus_from_pgn.zig");
        _ = @import("tools/corpus_search_label.zig");
        _ = @import("tools/corpus_validate.zig");
        _ = @import("tools/history_report.zig");
        _ = @import("tools/move_diag.zig");
        _ = @import("tools/nnue_dump.zig");
        _ = @import("tools/raw_search_probe.zig");
        _ = @import("tools/root_trace.zig");
        _ = @import("tools/search_profile.zig");
        _ = @import("tools/search_profile_sequence.zig");
        _ = @import("tools/time_profile.zig");
    }
}
