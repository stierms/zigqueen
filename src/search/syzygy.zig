//! Syzygy tablebase probing with our own prober (src/tb,
//! docs/SYZYGY_FORMAT.md). Disabled unless a SyzygyPath is set — with no path,
//! probeWdl always returns null and play is bit-identical to a TB-less build.
//!
//! Threading: `init` builds an immutable snapshot off the search path and
//! swaps it in. A search pins the current snapshot for its whole job with one
//! lease (`beginJob`); helpers borrow that Job. Probes take no lock and nothing
//! is exclusive. Releasing a lease never frees: a replaced snapshot is freed by
//! the thread that calls `init`, `disable` or `collect` (the UCI thread), once
//! its last lease is gone. The engine also stops every search before a path
//! change, so in practice the old snapshot is freed inside `init`.
const std = @import("std");
const build_options = @import("build_options");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");
const tb = @import("../tb/tb.zig");
const move_mod = @import("../core/move.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const repetition = @import("repetition.zig");
const MoveList = move_mod.MoveList;

const storage_mode = tb.storage.modeFromName(build_options.tb_storage);
const Backend = tb.storage.Backend(storage_mode);
const Registry = tb.Registry(Backend);
const Prober = tb.Prober(Backend);
// The process registry: one current snapshot, leased per job.
var registry: Registry = .{};

/// Clearly above any eval, clearly below the mate band (MATE_SCORE 29_000,
/// threshold 28_872): a proven TB win outranks judgment, never masquerades
/// as a concrete mate.
pub const TB_WIN_SCORE: types.Score = score_mod.TB_WIN_SCORE;

/// Load the tables of a SyzygyPath list (`:`-separated, `;` on Windows). True
/// when at least one table loaded; otherwise tablebases are off. The mapping
/// modes map every file here, smallest first and as the budget allows, so
/// `report` can tell what is mapped and what falls back to positioned reads
/// before any search runs.
pub fn init(path: []const u8) bool {
    return load(path, .{});
}

/// `init` with explicit storage options (tests: a small budget).
pub fn load(path: []const u8, options: tb.storage.Options) bool {
    const snap = tb.registry.build(Backend, std.heap.page_allocator, path, options) catch {
        registry.swap(null);
        return false;
    };
    if (snap.max_pieces == 0) {
        snap.destroy();
        registry.swap(null);
        return false;
    }
    // Publish first: the swap frees the previous snapshot (no search holds a
    // lease during a path change), so its mappings no longer occupy the
    // address space this snapshot maps into. Only this (the UCI) thread frees
    // snapshots, and each file's mapping is published once by CAS, so mapping
    // after publication is safe even against a concurrent probe.
    registry.swap(snap);
    if (comptime @hasDecl(Backend, "mapAll")) snap.io.mapAll();
    return true;
}

/// What the current tables are and how they are stored.
pub const Report = struct {
    wdl_files: u32,
    dtz_files: u32,
    rejected: u32,
    max_pieces: u8,
    storage: []const u8 = build_options.tb_storage,
    mapped_files: u32,
    mapped_bytes: u64,
    pread_files: u32,
    map_failures: u32,

    /// One `info string` line for the UCI thread after a SyzygyPath change.
    /// Formatted into its own buffer, sized for the largest values (tested),
    /// so a long line can never fail the UCI command that prints it.
    pub fn write(self: Report, writer: anytype) !void {
        var buffer: [line_capacity]u8 = undefined;
        try writer.writeAll(self.line(&buffer));
    }

    const line_capacity = 384;

    fn line(self: Report, buffer: *[line_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "info string Syzygy tables: {d} WDL and {d} DTZ files, up to {d} pieces, {d} rejected; storage {s}: {d} files mapped ({d} MiB), {d} on positioned reads, {d} mapping failures\n", .{
            self.wdl_files, self.dtz_files, self.max_pieces, self.rejected, self.storage, self.mapped_files, self.mapped_bytes >> 20, self.pread_files, self.map_failures,
        }) catch "info string Syzygy tables: report too long\n";
    }
};

/// The current tables' report; null when tablebases are off.
pub fn report() ?Report {
    var job = beginJob();
    defer job.deinit();
    const snap = job.lease.snap orelse return null;
    const io = snap.ioStats();
    const files: u32 = @intCast(snap.files.paths.len);
    return .{
        .wdl_files = snap.stats.wdl_files,
        .dtz_files = snap.stats.dtz_files,
        .rejected = snap.stats.rejected,
        .max_pieces = snap.max_pieces,
        .mapped_files = io.mapped_files,
        .mapped_bytes = io.mapped_bytes,
        .pread_files = if (comptime storage_mode == .pread) files else io.pread_files,
        .map_failures = io.map_failures,
    };
}
pub fn disable() void {
    registry.swap(null);
}
/// Free replaced snapshots whose last lease is gone. Same thread as `init`.
pub fn collect() void {
    registry.collect();
}
/// Replaced snapshots still pinned by a lease (0 whenever no search runs).
pub fn retiredCount() usize {
    return registry.retiredCount();
}
pub fn enabled() bool {
    return pieceLimit() != 0;
}
pub fn pieceLimit() u32 {
    return registry.pieceLimit();
}

/// One search job's pinned snapshot. The owner releases it once, after every
/// helper borrowing *const Job has returned.
pub const Job = struct {
    lease: Registry.Lease = .{},

    pub fn deinit(self: *Job) void {
        self.lease.release();
    }
    pub fn enabled(self: *const Job) bool {
        return self.lease.largest != 0;
    }
    /// Per-node search gate: false for every position out of WDL scope (clock,
    /// castling, piece count), so the caller skips the out-of-line probe.
    pub inline fn wdlInScope(self: *const Job, pos: *const position.Position) bool {
        return pos.halfmove_clock == 0 and inScope(pos, self.lease.largest);
    }
    pub inline fn probeWdl(self: *const Job, pos: *const position.Position) ?Wdl {
        if (!self.wdlInScope(pos)) return null;
        return self.probeCoveredWdl(pos);
    }
    /// Out-of-line probe for a position that passed wdlInScope.
    pub noinline fn probeCoveredWdl(self: *const Job, pos: *const position.Position) ?Wdl {
        const snap = self.lease.snap orelse return null;
        return collapseWdl(Prober.wdlLegal(snap, pos) catch return null);
    }
    /// Clock- and history-aware root ranking of every legal move, reduced to
    /// the moves that keep the best outcome (`rootPolicy`). `history` is the
    /// game so far, ending with `pos`; the tables themselves never see it.
    /// Null when the root is out of scope, terminal, or any probe fails.
    pub fn probeRootMoves(self: *const Job, pos: *const position.Position, allowed: ?*const MoveList, history: ?*const repetition.History) ?RootPolicy {
        const snap = self.lease.snap orelse return null;
        if (!inScope(pos, self.lease.largest)) return null;
        var ranking: tb.RootRanking = .{};
        Prober.rankRoot(snap, pos, pos.halfmove_clock, &ranking) catch return null;
        if (ranking.terminal != .none) return null;
        var seen = [_]u8{0} ** move_mod.MAX_MOVES;
        var repeated = false;
        if (history) |game| {
            childOccurrences(pos, &ranking, game, &seen);
            repeated = game.windowHasRepetition(pos.halfmove_clock);
        }
        return rootPolicy(&ranking, allowed, pos.halfmove_clock, &seen, repeated);
    }
};

pub fn beginJob() Job {
    return .{ .lease = registry.acquire() };
}

inline fn inScope(pos: *const position.Position, limit: u32) bool {
    return @popCount(pos.occupied) <= limit and !pos.castling_rights.hasAny();
}

pub const Wdl = enum { loss, draw, win };

fn collapseWdl(w: tb.Wdl5) Wdl {
    return switch (w) {
        .win => .win,
        .loss => .loss,
        .draw, .cursed_win, .blessed_loss => .draw,
    };
}

/// WDL probe. Null when disabled, position out of TB scope, or probing is
/// unsound (castling rights, nonzero halfmove clock — WDL tables assume a
/// fresh rule-50 counter). Cursed wins / blessed losses collapse to draw (the
/// 50-move rule saves/dooms them). Pins a snapshot for this one probe.
pub fn probeWdl(pos: *const position.Position) ?Wdl {
    var job = beginJob();
    defer job.deinit();
    return job.probeWdl(pos);
}

/// Immutable once the coordinator publishes helpers. `moves` holds every legal
/// move inside the caller's searchmoves restriction that keeps the best
/// outcome; cursed wins and blessed losses are draws, so practical
/// alternatives are retained.
pub const RootPolicy = struct {
    moves: MoveList,
    /// The best outcome among those moves' own states.
    wdl: Wdl,
    /// The certain win the engine plays at once (`rootPolicy`), or null: the
    /// root is no win, or no allowed win is certain, and the engine searches
    /// `moves` instead.
    instant: ?move_mod.Move,
    /// |DTZ| in plies behind `instant`: the root's for the ranking's
    /// suggested move, the move's own otherwise. 0 without `instant`.
    dtz: u32,
    /// `wdl` is proven, not only a ranking: false for a win with no certain
    /// allowed win, for a loss with an uncertain allowed loss, and for a win
    /// or loss once the game history holds a repeated position
    /// (`authoritativeWdl`).
    proven: bool,

    /// The outcome the engine may install as the root's score in place of
    /// searched scores, or null when `wdl` only ranks `moves`. With only
    /// rounded boundary wins allowed, or one rounded boundary loss, the root
    /// may be a 50-move draw, and a repeated position in the history may let
    /// either side claim a draw later, so the search decides the score
    /// (review round, U-TB-DTZ100, U-TB-REP).
    pub fn authoritativeWdl(self: *const RootPolicy) ?Wdl {
        return if (self.proven) self.wdl else null;
    }
};

/// How often each non-zeroing root move's child already occurred in the game
/// (`repetition.History.childOccurrences`); zeroing moves reset the window.
fn childOccurrences(pos: *const position.Position, ranking: *const tb.RootRanking, history: *const repetition.History, seen: *[move_mod.MAX_MOVES]u8) void {
    for (ranking.slice(), 0..) |rec, i| {
        if (rec.zeroing) continue;
        var child = pos.*;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&child, rec.move, &state);
        seen[i] = @intCast(@min(history.childOccurrences(child.zobrist_key, child.halfmove_clock), 2));
    }
}

