//! Game-order-aware Syzygy backfill of the RESULT channel in datagen text.
//!
//! WHY THIS EXISTS: datagen writes ONE game result onto EVERY position of the
//! game (src/tools/datagen.zig backfills `result_text` over all buffered
//! records). Generation runs with no SyzygyPath, so the engine cannot convert
//! basic tablebase wins -- measured 67.0% conversion with tablebases off vs
//! 96.6% with them on, same positions and node budget. A game that reaches a
//! won endgame and then draws it by the 50-move rule therefore mislabels its
//! WHOLE history, most of which is middlegame positions. Measured blast radius:
//! ~3.2% of games, ~7% of positions -- far more than the 10.3% <=5-man slice a
//! per-position rescore can reach, because the packed corpus is shuffled and
//! has no game identity left.
//!
//! WHAT IT CHANGES: the result field only. Scores are untouched, so the result
//! channel is the single variable.
//!
//! GAME SEGMENTATION: datagen emits a game's records contiguously, in ply
//! order, so (fullmove_number, side_to_move) strictly increases within a game
//! and resets to (9, white) at the next game. A new game is therefore declared
//! whenever that pair fails to increase -- which catches the awkward case of a
//! game that recorded only its first ply or two, where a bare "fullmove
//! decreased" test would silently merge two games.
//!
//! CLOCK HANDLING, and why it needs care both ways:
//!   * `syzygy.probeWdl` REFUSES a position with halfmove_clock != 0 (its
//!     in-search contract), and 92.3% of the corpus's <=5-man positions have a
//!     nonzero clock -- so probing the position as-is silently answers "unknown"
//!     for almost everything. The probe is therefore issued on a clock-zeroed
//!     copy, which is what WDL tables actually model.
//!   * That makes the verdict rule-50-blind, so positions with halfmove_clock
//!     >= `hmc_cutoff` (default 90) are NOT used as evidence: near the 50-move
//!     boundary a WDL "win" may genuinely be a draw. A game whose only
//!     tablebase-decided positions sit above the cutoff keeps its original
//!     result. The skipped fraction is reported.
//!
//! VERDICT CHOICE: the FIRST tablebase-decided position the game reaches (below
//! the cutoff) supplies the result. That is the earliest moment the game's value
//! became knowable; later positions can be worse only because a side blundered,
//! which is exactly the failure being corrected.
const std = @import("std");
const fen = @import("../core/fen.zig");
const position = @import("../core/position.zig");
const syzygy = @import("../search/syzygy.zig");

pub const Options = struct {
    input_path: []const u8,
    output_path: []const u8,
    tb_path: []const u8,
    /// Process only the first N lines (reproduces a live-snapshot pack).
    max_lines: u64,
    /// halfmove_clock at/above which a WDL verdict is not trusted.
    hmc_cutoff: u16,
    dry_run: bool,
};

pub const Stats = struct {
    lines: u64 = 0,
    games: u64 = 0,
    games_reached_tb: u64 = 0,
    games_changed: u64 = 0,
    lines_changed: u64 = 0,
    /// games where every TB-decided position sat at/above the clock cutoff
    games_skipped_hmc: u64 = 0,
    parse_fail: u64 = 0,
    truncated_tail: u64 = 0,
    /// original -> new result transitions, indexed [old][new] with 0=L,1=D,2=W
    trans: [3][3]u64 = .{.{0} ** 3} ** 3,

    pub fn merge(self: *Stats, o: *const Stats) void {
        self.lines += o.lines;
        self.games += o.games;
        self.games_reached_tb += o.games_reached_tb;
        self.games_changed += o.games_changed;
        self.lines_changed += o.lines_changed;
        self.games_skipped_hmc += o.games_skipped_hmc;
        self.parse_fail += o.parse_fail;
        self.truncated_tail += o.truncated_tail;
        for (0..3) |i| for (0..3) |j| {
            self.trans[i][j] += o.trans[i][j];
        };
    }
};

const MAX_GAME_LINES: usize = 2048;

fn resultIdx(text: []const u8) ?u8 {
    if (std.mem.eql(u8, text, "1.0")) return 2;
    if (std.mem.eql(u8, text, "0.5")) return 1;
    if (std.mem.eql(u8, text, "0.0")) return 0;
    return null;
}

