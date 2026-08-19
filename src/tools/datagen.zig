//! Self-play fixed-node training-data generator (lever 5, gen-0).
//!
//! Emits bullet text lines byte-identical in shape to what
//! scripts/export-bullet-text.py produces:
//!
//!     <FEN> | <score> | <result>
//!
//! where <score> is the search score in WHITE-POV centipawns (integer) and
//! <result> is the game result from WHITE's POV: 1.0 / 0.5 / 0.0.
//!
//! UNITS: scores are the engine's OWN units (the builtin net at its builtin
//! nnue scale). Unit calibration for mixing with other corpora happens
//! downstream at packaging time (zq_house_chunks constant-factor rescale) —
//! this generator must NOT rescale.
//!
//! DETERMINISM: same seed + same args => byte-identical output file. The
//! per-game PRNG seed is Wyhash(seed, game_index) — deliberately NOT
//! seed + game_index, so neighbouring process seeds (base+0..P-1 in
//! scripts/datagen-run.sh) never replay each other's game streams. Engine
//! state is reset (ucinewgame equivalent: TT / eval-cache / history clear)
//! before every opening attempt; games then run sequentially at a fixed node
//! budget, so the file is a pure function of (seed, games, nodes_per_move,
//! random_plies, engine build).
//!
//! Game protocol per game:
//!   opening: `random_plies` uniformly-random legal moves from startpos; one
//!            fixed-node search verifies |white-POV eval| <= 400cp, else the
//!            opening is discarded and regenerated (counted).
//!   play:    fixed-node search per move (the opening verification search is
//!            reused as the first play move — same position, same budget).
//!   record:  every position from game ply 16 onward, before the move is
//!            made, unless the side to move is in check (matches the
//!            training filter). Result is backfilled at game end.
//!   end:     checkmate/stalemate, 50-move rule, game-level threefold
//!            repetition (claimable: current + two prior occurrences),
//!            win adjudication (|eval| >= 2500 white-POV, same sign, 4
//!            consecutive plies), draw adjudication (fullmove >= 40 and
//!            |eval| <= 8 for 8 consecutive plies), hard cap 200 fullmoves.

