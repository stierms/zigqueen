//! Transposition table: 64-byte clusters of five 12-byte entries. Its size is
//! UCI Hash less the eval caches' share (table_budget.zig).
//!
//! An entry is a 32-bit tag and a 64-bit word. The cluster is found from the
//! low half of the position key, the tag is the high half, so a probe
//! verifies log2(clusters) + 32 bits of the key (53.6 at Hash 256). A probe
//! for a position the cluster does not hold meets a foreign entry with the
//! same tag with probability 5 / 2^32: about one probe in a billion. Its move
//! is tested for legality before use (root.zig, qsearch.zig); its score and
//! eval are another position's. A 16-bit tag with six entries was built first
//! and given up for that: an 8-bit tag, 261 times its foreign hits, lost 65
//! Elo to it in games (docs/research/roadmap-20261111/table.md).
//!
//! Word layout, low to high: move 16, score 16 (signed), static eval 16
//! (signed), depth 8, bound 2, PV flag 1, generation 5. A tag of 0 marks an
//! empty slot, so zeroed memory is an empty table; a key whose tag bits are 0
//! uses tag 1.
//!
//! The same cluster serves the serial table here and the shared multi-thread
//! table (shared_tt.zig, probes/tt_snapshot.zig), which locks it with the
//! 32-bit sequence word; the serial table never touches that word.

const std = @import("std");
const build_options = @import("build_options");
const hugealloc = @import("../util/hugealloc.zig");
const move_mod = @import("../core/move.zig");
const table_budget = @import("table_budget.zig");

pub const DEFAULT_HASH_MB: u32 = 64;
pub const MIN_HASH_MB: u32 = 1;
pub const MAX_HASH_MB: u32 = 65_536;

pub const Bound = enum(u2) {
    exact,
    lower,
    upper,
};

/// Depth of a table entry in the search's frame. Main-search nodes store their
/// remaining depth (1 or more). Quiescence has two move sets: its first ply
/// searches captures, promotions and quiet checks, later plies no quiet
/// checks. An exact score or upper bound found over the narrower set says
/// nothing about the wider one (`7k/8/5KQ1/8/8/8/6p1/8 w`: 832 at a later
/// ply, mate at the first), so the two store different depths and a first-ply
/// probe asks for its own. A node in check searches every evasion at any ply
/// and stores the first-ply depth.
pub const QS_FIRST_PLY_DEPTH: i16 = 0;
pub const QS_LATER_PLY_DEPTH: i16 = -1;
/// The table keeps depths unsigned, so the search's depths are kept shifted by
/// this much (tt_store adds it, tt_probe removes it).
pub const STORED_DEPTH_OFFSET: i16 = -QS_LATER_PLY_DEPTH;
/// Largest depth an entry can hold, in the stored frame; deeper stores are
/// kept at this depth.
pub const MAX_STORED_DEPTH: i16 = 255;

/// A probe that finds an entry of an earlier search marks it as this
/// search's, so entries the search still uses are not the first replaced.
pub const REFRESH_ON_HIT_DEFAULT = false;

/// A store without a move keeps the move of the entry it overwrites, when
/// that entry is the same position's (round 3, 2026-11-13; `wordFor`).
/// On in the round-3 integration branch, with tt_store.FAIL_LOW_NO_MOVE_DEFAULT:
/// the cell that is tested as one.
pub const KEEP_MOVE_DEFAULT = true;

/// What the tuning flavour can change between searches (tunables.zig:
/// TtRefreshOnHit, TtKeepMove, TtTagBits, TtVerifyKeys). The release flavour
/// compiles the defaults in.
pub const Policy = struct {
    refresh_on_hit: bool = REFRESH_ON_HIT_DEFAULT,
    keep_move: bool = KEEP_MOVE_DEFAULT,
    /// Key bits kept in the tag. Fewer bits make foreign hits more frequent
    /// (2^-bits per occupied slot): the stress instrument for what they cost.
    tag_bits: u8 = TAG_BITS,
    /// Stats flavour only: a hit whose full key differs is a miss (the
    /// table then behaves as one with 64-bit keys would).
    verify_keys: bool = false,
};

/// Stats flavour: the serial table keeps every slot's full key beside it and
/// flags an entry found under another position's tag (Entry.foreign).
const shadow_keys = build_options.search_stats;

/// Sentinel for "no static eval cached" (evals live well inside i16).
pub const STATIC_EVAL_NONE: i16 = std.math.minInt(i16);

/// Entries per cluster (one 64-byte line).
pub const WAYS: usize = 5;
/// An entry's tag: the key's high half.
pub const Tag = u32;
pub const TAG_BITS: u8 = 32;
/// Generations an entry can tell apart; ages are taken modulo this.
pub const GENERATIONS: u8 = 32;

/// A table entry as the search reads it: a decoded copy, never a view into
/// the table. `depth` is in the stored frame (STORED_DEPTH_OFFSET).
/// `generation` is the table generation that wrote it, reconstructed from its
/// age (exact up to GENERATIONS - 1 searches back).
pub const Entry = struct {
    move_bits: u16 = 0,
    score: i32 = 0,
    depth: i16 = -1,
    generation: u8 = 0,
    bound: Bound = .exact,
    // Raw (uncorrected) static eval of the position — lever 1 (2026-07-16):
    // saves the NNUE forward on TT hits without a cutoff.
    static_eval: i16 = STATIC_EVAL_NONE,
    /// True when this position was stored from a PV node. Basin LMR uses the
    /// bit as an accuracy brake if the position later appears off-PV.
    was_pv: bool = false,
    /// Stats flavour, serial table: the entry belongs to another position
    /// with the same cluster and tag. Always false elsewhere.
    foreign: bool = false,
};