/// A win whose rule-50 outcome the tables guarantee: an exact DTZ, a mate or
/// zeroing win (r = 1), or room to spare (r + c <= 99). A rounded DTZ can be
/// one ply short, so at r + c = 100 it may be a 50-move draw (§8.1).
fn certainWin(rec: tb.RootRecord, c: u32) bool {
    return rec.exact or rec.r == 1 or @as(i64, rec.r) + c <= 99;
}

/// The mirror for a loss: an exact DTZ, a zeroing loss (r = -1), or
/// -r + c <= 99. A rounded opponent DTZ can be one ply short, so at
/// -r + c = 100 the move may reach the 50-move claim: in
/// `8/8/8/Q7/8/1p6/k6K/8 b - - 94 1`, a2b2 has r = -6 (opponent DTZ 5,
/// rounded) but White needs 6 plies, and Black claims the draw.
fn certainLoss(rec: tb.RootRecord, c: u32) bool {
    return rec.exact or rec.r == -1 or -@as(i64, rec.r) + c <= 99;
}

/// A root move's rank in `rootPolicy` (`wdl` is its outcome after history).
/// Without a repeated window certainty splits the decisive classes:
/// certain win > uncertain win > draw > uncertain loss > certain loss. An
/// uncertain win is at worst a draw and an uncertain loss at best one, so
/// keeping only the best rank discards no value, and a proven outcome comes
/// with a move set that holds only moves keeping it. With a repeated window
/// a claim may spoil a certain win or save a certain loss, so certainty
/// proves nothing there and the classes stay whole: win > draw > loss.
fn moveRank(wdl: Wdl, rec: tb.RootRecord, c: u32, repeated: bool) u3 {
    return switch (wdl) {
        .win => if (repeated or certainWin(rec, c)) 4 else 3,
        .draw => 2,
        .loss => if (repeated or certainLoss(rec, c)) 0 else 1,
    };
}

