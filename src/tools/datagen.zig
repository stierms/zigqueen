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
//! TABLEBASES ARE MANDATORY (`--syzygy <path>`, gate added 2026-08-13).
//! Root cause of the gen-0 label defect: datagen ran with no SyzygyPath, so
//! the shipped v5.8.3 root-DTZ conversion stayed dormant and the engine
//! shuffled its own won endings into 50-move draws. Measured on real corpus
//! positions (artifacts/labelqual/conversion_test.py, replaying datagen's exact
//! protocol): TB-OFF converted 67% of tablebase-proven wins, TB-ON 96.6% —
//! i.e. ~31% of TB-won endings were labelled DRAW, poisoning ~7% of corpus
//! positions through the result channel. So: `runThreaded` REFUSES to start
//! without `--syzygy`, verifies the path really holds a complete 3-4-5 set
//! (145 .rtbw + 145 .rtbz) and that Fathom actually loaded it (largest >= 5),
//! and logs the tablebase state in the startup banner of every run. The only
//! escape is the explicit `--allow-no-syzygy`, which prints a loud warning
//! banner and exists for deliberate experiments only.
//!
//! DETERMINISM: same seed + same args => byte-identical output file. The
//! per-game PRNG seed is Wyhash(seed, game_index) — deliberately NOT
//! seed + game_index, so neighbouring process seeds (base+0..P-1 in
//! scripts/datagen-run.sh) never replay each other's game streams. Engine
//! state is reset (ucinewgame equivalent: TT / eval-cache / history clear)
//! before every opening attempt; games then run sequentially at a fixed node
//! budget, so the file is a pure function of (seed, games, nodes_per_move,
//! random_plies, hash_mb, tablebase state, engine build). NOTE: hash_mb
//! (--hash) IS part of that tuple — TT size changes fixed-node search results
//! via replacement pressure, so corpora at different --hash values legitimately
//! differ. So does the TABLEBASE STATE: a TB-enabled run and a TB-blind run of
//! the same seed are different corpora, which is exactly why the banner records
//! it.
//!
//! THREADED (`--threads N`, runThreaded): one shared read-only net, N private
//! engines; worker k writes games [k*games/N, (k+1)*games/N) to
//! `<out_path>.w<k>`. Same per-game seed derivation and per-game engine reset,
//! so each .w file is deterministic and the union of positions for a given
//! (seed, games) is identical for every N.
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