pub const StoreOutcome = struct {
    stored: bool = false,
    skipped_same_generation_deeper: bool = false,
    same_key: bool = false,
    empty_slot: bool = false,
    replaced_occupied: bool = false,
    current_generation: u8 = 0,
    victim_generation: u8 = 0,
    victim_depth: i16 = -1,
    victim_bound: Bound = .exact,
    victim_had_move: bool = false,
    new_bound: Bound = .exact,
    new_had_move: bool = false,
};

pub const Cluster = extern struct {
    tags: [WAYS]Tag align(64) = [_]Tag{0} ** WAYS,
    /// Sequence lock of the shared table (probes/tt_snapshot.zig). Unused, and
    /// zero, in the serial table.
    sequence: u32 = 0,
    data: [WAYS]u64 = [_]u64{0} ** WAYS,
};

comptime {
    std.debug.assert(@sizeOf(Cluster) == 64 and @alignOf(Cluster) == 64);
    std.debug.assert(@offsetOf(Cluster, "sequence") == 20 and @offsetOf(Cluster, "data") == 24);
}

pub const MOVE_SHIFT = 0;
pub const SCORE_SHIFT = 16;
pub const EVAL_SHIFT = 32;
pub const DEPTH_SHIFT = 48;
pub const BOUND_SHIFT = 56;
pub const PV_SHIFT = 58;
pub const GENERATION_SHIFT = 59;

/// What a store writes, before it is packed.
pub const Record = struct {
    move_bits: u16,
    score: i32,
    /// Stored frame, any value; packed into 0..MAX_STORED_DEPTH.
    depth: i16,
    bound: Bound,
    static_eval: i16,
    was_pv: bool,
    generation: u8,
};

pub inline fn packedDepth(depth: i16) u8 {
    return @intCast(std.math.clamp(depth, 0, MAX_STORED_DEPTH));
}

pub inline fn pack(r: Record) u64 {
    // Search scores stay inside +/- MATE_SCORE (29,000) and evals are clamped
    // by tt_store.evalToTt; the clamp keeps a foreign caller's value in range.
    const score: i16 = @intCast(std.math.clamp(r.score, -std.math.maxInt(i16), std.math.maxInt(i16)));
    return (@as(u64, r.move_bits) << MOVE_SHIFT) |
        (@as(u64, @as(u16, @bitCast(score))) << SCORE_SHIFT) |
        (@as(u64, @as(u16, @bitCast(r.static_eval))) << EVAL_SHIFT) |
        (@as(u64, packedDepth(r.depth)) << DEPTH_SHIFT) |
        (@as(u64, @intFromEnum(r.bound)) << BOUND_SHIFT) |
        (@as(u64, @intFromBool(r.was_pv)) << PV_SHIFT) |
        (@as(u64, r.generation % GENERATIONS) << GENERATION_SHIFT);
}

pub inline fn wordDepth(word: u64) u8 {
    return @truncate(word >> DEPTH_SHIFT);
}

pub inline fn wordBoundBits(word: u64) u2 {
    return @truncate(word >> BOUND_SHIFT);
}

pub inline fn wordMoveBits(word: u64) u16 {
    return @truncate(word >> MOVE_SHIFT);
}

pub inline fn wordEval(word: u64) i16 {
    return @bitCast(@as(u16, @truncate(word >> EVAL_SHIFT)));
}

/// Searches since the entry was written, modulo GENERATIONS.
pub inline fn wordAge(word: u64, current_generation: u8) u8 {
    const written: u8 = @truncate(word >> GENERATION_SHIFT);
    return (current_generation -% written) % GENERATIONS;
}

/// The entry in `word`, read by a table whose generation is `current_generation`.
/// The word must be one `pack` produced (a stored word always is).
pub inline fn unpack(word: u64, current_generation: u8) Entry {
    return .{
        .move_bits = wordMoveBits(word),
        .score = @as(i16, @bitCast(@as(u16, @truncate(word >> SCORE_SHIFT)))),
        .depth = wordDepth(word),
        .generation = current_generation -% wordAge(word, current_generation),
        .bound = @enumFromInt(wordBoundBits(word)),
        .static_eval = wordEval(word),
        .was_pv = (word >> PV_SHIFT) & 1 != 0,
    };
}

/// Whether `word` decodes to a valid entry: a bound that exists and a move
/// flag that exists. Stored words always do; the shared table checks it on
/// words read without the cluster's lock.
pub inline fn wordIsValid(word: u64) bool {
    return wordBoundBits(word) != 3 and wordMoveBits(word) >> 12 <= 12;
}

/// The tag of `key`: its high half, never 0 (0 marks an empty slot).
pub inline fn tagOf(key: u64) Tag {
    return tagFor(key, .{});
}

/// The tag under `policy`: the low `tag_bits` of the full tag.
pub inline fn tagFor(key: u64, policy: Policy) Tag {
    const full: Tag = @truncate(key >> 32);
    const tag = if (policy.tag_bits >= TAG_BITS) full else full & ((@as(Tag, 1) << @intCast(policy.tag_bits)) - 1);
    return tag | @intFromBool(tag == 0);
}

