const std = @import("std");
const hugealloc = @import("../util/hugealloc.zig");
const move_mod = @import("../core/move.zig");

pub const DEFAULT_HASH_MB: u32 = 64;
pub const MIN_HASH_MB: u32 = 1;
pub const MAX_HASH_MB: u32 = 65_536;

pub const Bound = enum(u2) {
    exact,
    lower,
    upper,
};

/// Sentinel for "no static eval cached" (evals live well inside i16).
pub const STATIC_EVAL_NONE: i16 = std.math.minInt(i16);

pub const Entry = struct {
    key: u64 = 0,
    move_bits: u16 = 0,
    score: i32 = 0,
    depth: i16 = -1,
    generation: u8 = 0,
    bound: Bound = .exact,
    // Raw (uncorrected) static eval of the position — lever 1 (2026-07-16):
    // saves the NNUE forward on TT hits without a cutoff. Fits in the struct's
    // existing padding (18 -> 20 bytes, layout stays 24), so zero size cost.
    static_eval: i16 = STATIC_EVAL_NONE,
    /// True when this position was stored from a PV node. Basin LMR uses the
    /// bit as an accuracy brake if the position later appears off-PV.
    was_pv: bool = false,
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

const CLUSTER_SIZE: usize = 2;

pub const Cluster = struct {
    entries: [CLUSTER_SIZE]Entry = [_]Entry{.{}} ** CLUSTER_SIZE,
};

pub const TranspositionTable = struct {
    allocator: std.mem.Allocator,
    configured_hash_mb: u32 = 0,
    entries: []Cluster = &.{},
    /// How `entries` is backed (2MB huge pages when the OS grants them — a 64MB
    /// table on 4KB pages needs 16384 dTLB entries, so every zobrist-indexed
    /// probe is a likely TLB walk). Frees must go through hugealloc with this.
    alloc_method: hugealloc.Method = .heap,
    mask: u64 = 0,
    generation: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, hash_mb: u32) !TranspositionTable {
        var table = TranspositionTable{ .allocator = allocator };
        try table.resize(hash_mb);
        return table;
    }

    pub fn deinit(self: *TranspositionTable) void {
        hugealloc.free(Cluster, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.configured_hash_mb = 0;
        self.entries = &.{};
        self.alloc_method = .heap;
        self.mask = 0;
        self.generation = 0;
    }

    pub fn clear(self: *TranspositionTable) void {
        if (self.entries.len != 0) @memset(self.entries, .{});
        self.generation = 0;
    }

    pub fn newSearch(self: *TranspositionTable) void {
        self.generation +%= 1;
    }

    pub fn resize(self: *TranspositionTable, hash_mb: u32) !void {
        const clamped_mb = std.math.clamp(hash_mb, MIN_HASH_MB, MAX_HASH_MB);
        const new_len = entryCountForHash(clamped_mb);
        if (self.entries.len == new_len) {
            self.configured_hash_mb = clamped_mb;
            self.clear();
            return;
        }

        hugealloc.free(Cluster, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.entries = &.{};
        const backed = try hugealloc.alloc(Cluster, self.allocator, new_len);
        self.entries = backed.items;
        self.alloc_method = backed.method;
        self.configured_hash_mb = clamped_mb;
        self.mask = new_len - 1;
        self.clear();
    }

    pub fn hashSizeMb(self: *const TranspositionTable) u32 {
        return self.configured_hash_mb;
    }

    pub fn entryCount(self: *const TranspositionTable) usize {
        return self.entries.len * CLUSTER_SIZE;
    }

    /// Hint the CPU to start fetching a key's cluster into cache. Call as soon as
    /// a child position's key is known (after make-move) so the line arrives
    /// before that node probes -- hides the random-access TT miss latency.
    pub inline fn prefetch(self: *const TranspositionTable, key: u64) void {
        if (self.entries.len == 0) return;
        // A 48-byte cluster straddles two 64-byte lines at every index = 1, 2
        // (mod 4): hint its first and its last byte, so both lines are in flight
        // (a redundant second hint to the same line costs one load-port slot).
        const first: [*]const u8 = @ptrCast(&self.entries[index(self.mask, key)]);
        @prefetch(first, .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(first + (@sizeOf(Cluster) - 1), .{ .rw = .read, .locality = 3, .cache = .data });
    }

    /// Copy the matching entry at the table boundary. The caller owns this
    /// snapshot; later stores, clears or resize cannot mutate it. This serial
    /// implementation is not safe for concurrent writers (P2 adds coherence).
    pub inline fn lookup(self: *const TranspositionTable, key: u64) ?Entry {
        if (self.entries.len == 0) return null;
        const cluster = &self.entries[index(self.mask, key)];
        // Both slots tested without a branch per slot (the key compares wait on
        // the cluster's cache miss, so a per-slot branch resolves late), then
        // the first match is selected: the same entry the slot-order scan
        // returned.
        comptime std.debug.assert(CLUSTER_SIZE == 2);
        const first = &cluster.entries[0];
        const second = &cluster.entries[1];
        const hit_first = @intFromBool(first.key == key) & @intFromBool(first.depth >= 0);
        const hit_second = @intFromBool(second.key == key) & @intFromBool(second.depth >= 0);
        if (hit_first | hit_second == 0) return null;
        return (if (hit_first != 0) first else second).*;
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
        if (self.entries.len == 0) return outcome;

        const cluster = &self.entries[index(self.mask, key)];
        // The slot-order scan as data, not branches: slot 0 when it carries
        // `key` or is empty; else slot 1 when it carries `key`, is empty, or
        // is the better victim (older generation first, then shallower; slot
        // 0 on a tie). A slot carrying `key` is chosen only by that test, so
        // the same-generation-deeper skip below sees the same entry the scan
        // stopped at.
        comptime std.debug.assert(CLUSTER_SIZE == 2);
        const e0 = &cluster.entries[0];
        const e1 = &cluster.entries[1];
        const current0 = e0.generation == self.generation;
        const current1 = e1.generation == self.generation;
        const take0 = @intFromBool(e0.key == key) | @intFromBool(e0.depth < 0);
        const older1 = @intFromBool(!current1) & (@intFromBool(current0) | @intFromBool(e1.depth < e0.depth));
        const shallower1 = @intFromBool(current1) & @intFromBool(current0) & @intFromBool(e1.depth < e0.depth);
        const take1 = @intFromBool(e1.key == key) | @intFromBool(e1.depth < 0) | older1 | shallower1;
        const replacement = if (take0 == 0 and take1 != 0) e1 else e0;
        if (replacement.key == key and replacement.generation == self.generation and replacement.depth > depth) {
            outcome.skipped_same_generation_deeper = true;
            outcome.same_key = true;
            outcome.victim_generation = replacement.generation;
            outcome.victim_depth = replacement.depth;
            outcome.victim_bound = replacement.bound;
            outcome.victim_had_move = replacement.move_bits != 0;
            return outcome;
        }

        const victim = replacement.*;
        outcome.stored = true;
        outcome.same_key = victim.depth >= 0 and victim.key == key;
        outcome.empty_slot = victim.depth < 0;
        outcome.replaced_occupied = victim.depth >= 0 and !outcome.same_key;
        if (victim.depth >= 0) {
            outcome.victim_generation = victim.generation;
            outcome.victim_depth = victim.depth;
            outcome.victim_bound = victim.bound;
            outcome.victim_had_move = victim.move_bits != 0;
        }

        // Static eval is position-invariant: a same-key overwrite that arrives
        // without one (e.g. a null-move bound store) preserves the cached value.
        const kept_eval = if (static_eval == STATIC_EVAL_NONE and outcome.same_key) victim.static_eval else static_eval;
        replacement.key = key;
        replacement.move_bits = if (mv) |move| @bitCast(move) else 0;
        replacement.score = score;
        replacement.depth = depth;
        replacement.generation = self.generation;
        replacement.bound = bound;
        replacement.static_eval = kept_eval;
        replacement.was_pv = was_pv;
        return outcome;
    }

    pub fn hashfullPermille(self: *const TranspositionTable) u16 {
        if (self.entries.len == 0) return 0;

        const sample_len = @min(self.entries.len, 1000);
        var used: usize = 0;
        for (self.entries[0..sample_len]) |cluster| {
            for (cluster.entries) |entry| {
                if (entry.depth >= 0) used += 1;
            }
        }
        return @intCast((used * 1000) / (sample_len * CLUSTER_SIZE));
    }
};

pub inline fn moveFromEntry(entry: Entry) ?move_mod.Move {
    if (entry.move_bits == 0) return null;
    return @bitCast(entry.move_bits);
}

fn entryCountForHash(hash_mb: u32) usize {
    const target_bytes = @as(u64, hash_mb) * 1024 * 1024;
    const max_clusters = @max(@as(u64, 1), target_bytes / @sizeOf(Cluster));

    var clusters: u64 = 1;
    while ((clusters << 1) <= max_clusters) : (clusters <<= 1) {}
    return @intCast(clusters);
}

inline fn index(mask: u64, key: u64) usize {
    return @intCast(key & mask);
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

test "tt resizes to a power-of-two cluster count" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    try std.testing.expect(tt.entryCount() != 0);
    try std.testing.expect((tt.entries.len & (tt.entries.len - 1)) == 0);
}

test "tt keeps colliding keys in the same cluster" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const key_a: u64 = 1;
    const key_b = key_a + @as(u64, @intCast(tt.entries.len));
    tt.store(key_a, 4, 11, .exact, null);
    tt.store(key_b, 5, 13, .exact, null);

    try std.testing.expectEqual(@as(i32, 11), tt.lookup(key_a).?.score);
    try std.testing.expectEqual(@as(i32, 13), tt.lookup(key_b).?.score);
}

test "tt generation ages replacement candidates" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    const key_a: u64 = 1;
    const key_b = key_a + @as(u64, @intCast(tt.entries.len));
    const key_c = key_a + 2 * @as(u64, @intCast(tt.entries.len));
    tt.store(key_a, 10, 11, .exact, null);
    tt.store(key_b, 9, 13, .exact, null);

    tt.newSearch();
    tt.store(key_a, 5, 17, .lower, null);
    try std.testing.expectEqual(@as(i16, 5), tt.lookup(key_a).?.depth);
    try std.testing.expectEqual(@as(i32, 17), tt.lookup(key_a).?.score);

    tt.store(key_c, 1, 19, .exact, null);
    try std.testing.expectEqual(@as(i32, 19), tt.lookup(key_c).?.score);
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
}

test "tt hashfull reports occupancy in permille" {
    var tt = try TranspositionTable.init(std.testing.allocator, 1);
    defer tt.deinit();

    try std.testing.expectEqual(@as(u16, 0), tt.hashfullPermille());

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        tt.store(i, 1, 0, .exact, null);
    }

    try std.testing.expect(tt.hashfullPermille() > 0);
}

test "TT lookup exposes only an owned entry snapshot" {
    try std.testing.expect(!@hasDecl(TranspositionTable, "lookupPtr"));
    try std.testing.expect(@typeInfo(@TypeOf(TranspositionTable.lookup)).@"fn".return_type.? == ?Entry);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Entry));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Cluster));
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const mv = move_mod.Move.init(.e2, .e4, .double_push);
    _ = table.storeWithOutcome(1234, 5, 17, .exact, mv, -23, true);
    const saved = table.lookup(1234).?;
    const expected = Entry{ .key = 1234, .move_bits = @bitCast(mv), .depth = 5, .score = 17, .static_eval = -23, .was_pv = true };
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