const std = @import("std");
const fen = @import("../core/fen.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const time = @import("../search/time.zig");
const types = @import("../core/types.zig");

pub const default_nodes_per_move: u64 = 5000;
pub const default_random_plies: u32 = 8;

/// Small TT on purpose: 5k-node searches gain nothing from a big table and
/// datagen runs ~20 processes per box. Determinism is per-game (reset) and
/// does not depend on the size.
const HASH_MB: u32 = 16;
const OPENING_MAX_ABS_CP: i32 = 400;
const OPENING_MAX_ATTEMPTS: u64 = 10_000;
const RECORD_MIN_PLY: u32 = 16;
const WIN_ADJ_ABS_CP: i32 = 2500;
const WIN_ADJ_PLIES: u32 = 4;
const DRAW_ADJ_MIN_FULLMOVE: u16 = 40;
const DRAW_ADJ_ABS_CP: i32 = 8;
const DRAW_ADJ_PLIES: u32 = 8;
const MAX_FULLMOVES: u16 = 200;
const PROGRESS_EVERY_GAMES: u64 = 100;

/// Hard bound: the fullmove cap ends every game before 404 plies, and only
/// plies >= RECORD_MIN_PLY are buffered.
const MAX_RECORDS: usize = 512;

const GameResult = enum {
    white_win,
    draw,
    black_win,

    fn text(self: GameResult) []const u8 {
        return switch (self) {
            .white_win => "1.0",
            .draw => "0.5",
            .black_win => "0.0",
        };
    }
};

const Record = struct {
    fen_text: []const u8,
    score_white_pov: i32,
};

const GameStats = struct {
    positions: u64,
    discards: u64,
};

pub fn run(
    progress: anytype,
    seed: u64,
    games: u64,
    out_path: []const u8,
    nodes_per_move: u64,
    random_plies: u32,
) !void {
    if (games == 0) return error.InvalidGameCount;
    if (nodes_per_move == 0) return error.InvalidNodeLimit;
    if (random_plies == 0 or random_plies > 100) return error.InvalidRandomPlies;

    const allocator = std.heap.page_allocator;

    var engine = try search_engine.Engine.initWithOptions(allocator, HASH_MB, .{});
    defer engine.deinit();

    var records: [MAX_RECORDS]Record = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var out_file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_file.close();
    var out_buffer: [128 * 1024]u8 = undefined;
    var file_writer = out_file.writer(&out_buffer);
    const out = &file_writer.interface;

    const limits = time.Limits{ .node_limit = nodes_per_move };

    var timer = try std.time.Timer.start();
    var total_positions: u64 = 0;
    var total_discards: u64 = 0;

    var game_index: u64 = 0;
    while (game_index < games) : (game_index += 1) {
        _ = arena.reset(.retain_capacity);
        var prng = std.Random.DefaultPrng.init(gameSeed(seed, game_index));
        const stats = try playOneGame(
            &engine,
            arena.allocator(),
            prng.random(),
            limits,
            random_plies,
            &records,
            out,
        );
        total_positions += stats.positions;
        total_discards += stats.discards;
        // Flush per game so the file always ends on a game boundary and live
        // line counts (datagen-run.sh status) track finished games.
        try out.flush();

        if ((game_index + 1) % PROGRESS_EVERY_GAMES == 0) {
            try printProgress(progress, game_index + 1, games, total_positions, total_discards, timer.read());
        }
    }

    try progress.print("datagen done: seed {d} games {d} positions {d} discards {d} elapsed_s {d:.1} pos_per_sec {d:.1}\n", .{
        seed,
        games,
        total_positions,
        total_discards,
        elapsedSeconds(timer.read()),
        rate(total_positions, timer.read()),
    });
    try progress.flush();
}

fn playOneGame(
    engine: *search_engine.Engine,
    arena: std.mem.Allocator,
    random: std.Random,
    limits: time.Limits,
    random_plies: u32,
    records: *[MAX_RECORDS]Record,
    out: anytype,
) !GameStats {
    var stop_flag = std.atomic.Value(bool).init(false);
    var discards: u64 = 0;

    // --- Opening: random plies + rebalance guard ---------------------------
    var pos: position.Position = undefined;
    var history = repetition.History{};
    var first_search: search_engine.SearchResult = undefined;

    opening: while (true) {
        if (discards >= OPENING_MAX_ATTEMPTS) return error.OpeningGenerationFailed;
        // Fresh search state per game/attempt — the ucinewgame equivalent
        // (uci worker resetEngine -> engine.reset()).
        engine.reset();
        pos = try fen.startpos();
        history.clear();
        history.push(pos.zobrist_key);

        var ply: u32 = 0;
        while (ply < random_plies) : (ply += 1) {
            var list = move_mod.MoveList.init();
            legal.generate(&pos, &list);
            if (list.count == 0) {
                // Random line hit a terminal position: regenerate.
                discards += 1;
                continue :opening;
            }
            const mv = list.moves[random.uintLessThan(usize, list.count)];
            var state: make_unmake.StateInfo = undefined;
            const key = make_unmake.makeMove(&pos, mv, &state);
            history.push(key);
        }

        var list = move_mod.MoveList.init();
        legal.generate(&pos, &list);
        if (list.count == 0) {
            discards += 1;
            continue :opening;
        }

        first_search = engine.searchRawNoBook(&pos, &history, limits, &stop_flag);
        const white_pov = whitePov(first_search.score, pos.side_to_move);
        if (white_pov > OPENING_MAX_ABS_CP or white_pov < -OPENING_MAX_ABS_CP) {
            discards += 1;
            continue :opening;
        }
        break;
    }

    // --- Play --------------------------------------------------------------
    var game_ply: u32 = random_plies;
    var record_count: usize = 0;
    var win_streak: u32 = 0;
    var win_streak_positive = false;
    var draw_streak: u32 = 0;
    var pending_first: ?search_engine.SearchResult = first_search;

    const result: GameResult = play: {
        while (true) {
            const in_check = legal.isInCheck(&pos, pos.side_to_move);
            var list = move_mod.MoveList.init();
            legal.generate(&pos, &list);
            if (list.count == 0) {
                if (in_check) {
                    break :play if (pos.side_to_move == .white) GameResult.black_win else GameResult.white_win;
                }
                break :play GameResult.draw; // stalemate
            }
            if (pos.halfmove_clock >= 100) break :play GameResult.draw;
            if (history.isClaimableCurrentRepetition(pos.halfmove_clock)) break :play GameResult.draw;
            if (pos.fullmove_number > MAX_FULLMOVES) break :play GameResult.draw;

            const search_result = if (pending_first) |first| blk: {
                pending_first = null;
                break :blk first;
            } else engine.searchRawNoBook(&pos, &history, limits, &stop_flag);
            const best_move = search_result.best_move orelse return error.SearchReturnedNoMove;
            const white_pov = whitePov(search_result.score, pos.side_to_move);

            if (game_ply >= RECORD_MIN_PLY and !in_check) {
                if (record_count >= records.len) return error.RecordOverflow;
                records[record_count] = .{
                    .fen_text = try fen.format(arena, &pos),
                    .score_white_pov = white_pov,
                };
                record_count += 1;
            }

            // Win adjudication: same-sign |eval| >= 2500 for 4 consecutive plies.
            if (white_pov >= WIN_ADJ_ABS_CP) {
                if (win_streak != 0 and win_streak_positive) {
                    win_streak += 1;
                } else {
                    win_streak = 1;
                    win_streak_positive = true;
                }
            } else if (white_pov <= -WIN_ADJ_ABS_CP) {
                if (win_streak != 0 and !win_streak_positive) {
                    win_streak += 1;
                } else {
                    win_streak = 1;
                    win_streak_positive = false;
                }
            } else {
                win_streak = 0;
            }
            if (win_streak >= WIN_ADJ_PLIES) {
                break :play if (win_streak_positive) GameResult.white_win else GameResult.black_win;
            }

            // Draw adjudication: fullmove >= 40 and |eval| <= 8 for 8 consecutive plies.
            if (pos.fullmove_number >= DRAW_ADJ_MIN_FULLMOVE and
                white_pov <= DRAW_ADJ_ABS_CP and white_pov >= -DRAW_ADJ_ABS_CP)
            {
                draw_streak += 1;
                if (draw_streak >= DRAW_ADJ_PLIES) break :play GameResult.draw;
            } else {
                draw_streak = 0;
            }

            var state: make_unmake.StateInfo = undefined;
            const key = make_unmake.makeMove(&pos, best_move, &state);
            history.push(key);
            game_ply += 1;
        }
    };

    // --- Backfill result and append ----------------------------------------
    const result_text = result.text();
    for (records[0..record_count]) |record| {
        try out.print("{s} | {d} | {s}\n", .{ record.fen_text, record.score_white_pov, result_text });
    }

    return .{ .positions = record_count, .discards = discards };
}

/// Mix the run seed with the game index. Wyhash instead of seed+index so
/// process seeds base+0..P-1 produce disjoint game streams (seed s game g
/// would otherwise collide with seed s+1 game g-1 across the whole file).
fn gameSeed(seed: u64, game_index: u64) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    const index_le = std.mem.nativeToLittle(u64, game_index);
    hasher.update(std.mem.asBytes(&index_le));
    return hasher.final();
}

