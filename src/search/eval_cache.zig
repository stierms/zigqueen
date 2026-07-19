//! Dedicated raw-eval cache: a position-keyed memo of the RAW static
//! eval — the exact value `resources.evaluator.evaluate` would return.
//!
//! Motivation: post-LTO profiles put the NNUE eval family at 63-66% of
//! opening/middle cycles with per-eval cost at its measured floor; the
//! remaining lever is evaluating FEWER positions. The TT already caches the
//! raw eval (Entry.static_eval), but TT capacity is
//! contended by depth-preferred replacement — a TT-evicted position pays a
//! full NNUE forward on revisit. This table is a cheap second chance keyed
//! ONLY by position, with no depth competition.
//!
//! Design:
//!   - 2-way set-associative, 1-bit-LRU. Sets are 2 adjacent 16-byte
//!     entries (32B, in-line — 4 entries per 64B line); the victim is the
//!     slot NOT hit last. Measured at depth 18, 2-way is worth about a full
//!     size doubling over direct-mapped (+2.5-3.1pp hit rate at equal size).
//!   - Verifier = the FULL 64-bit zobrist key, matching the TT's verifier
//!     width exactly: a hit returns the raw eval of that exact position up to
//!     a full zobrist collision — the identical risk class the TT already
//!     accepts for Entry.static_eval reuse. Never narrow this to save space;
//!     d14 node-identity vs the uncached binary is the standing proof.
//!   - Indexed by the HIGH key bits (key >> (64 - log2(len))). The TT and
//!     rfp-hint tables both index by the LOW bits (key & mask); using the
//!     high bits decorrelates this table's conflict sets from theirs at zero
//!     cost (any index derivation is safe — the full key is the verifier).
//!   - key == 0 is the empty sentinel; a real position whose zobrist is
//!     exactly 0 (p ~ 2^-64, same class as a zobrist collision) is simply
//!     never cached (probe misses, store skips).
//!   - Sized off UCI Hash: Hash/4 clamped to [4, 64] MB (64MB default Hash
//!     -> 16MB cache; halving that measured 90-97% full at depth 18,
//!     thrashing against a ~1.1M-entry working set). No UCI option
//!     of its own; ucinewgame clears it (via Engine.reset), Hash resize
//!     re-sizes it.
//!   - Allocation routed through util/hugealloc like the TT/rfp-hint tables
//!     (zobrist-indexed random access over MBs -> same dTLB story).
//!
//! Experiment scaffolding (compiled into -Dsearch-stats builds ONLY;
//! release builds comptime-fold every policy check to the shipped default):
//!   - ZQ_EVAL_CACHE_MB: override the table size (clamped [4, 256] MB) for
//!     sizing sweeps at fixed Hash.
//!   - ZQ_EVAL_CACHE_ASSOC=1|2: direct-mapped vs 2-way. The 2-way variant
//!     pairs adjacent entries (32B set — in-line: 4 entries per 64B line) and
//!     replaces the slot NOT hit last (1-bit LRU stored in slot0's spare
//!     byte; a probe hit writes the bit only when it changes). Values stay
//!     exact — node-identity holds for every variant.

const std = @import("std");
const build_options = @import("build_options");
const hugealloc = @import("../util/hugealloc.zig");

/// Experiment knobs (env overrides + runtime associativity switch) exist only
/// in stats builds; release builds fold every policy check to the default.
pub const experiment_overrides_enabled: bool = build_options.search_stats;

/// Shipped replacement policy: 1 = direct-mapped, 2 = 2-way 1-bit-LRU.
pub const default_assoc: u8 = 2;

/// Absolute table bounds (resize clamp). The wide 256MB ceiling exists for
/// stats-build sizing sweeps; the SHIPPED size always comes from sizeForHash,
/// whose own clamp below is much tighter.
pub const MIN_CACHE_MB: u32 = 4;
pub const MAX_CACHE_MB: u32 = 256;

/// Hash-derived sizing clamp (the shipped config): Hash/4 in [4, 64] MB.
pub const HASH_DERIVED_MIN_MB: u32 = 4;
pub const HASH_DERIVED_MAX_MB: u32 = 64;

pub const Entry = struct {
    /// Full 64-bit zobrist key (verifier). 0 = empty.
    key: u64 = 0,
    /// Raw static eval, exactly what evaluator.evaluate returned. Raw NNUE
    /// output is well inside i16 (the TT stores the same value as i16).
    eval: i16 = 0,
    /// 2-way mode only, meaningful on slot0 of each pair: index (0/1) of the
    /// most-recently-USED slot in the set; the victim is the other slot.
    /// Lives in what was padding — Entry stays 16 bytes. Unused when direct.
    meta: u8 = 0,
};

comptime {
    // 4 entries per 64B cache line; the index math assumes a 16B stride and
    // 2-way sets (2 adjacent entries, 32B) never straddling a line.
    std.debug.assert(@sizeOf(Entry) == 16);
}

pub const Occupancy = struct { filled: usize, total: usize };