/// The root policy over the prober's history-free ranking (SYZYGY_FORMAT.md
/// §9.2, §9.5); the clock `c` and the game history are applied here:
/// - A non-zeroing move whose child would be the third occurrence of its
///   position is a draw, whatever the tables say: the opponent can claim it
///   (audit D, U-TB-REP).
/// - The outcome is the best among the allowed moves' own states. The root
///   summary state never stands in for the suggested move's own state: at
///   clock 99 every move of `8/8/8/6p1/8/8/Q7/3K3k w - - 99 2` reaches the
///   50-move claim, but the summary said win (U-TB-DTZ100).
/// - `moves` holds the allowed moves of the best rank (`moveRank`). A
///   rounded boundary win (r + c = 100, `8/8/Q7/6p1/8/8/8/3K2k1 w - - 97 1`
///   a6a2) is dropped once a certain win is allowed: in a mixed set the
///   search chose it and the root reported the certain win's proof (review
///   round, Astra F1). A rounded boundary loss is kept over certain losses:
///   it may draw.
/// - Only a certain win (`certainWin`) whose child has not occurred before
///   is played at once: the suggested move when it is one, else the one with
///   the smallest r (generation order on ties). A certain win into a twofold
///   stays in `moves`; with nothing to play at once the engine searches
///   `moves`.
/// - The outcome is proven (`RootPolicy.authoritativeWdl`) for a draw, and
///   for a win or loss only at the certain ranks: every move in `moves` then
///   keeps it.
/// - `repeated`: some position of the root's reversible window has already
///   occurred twice (`repetition.History.windowHasRepetition`). Then nothing
///   is played at once, a win or loss is not proven, and the decisive
///   classes stay whole: a later reply may complete a third occurrence
///   (review round, U-TB-REP: after `e1f1` in
///   `8/8/8/8/8/8/7k/R4K2 w - - 1 1 moves f1e1 h2h3 e1f1 h3h2 f1e1 h2h1`
///   Black's only move repeats the start a third time). Otherwise the winner
///   plays DTZ-optimally from a certain win: DTZ falls every ply until the
///   next zeroing move, so no position of that line repeats within it, an
///   earlier position can come back at most once (it occurred at most once
///   before), and no third occurrence exists. A draw stays proven: claims
///   only draw.
fn rootPolicy(ranking: *const tb.RootRanking, allowed: ?*const MoveList, c: u32, seen: *const [move_mod.MAX_MOVES]u8, repeated: bool) ?RootPolicy {
    const suggested = ranking.suggested orelse return null;
    var policy = RootPolicy{ .moves = MoveList.init(), .wdl = .loss, .instant = null, .dtz = 0, .proven = false };
    var best: ?u3 = null;
    var instant: ?usize = null;
    for (ranking.slice(), 0..) |rec, i| {
        if (allowed) |list| {
            if (std.mem.indexOfScalar(move_mod.Move, list.slice(), rec.move) == null) continue;
        }
        const wdl = if (seen[i] >= 2) Wdl.draw else collapseWdl(rec.state);
        const rank = moveRank(wdl, rec, c, repeated);
        if (best == null or rank > best.?) {
            policy.moves.clear();
            best = rank;
            policy.wdl = wdl;
            instant = null;
        }
        if (rank != best.?) continue;
        policy.moves.add(rec.move);
        if (wdl != .win or !certainWin(rec, c)) continue;
        if (seen[i] != 0 or repeated) continue;
        const keep_current = if (instant) |current| current == suggested or rec.r >= ranking.records[current].r else false;
        if (i == suggested or !keep_current) instant = i;
    }
    if (best == null) return null;
    policy.proven = switch (best.?) {
        4, 0 => !repeated,
        2 => true,
        else => false,
    };
    if (instant) |i| {
        policy.instant = ranking.records[i].move;
        policy.dtz = if (i == suggested) @abs(ranking.root_dtz.plies) else @abs(ranking.records[i].r);
    }
    return policy;
}