const builtin = @import("builtin");
const std = @import("std");
const fen = @import("../core/fen.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const syzygy = @import("../search/syzygy.zig");
const time = @import("../search/time.zig");
const types = @import("../core/types.zig");

pub const default_nodes_per_move: u64 = 5000;
pub const default_random_plies: u32 = 8;

/// Small TT default on purpose: 5k-node searches gain nothing from a big
/// table and datagen runs ~20 workers per box. Determinism is per-game
/// (reset) and does not depend on the size — but the SIZE ITSELF changes
/// search results at fixed nodes (replacement pressure), so a corpus is only
/// reproducible from seed+args+hash_mb. Overridable via `--hash <mb>`.
pub const default_hash_mb: u32 = 16;
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

// --- Tablebase gate ---------------------------------------------------------

/// A complete 3-4-5 Syzygy set is 145 WDL (.rtbw) + 145 DTZ (.rtbz) files.
/// Datagen needs BOTH halves: the in-search WDL probe SCORES a covered ending,
/// the root DTZ probe CONVERTS it (v5.8.3; it is the only one that works in
/// pawnless wins, where no move ever zeroes the rule-50 clock the WDL gate
/// requires). A WDL-only directory would pass a naive "tables exist" check and
/// still lose exactly the conversions this gate is here to protect.
pub const MIN_RTBW_FILES: usize = 145;
pub const MIN_RTBZ_FILES: usize = 145;

/// Lower edge of the tablebase score band, used ONLY to count how many emitted
/// labels are tablebase verdicts rather than search judgments.
/// Root DTZ scores are TB_WIN_SCORE - min(dtz, 1000) -> |s| in [27000, 28000];
/// in-search WDL scores are TB_WIN_SCORE - ply -> |s| just under 28000. Mate
/// scores start at MATE_THRESHOLD (28872), so the two bands are disjoint and a
/// mate can never be miscounted as a tablebase verdict.
const TB_SCORE_MIN: i32 = syzygy.TB_WIN_SCORE - 1000;

/// What the caller asked for on the command line. `path == null` means the
/// `--syzygy` flag was absent, which is a REFUSAL unless `allow_none` is set.
pub const TbOptions = struct {
    path: ?[]const u8 = null,
    allow_none: bool = false,
};

/// Verified tablebase state, logged in the startup banner of every run so that
/// any datagen log ever after answers "were tablebases on?" without archaeology.
pub const TbState = struct {
    enabled: bool = false,
    path: []const u8 = "",
    rtbw: usize = 0,
    rtbz: usize = 0,
    largest: u32 = 0,
};

const TbFileCounts = struct { rtbw: usize = 0, rtbz: usize = 0 };

/// Fathom accepts several directories in one path string, ':'-separated on
/// POSIX and ';'-separated on Windows (deps/fathom/tbprobe.c SEP_CHAR). The
/// gate must count over the same split, or a legitimate multi-directory setup
/// would fail the file-count check.
const TB_PATH_SEP: u8 = if (builtin.os.tag == .windows) ';' else ':';

fn countTbFiles(path: []const u8) !TbFileCounts {
    var counts = TbFileCounts{};
    var dirs = std.mem.splitScalar(u8, path, TB_PATH_SEP);
    var dirs_seen: usize = 0;
    while (dirs.next()) |raw| {
        const dir_path = std.mem.trim(u8, raw, " \t\r\n");
        if (dir_path.len == 0) continue;
        dirs_seen += 1;
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return error.SyzygyPathUnreadable;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            // Kind can come back .unknown on some mounts (drvfs/9p), so filter
            // by "not a directory" rather than by "is a regular file".
            if (entry.kind == .directory) continue;
            if (std.mem.endsWith(u8, entry.name, ".rtbw")) {
                counts.rtbw += 1;
            } else if (std.mem.endsWith(u8, entry.name, ".rtbz")) {
                counts.rtbz += 1;
            }
        }
    }
    if (dirs_seen == 0) return error.SyzygyPathRequired;
    return counts;
}