/// `word` as an entry of the search of `generation`.
pub inline fn withGeneration(word: u64, generation: u8) u64 {
    const mask: u64 = @as(u64, GENERATIONS - 1) << GENERATION_SHIFT;
    return (word & ~mask) | (@as(u64, generation % GENERATIONS) << GENERATION_SHIFT);
}

/// The cluster of `key` among `count`: the key's low 32 bits as a fraction of
/// the table, so any count up to 2^32 is used whole, not only powers of two.
/// (The raw-eval cache indexes by the key's high bits; the two tables'
/// conflict sets stay unrelated.)
pub inline fn clusterIndex(key: u64, count: usize) usize {
    return @intCast((@as(u64, @as(u32, @truncate(key))) * @as(u64, count)) >> 32);
}

/// Replacement worth of an occupied slot: the slot with the lowest worth is
/// overwritten. Entries of an earlier search go first, the shallowest of them
/// first; then the shallowest entry of the current search.
inline fn replacementWorth(depth: u8, age: u8) u32 {
    return @as(u32, depth) + (if (age == 0) @as(u32, MAX_STORED_DEPTH) + 1 else 0);
}

/// Where a store of `tag` at `depth` (stored frame) goes in a cluster, and
/// whether it is written at all. Shared by the serial and the shared table.
///   1. The slot that already carries the tag. Skipped when that entry is of
///      the current search and deeper than the new one.
///   2. Else the first empty slot.
///   3. Else the slot of the lowest replacement worth, the first on a tie.
/// Fills `outcome` (statistics only); returns null when the store is skipped.
pub inline fn chooseWay(
    tags: *const [WAYS]Tag,
    data: *const [WAYS]u64,
    tag: Tag,
    depth: u8,
    generation: u8,
    outcome: *StoreOutcome,
) ?usize {
    // One rank per slot, lowest wins: 0 for the tag's own slot, 1 for an
    // empty one, else 2 + worth. The way is packed into the low bits so the
    // minimum is also the first of equals.
    var best: u32 = std.math.maxInt(u32);
    inline for (0..WAYS) |way| {
        const word = data[way];
        const worth = replacementWorth(wordDepth(word), wordAge(word, generation));
        const occupied_rank: u32 = 2 + worth;
        const rank: u32 = if (tags[way] == tag) 0 else if (tags[way] == 0) 1 else occupied_rank;
        best = @min(best, (rank << 3) | way);
    }
    const way: usize = best & 7;
    const rank = best >> 3;
    const victim = data[way];
    const victim_depth = wordDepth(victim);
    if (rank == 0) {
        outcome.same_key = true;
        if (wordAge(victim, generation) == 0 and victim_depth > depth) {
            outcome.skipped_same_generation_deeper = true;
            noteVictim(outcome, victim, generation);
            return null;
        }
    }
    outcome.stored = true;
    outcome.empty_slot = rank == 1;
    outcome.replaced_occupied = rank >= 2;
    if (rank != 1) noteVictim(outcome, victim, generation);
    return way;
}

inline fn noteVictim(outcome: *StoreOutcome, victim: u64, generation: u8) void {
    outcome.victim_generation = generation -% wordAge(victim, generation);
    outcome.victim_depth = wordDepth(victim);
    outcome.victim_bound = @enumFromInt(wordBoundBits(victim));
    outcome.victim_had_move = wordMoveBits(victim) != 0;
}

/// The word a store writes over `victim`: a same-position overwrite that
/// arrives without a static eval keeps the cached one (the eval is a property
/// of the position).
///
/// With `keep_move`, one that arrives without a move keeps the stored move
/// too, whatever the depths, bounds and searches of the two records: a null
/// move cutoff or a stand-pat says nothing about the position's moves, so the
/// move an earlier search found stays the one to try first. The entry's
/// score, depth and bound are then the new record's and its move an older
/// one's: the move orders, it is not what proved the bound. "Same position"
/// is the table's own notion, as for the eval: the slot carried this tag
/// (`chooseWay`), so one overwrite in about a billion keeps a foreign move,
/// which every reader tests for legality before use.
pub inline fn wordFor(record: Record, same_key: bool, victim: u64, keep_move: bool) u64 {
    var r = record;
    if (r.static_eval == STATIC_EVAL_NONE and same_key) r.static_eval = wordEval(victim);
    if (keep_move and r.move_bits == 0 and same_key) r.move_bits = wordMoveBits(victim);
    return pack(r);
}

