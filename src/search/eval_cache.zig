//! Dedicated raw-eval cache (perf-r11): a position-keyed memo of the RAW static
//! eval — the exact value `resources.evaluator.evaluate` would return.
//!
//! Motivation: post-LTO profiles put the NNUE eval family at 63-66% of
//! opening/middle cycles with per-eval cost at its measured floor; the
//! remaining lever is evaluating FEWER positions. The TT already caches the
//! raw eval (v5.1.0 "Lever 1", Entry.static_eval), but TT capacity is
//! contended by depth-preferred replacement — a TT-evicted position pays a
//! full NNUE forward on revisit. This table is a cheap second chance keyed
//! ONLY by position, with no depth competition.
//!
//! Design (perf r3, compact form; 2-way 16-byte entries before):
//!   - 8-way sets of 8-byte entries: one set is one 64-byte line, so a probe
//!     still touches one line, and the same memory holds twice the entries.
//!     LRU by move-to-front inside the set: a hit or a store puts its entry
//!     first, a store of a new key drops the last.
//!   - An entry is the key's low 48 bits (the tag) above the i16 eval. Sets are
//!     indexed by the HIGH key bits (key >> (64 - log2(sets))), at least 16 of
//!     them at every allowed size (asserted at resize), so tag and index
//!     together are the FULL 64-bit key: a hit returns the raw eval of that
//!     exact position up to a full zobrist collision, the risk class the TT
//!     already accepts for Entry.static_eval reuse. d13 node identity vs the
//!     uncached binary is the standing proof.
//!   - The TT and rfp-hint tables index by the LOW key bits; the high-bit index
//!     decorrelates this table's conflict sets from theirs at zero cost.
//!   - A zero entry is empty; a key whose low 48 bits are all zero (p ~ 2^-48)
//!     is simply never cached (probe misses, store skips).
//!   - Sized off UCI Hash: Hash/4 clamped to [4, 64] MB. No UCI option of its
//!     own; ucinewgame clears it (via Engine.reset), Hash resize re-sizes it.
//!     At Threads = N every engine keeps a private copy of 1/N of that size
//!     (floor 4 MB; engine.zig PrivateTableSizes).
//!   - Allocation routed through util/hugealloc like the TT/rfp-hint tables
//!     (zobrist-indexed random access over MBs -> same dTLB story).
//!
//! Stats builds only (release builds fold it away): ZQ_EVAL_CACHE_MB overrides
//! the table size (clamped [4, 256] MB) for sizing sweeps at fixed Hash.

const std = @import("std");
const build_options = @import("build_options");
const hugealloc = @import("../util/hugealloc.zig");

/// The size override exists only in stats builds.
pub const experiment_overrides_enabled: bool = build_options.search_stats;

/// Entries per set (one 64-byte line).
pub const WAYS: usize = 8;

/// Absolute table bounds (resize clamp). The wide 256MB ceiling exists for
/// stats-build sizing sweeps; the SHIPPED size always comes from sizeForHash,
/// whose own clamp below is much tighter.
pub const MIN_CACHE_MB: u32 = 4;
pub const MAX_CACHE_MB: u32 = 256;

/// Hash-derived sizing clamp (the shipped config): Hash/4 in [4, 64] MB.
pub const HASH_DERIVED_MIN_MB: u32 = 4;
pub const HASH_DERIVED_MAX_MB: u32 = 64;

/// Key bits stored in an entry; the set index must supply the other 16.
const TAG_BITS = 48;
const TAG_MASK: u64 = (@as(u64, 1) << TAG_BITS) - 1;
const MIN_INDEX_BITS = 64 - TAG_BITS;

/// One line: entries most recently used first. An entry is
/// `tag << 16 | (eval as u16)`; 0 is empty.
pub const Set = extern struct {
    slots: [WAYS]u64 align(64) = [_]u64{0} ** WAYS,
};

comptime {
    std.debug.assert(@sizeOf(Set) == 64 and @alignOf(Set) == 64);
    // The smallest table still has enough index bits for full-key equivalence.
    std.debug.assert(std.math.log2_int(u64, setCountFor(MIN_CACHE_MB)) >= MIN_INDEX_BITS);
}