fn resultText(idx: u8) []const u8 {
    return switch (idx) {
        2 => "1.0",
        1 => "0.5",
        else => "0.0",
    };
}

const LineInfo = struct {
    pos: position.Position,
    men: u32,
    hmc: u16,
    fullmove: u32,
    stm_rank: u8, // 0 white, 1 black
};

fn parseLine(line: []const u8) ?LineInfo {
    const bar = std.mem.indexOfScalar(u8, line, '|') orelse return null;
    const fen_text = std.mem.trimRight(u8, line[0..bar], " ");
    const pos = fen.parse(fen_text) catch return null;
    return .{
        .pos = pos,
        .men = @popCount(pos.occupied),
        .hmc = pos.halfmove_clock,
        .fullmove = pos.fullmove_number,
        .stm_rank = if (pos.side_to_move == .white) 0 else 1,
    };
}

const Ctx = struct {
    st: *Stats,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    game: *std.ArrayList([]const u8),
    out: ?*std.Io.Writer,
    hmc_cutoff: u16,
    prev_fm: u32 = 0,
    prev_stm: u8 = 0,
    verdict: ?u8 = null,
    had_above: bool = false,
    reached_tb: bool = false,

    fn resetGame(self: *Ctx) void {
        _ = self.arena.reset(.retain_capacity);
        self.game.clearRetainingCapacity();
        self.verdict = null;
        self.had_above = false;
        self.reached_tb = false;
    }

    fn flush(self: *Ctx) !void {
        if (self.game.items.len == 0) return;
        const st = self.st;
        st.games += 1;
        if (self.reached_tb) st.games_reached_tb += 1;
        if (!self.reached_tb and self.had_above) st.games_skipped_hmc += 1;

        // The original result is constant within a game; read it from line 1.
        const first = self.game.items[0];
        const old_idx: ?u8 = blk: {
            const cut = std.mem.lastIndexOfScalar(u8, first, '|') orelse break :blk null;
            break :blk resultIdx(std.mem.trim(u8, first[cut + 1 ..], " \r"));
        };

        const change = self.verdict != null and old_idx != null and self.verdict.? != old_idx.?;
        if (change) {
            st.games_changed += 1;
            st.lines_changed += self.game.items.len;
            st.trans[old_idx.?][self.verdict.?] += self.game.items.len;
        }

        if (self.out) |w| {
            if (change) {
                const new_text = resultText(self.verdict.?);
                for (self.game.items) |line| {
                    const cut = std.mem.lastIndexOfScalar(u8, line, '|') orelse {
                        try w.print("{s}\n", .{line});
                        continue;
                    };
                    // `cut` is the index of the last '|', so the slice already
                    // ENDS with it — append " <result>", never another bar.
                    try w.print("{s} {s}\n", .{ line[0 .. cut + 1], new_text });
                }
            } else {
                for (self.game.items) |line| try w.print("{s}\n", .{line});
            }
        }
    }

    fn processLine(self: *Ctx, line: []const u8) !void {
        self.st.lines += 1;
        const info = parseLine(line) orelse {
            self.st.parse_fail += 1;
            return;
        };

        const is_new = self.game.items.len > 0 and
            (info.fullmove < self.prev_fm or
                (info.fullmove == self.prev_fm and info.stm_rank <= self.prev_stm));
        if (is_new) {
            try self.flush();
            self.resetGame();
        }
        self.prev_fm = info.fullmove;
        self.prev_stm = info.stm_rank;

        if (info.men <= syzygy.pieceLimit()) {
            if (info.hmc >= self.hmc_cutoff) {
                self.had_above = true;
            } else {
                // WDL tables model a fresh rule-50 counter; probeWdl refuses a
                // nonzero clock, so probe a clock-zeroed copy. The cutoff above
                // is what keeps that sound.
                var p = info.pos;
                p.halfmove_clock = 0;
                if (syzygy.probeWdl(&p)) |wdl| {
                    self.reached_tb = true;
                    if (self.verdict == null) {
                        switch (wdl) {
                            .win => self.verdict = if (info.stm_rank == 0) @as(u8, 2) else @as(u8, 0),
                            .loss => self.verdict = if (info.stm_rank == 0) @as(u8, 0) else @as(u8, 2),
                            .draw => {},
                        }
                    }
                }
            }
        }

        if (self.game.items.len >= MAX_GAME_LINES) {
            // Defensive: never let a segmentation slip grow unbounded.
            try self.flush();
            self.resetGame();
        }
        try self.game.append(self.allocator, try self.arena.allocator().dupe(u8, line));
    }
};