pub const TranspositionTable = struct {
    allocator: std.mem.Allocator,
    configured_hash_mb: u32 = 0,
    clusters: []Cluster = &.{},
    /// How `clusters` is backed (2MB huge pages when the OS grants them — a
    /// 64MB table on 4KB pages needs 16384 dTLB entries, so every
    /// zobrist-indexed probe is a likely TLB walk). Frees must go through
    /// hugealloc with this.
    alloc_method: hugealloc.Method = .heap,
    generation: u8 = 0,
    /// Read only in the tuning flavour (activePolicy); the engine sets it
    /// from the tunables before each search.
    policy: Policy = .{},
    /// Stats flavour: the full key of every slot, `WAYS` per cluster.
    shadow: if (shadow_keys) []u64 else void = if (shadow_keys) &.{} else {},

    pub fn init(allocator: std.mem.Allocator, hash_mb: u32) !TranspositionTable {
        var table = TranspositionTable{ .allocator = allocator };
        try table.resize(hash_mb);
        return table;
    }

    pub fn deinit(self: *TranspositionTable) void {
        hugealloc.free(Cluster, self.allocator, .{ .items = self.clusters, .method = self.alloc_method });
        if (shadow_keys) {
            self.allocator.free(self.shadow);
            self.shadow = &.{};
        }
        self.configured_hash_mb = 0;
        self.clusters = &.{};
        self.alloc_method = .heap;
        self.generation = 0;
    }

    pub fn clear(self: *TranspositionTable) void {
        if (self.clusters.len != 0) @memset(self.clusters, .{});
        if (shadow_keys) @memset(self.shadow, 0);
        self.generation = 0;
    }

    inline fn activePolicy(self: *const TranspositionTable) Policy {
        if (comptime build_options.tuning) return self.policy;
        return .{};
    }

    pub fn newSearch(self: *TranspositionTable) void {
        self.generation +%= 1;
    }

    pub fn resize(self: *TranspositionTable, hash_mb: u32) !void {
        const clamped_mb = std.math.clamp(hash_mb, MIN_HASH_MB, MAX_HASH_MB);
        const new_len = clusterCountForHash(clamped_mb);
        if (self.clusters.len == new_len) {
            self.configured_hash_mb = clamped_mb;
            self.clear();
            return;
        }

        hugealloc.free(Cluster, self.allocator, .{ .items = self.clusters, .method = self.alloc_method });
        self.clusters = &.{};
        if (shadow_keys) {
            self.allocator.free(self.shadow);
            self.shadow = &.{};
            self.shadow = try self.allocator.alloc(u64, new_len * WAYS);
        }
        // Stats flavour: when the table's own allocation fails, the shadow
        // keys allocated just above go too, so a failed resize leaves an
        // empty table that owns nothing (init's caller has nothing to free).
        errdefer {
            if (shadow_keys) {
                self.allocator.free(self.shadow);
                self.shadow = &.{};
            }
        }
        const backed = try hugealloc.alloc(Cluster, self.allocator, new_len);
        self.clusters = backed.items;
        self.alloc_method = backed.method;
        self.configured_hash_mb = clamped_mb;
        self.clear();
    }

    pub fn hashSizeMb(self: *const TranspositionTable) u32 {
        return self.configured_hash_mb;
    }

    pub fn entryCount(self: *const TranspositionTable) usize {
        return self.clusters.len * WAYS;
    }

    /// Hint the CPU to start fetching a key's cluster into cache. Call as soon as
    /// a child position's key is known (after make-move) so the line arrives
    /// before that node probes -- hides the random-access TT miss latency.
    pub inline fn prefetch(self: *const TranspositionTable, key: u64) void {
        if (self.clusters.len == 0) return;
        @prefetch(&self.clusters[clusterIndex(key, self.clusters.len)], .{ .rw = .read, .locality = 3, .cache = .data });
    }

    /// Copy the matching entry at the table boundary. The caller owns this
    /// snapshot; later stores, clears or resize cannot mutate it. This serial
    /// implementation is not safe for concurrent writers (shared_tt.zig is).
    pub inline fn lookup(self: *const TranspositionTable, key: u64) ?Entry {
        if (self.clusters.len == 0) return null;
        const policy = self.activePolicy();
        const index = clusterIndex(key, self.clusters.len);
        const cluster = &self.clusters[index];
        const way = matchingWay(cluster, tagFor(key, policy)) orelse return null;
        var entry = unpack(cluster.data[way], self.generation);
        if (shadow_keys) {
            entry.foreign = self.shadow[index * WAYS + way] != key;
            if (entry.foreign and policy.verify_keys) return null;
        }
        return entry;
    }

    /// `lookup` for the search's own probe: under `refresh_on_hit` an entry
    /// of an earlier search becomes one of this search. The entry returned
    /// is as it was found.
    pub inline fn probe(self: *TranspositionTable, key: u64) ?Entry {
        const entry = self.lookup(key) orelse return null;
        if (self.activePolicy().refresh_on_hit and entry.generation != self.generation) {
            const cluster = &self.clusters[clusterIndex(key, self.clusters.len)];
            const way = matchingWay(cluster, tagFor(key, self.activePolicy())).?;
            cluster.data[way] = withGeneration(cluster.data[way], self.generation);
        }
        return entry;
    }

    pub fn bestMove(self: *const TranspositionTable, key: u64) ?move_mod.Move {
        const entry = self.lookup(key) orelse return null;
        return moveFromEntry(entry);
    }

    pub inline fn store(self: *TranspositionTable, key: u64, depth: i16, score: i32, bound: Bound, mv: ?move_mod.Move) void {
        _ = self.storeWithOutcome(key, depth, score, bound, mv, STATIC_EVAL_NONE, false);
    }

    pub inline fn storeWithOutcome(self: *TranspositionTable, key: u64, depth: i16, score: i32, bound: Bound, mv: ?move_mod.Move, static_eval: i16, was_pv: bool) StoreOutcome {
        var outcome = StoreOutcome{
            .current_generation = self.generation,
            .new_bound = bound,
            .new_had_move = mv != null,
        };
        if (self.clusters.len == 0) return outcome;

        const policy = self.activePolicy();
        const index = clusterIndex(key, self.clusters.len);
        const cluster = &self.clusters[index];
        const tag = tagFor(key, policy);
        const way = chooseWay(&cluster.tags, &cluster.data, tag, packedDepth(depth), self.generation, &outcome) orelse return outcome;
        if (shadow_keys) {
            // A foreign entry under this tag is replaced, not updated: the
            // new position has no eval of its own in it.
            if (self.shadow[index * WAYS + way] != key) outcome.same_key = outcome.same_key and !policy.verify_keys;
            self.shadow[index * WAYS + way] = key;
        }
        cluster.data[way] = wordFor(.{
            .move_bits = if (mv) |move| @bitCast(move) else 0,
            .score = score,
            .depth = depth,
            .bound = bound,
            .static_eval = static_eval,
            .was_pv = was_pv,
            .generation = self.generation,
        }, outcome.same_key, cluster.data[way], policy.keep_move);
        cluster.tags[way] = tag;
        return outcome;
    }

    pub fn hashfullPermille(self: *const TranspositionTable) u16 {
        if (self.clusters.len == 0) return 0;

        const sample_len = @min(self.clusters.len, 1000);
        var used: usize = 0;
        for (self.clusters[0..sample_len]) |*cluster| {
            for (cluster.tags) |tag| used += @intFromBool(tag != 0);
        }
        return @intCast((used * 1000) / (sample_len * WAYS));
    }
};