pub const EvalCache = struct {
    allocator: std.mem.Allocator,
    configured_mb: u32 = 0,
    entries: []Entry = &.{},
    /// How `entries` is backed; frees must go through hugealloc with this.
    alloc_method: hugealloc.Method = .heap,
    /// Right-shift that maps a key's HIGH bits onto [0, entries.len).
    index_shift: u6 = 63,
    /// Associativity (1 or 2). Only consulted in stats builds; release builds
    /// use default_assoc at comptime (isTwoWay folds the field access away).
    assoc: u8 = default_assoc,

    pub fn init(allocator: std.mem.Allocator, cache_mb: u32) !EvalCache {
        var cache = EvalCache{ .allocator = allocator };
        try cache.resize(cache_mb);
        if (comptime experiment_overrides_enabled) {
            if (envU32(allocator, "ZQ_EVAL_CACHE_MB")) |mb| try cache.resize(mb);
            if (envU32(allocator, "ZQ_EVAL_CACHE_ASSOC")) |ways| {
                if (ways == 1 or ways == 2) cache.assoc = @intCast(ways);
            }
        }
        return cache;
    }

    pub fn deinit(self: *EvalCache) void {
        hugealloc.free(Entry, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.configured_mb = 0;
        self.entries = &.{};
        self.alloc_method = .heap;
        self.index_shift = 63;
    }

    pub fn clear(self: *EvalCache) void {
        if (self.entries.len != 0) @memset(self.entries, .{});
    }

    pub fn resize(self: *EvalCache, cache_mb: u32) !void {
        const clamped_mb = std.math.clamp(cache_mb, MIN_CACHE_MB, MAX_CACHE_MB);
        const new_len = entryCountFor(clamped_mb);
        if (self.entries.len == new_len) {
            self.configured_mb = clamped_mb;
            self.clear();
            return;
        }

        hugealloc.free(Entry, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.entries = &.{};
        const backed = try hugealloc.alloc(Entry, self.allocator, new_len);
        self.entries = backed.items;
        self.alloc_method = backed.method;
        self.configured_mb = clamped_mb;
        self.index_shift = @intCast(@as(usize, 64) - std.math.log2_int(usize, new_len));
        self.clear();
    }

    pub fn cacheSizeMb(self: *const EvalCache) u32 {
        return self.configured_mb;
    }

    pub fn assocWays(self: *const EvalCache) u8 {
        return if (self.isTwoWay()) 2 else 1;
    }

    /// Filled-entry count (report-time scan; never on the search path).
    pub fn occupancy(self: *const EvalCache) Occupancy {
        var filled: usize = 0;
        for (self.entries) |*entry| {
            if (entry.key != 0) filled += 1;
        }
        return .{ .filled = filled, .total = self.entries.len };
    }

    /// The raw static eval for `key`, or null. A non-null result is THE value
    /// evaluator.evaluate would return for this position (full-key verified).
    /// Takes *EvalCache: the 2-way variant refreshes its per-set LRU bit on a
    /// hit (write only when the bit changes); the direct path never writes.
    pub inline fn probe(self: *EvalCache, key: u64) ?i16 {
        if (self.entries.len == 0) return null;
        if (self.isTwoWay()) {
            if (key == 0) return null;
            const base = self.setBase(key);
            const e0: *Entry = &self.entries[base];
            const e1: *Entry = &self.entries[base + 1];
            if (e0.key == key) {
                if (e0.meta != 0) e0.meta = 0;
                return e0.eval;
            }
            if (e1.key == key) {
                if (e0.meta != 1) e0.meta = 1;
                return e1.eval;
            }
            return null;
        }
        const entry = &self.entries[self.index(key)];
        if (entry.key == key and key != 0) return entry.eval;
        return null;
    }

    /// Memoize a freshly computed raw eval. Direct: always replaces. 2-way:
    /// matching slot, else an empty slot, else the slot NOT hit last.
    pub inline fn store(self: *EvalCache, key: u64, eval: i16) void {
        if (self.entries.len == 0 or key == 0) return;
        if (self.isTwoWay()) {
            const base = self.setBase(key);
            const e0: *Entry = &self.entries[base];
            const e1: *Entry = &self.entries[base + 1];
            if (e0.key == key or e0.key == 0) {
                e0.key = key;
                e0.eval = eval;
                e0.meta = 0;
                return;
            }
            if (e1.key == key or e1.key == 0) {
                e1.key = key;
                e1.eval = eval;
                e0.meta = 1;
                return;
            }
            if (e0.meta == 0) {
                // Slot0 was used last -> evict slot1.
                e1.key = key;
                e1.eval = eval;
                e0.meta = 1;
            } else {
                e0.key = key;
                e0.eval = eval;
                e0.meta = 0;
            }
            return;
        }
        self.entries[self.index(key)] = .{ .key = key, .eval = eval };
    }

    inline fn isTwoWay(self: *const EvalCache) bool {
        if (comptime !experiment_overrides_enabled) return default_assoc == 2;
        return self.assoc == 2;
    }

    inline fn index(self: *const EvalCache, key: u64) usize {
        return @intCast(key >> self.index_shift);
    }

    /// 2-way set base: high key bits select one of len/2 sets of 2 adjacent
    /// entries (even index). One extra shift vs direct — same single line.
    inline fn setBase(self: *const EvalCache, key: u64) usize {
        return @intCast((key >> (self.index_shift + 1)) << 1);
    }
};

fn entryCountFor(cache_mb: u32) usize {
    const target_bytes = @as(u64, cache_mb) * 1024 * 1024;
    const max_entries = @max(@as(u64, 1), target_bytes / @sizeOf(Entry));

    var entries: u64 = 1;
    while ((entries << 1) <= max_entries) : (entries <<= 1) {}
    return @intCast(entries);
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
}

test "eval cache verifies the full key on colliding index" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    // Direct-mapped-specific assertions; runnable only when the runtime
    // assoc switch exists (stats builds) or the shipped default is direct.
    cache.assoc = 1;
    if (cache.assocWays() != 1) return error.SkipZigTest;

    // Same table index (high bits), different keys: the low bits differ.
    const key_a: u64 = 0xABCD_0000_0000_0001;
    const key_b: u64 = 0xABCD_0000_0000_0002;
    try std.testing.expectEqual(cache.entries.len - 1, cache.index(0xFFFF_FFFF_FFFF_FFFF));
    cache.store(key_a, 55);
    try std.testing.expectEqual(@as(?i16, 55), cache.probe(key_a));
    try std.testing.expect(cache.probe(key_b) == null);

    // Direct-mapped always-replace: key_b evicts key_a.
    cache.store(key_b, -7);
    try std.testing.expectEqual(@as(?i16, -7), cache.probe(key_b));
    try std.testing.expect(cache.probe(key_a) == null);
}

test "eval cache never hits on the empty sentinel key" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    try std.testing.expect(cache.probe(0) == null);
    cache.store(0, 99); // skipped
    try std.testing.expect(cache.probe(0) == null);
}

