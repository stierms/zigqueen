const std = @import("std");
const hugealloc = @import("../util/hugealloc.zig");

pub const MIN_HINT_MB: u32 = 1;
pub const MAX_HINT_MB: u32 = 1_024;

pub const Entry = struct {
    key: u64 = 0,
    score: i32 = 0,
    depth: i16 = -1,
};

const CLUSTER_SIZE: usize = 2;

pub const Cluster = struct {
    entries: [CLUSTER_SIZE]Entry = [_]Entry{.{}} ** CLUSTER_SIZE,
};

pub const HintTable = struct {
    allocator: std.mem.Allocator,
    configured_hint_mb: u32 = 0,
    entries: []Cluster = &.{},
    /// How `entries` is backed (same dTLB story as the TT — zobrist-indexed
    /// random access over tens of MB). Frees must go through hugealloc with this.
    alloc_method: hugealloc.Method = .heap,
    mask: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, hint_mb: u32) !HintTable {
        var table = HintTable{ .allocator = allocator };
        try table.resize(hint_mb);
        return table;
    }

    pub fn deinit(self: *HintTable) void {
        hugealloc.free(Cluster, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.configured_hint_mb = 0;
        self.entries = &.{};
        self.alloc_method = .heap;
        self.mask = 0;
    }

    pub fn clear(self: *HintTable) void {
        if (self.entries.len != 0) @memset(self.entries, .{});
    }

    pub fn resize(self: *HintTable, hint_mb: u32) !void {
        const clamped_mb = std.math.clamp(hint_mb, MIN_HINT_MB, MAX_HINT_MB);
        const new_len = entryCountForHint(clamped_mb);
        if (self.entries.len == new_len) {
            self.configured_hint_mb = clamped_mb;
            self.clear();
            return;
        }

        hugealloc.free(Cluster, self.allocator, .{ .items = self.entries, .method = self.alloc_method });
        self.entries = &.{};
        const backed = try hugealloc.alloc(Cluster, self.allocator, new_len);
        self.entries = backed.items;
        self.alloc_method = backed.method;
        self.configured_hint_mb = clamped_mb;
        self.mask = new_len - 1;
        self.clear();
    }

    /// Overlap the per-node hint-cluster cache miss with the work before the probe
    /// (same idea as the TT prefetch). The cluster is zobrist-indexed -> a cache miss
    /// per probed node; prefetching it in the parent hides most of that latency.
    pub inline fn prefetch(self: *const HintTable, key: u64) void {
        if (self.entries.len == 0) return;
        @prefetch(&self.entries[index(self.mask, key)], .{ .rw = .read, .locality = 3, .cache = .data });
    }

    pub inline fn lookup(
        self: *const HintTable,
        key: u64,
        required_depth: i16,
    ) ?i32 {
        if (self.entries.len == 0) return null;
        // Reference the cluster (don't copy the whole 32-byte struct to the stack);
        // iterate entries by pointer.
        const cluster = &self.entries[index(self.mask, key)];
        for (&cluster.entries) |*entry| {
            if (entry.depth < 0) continue;
            if (entry.key != key) continue;
            if (entry.depth < required_depth) continue;
            return entry.score;
        }
        return null;
    }

    pub inline fn store(self: *HintTable, key: u64, depth: i16, score: i32) void {
        if (self.entries.len == 0) return;

        const cluster = &self.entries[index(self.mask, key)];
        var replacement: *Entry = &cluster.entries[0];

        for (&cluster.entries) |*entry| {
            if (entry.key == key) {
                if (entry.depth > depth) return;
                replacement = entry;
                break;
            }
            if (entry.depth < 0) {
                replacement = entry;
                break;
            }
            if (entry.depth < replacement.depth) replacement = entry;
        }

        replacement.key = key;
        replacement.score = score;
        replacement.depth = depth;
    }
};

fn entryCountForHint(hint_mb: u32) usize {
    const target_bytes = @as(u64, hint_mb) * 1024 * 1024;
    const max_clusters = @max(@as(u64, 1), target_bytes / @sizeOf(Cluster));

    var clusters: u64 = 1;
    while ((clusters << 1) <= max_clusters) : (clusters <<= 1) {}
    return @intCast(clusters);
}

fn index(mask: u64, key: u64) usize {
    return @intCast(key & mask);
}

test "hint table stores and retrieves entries at sufficient depth" {
    var table = try HintTable.init(std.testing.allocator, MIN_HINT_MB);
    defer table.deinit();

    table.store(0xABCD, 3, 75);
    try std.testing.expectEqual(@as(?i32, 75), table.lookup(0xABCD, 3));
    try std.testing.expectEqual(@as(?i32, 75), table.lookup(0xABCD, 1));
}

test "hint table skips lookups below required depth" {
    var table = try HintTable.init(std.testing.allocator, MIN_HINT_MB);
    defer table.deinit();

    table.store(0x1234, 2, 50);
    try std.testing.expect(table.lookup(0x1234, 3) == null);
    try std.testing.expectEqual(@as(?i32, 50), table.lookup(0x1234, 2));
}

test "hint table prefers the deeper existing entry on conflict" {
    var table = try HintTable.init(std.testing.allocator, MIN_HINT_MB);
    defer table.deinit();

    table.store(0x42, 4, 100);
    table.store(0x42, 2, 10);

    try std.testing.expectEqual(@as(?i32, 100), table.lookup(0x42, 4));
}

test "hint table honours independent cluster entries for colliding keys" {
    var table = try HintTable.init(std.testing.allocator, MIN_HINT_MB);
    defer table.deinit();

    const key_a: u64 = 1;
    const key_b: u64 = key_a + @as(u64, @intCast(table.entries.len));
    table.store(key_a, 3, 33);
    table.store(key_b, 3, 44);

    try std.testing.expectEqual(@as(?i32, 33), table.lookup(key_a, 3));
    try std.testing.expectEqual(@as(?i32, 44), table.lookup(key_b, 3));
}

test "hint table resize clears previous entries" {
    var table = try HintTable.init(std.testing.allocator, MIN_HINT_MB);
    defer table.deinit();

    table.store(0x10, 3, 50);
    try table.resize(2);
    try std.testing.expect(table.lookup(0x10, 3) == null);
}