/// The slot of `cluster` that carries `tag`, if one does. One compare over
/// the cluster's first 32 bytes (the lanes of the sequence word and of the
/// first entry word are masked off), no branch per slot: the compares wait on
/// the cluster's cache miss, so a per-slot branch would resolve late. A tag
/// stands in at most one slot (chooseWay rule 1).
inline fn matchingWay(cluster: *const Cluster, tag: Tag) ?usize {
    const lanes: *const [8]Tag = @ptrCast(&cluster.tags);
    const head: @Vector(8, Tag) = lanes.*;
    const hits: u8 = @as(u8, @bitCast(head == @as(@Vector(8, Tag), @splat(tag)))) & ((1 << WAYS) - 1);
    if (hits == 0) return null;
    return @ctz(hits);
}

pub inline fn moveFromEntry(entry: Entry) ?move_mod.Move {
    if (entry.move_bits == 0) return null;
    return @bitCast(entry.move_bits);
}

/// Clusters for a Hash setting: Hash less the eval caches' share
/// (table_budget.zig), in whole 64-byte lines.
pub fn clusterCountForHash(hash_mb: u32) usize {
    return @intCast(table_budget.ttBytes(hash_mb) / @sizeOf(Cluster));
}

/// A key that lands in cluster `index` of `count` with tag bits `tag_bits`
/// (tests build colliding keys with it).
pub fn keyFor(index: usize, count: usize, tag_bits: Tag) u64 {
    // The smallest low half whose fraction of the table reaches `index`.
    const low: u64 = ((@as(u64, index) << 32) + count - 1) / count;
    std.debug.assert(clusterIndex(low, count) == index);
    return (@as(u64, tag_bits) << 32) | low;
}

test "tt stores and retrieves exact entries" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    tt.store(1234, 5, 17, .exact, mv);

    const entry = tt.lookup(1234).?;
    try std.testing.expectEqual(@as(i16, 5), entry.depth);
    try std.testing.expectEqual(@as(i32, 17), entry.score);
    try std.testing.expectEqual(mv, tt.bestMove(1234).?);
}

test "tt entry word keeps every field over its whole range" {
    const mv_bits: u16 = @bitCast(move_mod.Move.init(.h7, .g8, .promo_queen_capture));
    for ([_]i32{ -29_000, -1, 0, 1, 29_000, std.math.maxInt(i16) }) |score| {
        for ([_]i16{ 0, 1, 2, 128, 255 }) |depth| {
            for ([_]i16{ STATIC_EVAL_NONE, -32_700, -1, 0, 32_700 }) |eval| {
                for (0..3) |bound| {
                    for ([_]u8{ 0, 1, 31, 32, 200, 255 }) |generation| {
                        const record = Record{ .move_bits = mv_bits, .score = score, .depth = depth, .bound = @enumFromInt(bound), .static_eval = eval, .was_pv = generation & 1 != 0, .generation = generation };
                        const word = pack(record);
                        try std.testing.expect(wordIsValid(word));
                        const entry = unpack(word, generation);
                        try std.testing.expectEqualDeep(Entry{ .move_bits = mv_bits, .score = score, .depth = depth, .generation = generation, .bound = @enumFromInt(bound), .static_eval = eval, .was_pv = generation & 1 != 0 }, entry);
                        // Read three searches later, across the counter's wrap.
                        const later = unpack(word, generation +% 3);
                        try std.testing.expectEqual(generation, later.generation);
                        try std.testing.expectEqual(@as(u8, 3), wordAge(word, generation +% 3));
                    }
                }
            }
        }
    }
    // Out-of-range values are kept at the nearest end.
    try std.testing.expectEqual(@as(i16, 255), unpack(pack(.{ .move_bits = 0, .score = 0, .depth = 300, .bound = .exact, .static_eval = 0, .was_pv = false, .generation = 0 }), 0).depth);
    try std.testing.expectEqual(@as(i16, 0), unpack(pack(.{ .move_bits = 0, .score = 0, .depth = -1, .bound = .exact, .static_eval = 0, .was_pv = false, .generation = 0 }), 0).depth);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i16)), unpack(pack(.{ .move_bits = 0, .score = 1_000_000, .depth = 1, .bound = .exact, .static_eval = 0, .was_pv = false, .generation = 0 }), 0).score);
    try std.testing.expectEqual(@as(i32, -std.math.maxInt(i16)), unpack(pack(.{ .move_bits = 0, .score = std.math.minInt(i32), .depth = 1, .bound = .exact, .static_eval = 0, .was_pv = false, .generation = 0 }), 0).score);
}