pub fn runFile(opts: Options) !Stats {
    var st = Stats{};
    const allocator = std.heap.page_allocator;

    const in_file = try std.fs.cwd().openFile(opts.input_path, .{});
    defer in_file.close();

    var out_file: ?std.fs.File = null;
    defer if (out_file) |f| f.close();
    const out_buf = try allocator.alloc(u8, 4 << 20);
    defer allocator.free(out_buf);
    var out_writer: std.fs.File.Writer = undefined;
    var out: ?*std.Io.Writer = null;
    if (!opts.dry_run) {
        out_file = try std.fs.cwd().createFile(opts.output_path, .{ .truncate = true });
        out_writer = out_file.?.writer(out_buf);
        out = &out_writer.interface;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var game = std.ArrayList([]const u8){};
    defer game.deinit(allocator);
    try game.ensureTotalCapacity(allocator, MAX_GAME_LINES);

    var ctx = Ctx{
        .st = &st,
        .allocator = allocator,
        .arena = &arena,
        .game = &game,
        .out = out,
        .hmc_cutoff = opts.hmc_cutoff,
    };

    // Manual chunked line splitting. The Io.Reader delimiter helpers differ in
    // whether they consume the delimiter, and getting that wrong is an infinite
    // loop on empty lines; a plain read + memchr loop has no such ambiguity and
    // reproduces the packer's torn-tail rule exactly (a trailing line with no
    // newline is dropped, matching zq_pack_selfplay).
    const CHUNK: usize = 8 << 20;
    const buf = try allocator.alloc(u8, CHUNK);
    defer allocator.free(buf);
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    var done = false;
    while (!done) {
        const n = try in_file.readAll(buf);
        if (n == 0) break;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf[0..n], start, '\n')) |nl| {
            var line = buf[start..nl];
            if (carry.items.len > 0) {
                try carry.appendSlice(allocator, line);
                line = carry.items;
            }
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len > 0) {
                if (opts.max_lines != 0 and st.lines >= opts.max_lines) {
                    done = true;
                    carry.clearRetainingCapacity();
                    break;
                }
                try ctx.processLine(trimmed);
            }
            carry.clearRetainingCapacity();
            start = nl + 1;
        }
        if (!done and start < n) try carry.appendSlice(allocator, buf[start..n]);
        if (n < buf.len) break;
    }
    // A leftover carry means the file did not end with a newline: that is the
    // packer's `truncated_tail` case, and the line is dropped, not emitted.
    if (carry.items.len > 0) st.truncated_tail += 1;

    try ctx.flush();
    if (out) |w| try w.flush();
    return st;
}

/// Multi-file driver: one worker per file (files are independent).
pub fn run(
    progress: *std.Io.Writer,
    files: []const []const u8,
    out_dir: []const u8,
    opts: Options,
    max_lines: []const u64,
    threads: u32,
) !void {
    @import("../search/startup.zig").ensure();
    const allocator = std.heap.page_allocator;
    const tb_pathz = try allocator.dupeZ(u8, opts.tb_path);
    defer allocator.free(tb_pathz);
    if (!syzygy.init(tb_pathz)) return error.SyzygyInitFailed;
    defer syzygy.disable();

    try progress.print("result_backfill start: files {d} tb_largest {d} threads {d} hmc_cutoff {d} dry_run {}\n", .{
        files.len, syzygy.pieceLimit(), threads, opts.hmc_cutoff, opts.dry_run,
    });
    try progress.flush();

    var shared = Shared{
        .progress = progress,
        .files = files,
        .out_dir = out_dir,
        .opts = opts,
        .max_lines = max_lines,
        .total_files = files.len,
    };
    const handles = try allocator.alloc(std.Thread, threads);
    defer allocator.free(handles);
    var spawned: usize = 0;
    for (handles) |*h| {
        h.* = std.Thread.spawn(.{}, worker, .{&shared}) catch break;
        spawned += 1;
    }
    for (handles[0..spawned]) |h| h.join();
    if (shared.failed.load(.acquire)) return error.BackfillWorkerFailed;

    const st = shared.stats;
    const pct = struct {
        fn f(x: u64, n: u64) f64 {
            return if (n == 0) 0 else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(n));
        }
    }.f;
    try progress.print("\nBACKFILLSTATS lines={d} games={d} mean_lines_per_game={d:.1} truncated_tail={d}\n", .{
        st.lines,                                                                                        st.games,
        if (st.games == 0) 0 else @as(f64, @floatFromInt(st.lines)) / @as(f64, @floatFromInt(st.games)), st.truncated_tail,
    });
    try progress.print("BACKFILLSTATS games_reached_tb={d} ({d:.2}%) games_changed={d} ({d:.2}%) lines_changed={d} ({d:.2}%)\n", .{
        st.games_reached_tb, pct(st.games_reached_tb, st.games),
        st.games_changed,    pct(st.games_changed, st.games),
        st.lines_changed,    pct(st.lines_changed, st.lines),
    });
    try progress.print("BACKFILLSTATS games_skipped_by_hmc_cutoff={d} ({d:.3}%) parse_fail={d}\n", .{
        st.games_skipped_hmc, pct(st.games_skipped_hmc, st.games), st.parse_fail,
    });
    const nm = [_][]const u8{ "loss", "draw", "win " };
    try progress.print("RESULT TRANSITIONS (positions) old -> new\n", .{});
    for (0..3) |i| for (0..3) |j| {
        if (st.trans[i][j] != 0) {
            try progress.print("  {s} -> {s} : {d}\n", .{ nm[i], nm[j], st.trans[i][j] });
        }
    };
    try progress.flush();
}