/// THE GATE. Runs before a single game is played; every failure path is fatal
/// and prints why. Returns the state the banner logs.
///
/// Errors:
///   SyzygyPathRequired    — no `--syzygy` and no `--allow-no-syzygy`
///   SyzygyFlagConflict    — both flags passed (the intent is ambiguous)
///   SyzygyPathUnreadable  — a listed directory cannot be opened
///   SyzygyTablesIncomplete— fewer than 145 .rtbw / 145 .rtbz across the path
///   SyzygyInitFailed      — Fathom refused the path, or loaded < 5-man tables
pub fn initTablebases(progress: *std.Io.Writer, opts: TbOptions) !TbState {
    const path = opts.path orelse {
        if (!opts.allow_none) {
            try printRefusal(progress);
            return error.SyzygyPathRequired;
        }
        try printNoTbWarning(progress);
        return .{ .enabled = false };
    };
    if (opts.allow_none) {
        try progress.print(
            "datagen FATAL: --syzygy and --allow-no-syzygy are mutually exclusive.\n",
            .{},
        );
        try progress.flush();
        std.debug.print("datagen FATAL: --syzygy and --allow-no-syzygy are mutually exclusive.\n", .{});
        return error.SyzygyFlagConflict;
    }
    if (std.mem.trim(u8, path, " \t\r\n").len == 0) {
        try printRefusal(progress);
        return error.SyzygyPathRequired;
    }

    const counts = countTbFiles(path) catch |err| {
        try progress.print(
            "datagen FATAL: --syzygy path is not readable: '{s}' ({s}).\n" ++
                "  Expected a directory holding the 3-4-5 Syzygy set (145 .rtbw + 145 .rtbz).\n",
            .{ path, @errorName(err) },
        );
        try progress.flush();
        std.debug.print("datagen FATAL: --syzygy path is not readable: '{s}' ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    if (counts.rtbw < MIN_RTBW_FILES or counts.rtbz < MIN_RTBZ_FILES) {
        try progress.print(
            "datagen FATAL: incomplete tablebase set at '{s}': found {d} .rtbw and {d} .rtbz,\n" ++
                "  need at least {d} + {d} (the full 3-4-5 set). Datagen needs BOTH halves:\n" ++
                "  .rtbw scores a covered ending in search, .rtbz (root DTZ) converts it.\n",
            .{ path, counts.rtbw, counts.rtbz, MIN_RTBW_FILES, MIN_RTBZ_FILES },
        );
        try progress.flush();
        std.debug.print(
            "datagen FATAL: incomplete tablebase set at '{s}' ({d} .rtbw / {d} .rtbz)\n",
            .{ path, counts.rtbw, counts.rtbz },
        );
        return error.SyzygyTablesIncomplete;
    }

    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) {
        try progress.print("datagen FATAL: --syzygy path too long ({d} bytes, max {d}).\n", .{ path.len, buf.len - 1 });
        try progress.flush();
        return error.SyzygyInitFailed;
    }
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (!syzygy.init(buf[0..path.len :0]) or syzygy.pieceLimit() < 5) {
        const largest = syzygy.pieceLimit();
        syzygy.disable();
        try progress.print(
            "datagen FATAL: Fathom could not load tablebases from '{s}' (largest = {d}, need >= 5).\n" ++
                "  The files are present but unusable — check permissions and file integrity.\n",
            .{ path, largest },
        );
        try progress.flush();
        std.debug.print("datagen FATAL: Fathom could not load tablebases from '{s}' (largest {d})\n", .{ path, largest });
        return error.SyzygyInitFailed;
    }

    return .{
        .enabled = true,
        .path = path,
        .rtbw = counts.rtbw,
        .rtbz = counts.rtbz,
        .largest = syzygy.pieceLimit(),
    };
}

fn printRefusal(progress: *std.Io.Writer) !void {
    const text =
        \\
        \\================================================================
        \\ datagen REFUSES TO START: no --syzygy <path> given.
        \\
        \\ Tablebases are REQUIRED for training-data generation. Without
        \\ them this engine cannot convert its own tablebase-won endings:
        \\ measured 2026-08-13 on real corpus positions, TB-OFF converted
        \\ 67% of proven wins vs 96.6% TB-ON, so ~31% of tablebase-won
        \\ endings were labelled DRAW and ~7% of corpus positions were
        \\ result-poisoned.
        \\
        \\ Fix:      ... datagen <seed> <games> <out> [...] --syzygy /path/to/3-4-5
        \\ Override: --allow-no-syzygy  (deliberate experiments ONLY, never
        \\           for data that will be trained on)
        \\================================================================
        \\
    ;
    try progress.print("{s}", .{text});
    try progress.flush();
    std.debug.print("datagen REFUSES TO START: no --syzygy <path> given (override: --allow-no-syzygy).\n", .{});
}

fn printNoTbWarning(progress: *std.Io.Writer) !void {
    const text =
        \\
        \\****************************************************************
        \\ WARNING: TB-BLIND GENERATION (--allow-no-syzygy)
        \\
        \\ Tablebases are OFF. Every tablebase-won ending this run reaches
        \\ is at risk of being shuffled into a 50-move draw and labelled
        \\ 0.5 (measured: 67% conversion TB-OFF vs 96.6% TB-ON).
        \\
        \\ Output of this run is EXPERIMENTAL. Do not train on it.
        \\****************************************************************
        \\
    ;
    try progress.print("{s}", .{text});
    try progress.flush();
    std.debug.print("datagen WARNING: TB-BLIND GENERATION (--allow-no-syzygy) — do not train on this output.\n", .{});
}