test "tt key maps to a cluster inside the table and a nonzero tag" {
    var rng = std.Random.DefaultPrng.init(0x7ab1e);
    const r = rng.random();
    for ([_]usize{ 1, 2, 3, 1000, 16_384, 4_194_304, 1 << 30 }) |count| {
        try std.testing.expectEqual(@as(usize, 0), clusterIndex(0, count));
        try std.testing.expectEqual(count - 1, clusterIndex(std.math.maxInt(u64), count));
        for (0..2000) |_| {
            const key = r.int(u64);
            try std.testing.expect(clusterIndex(key, count) < count);
            try std.testing.expect(tagOf(key) != 0);
            const index = r.uintLessThan(usize, count);
            const built = keyFor(index, count, r.int(Tag));
            try std.testing.expectEqual(index, clusterIndex(built, count));
        }
    }
    try std.testing.expectEqual(@as(Tag, 1), tagOf(0));
    try std.testing.expectEqual(@as(Tag, 1), tagOf(1 << 32));
    try std.testing.expectEqual(@as(Tag, 0xffff_beef), tagOf(0xffff_beef_0000_0000));
}

test "tt takes Hash less the eval caches' share, in 64-byte lines" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    // Hash 1: 1 MiB less 256 KiB of eval cache.
    try std.testing.expectEqual(@as(usize, 12_288), tt.clusters.len);
    try std.testing.expectEqual(@as(usize, 61_440), tt.entryCount());
    // Hash 256: 192 MiB, 15.7 million entries. Hash 100: 84 MiB.
    try std.testing.expectEqual(@as(usize, 3_145_728), clusterCountForHash(256));
    try std.testing.expectEqual(@as(usize, 1_376_256), clusterCountForHash(100));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(tt.clusters.ptr) % 64);
}

test "tt keeps five colliding keys in one cluster and replaces the least worth" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const count = tt.clusters.len;
    var keys: [WAYS + 2]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = keyFor(7, count, @intCast(100 + i));
    // Five entries of depths 10, 9, 8, 7, 6 fill the cluster.
    for (keys[0..WAYS], 0..) |key, i| tt.store(key, @intCast(10 - i), @intCast(i), .exact, null);
    for (keys[0..WAYS], 0..) |key, i| try std.testing.expectEqual(@as(i32, @intCast(i)), tt.lookup(key).?.score);
    // A sixth takes the shallowest slot, whatever its own depth.
    tt.store(keys[WAYS], 1, 77, .exact, null);
    try std.testing.expect(tt.lookup(keys[WAYS - 1]) == null);
    try std.testing.expectEqual(@as(i32, 77), tt.lookup(keys[WAYS]).?.score);
    for (keys[0 .. WAYS - 1]) |key| try std.testing.expect(tt.lookup(key) != null);
    // A seventh takes that slot again: it is the shallowest now.
    tt.store(keys[WAYS + 1], 3, 88, .exact, null);
    try std.testing.expect(tt.lookup(keys[WAYS]) == null);
    try std.testing.expectEqual(@as(i32, 88), tt.lookup(keys[WAYS + 1]).?.score);
}

test "tt generation ages replacement candidates" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const count = tt.clusters.len;
    var keys: [WAYS + 1]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = keyFor(3, count, @intCast(500 + i));
    for (keys[0..WAYS], 0..) |key, i| tt.store(key, @intCast(20 + i), 11, .exact, null);

    tt.newSearch();
    // The same position again, shallower: an entry of an earlier search does
    // not hold its slot against it.
    tt.store(keys[0], 5, 17, .lower, null);
    try std.testing.expectEqual(@as(i16, 5), tt.lookup(keys[0]).?.depth);
    try std.testing.expectEqual(@as(i32, 17), tt.lookup(keys[0]).?.score);
    try std.testing.expectEqual(tt.generation, tt.lookup(keys[0]).?.generation);
    try std.testing.expectEqual(tt.generation -% 1, tt.lookup(keys[1]).?.generation);

    // A new position takes the shallowest entry of the earlier search, not
    // the shallower entry of the current one.
    tt.store(keys[WAYS], 1, 19, .exact, null);
    try std.testing.expectEqual(@as(i32, 19), tt.lookup(keys[WAYS]).?.score);
    try std.testing.expect(tt.lookup(keys[0]) != null);
    try std.testing.expect(tt.lookup(keys[1]) == null);
}