pub const Occupancy = struct { filled: usize, total: usize };

pub const EvalCache = struct {
    allocator: std.mem.Allocator,
    configured_mb: u32 = 0,
    sets: []Set = &.{},
    /// How `sets` is backed; frees must go through hugealloc with this.
    alloc_method: hugealloc.Method = .heap,
    /// Right-shift that maps a key's HIGH bits onto [0, sets.len).
    index_shift: u6 = 63,

    pub fn init(allocator: std.mem.Allocator, cache_mb: u32) !EvalCache {
        var cache = EvalCache{ .allocator = allocator };
        try cache.resize(cache_mb);
        if (comptime experiment_overrides_enabled) {
            if (envU32(allocator, "ZQ_EVAL_CACHE_MB")) |mb| try cache.resize(mb);
        }
        return cache;
    }

    pub fn deinit(self: *EvalCache) void {
        hugealloc.free(Set, self.allocator, .{ .items = self.sets, .method = self.alloc_method });
        self.configured_mb = 0;
        self.sets = &.{};
        self.alloc_method = .heap;
        self.index_shift = 63;
    }

    pub fn clear(self: *EvalCache) void {
        if (self.sets.len != 0) @memset(self.sets, .{});
    }

    pub fn resize(self: *EvalCache, cache_mb: u32) !void {
        const clamped_mb = std.math.clamp(cache_mb, MIN_CACHE_MB, MAX_CACHE_MB);
        const new_len = setCountFor(clamped_mb);
        if (self.sets.len == new_len) {
            self.configured_mb = clamped_mb;
            self.clear();
            return;
        }

        hugealloc.free(Set, self.allocator, .{ .items = self.sets, .method = self.alloc_method });
        self.sets = &.{};
        const backed = try hugealloc.alloc(Set, self.allocator, new_len);
        self.sets = backed.items;
        self.alloc_method = backed.method;
        self.configured_mb = clamped_mb;
        const index_bits = std.math.log2_int(usize, new_len);
        // Tag + index = the full 64-bit key (see the design notes).
        std.debug.assert(index_bits >= MIN_INDEX_BITS);
        self.index_shift = @intCast(@as(usize, 64) - index_bits);
        self.clear();
    }

    pub fn cacheSizeMb(self: *const EvalCache) u32 {
        return self.configured_mb;
    }

    pub fn assocWays(self: *const EvalCache) u8 {
        _ = self;
        return WAYS;
    }

    /// Filled-entry count (report-time scan; never on the search path).
    pub fn occupancy(self: *const EvalCache) Occupancy {
        var filled: usize = 0;
        for (self.sets) |*set| {
            for (set.slots) |slot| filled += @intFromBool(slot != 0);
        }
        return .{ .filled = filled, .total = self.sets.len * WAYS };
    }

    /// The raw static eval for `key`, or null. A non-null result is THE value
    /// evaluator.evaluate would return for this position (full-key verified).
    /// A hit moves its entry to the front of the set.
    pub inline fn probe(self: *EvalCache, key: u64) ?i16 {
        if (self.sets.len == 0) return null;
        const tag = key & TAG_MASK;
        if (tag == 0) return null;
        const set = &self.sets[self.setIndex(key)];
        const slots: @Vector(WAYS, u64) = set.slots;
        const hits: u8 = @bitCast((slots >> @splat(16)) == @as(@Vector(WAYS, u64), @splat(tag)));
        if (hits == 0) return null;
        const way: u3 = @intCast(@ctz(hits));
        const entry = set.slots[way];
        if (way != 0) moveToFront(set, slots, way, entry);
        return @bitCast(@as(u16, @truncate(entry)));
    }

    /// Overlap a child's eval-cache miss with its TT probe: the parent issues
    /// this right after makeMove, beside the TT prefetch. The child probes this
    /// line whenever its TT entry carries no static eval, and the 16 MB+ table
    /// misses the caches on most probes (the probe compare was 6% of negamax and
    /// 11-17% of quiescence cycles). A hint only: no value changes.
    pub inline fn prefetch(self: *const EvalCache, key: u64) void {
        if (self.sets.len == 0) return;
        @prefetch(&self.sets[self.setIndex(key)], .{ .rw = .read, .locality = 3, .cache = .data });
    }

    /// Memoize a freshly computed raw eval: the entry goes to the front of its
    /// set, replacing the key's old entry if there is one, else the last.
    pub inline fn store(self: *EvalCache, key: u64, eval: i16) void {
        if (self.sets.len == 0) return;
        const tag = key & TAG_MASK;
        if (tag == 0) return;
        const set = &self.sets[self.setIndex(key)];
        const slots: @Vector(WAYS, u64) = set.slots;
        const hits: u8 = @bitCast((slots >> @splat(16)) == @as(@Vector(WAYS, u64), @splat(tag)));
        const way: u3 = if (hits != 0) @intCast(@ctz(hits)) else WAYS - 1;
        moveToFront(set, slots, way, (tag << 16) | @as(u16, @bitCast(eval)));
    }

    inline fn setIndex(self: *const EvalCache, key: u64) usize {
        return @intCast(key >> self.index_shift);
    }
};