fn printTbBanner(progress: *std.Io.Writer, tb: TbState) !void {
    if (tb.enabled) {
        try progress.print(
            "datagen syzygy: ENABLED path {s} rtbw {d} rtbz {d} largest {d}\n",
            .{ tb.path, tb.rtbw, tb.rtbz, tb.largest },
        );
    } else {
        try progress.print("datagen syzygy: DISABLED (--allow-no-syzygy) — TB-BLIND, experimental output\n", .{});
    }
    try progress.flush();
}

/// True for a search answered by the ROOT DTZ probe: it is the only path that
/// returns depth 1 / nodes 1 with a score in the tablebase band. The engine
/// no longer has an opening-book shortcut that could bypass the search.
fn isRootTbAnswer(result: search_engine.SearchResult) bool {
    return result.depth == 1 and result.nodes == 1 and isTbScore(result.score);
}

fn isTbScore(score: i32) bool {
    const magnitude = if (score < 0) -@as(i64, score) else @as(i64, score);
    return magnitude >= TB_SCORE_MIN and magnitude <= syzygy.TB_WIN_SCORE;
}

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
    /// Searches answered directly by the root DTZ probe (how often tablebases
    /// actually steered play), whether or not the position was recorded.
    tb_root_hits: u64,
    /// EMITTED records whose label is a tablebase verdict (|score| in the TB
    /// band). These are the ±28000-magnitude labels that sit far outside
    /// zq_pack_selfplay's ±4800 engine-unit score cap — see the TODO at that
    /// cap site; this counter exists to make the magnitude visible.
    tb_scored_positions: u64,
};

/// The single-thread game loop. PRIVATE ON PURPOSE: the tablebase gate lives in
/// `runThreaded`, the sole public entry point, so no production caller can walk
/// past it. In-file tests call this directly to compare byte-for-byte against
/// the threaded partition.
fn run(
    progress: anytype,
    seed: u64,
    games: u64,
    out_path: []const u8,
    nodes_per_move: u64,
    random_plies: u32,
    hash_mb: u32,
) !void {
    if (games == 0) return error.InvalidGameCount;
    if (nodes_per_move == 0) return error.InvalidNodeLimit;
    if (random_plies == 0 or random_plies > 100) return error.InvalidRandomPlies;
    if (hash_mb == 0 or hash_mb > 65_536) return error.InvalidHashSize;

    const allocator = std.heap.page_allocator;

    var engine = try search_engine.Engine.initWithOptions(allocator, hash_mb, .{});
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
    var total_tb_root_hits: u64 = 0;
    var total_tb_scored: u64 = 0;

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
        total_tb_root_hits += stats.tb_root_hits;
        total_tb_scored += stats.tb_scored_positions;
        // Flush per game so the file always ends on a game boundary and live
        // line counts (datagen-run.sh status) track finished games.
        try out.flush();

        if ((game_index + 1) % PROGRESS_EVERY_GAMES == 0) {
            try printProgress(progress, game_index + 1, games, total_positions, total_discards, total_tb_root_hits, total_tb_scored, timer.read());
        }
    }

    // pos_per_sec stays LAST: scripts/datagen-run.sh reads it as awk $(NF).
    // The new tokens are distinct from "positions", so zqb_done_line's token
    // scan (`$i == "positions"`) still picks up the right field.
    try progress.print("datagen done: seed {d} games {d} positions {d} discards {d} tb_root_hits {d} tb_scored_positions {d} elapsed_s {d:.1} pos_per_sec {d:.1}\n", .{
        seed,
        games,
        total_positions,
        total_discards,
        total_tb_root_hits,
        total_tb_scored,
        elapsedSeconds(timer.read()),
        rate(total_positions, timer.read()),
    });
    try progress.flush();
}