test "tt store outcome reports replacement classes" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    const first = tt.storeWithOutcome(0x55, 4, 10, .exact, mv, 123, true);
    try std.testing.expect(first.stored);
    try std.testing.expect(first.empty_slot);
    try std.testing.expect(first.new_had_move);

    const same = tt.storeWithOutcome(0x55, 5, 20, .lower, null, STATIC_EVAL_NONE, false);
    try std.testing.expect(same.stored);
    try std.testing.expect(same.same_key);
    try std.testing.expect(same.victim_had_move);
    try std.testing.expectEqual(Bound.exact, same.victim_bound);

    const skipped = tt.storeWithOutcome(0x55, 4, 30, .upper, null, STATIC_EVAL_NONE, false);
    // same-key overwrite without an eval preserved the cached one
    try std.testing.expectEqual(@as(i16, 123), tt.lookup(0x55).?.static_eval);
    try std.testing.expect(!skipped.stored);
    try std.testing.expect(skipped.skipped_same_generation_deeper);
    try std.testing.expect(skipped.same_key);
    try std.testing.expectEqual(@as(i16, 5), skipped.victim_depth);
    try std.testing.expectEqual(Bound.lower, skipped.victim_bound);

    const count = tt.clusters.len;
    for (1..WAYS) |i| _ = tt.storeWithOutcome(keyFor(0, count, @intCast(900 + i)), 9, 0, .exact, null, STATIC_EVAL_NONE, false);
    const replaced = tt.storeWithOutcome(keyFor(0, count, 999), 2, 0, .exact, null, STATIC_EVAL_NONE, false);
    try std.testing.expect(replaced.stored and replaced.replaced_occupied and !replaced.same_key and !replaced.empty_slot);
    try std.testing.expectEqual(@as(i16, 5), replaced.victim_depth);
}

test "tt hashfull reports occupancy in permille" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    try std.testing.expectEqual(@as(u16, 0), tt.hashfullPermille());

    const count = tt.clusters.len;
    // Two of the five slots in each of the first 300 of the 1000 sampled clusters.
    for (0..600) |i| tt.store(keyFor(i / 2, count, @intCast(1 + i % 2)), 1, 0, .exact, null);

    try std.testing.expectEqual(@as(u16, 120), tt.hashfullPermille());
}

test "TT lookup exposes only an owned entry snapshot" {
    try std.testing.expect(!@hasDecl(TranspositionTable, "lookupPtr"));
    try std.testing.expect(@typeInfo(@TypeOf(TranspositionTable.lookup)).@"fn".return_type.? == ?Entry);
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Cluster));
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    _ = table.storeWithOutcome(1234, 5, 17, .exact, mv, -23, true);
    const saved = table.lookup(1234).?;
    const expected = Entry{ .move_bits = @bitCast(mv), .depth = 5, .score = 17, .static_eval = -23, .was_pv = true };
    try std.testing.expectEqualDeep(expected, saved);
    _ = table.storeWithOutcome(1234, 6, -40, .lower, null, STATIC_EVAL_NONE, false);
    try std.testing.expectEqual(@as(i32, -40), table.lookup(1234).?.score);
    try std.testing.expectEqual(@as(i16, -23), table.lookup(1234).?.static_eval);
    try std.testing.expectEqualDeep(expected, saved);
    table.clear();
    try std.testing.expect(table.lookup(1234) == null);
    try std.testing.expectEqualDeep(expected, saved);
    try table.resize(2);
    try std.testing.expectEqualDeep(expected, saved);
    try std.testing.expect(table.lookup(1234) == null);
}

test "a zeroed cluster is empty and a foreign tag is a miss" {
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const count = table.clusters.len;
    // A key whose tag bits are zero is stored under tag 1 and found again;
    // empty slots never answer for it.
    const zero_tag = keyFor(9, count, 0);
    try std.testing.expect(table.lookup(zero_tag) == null);
    table.store(zero_tag, 3, 41, .exact, null);
    try std.testing.expectEqual(@as(i32, 41), table.lookup(zero_tag).?.score);
    try std.testing.expect(table.lookup(keyFor(9, count, 2)) == null);
    // The sequence word is not a tag: no key matches whatever it holds.
    table.clusters[9].sequence = 0x0002_0002;
    try std.testing.expect(table.lookup(keyFor(9, count, 2)) == null);
}

test "a refreshing probe makes an entry of an earlier search one of this search (tuning flavour)" {
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const count = table.clusters.len;
    var keys: [WAYS + 1]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = keyFor(5, count, @intCast(300 + i));
    // Five entries of one search; the deepest is the one the next search uses.
    for (keys[0..WAYS], 0..) |key, i| table.store(key, @intCast(4 + i), @intCast(i), .exact, null);
    table.newSearch();
    table.policy.refresh_on_hit = true;
    const found = table.probe(keys[WAYS - 1]).?;
    try std.testing.expectEqual(table.generation -% 1, found.generation);
    try std.testing.expectEqual(@as(i32, WAYS - 1), found.score);
    const refreshed = build_options.tuning;
    try std.testing.expectEqual(if (refreshed) table.generation else table.generation -% 1, table.lookup(keys[WAYS - 1]).?.generation);
    // The other four are replaced before it, shallowest first; then it is
    // the deepest entry of this search and stays. Without the refresh it is
    // the last of the earlier search to go: the fifth store takes it.
    for (0..WAYS) |i| table.store(keyFor(5, count, @intCast(400 + i)), 1, 0, .exact, null);
    try std.testing.expectEqual(refreshed, table.lookup(keys[WAYS - 1]) != null);
    for (keys[0 .. WAYS - 1]) |key| try std.testing.expect(table.lookup(key) == null);
    // The word keeps everything but its generation.
    const word = pack(.{ .move_bits = 0x1234, .score = -77, .depth = 9, .bound = .upper, .static_eval = 55, .was_pv = true, .generation = 3 });
    var expected = unpack(word, 3);
    expected.generation = 30;
    try std.testing.expectEqualDeep(expected, unpack(withGeneration(word, 30), 30));
}