/// Side-to-move-relative score for a TB verdict, ply-adjusted so nearer
/// conversions rank higher, mirroring mate-score conventions.
pub fn wdlScore(wdl: Wdl, ply: usize) types.Score {
    return switch (wdl) {
        .win => TB_WIN_SCORE - @as(types.Score, @intCast(ply)),
        .loss => -TB_WIN_SCORE + @as(types.Score, @intCast(ply)),
        .draw => 0,
    };
}

test "syzygy init smoke (opt-in via ZQ_TB_PATH)" {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer std.testing.allocator.free(path);
    const ok = init(path);
    std.debug.print("\nsyzygy init ok={} largest={}\n", .{ ok, pieceLimit() });
    try std.testing.expect(ok);
    try std.testing.expect(pieceLimit() >= 5);
    // Every file is accounted for at load: mapped, or on positioned reads.
    const r = report().?;
    try std.testing.expect(r.wdl_files >= 145 and r.dtz_files >= 145);
    try std.testing.expectEqual(r.wdl_files + r.dtz_files, r.mapped_files + r.pread_files);
    if (storage_mode != .pread and tb.storage.defaultBudget() == tb.storage.unlimited) try std.testing.expectEqual(r.wdl_files + r.dtz_files, r.mapped_files);
    // Review finding 1: an illegal back-rank pawn position is refused, not probed.
    const back_rank = try @import("../core/fen.zig").parse("PP6/8/8/8/8/8/1r6/K6k w - - 0 1");
    try std.testing.expectEqual(@as(?Wdl, null), probeWdl(&back_rank));
    disable();
    try std.testing.expectEqual(@as(usize, 0), retiredCount());
}

test "the report line fits its buffer at the largest values" {
    const max32 = std.math.maxInt(u32);
    const r = Report{ .wdl_files = max32, .dtz_files = max32, .rejected = max32, .max_pieces = std.math.maxInt(u8), .storage = "budget", .mapped_files = max32, .mapped_bytes = std.math.maxInt(u64), .pread_files = max32, .map_failures = max32 };
    var buffer: [Report.line_capacity]u8 = undefined;
    const text = r.line(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, text, "info string Syzygy tables: 4294967295 WDL"));
    try std.testing.expect(std.mem.endsWith(u8, text, " 4294967295 mapping failures\n"));
}

const MappedSet = struct {
    mapped: [][]const u8,
    pread: usize,
    max_mapped: u64,
    min_unmapped: u64,
    failures: u32,

    fn deinit(self: MappedSet, a: std.mem.Allocator) void {
        for (self.mapped) |name| a.free(name);
        a.free(self.mapped);
    }
};