/// Threaded front-end (`--threads N`): ONE shared read-only net, N worker
/// threads each with private search state (Engine: TT `hash_mb` MB / hint /
/// eval-cache / history / context; hint and eval-cache sizes derive from
/// hash_mb). Worker k plays games [k*games/N, (k+1)*games/N) with
/// the SAME per-game seed derivation as the single-thread path (Wyhash(seed,
/// game_index)), and games are engine-reset-isolated, so the UNION of
/// positions for a given (seed, games) is IDENTICAL for every N. Output: one
/// file per worker, `<out_path>.w<k>`, each individually deterministic;
/// N == 1 falls through to `run` (plain out_path, byte-identical to before
/// this mode existed). Progress lines aggregate across workers.
pub fn runThreaded(
    progress: *std.Io.Writer,
    seed: u64,
    games: u64,
    out_path: []const u8,
    nodes_per_move: u64,
    random_plies: u32,
    hash_mb: u32,
    threads: u32,
    tb_options: TbOptions,
) !void {
    if (threads == 0 or threads > 512) return error.InvalidThreadCount;
    if (games == 0) return error.InvalidGameCount;
    if (nodes_per_move == 0) return error.InvalidNodeLimit;
    if (random_plies == 0 or random_plies > 100) return error.InvalidRandomPlies;
    if (hash_mb == 0 or hash_mb > 65_536) return error.InvalidHashSize;

    // THE GATE — before any game is played, before the net is loaded. Fathom's
    // globals are set up once here and shared by every worker (tbprobe.c guards
    // its lazy table mapping with a mutex; TB_NO_THREADS is deliberately not
    // defined in the build, see build.zig addFathom).
    const tb = try initTablebases(progress, tb_options);
    defer if (tb.enabled) syzygy.disable();

    // Startup line: hash_mb makes corpora attributable — TT size changes
    // search results at fixed nodes, so it is part of a corpus's identity.
    try progress.print("datagen start: seed {d} games {d} threads {d} nodes {d} random_plies {d} hash_mb {d}\n", .{
        seed, games, threads, nodes_per_move, random_plies, hash_mb,
    });
    try printTbBanner(progress, tb);

    if (threads == 1) return run(progress, seed, games, out_path, nodes_per_move, random_plies, hash_mb);

    const allocator = std.heap.page_allocator;

    // The whole point: load the 74.6MB net ONCE and lend it to every worker.
    const net = try search_engine.loadDefaultNet(allocator);
    defer net.destroy(allocator);

    var shared = SharedProgress{
        .progress = progress,
        .games_total = games,
        .timer = try std.time.Timer.start(),
    };

    const contexts = try allocator.alloc(WorkerContext, threads);
    defer allocator.free(contexts);
    var paths_made: usize = 0;
    defer for (contexts[0..paths_made]) |ctx| allocator.free(ctx.out_path);
    for (contexts, 0..) |*ctx, k| {
        ctx.* = .{
            .shared = &shared,
            .net = net,
            .seed = seed,
            .first_game = @as(u64, k) * games / threads,
            .last_game = (@as(u64, k) + 1) * games / threads,
            .out_path = try std.fmt.allocPrint(allocator, "{s}.w{d}", .{ out_path, k }),
            .nodes_per_move = nodes_per_move,
            .random_plies = random_plies,
            .hash_mb = hash_mb,
        };
        paths_made += 1;
    }

    const handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);
    var spawned: usize = 0;
    var spawn_err: ?anyerror = null;
    for (handles, contexts) |*handle, *ctx| {
        handle.* = std.Thread.spawn(.{}, workerMain, .{ctx}) catch |err| {
            spawn_err = err;
            break;
        };
        spawned += 1;
    }
    for (handles[0..spawned]) |handle| handle.join();
    if (spawn_err) |err| return err;
    if (shared.failed.load(.acquire)) return error.DatagenWorkerFailed;

    const positions = shared.positions.load(.monotonic);
    const discards = shared.discards.load(.monotonic);
    const tb_root_hits = shared.tb_root_hits.load(.monotonic);
    const tb_scored = shared.tb_scored.load(.monotonic);
    const elapsed_ns = shared.timer.read();
    try progress.print("datagen done: seed {d} games {d} threads {d} positions {d} discards {d} tb_root_hits {d} tb_scored_positions {d} elapsed_s {d:.1} pos_per_sec {d:.1}\n", .{
        seed,
        games,
        threads,
        positions,
        discards,
        tb_root_hits,
        tb_scored,
        elapsedSeconds(elapsed_ns),
        rate(positions, elapsed_ns),
    });
    try progress.flush();
}