test "a narrower tag keeps the low tag bits and is never zero" {
    const key: u64 = 0xabcd_1234_0000_0000;
    try std.testing.expectEqual(@as(Tag, 0xabcd_1234), tagFor(key, .{}));
    try std.testing.expectEqual(@as(Tag, 0x34), tagFor(key, .{ .tag_bits = 8 }));
    try std.testing.expectEqual(@as(Tag, 0x1234), tagFor(key, .{ .tag_bits = 16 }));
    try std.testing.expectEqual(@as(Tag, 1), tagFor(0x0000_ff00_0000_0000, .{ .tag_bits = 8 }));
    try std.testing.expectEqual(tagOf(key), tagFor(key, .{ .tag_bits = TAG_BITS }));
}

test "an entry is found only under its whole tag: a key that differs in any high bit is a miss" {
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const count = table.clusters.len;
    const key = keyFor(77, count, 0x5a5a_1234);
    table.store(key, 40, 29_000 - 3, .exact, move_mod.Move.init(.e2, .e4, .double_push));
    try std.testing.expect(table.lookup(key) != null);
    // The same cluster and the same 31 of the 32 tag bits: never this entry.
    for (0..32) |bit| {
        const other = key ^ (@as(u64, 1) << @intCast(32 + bit));
        try std.testing.expectEqual(clusterIndex(key, count), clusterIndex(other, count));
        try std.testing.expect(table.lookup(other) == null);
        try std.testing.expect(table.probe(other) == null);
        try std.testing.expect(table.bestMove(other) == null);
    }
    // Stored under a 16-bit tag (the stress knob, tuning flavour), the key
    // that shares the low 16 tag bits does find it: the foreign hit the wide
    // tag removes.
    table.clear();
    table.policy.tag_bits = 16;
    table.store(key, 40, 29_000 - 3, .exact, null);
    const foreign = key ^ (@as(u64, 1) << 63);
    try std.testing.expectEqual(build_options.tuning, table.lookup(foreign) != null);
}

test "a store without a move keeps the stored move only under keep_move, and only on the same position" {
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    const old = pack(.{ .move_bits = @bitCast(mv), .score = 40, .depth = 9, .bound = .lower, .static_eval = 12, .was_pv = true, .generation = 2 });
    const moveless = Record{ .move_bits = 0, .score = -7, .depth = 3, .bound = .upper, .static_eval = STATIC_EVAL_NONE, .was_pv = false, .generation = 5 };

    // Today's rule: the eval stays, the move goes.
    const erased = unpack(wordFor(moveless, true, old, false), 5);
    try std.testing.expectEqual(@as(u16, 0), erased.move_bits);
    try std.testing.expectEqual(@as(i16, 12), erased.static_eval);

    // keep_move: the move stays; score, depth, bound and PV flag are the new record's.
    const kept = unpack(wordFor(moveless, true, old, true), 5);
    try std.testing.expectEqual(mv, moveFromEntry(kept).?);
    try std.testing.expectEqual(@as(i32, -7), kept.score);
    try std.testing.expectEqual(@as(i16, 3), kept.depth);
    try std.testing.expectEqual(Bound.upper, kept.bound);
    try std.testing.expect(!kept.was_pv);
    try std.testing.expectEqual(@as(u8, 5), kept.generation);

    // Another position's slot gives nothing, and a record with a move keeps its own.
    try std.testing.expectEqual(@as(u16, 0), unpack(wordFor(moveless, false, old, true), 5).move_bits);
    const other = move_mod.Move.init(.g1, .f3, .quiet);
    var with_move = moveless;
    with_move.move_bits = @bitCast(other);
    try std.testing.expectEqual(other, moveFromEntry(unpack(wordFor(with_move, true, old, true), 5)).?);
}

test "the table's keep_move policy is read in the tuning flavour only; the release flavour has the default" {
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    // The policy that is not the default: only the tuning flavour follows it.
    table.policy.keep_move = !KEEP_MOVE_DEFAULT;
    const keeps = if (build_options.tuning) table.policy.keep_move else KEEP_MOVE_DEFAULT;
    const key = keyFor(3, table.clusters.len, 77);
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    table.store(key, 6, 30, .lower, mv);
    // A later search's shallower store without a move (a stand-pat, a null-move cutoff).
    table.newSearch();
    table.store(key, 1, 10, .lower, null);
    const entry = table.lookup(key).?;
    try std.testing.expectEqual(@as(i16, 1), entry.depth);
    try std.testing.expectEqual(if (keeps) @as(?move_mod.Move, mv) else null, moveFromEntry(entry));
    // A slot of another position that is replaced hands nothing on.
    var keys: [WAYS]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = keyFor(9, table.clusters.len, @intCast(500 + i));
    for (keys) |k| table.store(k, 2, 0, .exact, mv);
    const newcomer = keyFor(9, table.clusters.len, 600);
    table.store(newcomer, 2, 0, .exact, null);
    try std.testing.expect(moveFromEntry(table.lookup(newcomer).?) == null);
}