/// Names of the current snapshot's mapped files, the number on positioned
/// reads, and the largest mapped and smallest unmapped size (test helper).
fn mappedSet(a: std.mem.Allocator) !MappedSet {
    const snap = registry.current.?;
    var names: std.ArrayList([]const u8) = .empty;
    var pread: usize = 0;
    var max_mapped: u64 = 0;
    var min_unmapped: u64 = std.math.maxInt(u64);
    for (snap.files.paths, snap.files.sizes, 0..) |path, size, i| {
        if (snap.io.isMapped(@intCast(i))) {
            // Owned copy: the snapshot (and its path strings) dies at the next load.
            try names.append(a, try a.dupe(u8, std.fs.path.basename(path)));
            max_mapped = @max(max_mapped, size);
        } else {
            pread += 1;
            min_unmapped = @min(min_unmapped, size);
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return .{ .mapped = try names.toOwnedSlice(a), .pread = pread, .max_mapped = max_mapped, .min_unmapped = min_unmapped, .failures = snap.ioStats().map_failures };
}

test "a reload under a small budget maps the same files as a fresh load, smallest first" {
    if (comptime storage_mode != .mmap_budget) return error.SkipZigTest;
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    var dirs = std.mem.tokenizeScalar(u8, path, tb.registry.path_separator);
    const dir = dirs.next() orelse return error.SkipZigTest;
    // The same directory spelled another way: trailing separator, and `x/.`.
    const spelled = try std.mem.concat(a, u8, &.{ dir, std.fs.path.sep_str });
    defer a.free(spelled);
    const dotted = try std.mem.concat(a, u8, &.{ dir, std.fs.path.sep_str, "." });
    defer a.free(dotted);
    const budget = tb.storage.Options{ .budget = 64 << 20 };
    defer disable();

    try std.testing.expect(load(dir, budget));
    const fresh = try mappedSet(a);
    defer fresh.deinit(a);
    try std.testing.expect(fresh.mapped.len > 0 and fresh.pread > 0);
    try std.testing.expectEqual(@as(u32, 0), fresh.failures);
    // Smallest first: nothing left on positioned reads is smaller than a mapped file.
    try std.testing.expect(fresh.max_mapped <= fresh.min_unmapped);

    for ([_][]const u8{ spelled, dotted, dir }) |again| {
        try std.testing.expect(load(again, budget));
        try std.testing.expectEqual(@as(usize, 0), retiredCount());
        const reloaded = try mappedSet(a);
        defer reloaded.deinit(a);
        try std.testing.expectEqual(@as(u32, 0), reloaded.failures);
        try std.testing.expectEqual(fresh.pread, reloaded.pread);
        try std.testing.expectEqual(fresh.mapped.len, reloaded.mapped.len);
        for (fresh.mapped, reloaded.mapped) |x, y| try std.testing.expectEqualStrings(x, y);
    }
}

fn testRanking(pos: *const position.Position, states: []const tb.Wdl5, suggested: u16) tb.RootRanking {
    var moves = MoveList.init();
    @import("../movegen/legal.zig").generate(pos, &moves);
    const root_state = states[@min(suggested, states.len - 1)];
    var ranking: tb.RootRanking = .{ .count = @intCast(moves.count), .suggested = suggested, .root_state = root_state, .root_dtz = .{ .plies = 7, .exact = true } };
    for (moves.slice(), 0..) |mv, i| ranking.records[i] = .{
        .move = mv,
        .r = @intCast(i + 1),
        .state = states[@min(i, states.len - 1)],
        .exact = true,
        .zeroing = false,
        .en_passant = mv.flag == .en_passant,
    };
    return ranking;
}

const no_history = [_]u8{0} ** move_mod.MAX_MOVES;

test "root policy keeps the best outcome inside searchmoves" {
    const pos = try @import("../core/fen.zig").parse("8/3q3k/7P/6P1/7K/2Q5/8/8 b - - 10 161");
    var moves = MoveList.init();
    @import("../movegen/legal.zig").generate(&pos, &moves);
    // Move 0 loses, move 1 is a cursed win (suggested), every other move draws.
    const ranking = testRanking(&pos, &.{ .loss, .cursed_win, .draw }, 1);
    const policy = rootPolicy(&ranking, null, 10, &no_history, false).?;
    try std.testing.expectEqual(Wdl.draw, policy.wdl);
    try std.testing.expectEqual(moves.count - 1, policy.moves.count);
    for (policy.moves.slice()) |mv| try std.testing.expect(mv != moves.moves[0]);
    try std.testing.expectEqual(@as(?move_mod.Move, null), policy.instant);
    try std.testing.expectEqual(@as(?Wdl, .draw), policy.authoritativeWdl());
    var restricted = MoveList.init();
    restricted.add(moves.moves[0]);
    const losing = rootPolicy(&ranking, &restricted, 10, &no_history, false).?;
    try std.testing.expectEqual(Wdl.loss, losing.wdl);
    try std.testing.expectEqual(@as(?Wdl, .loss), losing.authoritativeWdl());
    try std.testing.expectEqual(@as(usize, 1), losing.moves.count);
    try std.testing.expectEqual(moves.moves[0], losing.moves.moves[0]);
    try std.testing.expectEqual(@as(?move_mod.Move, null), losing.instant);
    restricted.clear();
    try std.testing.expect(rootPolicy(&ranking, &restricted, 10, &no_history, false) == null);
    var unsuggested = ranking;
    unsuggested.suggested = null;
    try std.testing.expect(rootPolicy(&unsuggested, null, 10, &no_history, false) == null);
}

test "root policy plays the first winning move when searchmoves excludes the suggested one" {
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 0 1");
    var moves = MoveList.init();
    @import("../movegen/legal.zig").generate(&pos, &moves);
    // Every move wins; the last one is suggested.
    const last: u16 = @intCast(moves.count - 1);
    const ranking = testRanking(&pos, &.{.win}, last);
    const all = rootPolicy(&ranking, null, 0, &no_history, false).?;
    try std.testing.expectEqual(moves.count, all.moves.count);
    try std.testing.expectEqual(moves.moves[last], all.instant.?);
    try std.testing.expectEqual(@as(u32, 7), all.dtz);
    var restricted = MoveList.init();
    restricted.add(moves.moves[2]);
    restricted.add(moves.moves[1]);
    const first = rootPolicy(&ranking, &restricted, 0, &no_history, false).?;
    try std.testing.expectEqual(Wdl.win, first.wdl);
    try std.testing.expectEqual(moves.moves[1], first.instant.?);
    try std.testing.expectEqual(@as(u32, 2), first.dtz);
}

test "root policy plays only certain wins at once: rounded DTZ at the rule-50 boundary ranks below" {
    // Audit D (U-TB-DTZ100): at clock c a rounded (non-exact) r with r + c = 100
    // may be a 50-move draw by one ply; it tied with exact wins and won the tie.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 97 1");
    var ranking = testRanking(&pos, &.{.win}, 0);
    for (ranking.records[0..ranking.count]) |*rec| rec.r = 3;
    ranking.records[0].exact = false; // the suggested move: uncertain
    ranking.records[1].exact = false;
    const policy = rootPolicy(&ranking, null, 97, &no_history, false).?;
    try std.testing.expectEqual(Wdl.win, policy.wdl);
    // Only the certain wins stay in the move set (review round, Astra F1).
    try std.testing.expectEqual(@as(usize, ranking.count - 2), policy.moves.count);
    for (policy.moves.slice()) |mv| try std.testing.expect(mv != ranking.records[0].move and mv != ranking.records[1].move);
    try std.testing.expectEqual(ranking.records[2].move, policy.instant.?);
    try std.testing.expectEqual(@as(u32, 3), policy.dtz);
    // r + c <= 99 is certain even when rounded; r = 1 always is.
    var roomy = ranking;
    roomy.records[0].r = 2;
    try std.testing.expectEqual(roomy.records[0].move, rootPolicy(&roomy, null, 97, &no_history, false).?.instant.?);
    // Only uncertain wins: no instant move; they stay the move set to search.
    var uncertain = ranking;
    for (uncertain.records[0..uncertain.count]) |*rec| rec.exact = false;
    const searched = rootPolicy(&uncertain, null, 97, &no_history, false).?;
    try std.testing.expectEqual(Wdl.win, searched.wdl);
    try std.testing.expectEqual(@as(usize, uncertain.count), searched.moves.count);
    try std.testing.expectEqual(@as(?move_mod.Move, null), searched.instant);
    // ...and their win is only a ranking: the search decides the score
    // (review round, U-TB-DTZ100: a searched draw was reported as 28000).
    try std.testing.expectEqual(@as(?Wdl, null), searched.authoritativeWdl());
    try std.testing.expectEqual(@as(?Wdl, .win), policy.authoritativeWdl());
    uncertain.records[3].r = 1;
    const mating = rootPolicy(&uncertain, null, 97, &no_history, false).?;
    try std.testing.expectEqual(uncertain.records[3].move, mating.instant.?);
    try std.testing.expectEqual(@as(?Wdl, .win), mating.authoritativeWdl());
    // A certain win outside searchmoves proves nothing for the allowed ones.
    var only_uncertain = MoveList.init();
    only_uncertain.add(uncertain.records[0].move);
    only_uncertain.add(uncertain.records[1].move);
    const restricted = rootPolicy(&uncertain, &only_uncertain, 97, &no_history, false).?;
    try std.testing.expectEqual(Wdl.win, restricted.wdl);
    try std.testing.expectEqual(@as(?move_mod.Move, null), restricted.instant);
    try std.testing.expectEqual(@as(?Wdl, null), restricted.authoritativeWdl());
}

test "root policy never lets the root summary stand in for the moves' own states" {
    // Audit D (U-TB-DTZ100, the syzygy.zig:239 overwrite): every move is a cursed
    // win at clock 99 while the root summary says win; the policy is a draw.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 99 1");
    var ranking = testRanking(&pos, &.{.cursed_win}, 0);
    ranking.root_state = .win;
    ranking.root_dtz = .{ .plies = 1, .exact = true };
    const policy = rootPolicy(&ranking, null, 99, &no_history, false).?;
    try std.testing.expectEqual(Wdl.draw, policy.wdl);
    try std.testing.expectEqual(@as(usize, ranking.count), policy.moves.count);
    try std.testing.expectEqual(@as(?move_mod.Move, null), policy.instant);
}

test "root policy treats a third occurrence as a draw and never plays a repeating win at once" {
    // Audit D (U-TB-REP): the instant TB win ignored the game history.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 10 1");
    const ranking = testRanking(&pos, &.{.win}, 0);
    // A twofold child stays a win but is not played at once.
    var seen = no_history;
    seen[0] = 1;
    const twofold = rootPolicy(&ranking, null, 10, &seen, false).?;
    try std.testing.expectEqual(@as(usize, ranking.count), twofold.moves.count);
    try std.testing.expectEqual(ranking.records[1].move, twofold.instant.?);
    try std.testing.expectEqual(@as(u32, 2), twofold.dtz);
    // Every win repeats: no instant move; the twofold wins are searched. Each
    // child occurred once, so the win is still proven.
    for (seen[0..ranking.count]) |*count| count.* = 1;
    const repeating = rootPolicy(&ranking, null, 10, &seen, false).?;
    try std.testing.expectEqual(Wdl.win, repeating.wdl);
    try std.testing.expectEqual(@as(usize, ranking.count), repeating.moves.count);
    try std.testing.expectEqual(@as(?move_mod.Move, null), repeating.instant);
    try std.testing.expectEqual(@as(?Wdl, .win), repeating.authoritativeWdl());
    // The suggested move's child would be a third occurrence: a draw, out of
    // the set. That child occurred twice in the window, so the window repeats.
    seen = no_history;
    seen[0] = 2;
    const third = rootPolicy(&ranking, null, 10, &seen, true).?;
    try std.testing.expectEqual(Wdl.win, third.wdl);
    try std.testing.expectEqual(@as(usize, ranking.count - 1), third.moves.count);
    for (third.moves.slice()) |mv| try std.testing.expect(mv != ranking.records[0].move);
    try std.testing.expectEqual(@as(?move_mod.Move, null), third.instant);
    try std.testing.expectEqual(@as(?Wdl, null), third.authoritativeWdl());
    // Every win a third occurrence: the root is a draw, all moves drawing.
    for (seen[0..ranking.count]) |*count| count.* = 2;
    const drawn = rootPolicy(&ranking, null, 10, &seen, true).?;
    try std.testing.expectEqual(Wdl.draw, drawn.wdl);
    try std.testing.expectEqual(@as(usize, ranking.count), drawn.moves.count);
    try std.testing.expectEqual(@as(?move_mod.Move, null), drawn.instant);
    try std.testing.expectEqual(@as(?Wdl, .draw), drawn.authoritativeWdl());
}

test "root policy: a position repeated in the window blocks the instant move and decisive authority" {
    // Review round (U-TB-REP): a fresh child can still let the opponent's reply
    // complete a third occurrence, so no instant move and no proven win or loss.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 10 1");
    const ranking = testRanking(&pos, &.{.win}, 0);
    const fresh = rootPolicy(&ranking, null, 10, &no_history, false).?;
    try std.testing.expectEqual(ranking.records[0].move, fresh.instant.?);
    try std.testing.expectEqual(@as(?Wdl, .win), fresh.authoritativeWdl());
    const repeated = rootPolicy(&ranking, null, 10, &no_history, true).?;
    try std.testing.expectEqual(Wdl.win, repeated.wdl);
    try std.testing.expectEqual(@as(usize, ranking.count), repeated.moves.count);
    try std.testing.expectEqual(@as(?move_mod.Move, null), repeated.instant);
    try std.testing.expectEqual(@as(u32, 0), repeated.dtz);
    try std.testing.expectEqual(@as(?Wdl, null), repeated.authoritativeWdl());
    // A loss the history could turn into a draw (Opus judge D, section 4).
    const losing = testRanking(&pos, &.{.loss}, 0);
    try std.testing.expectEqual(@as(?Wdl, .loss), rootPolicy(&losing, null, 10, &no_history, false).?.authoritativeWdl());
    const lost_repeated = rootPolicy(&losing, null, 10, &no_history, true).?;
    try std.testing.expectEqual(Wdl.loss, lost_repeated.wdl);
    try std.testing.expectEqual(@as(usize, losing.count), lost_repeated.moves.count);
    try std.testing.expectEqual(@as(?Wdl, null), lost_repeated.authoritativeWdl());
    // A draw stays proven: a claim can only draw.
    const drawing = testRanking(&pos, &.{.draw}, 0);
    try std.testing.expectEqual(@as(?Wdl, .draw), rootPolicy(&drawing, null, 10, &no_history, true).?.authoritativeWdl());
}

test "root policy proves a loss only when every allowed loss is certain" {
    // Review round follow-up: a rounded loss at -r + c = 100 may reach the
    // 50-move claim (8/8/8/Q7/8/1p6/k6K/8 b - - 94 1, a2b2), but the root
    // still reported a proven loss and the engine overrode the searched draw.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 b - - 94 1");
    var ranking = testRanking(&pos, &.{.loss}, 0);
    for (ranking.records[0..ranking.count]) |*rec| rec.r = -4;
    ranking.records[0].r = -6;
    ranking.records[0].exact = false;
    const boundary = rootPolicy(&ranking, null, 94, &no_history, false).?;
    try std.testing.expectEqual(Wdl.loss, boundary.wdl);
    try std.testing.expectEqual(@as(?Wdl, null), boundary.authoritativeWdl());
    // The uncertain loss may draw, so it outranks the certain losses (Astra F1
    // mirror): the move set keeps it alone.
    try std.testing.expectEqual(@as(usize, 1), boundary.moves.count);
    try std.testing.expectEqual(ranking.records[0].move, boundary.moves.moves[0]);
    // Exact, or one ply of room (-r + c <= 99): proven again.
    var exact = ranking;
    exact.records[0].exact = true;
    try std.testing.expectEqual(@as(?Wdl, .loss), rootPolicy(&exact, null, 94, &no_history, false).?.authoritativeWdl());
    try std.testing.expectEqual(@as(?Wdl, .loss), rootPolicy(&ranking, null, 93, &no_history, false).?.authoritativeWdl());
    // searchmoves without the uncertain move: the allowed losses are certain.
    var others = MoveList.init();
    for (ranking.records[1..ranking.count]) |rec| others.add(rec.move);
    try std.testing.expectEqual(@as(?Wdl, .loss), rootPolicy(&ranking, &others, 94, &no_history, false).?.authoritativeWdl());
}

test "root policy: a certain win drops uncertain wins from the move set, also when its child repeats" {
    // Review round (three-way review, Astra F1): in
    // 8/8/8/Q5p1/8/8/8/3K2k1 b - - 94 1 moves g1h1 a5a6 h1g1, searchmoves a6a2
    // a6a5, the certain a6a5 returns to a child seen once (no instant move),
    // a6a2 is a rounded boundary win that draws; both stayed in the set, the
    // search chose a6a2, and the root reported a6a5's proof as cp 28000.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 97 1");
    var ranking = testRanking(&pos, &.{.win}, 0);
    for (ranking.records[0..ranking.count]) |*rec| {
        rec.r = 3;
        rec.exact = false;
    }
    ranking.records[1].exact = true;
    var both = MoveList.init();
    both.add(ranking.records[0].move);
    both.add(ranking.records[1].move);
    var seen = no_history;
    seen[1] = 1;
    const mixed = rootPolicy(&ranking, &both, 97, &seen, false).?;
    try std.testing.expectEqual(Wdl.win, mixed.wdl);
    try std.testing.expectEqual(@as(usize, 1), mixed.moves.count);
    try std.testing.expectEqual(ranking.records[1].move, mixed.moves.moves[0]);
    try std.testing.expectEqual(@as(?move_mod.Move, null), mixed.instant);
    try std.testing.expectEqual(@as(?Wdl, .win), mixed.authoritativeWdl());
}

test "root policy: a repeated window keeps certain and uncertain moves together" {
    // With a repeated window a claim may spoil a certain win or save a certain
    // loss, so certainty proves nothing and splitting the class could drop the
    // only real win or draw: the decisive classes stay whole, never proven.
    const pos = try @import("../core/fen.zig").parse("7k/P7/8/8/8/8/8/K7 w - - 94 1");
    var wins = testRanking(&pos, &.{.win}, 0);
    for (wins.records[0..wins.count]) |*rec| rec.r = 6;
    wins.records[0].exact = false;
    const win_set = rootPolicy(&wins, null, 94, &no_history, true).?;
    try std.testing.expectEqual(Wdl.win, win_set.wdl);
    try std.testing.expectEqual(@as(usize, wins.count), win_set.moves.count);
    try std.testing.expectEqual(@as(?Wdl, null), win_set.authoritativeWdl());
    // Without the repeated window the uncertain win would be dropped.
    try std.testing.expectEqual(@as(usize, wins.count - 1), rootPolicy(&wins, null, 94, &no_history, false).?.moves.count);
    var losses = testRanking(&pos, &.{.loss}, 0);
    for (losses.records[0..losses.count]) |*rec| rec.r = -4;
    losses.records[0].r = -6;
    losses.records[0].exact = false;
    const loss_set = rootPolicy(&losses, null, 94, &no_history, true).?;
    try std.testing.expectEqual(Wdl.loss, loss_set.wdl);
    try std.testing.expectEqual(@as(usize, losses.count), loss_set.moves.count);
    try std.testing.expectEqual(@as(?Wdl, null), loss_set.authoritativeWdl());
    // Without it only the uncertain loss would stay.
    try std.testing.expectEqual(@as(usize, 1), rootPolicy(&losses, null, 94, &no_history, false).?.moves.count);
}

test "real root policy excludes the two gauntlet losing moves" {
    const a = std.testing.allocator;
    const path = std.process.getEnvVarOwned(a, "ZQ_ROOT_TB_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    try std.testing.expect(init(path));
    defer disable();
    var job = beginJob();
    defer job.deinit();
    const cases = .{
        .{ "8/3q3k/7P/6P1/7K/2Q5/8/8 b - - 10 161", move_mod.Move.init(.d7, .f7, .quiet), @as(usize, 3) },
        .{ "7k/1q6/7P/6P1/2Q3K1/8/8/8 b - - 54 170", move_mod.Move.init(.b7, .g2, .quiet), @as(usize, 2) },
    };
    inline for (cases) |c| {
        const pos = try @import("../core/fen.zig").parse(c[0]);
        const policy = job.probeRootMoves(&pos, null, null) orelse return error.MissingRootTables;
        try std.testing.expectEqual(Wdl.draw, policy.wdl);
        try std.testing.expectEqual(c[2], policy.moves.count);
        for (policy.moves.slice()) |mv| try std.testing.expect(mv != c[1]);
        var only_loser = MoveList.init();
        only_loser.add(c[1]);
        const restricted = job.probeRootMoves(&pos, &only_loser, null).?;
        try std.testing.expectEqual(Wdl.loss, restricted.wdl);
        try std.testing.expectEqual(c[1], restricted.moves.moves[0]);
    }
}

test "path lists without tables leave tablebases off" {
    const sep = [_]u8{tb.registry.path_separator};
    for ([_][]const u8{ "", &sep, &(sep ++ sep), "/nonexistent-zigqueen-tablebases", "/nonexistent-zigqueen-tablebases" ++ sep }) |path| {
        try std.testing.expect(!init(path));
        try std.testing.expect(!enabled());
        var job = beginJob();
        defer job.deinit();
        try std.testing.expect(!job.enabled());
    }
    try std.testing.expectEqual(@as(usize, 0), retiredCount());
}