const SharedProgress = struct {
    progress: *std.Io.Writer,
    /// Serializes progress prints AND the timer reads feeding them (Timer.read
    /// mutates its monotonicity guard).
    mutex: std.Thread.Mutex = .{},
    games_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    positions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    discards: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tb_root_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tb_scored: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    games_total: u64,
    timer: std.time.Timer,
};

const WorkerContext = struct {
    shared: *SharedProgress,
    net: *search_engine.Net,
    seed: u64,
    first_game: u64,
    last_game: u64, // exclusive
    out_path: []u8,
    nodes_per_move: u64,
    random_plies: u32,
    hash_mb: u32,
};

fn workerMain(ctx: *WorkerContext) void {
    workerRun(ctx) catch |err| {
        ctx.shared.failed.store(true, .release);
        ctx.shared.mutex.lock();
        defer ctx.shared.mutex.unlock();
        ctx.shared.progress.print("datagen worker error: {s}: {s}\n", .{ ctx.out_path, @errorName(err) }) catch {};
        ctx.shared.progress.flush() catch {};
    };
}

/// The single-thread game loop, re-rooted at a worker's game range. Mirrors
/// `run` exactly (engine reset per game keeps games order-independent); the
/// only structural difference is the borrowed net and the aggregate counters.
fn workerRun(ctx: *WorkerContext) !void {
    const allocator = std.heap.page_allocator;

    var engine = try search_engine.Engine.initWithSharedNet(allocator, ctx.hash_mb, ctx.net);
    defer engine.deinit();

    var records: [MAX_RECORDS]Record = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var out_file = try std.fs.cwd().createFile(ctx.out_path, .{ .truncate = true });
    defer out_file.close();
    var out_buffer: [128 * 1024]u8 = undefined;
    var file_writer = out_file.writer(&out_buffer);
    const out = &file_writer.interface;

    const limits = time.Limits{ .node_limit = ctx.nodes_per_move };

    var game_index: u64 = ctx.first_game;
    while (game_index < ctx.last_game) : (game_index += 1) {
        _ = arena.reset(.retain_capacity);
        var prng = std.Random.DefaultPrng.init(gameSeed(ctx.seed, game_index));
        const stats = try playOneGame(
            &engine,
            arena.allocator(),
            prng.random(),
            limits,
            ctx.random_plies,
            &records,
            out,
        );
        try out.flush();

        _ = ctx.shared.positions.fetchAdd(stats.positions, .monotonic);
        _ = ctx.shared.discards.fetchAdd(stats.discards, .monotonic);
        _ = ctx.shared.tb_root_hits.fetchAdd(stats.tb_root_hits, .monotonic);
        _ = ctx.shared.tb_scored.fetchAdd(stats.tb_scored_positions, .monotonic);
        const done = ctx.shared.games_done.fetchAdd(1, .monotonic) + 1;
        if (done % PROGRESS_EVERY_GAMES == 0) {
            ctx.shared.mutex.lock();
            defer ctx.shared.mutex.unlock();
            const positions = ctx.shared.positions.load(.monotonic);
            const discards = ctx.shared.discards.load(.monotonic);
            const tb_root_hits = ctx.shared.tb_root_hits.load(.monotonic);
            const tb_scored = ctx.shared.tb_scored.load(.monotonic);
            printProgress(ctx.shared.progress, done, ctx.shared.games_total, positions, discards, tb_root_hits, tb_scored, ctx.shared.timer.read()) catch {};
        }
    }
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
    var tb_root_hits: u64 = 0;
    var tb_scored_positions: u64 = 0;

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

        first_search = engine.search(&pos, &history, limits, &stop_flag);
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
            } else engine.search(&pos, &history, limits, &stop_flag);
            const best_move = search_result.best_move orelse return error.SearchReturnedNoMove;
            const white_pov = whitePov(search_result.score, pos.side_to_move);
            if (isRootTbAnswer(search_result)) tb_root_hits += 1;

            if (game_ply >= RECORD_MIN_PLY and !in_check) {
                if (record_count >= records.len) return error.RecordOverflow;
                records[record_count] = .{
                    .fen_text = try fen.format(arena, &pos),
                    .score_white_pov = white_pov,
                };
                record_count += 1;
                if (isTbScore(white_pov)) tb_scored_positions += 1;
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

    return .{
        .positions = record_count,
        .discards = discards,
        .tb_root_hits = tb_root_hits,
        .tb_scored_positions = tb_scored_positions,
    };
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

fn printProgress(
    progress: anytype,
    done: u64,
    games: u64,
    positions: u64,
    discards: u64,
    tb_root_hits: u64,
    tb_scored: u64,
    elapsed_ns: u64,
) !void {
    // FIELD ORDER IS LOAD-BEARING — new fields go at the END, never in the
    // middle. Downstream parsers pin the first ten tokens:
    //   scripts/cloud-burst/zqb-lib.sh  awk positions=$6, pos_per_sec=$10
    //   zq-fleet server/backfill.py + server/launchers.py  regex requiring
    //     "... discards D pos_per_sec R" ADJACENT
    //   scripts/datagen-mainbox.sh  grep -o 'pos_per_sec [0-9.]*'
    // (The `datagen done:` line has the opposite constraint: pos_per_sec must
    // stay LAST, because scripts/datagen-run.sh reads it as awk $(NF).)
    try progress.print("datagen progress: games {d}/{d} positions {d} discards {d} pos_per_sec {d:.1} tb_root_hits {d} tb_scored_positions {d}\n", .{
        done,
        games,
        positions,
        discards,
        rate(positions, elapsed_ns),
        tb_root_hits,
        tb_scored,
    });
    try progress.flush();
}

test "game seeds do not collide across neighbouring process seeds" {
    // seed s game g must differ from seed s+1 game g-1 (the additive trap).
    try std.testing.expect(gameSeed(1000, 1) != gameSeed(1001, 0));
    try std.testing.expect(gameSeed(1000, 0) != gameSeed(1001, 0));
    try std.testing.expect(gameSeed(1000, 0) != gameSeed(1000, 1));
}

test "threaded datagen partitions the exact single-thread game stream" {
    // 2 workers over 4 games must produce, concatenated in worker order, the
    // byte-identical single-thread file: the split is a pure partition of the
    // same per-game streams (order within each range preserved), so this is
    // stronger than the sorted-union check the ship gates run externally.
    const path_single = "zigqueen-datagen-test-single.txt";
    const path_threaded = "zigqueen-datagen-test-threaded.txt";
    defer std.fs.cwd().deleteFile(path_single) catch {};
    defer std.fs.cwd().deleteFile(path_threaded ++ ".w0") catch {};
    defer std.fs.cwd().deleteFile(path_threaded ++ ".w1") catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    // TB-blind on purpose: this test asserts the worker PARTITION, and the
    // partition must not depend on tablebase state (which is a global).
    try run(&sink.writer, 42, 4, path_single, 64, 6, default_hash_mb);
    try runThreaded(&sink.writer, 42, 4, path_threaded, 64, 6, default_hash_mb, 2, .{ .allow_none = true });

    const single = try std.fs.cwd().readFileAlloc(std.testing.allocator, path_single, 16 << 20);
    defer std.testing.allocator.free(single);
    const w0 = try std.fs.cwd().readFileAlloc(std.testing.allocator, path_threaded ++ ".w0", 16 << 20);
    defer std.testing.allocator.free(w0);
    const w1 = try std.fs.cwd().readFileAlloc(std.testing.allocator, path_threaded ++ ".w1", 16 << 20);
    defer std.testing.allocator.free(w1);

    const joined = try std.mem.concat(std.testing.allocator, u8, &.{ w0, w1 });
    defer std.testing.allocator.free(joined);
    try std.testing.expect(single.len > 0);
    try std.testing.expectEqualStrings(single, joined);
}

test "datagen output is deterministic, parseable, and check-free" {
    const path_a = "zigqueen-datagen-test-a.txt";
    const path_b = "zigqueen-datagen-test-b.txt";
    defer std.fs.cwd().deleteFile(path_a) catch {};
    defer std.fs.cwd().deleteFile(path_b) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, 42, 2, path_a, 64, 6, default_hash_mb);
    try run(&sink.writer, 42, 2, path_b, 64, 6, default_hash_mb);

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

test "datagen refuses to start without a tablebase path" {
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    // No --syzygy, no --allow-no-syzygy: hard refusal BEFORE any file is
    // created (the out_path below must never appear on disk).
    const path = "zigqueen-datagen-test-refused.txt";
    defer std.fs.cwd().deleteFile(path) catch {};
    try std.testing.expectError(
        error.SyzygyPathRequired,
        runThreaded(&sink.writer, 42, 1, path, 64, 6, default_hash_mb, 1, .{}),
    );
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));

    // An empty path string is the same refusal, not a silent TB-off run.
    try std.testing.expectError(
        error.SyzygyPathRequired,
        runThreaded(&sink.writer, 42, 1, path, 64, 6, default_hash_mb, 1, .{ .path = "" }),
    );

    // Both flags at once is ambiguous intent, never "the permissive one wins".
    try std.testing.expectError(
        error.SyzygyFlagConflict,
        runThreaded(&sink.writer, 42, 1, path, 64, 6, default_hash_mb, 1, .{ .path = "/nonexistent", .allow_none = true }),
    );

    // A path that is not a readable directory fails hard.
    try std.testing.expectError(
        error.SyzygyPathUnreadable,
        runThreaded(&sink.writer, 42, 1, path, 64, 6, default_hash_mb, 1, .{ .path = "/nonexistent-syzygy-dir" }),
    );

    // A directory with too few tables fails hard rather than half-working.
    const empty_dir = "zigqueen-datagen-test-emptytb";
    try std.fs.cwd().makePath(empty_dir);
    defer std.fs.cwd().deleteTree(empty_dir) catch {};
    try std.testing.expectError(
        error.SyzygyTablesIncomplete,
        runThreaded(&sink.writer, 42, 1, path, 64, 6, default_hash_mb, 1, .{ .path = empty_dir }),
    );
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));

    // Every refusal must have said why, loudly, in the run's own log stream.
    const log = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "REFUSES TO START") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "mutually exclusive") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "not readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "incomplete tablebase set") != null);
}