const Shared = struct {
    progress: *std.Io.Writer,
    mutex: std.Thread.Mutex = .{},
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stats: Stats = .{},
    files: []const []const u8,
    out_dir: []const u8,
    opts: Options,
    max_lines: []const u64,
    total_files: usize,
};

fn worker(sh: *Shared) void {
    const allocator = std.heap.page_allocator;
    while (true) {
        const idx = sh.next.fetchAdd(1, .monotonic);
        if (idx >= sh.files.len) return;
        const in_path = sh.files[idx];
        const base = std.fs.path.basename(in_path);
        const out_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sh.out_dir, base }) catch {
            sh.failed.store(true, .release);
            return;
        };
        defer allocator.free(out_path);

        var o = sh.opts;
        o.input_path = in_path;
        o.output_path = out_path;
        o.max_lines = if (idx < sh.max_lines.len) sh.max_lines[idx] else 0;

        const st = runFile(o) catch |err| {
            sh.failed.store(true, .release);
            sh.mutex.lock();
            defer sh.mutex.unlock();
            sh.progress.print("result_backfill error on {s}: {s}\n", .{ in_path, @errorName(err) }) catch {};
            sh.progress.flush() catch {};
            return;
        };

        sh.mutex.lock();
        defer sh.mutex.unlock();
        sh.stats.merge(&st);
        sh.progress.print("  [{d}/{d}] {s} lines={d} games={d} changed_games={d} changed_lines={d}\n", .{
            idx + 1, sh.total_files, base, st.lines, st.games, st.games_changed, st.lines_changed,
        }) catch {};
        sh.progress.flush() catch {};
    }
}

test "result text round-trips" {
    try std.testing.expectEqual(@as(?u8, 2), resultIdx("1.0"));
    try std.testing.expectEqual(@as(?u8, 1), resultIdx("0.5"));
    try std.testing.expectEqual(@as(?u8, 0), resultIdx("0.0"));
    try std.testing.expectEqualStrings("0.5", resultText(1));
    try std.testing.expectEqual(@as(?u8, null), resultIdx("x"));
}

test "line parse extracts the segmentation key" {
    const a = parseLine("4k3/8/8/4P3/8/8/8/4K3 w - - 0 9 | 10 | 1.0") orelse return error.TestParse;
    try std.testing.expectEqual(@as(u32, 9), a.fullmove);
    try std.testing.expectEqual(@as(u8, 0), a.stm_rank);
    try std.testing.expectEqual(@as(u32, 3), a.men);
    const b = parseLine("4k3/8/8/4P3/8/8/8/4K3 b - - 3 9 | 10 | 1.0") orelse return error.TestParse;
    try std.testing.expectEqual(@as(u8, 1), b.stm_rank);
    try std.testing.expectEqual(@as(u16, 3), b.hmc);
    try std.testing.expect(parseLine("garbage") == null);
}