/// Write `entry` to the front of `set` and shift the entries before `way` back
/// by one (`slots` is the set as loaded); entries after `way` stay.
inline fn moveToFront(set: *Set, slots: @Vector(WAYS, u64), way: u3, entry: u64) void {
    const LANE: @Vector(WAYS, u8) = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const shifted = @shuffle(u64, slots, @as(@Vector(1, u64), @splat(entry)), @Vector(WAYS, i32){ -1, 0, 1, 2, 3, 4, 5, 6 });
    const moved = LANE <= @as(@Vector(WAYS, u8), @splat(way));
    set.slots = @select(u64, moved, shifted, slots);
}

fn setCountFor(cache_mb: u32) usize {
    const target_bytes = @as(u64, cache_mb) * 1024 * 1024;
    const max_sets = @max(@as(u64, 1), target_bytes / @sizeOf(Set));

    var sets: u64 = 1;
    while ((sets << 1) <= max_sets) : (sets <<= 1) {}
    return @intCast(sets);
}

/// Cache size derived from UCI Hash: Hash/4, clamped to [4, 64] MB.
pub fn sizeForHash(hash_mb: u32) u32 {
    const quarter = hash_mb / 4;
    if (quarter < HASH_DERIVED_MIN_MB) return HASH_DERIVED_MIN_MB;
    if (quarter > HASH_DERIVED_MAX_MB) return HASH_DERIVED_MAX_MB;
    return quarter;
}

fn envU32(allocator: std.mem.Allocator, name: []const u8) ?u32 {
    const text = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(text);
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

test "eval cache stores and retrieves the raw eval" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    try std.testing.expect(cache.probe(0xDEADBEEF) == null);
    cache.store(0xDEADBEEF, -123);
    try std.testing.expectEqual(@as(?i16, -123), cache.probe(0xDEADBEEF));
    cache.store(0xDEADBEEF, 77);
    try std.testing.expectEqual(@as(?i16, 77), cache.probe(0xDEADBEEF));
    try std.testing.expectEqual(@as(usize, 1), cache.occupancy().filled);
}

test "eval cache verifies the full key: tag plus index bits" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    try std.testing.expect(64 - @as(usize, cache.index_shift) >= MIN_INDEX_BITS);

    // Same set (high bits), different low bits: different tags.
    const key_a: u64 = 0xABCD_0000_0000_0001;
    const key_b: u64 = 0xABCD_0000_0000_0002;
    // Same low 48 bits, different high bits: different sets.
    const key_c: u64 = 0x1234_0000_0000_0001;
    try std.testing.expectEqual(cache.setIndex(key_a), cache.setIndex(key_b));
    try std.testing.expect(cache.setIndex(key_a) != cache.setIndex(key_c));
    cache.store(key_a, 55);
    try std.testing.expectEqual(@as(?i16, 55), cache.probe(key_a));
    try std.testing.expect(cache.probe(key_b) == null);
    try std.testing.expect(cache.probe(key_c) == null);
}

test "eval cache never caches a key with an all-zero tag" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    try std.testing.expect(cache.probe(0) == null);
    cache.store(0, 99); // skipped
    cache.store(0xFFFF_0000_0000_0000, 98); // skipped: low 48 bits zero
    try std.testing.expect(cache.probe(0) == null);
    try std.testing.expect(cache.probe(0xFFFF_0000_0000_0000) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.occupancy().filled);
}