test "tablebase score band is disjoint from the mate band" {
    const score_mod = @import("../search/score.zig");
    // Root DTZ extremes (dtz 0 and the dtz 1000 clamp) and the in-search WDL
    // score both count as tablebase verdicts...
    try std.testing.expect(isTbScore(syzygy.TB_WIN_SCORE));
    try std.testing.expect(isTbScore(syzygy.TB_WIN_SCORE - 1000));
    try std.testing.expect(isTbScore(-(syzygy.TB_WIN_SCORE - 128)));
    // ...while mates and ordinary evals never do.
    try std.testing.expect(!isTbScore(score_mod.MATE_SCORE));
    try std.testing.expect(!isTbScore(score_mod.MATE_THRESHOLD));
    try std.testing.expect(!isTbScore(-score_mod.MATE_SCORE));
    try std.testing.expect(!isTbScore(0));
    try std.testing.expect(!isTbScore(4800));
    try std.testing.expect(!isTbScore(-4800));
    try std.testing.expect(!isTbScore(std.math.minInt(i32)));
    // The bands must not touch: highest TB score < lowest mate score.
    try std.testing.expect(syzygy.TB_WIN_SCORE < score_mod.MATE_THRESHOLD);
}

test "tablebase gate accepts a real table directory (opt-in via ZQ_TB_PATH)" {
    const tb_path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return;
    defer std.testing.allocator.free(tb_path);

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    const state = try initTablebases(&sink.writer, .{ .path = tb_path });
    defer syzygy.disable();
    try std.testing.expect(state.enabled);
    try std.testing.expect(state.rtbw >= MIN_RTBW_FILES);
    try std.testing.expect(state.rtbz >= MIN_RTBZ_FILES);
    try std.testing.expect(state.largest >= 5);
    try printTbBanner(&sink.writer, state);
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "datagen syzygy: ENABLED") != null);
}