test "eval cache clear and resize drop previous entries" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();

    cache.store(0x42_0000_0000_0000, 17);
    cache.clear();
    try std.testing.expect(cache.probe(0x42_0000_0000_0000) == null);

    cache.store(0x42_0000_0000_0000, 17);
    try cache.resize(MIN_CACHE_MB + 4);
    try std.testing.expect(cache.probe(0x42_0000_0000_0000) == null);
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
    cache.store(0x1111_0000_0000_0000, 5);
    cache.store(0x2222_0000_0000_0000, 6);
    const occ = cache.occupancy();
    try std.testing.expectEqual(@as(usize, 2), occ.filled);
    try std.testing.expectEqual(cache.entries.len, occ.total);
}

// ---- 2-way policy tests: run whenever the effective policy is 2-way
// (always with the shipped default; via the runtime switch in stats builds).

test "two-way set keeps two colliding keys live" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    cache.assoc = 2;
    if (cache.assocWays() != 2) return error.SkipZigTest;

    // Identical set (high bits after the extra shift), two distinct keys.
    const key_a: u64 = 0xABCD_0000_0000_0001;
    const key_b: u64 = 0xABCD_0000_0000_0002;
    cache.store(key_a, 10);
    cache.store(key_b, 20);
    try std.testing.expectEqual(@as(?i16, 10), cache.probe(key_a));
    try std.testing.expectEqual(@as(?i16, 20), cache.probe(key_b));
}

test "two-way evicts the slot not hit last" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    cache.assoc = 2;
    if (cache.assocWays() != 2) return error.SkipZigTest;

    const key_a: u64 = 0xABCD_0000_0000_0001;
    const key_b: u64 = 0xABCD_0000_0000_0002;
    const key_c: u64 = 0xABCD_0000_0000_0003;
    cache.store(key_a, 10); // slot0, MRU=0
    cache.store(key_b, 20); // slot1, MRU=1
    _ = cache.probe(key_a); // MRU=0 -> victim is slot1 (key_b)
    cache.store(key_c, 30);
    try std.testing.expectEqual(@as(?i16, 10), cache.probe(key_a));
    try std.testing.expectEqual(@as(?i16, 30), cache.probe(key_c));
    try std.testing.expect(cache.probe(key_b) == null);

    // Now key_c (slot1) was hit last -> victim is slot0 (key_a).
    cache.store(key_b, 21);
    try std.testing.expectEqual(@as(?i16, 21), cache.probe(key_b));
    try std.testing.expectEqual(@as(?i16, 30), cache.probe(key_c));
    try std.testing.expect(cache.probe(key_a) == null);
}

test "two-way verifies the full key and misses cleanly" {
    var cache = try EvalCache.init(std.testing.allocator, MIN_CACHE_MB);
    defer cache.deinit();
    cache.assoc = 2;
    if (cache.assocWays() != 2) return error.SkipZigTest;

    const key_a: u64 = 0xABCD_0000_0000_0001;
    cache.store(key_a, 42);
    try std.testing.expect(cache.probe(0xABCD_0000_0000_0009) == null);
    try std.testing.expect(cache.probe(0) == null);
    try std.testing.expectEqual(@as(?i16, 42), cache.probe(key_a));
}