fn whitePov(score_stm: i32, side_to_move: types.Color) i32 {
    return switch (side_to_move) {
        .white => score_stm,
        .black => -score_stm,
    };
}

fn elapsedSeconds(elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
}

fn rate(count: u64, elapsed_ns: u64) f64 {
    const seconds = elapsedSeconds(elapsed_ns);
    if (seconds <= 0) return 0;
    return @as(f64, @floatFromInt(count)) / seconds;
}

fn printProgress(progress: anytype, done: u64, games: u64, positions: u64, discards: u64, elapsed_ns: u64) !void {
    try progress.print("datagen progress: games {d}/{d} positions {d} discards {d} pos_per_sec {d:.1}\n", .{
        done,
        games,
        positions,
        discards,
        rate(positions, elapsed_ns),
    });
    try progress.flush();
}

test "game seeds do not collide across neighbouring process seeds" {
    // seed s game g must differ from seed s+1 game g-1 (the additive trap).
    try std.testing.expect(gameSeed(1000, 1) != gameSeed(1001, 0));
    try std.testing.expect(gameSeed(1000, 0) != gameSeed(1001, 0));
    try std.testing.expect(gameSeed(1000, 0) != gameSeed(1000, 1));
}

test "datagen output is deterministic, parseable, and check-free" {
    const path_a = "zigqueen-datagen-test-a.txt";
    const path_b = "zigqueen-datagen-test-b.txt";
    defer std.fs.cwd().deleteFile(path_a) catch {};
    defer std.fs.cwd().deleteFile(path_b) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, 42, 2, path_a, 64, 6);
    try run(&sink.writer, 42, 2, path_b, 64, 6);

    const data_a = try std.fs.cwd().readFileAlloc(std.testing.allocator, path_a, 16 << 20);
    defer std.testing.allocator.free(data_a);
    const data_b = try std.fs.cwd().readFileAlloc(std.testing.allocator, path_b, 16 << 20);
    defer std.testing.allocator.free(data_b);

    try std.testing.expect(data_a.len > 0);
    try std.testing.expectEqualStrings(data_a, data_b);

    var lines = std.mem.splitScalar(u8, data_a, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var fields = std.mem.splitSequence(u8, line, " | ");
        const fen_text = fields.next() orelse return error.TestMalformedLine;
        const score_text = fields.next() orelse return error.TestMalformedLine;
        const result_text = fields.next() orelse return error.TestMalformedLine;
        try std.testing.expectEqual(@as(?[]const u8, null), fields.next());

        const pos = try fen.parse(fen_text);
        try std.testing.expect(!legal.isInCheck(&pos, pos.side_to_move));
        _ = try std.fmt.parseInt(i32, score_text, 10);
        const valid_result = std.mem.eql(u8, result_text, "1.0") or
            std.mem.eql(u8, result_text, "0.5") or
            std.mem.eql(u8, result_text, "0.0");
        try std.testing.expect(valid_result);
    }
    try std.testing.expect(line_count > 0);
}