test "eval cache keeps eight keys per set and evicts the least recently used" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    const base: u64 = 0x5A5A_0000_0000_0000;
    for (1..9) |i| cache.store(base | i, @intCast(i));
    for (1..9) |i| try std.testing.expectEqual(@as(?i16, @intCast(i)), cache.probe(base | i));
    // Probed in order 1..8, so 1 is now the least recently used: a ninth key evicts it.
    cache.store(base | 9, 9);
    try std.testing.expect(cache.probe(base | 1) == null);
    for (2..10) |i| try std.testing.expectEqual(@as(?i16, @intCast(i)), cache.probe(base | i));
    // A hit refreshes: touch 2, then a new key evicts 3 (the oldest untouched).
    _ = cache.probe(base | 2);
    cache.store(base | 10, 10);
    try std.testing.expect(cache.probe(base | 3) == null);
    try std.testing.expectEqual(@as(?i16, 2), cache.probe(base | 2));
    try std.testing.expectEqual(@as(?i16, 10), cache.probe(base | 10));
}

test "eval cache LRU order matches the scalar move-to-front reference" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    var reference: [WAYS]u64 = [_]u64{0} ** WAYS;
    var prng = std.Random.DefaultPrng.init(0xe7a1_cac4);
    const rand = prng.random();
    const base: u64 = 0x3C3C_0000_0000_0000;
    for (0..20_000) |_| {
        const key = base | (1 + rand.uintLessThan(u64, 12));
        const tag = key & TAG_MASK;
        if (rand.boolean()) {
            const eval: i16 = rand.int(i16);
            cache.store(key, eval);
            var way: usize = WAYS - 1;
            for (reference, 0..) |slot, i| {
                if (slot >> 16 == tag) {
                    way = i;
                    break;
                }
            }
            var j = way;
            while (j > 0) : (j -= 1) reference[j] = reference[j - 1];
            reference[0] = (tag << 16) | @as(u16, @bitCast(eval));
        } else {
            const got = cache.probe(key);
            var expected: ?i16 = null;
            for (reference, 0..) |slot, i| {
                if (slot != 0 and slot >> 16 == tag) {
                    expected = @bitCast(@as(u16, @truncate(slot)));
                    var j = i;
                    while (j > 0) : (j -= 1) reference[j] = reference[j - 1];
                    reference[0] = slot;
                    break;
                }
            }
            try std.testing.expectEqual(expected, got);
        }
        try std.testing.expectEqualSlices(u64, &reference, &cache.sets[cache.setIndex(base)].slots);
    }
}

test "eval cache clear and resize drop previous entries" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    cache.store(0x42_0000_0000_0042, 17);
    cache.clear();
    try std.testing.expect(cache.probe(0x42_0000_0000_0042) == null);

    cache.store(0x42_0000_0000_0042, 17);
    try cache.resize(MIN_CACHE_MB + 4);
    try std.testing.expect(cache.probe(0x42_0000_0000_0042) == null);
}

test "hash-derived sizing clamps to [4, 64] MB" {
    try std.testing.expectEqual(@as(u32, HASH_DERIVED_MIN_MB), sizeForHash(1));
    try std.testing.expectEqual(@as(u32, HASH_DERIVED_MIN_MB), sizeForHash(8));
    try std.testing.expectEqual(@as(u32, 8), sizeForHash(32));
    try std.testing.expectEqual(@as(u32, 16), sizeForHash(64));
    try std.testing.expectEqual(@as(u32, 64), sizeForHash(256));
    try std.testing.expectEqual(@as(u32, HASH_DERIVED_MAX_MB), sizeForHash(4096));
}

test "occupancy counts filled entries" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    try std.testing.expectEqual(@as(usize, 0), cache.occupancy().filled);
    cache.store(0x1111_0000_0000_0001, 5);
    cache.store(0x2222_0000_0000_0002, 6);
    const occ = cache.occupancy();
    try std.testing.expectEqual(@as(usize, 2), occ.filled);
    try std.testing.expectEqual(cache.sets.len * WAYS, occ.total);
}
