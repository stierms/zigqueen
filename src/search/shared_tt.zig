//! Process-owned shared TT: the serial table's clusters (tt.Cluster), read and
//! written under the sequence lock of probes/tt_snapshot.zig.
//! One control thread owns lifecycle transitions; every view must stop being
//! used before endSearch. A live view permits only atomic snapshot/store access.
const std = @import("std");
const tt = @import("tt.zig");
const moves = @import("../core/move.zig");
const hugealloc = @import("../util/hugealloc.zig");
const protocol = @import("../probes/tt_snapshot.zig");

pub const SharedTable = struct {
    allocator: std.mem.Allocator,
    clusters: []protocol.Cluster = &.{},
    backing: hugealloc.Method = .heap,
    configured_hash_mb: u32 = 0,
    generation: u8 = 0,
    active: bool = false,
    /// Given to the views of the next search; the pool sets it from the
    /// tunables (tuning flavour).
    policy: tt.Policy = .{},

    pub fn init(allocator: std.mem.Allocator, hash_mb: u32) !SharedTable {
        var table = SharedTable{ .allocator = allocator };
        try table.resize(hash_mb);
        return table;
    }

    pub fn deinit(self: *SharedTable) void {
        std.debug.assert(!self.active);
        hugealloc.free(protocol.Cluster, self.allocator, .{ .items = self.clusters, .method = self.backing });
        self.* = .{ .allocator = self.allocator };
    }

    /// These lifecycle functions are control-thread-only, not synchronization
    /// primitives. Refusing an active job catches an accidental early resize.
    pub fn clear(self: *SharedTable) !void {
        if (self.active) return error.TableInUse;
        // A zeroed cluster is empty, with its sequence word even.
        @memset(self.clusters, .{});
        self.generation = 0;
    }

    pub fn resize(self: *SharedTable, hash_mb: u32) !void {
        if (self.active) return error.TableInUse;
        const mb = std.math.clamp(hash_mb, tt.MIN_HASH_MB, tt.MAX_HASH_MB);
        const len = clusterCount(mb);
        if (len == self.clusters.len) {
            try self.clear();
            self.configured_hash_mb = mb;
            return;
        }
        // Prepare before commit. Allocation failure preserves data and metadata.
        const fresh = try hugealloc.alloc(protocol.Cluster, self.allocator, len);
        @memset(fresh.items, .{});
        hugealloc.free(protocol.Cluster, self.allocator, .{ .items = self.clusters, .method = self.backing });
        self.clusters = fresh.items;
        self.backing = fresh.method;
        self.configured_hash_mb = mb;
        self.generation = 0;
    }

    pub fn beginSearch(self: *SharedTable) !View {
        if (self.active) return error.TableInUse;
        if (self.clusters.len == 0) return error.NoTable;
        self.generation +%= 1;
        self.active = true;
        return .{ .clusters = self.clusters, .generation = self.generation, .policy = self.policy };
    }

    /// The caller has joined/drained EVERY borrower before this transition.
    pub fn endSearch(self: *SharedTable) void {
        std.debug.assert(self.active);
        self.active = false;
    }

    pub fn entryCount(self: *const SharedTable) usize {
        return tt.WAYS * self.clusters.len;
    }

    pub fn allocatedBytes(self: *const SharedTable) usize {
        return self.clusters.len * @sizeOf(protocol.Cluster);
    }
};

/// Immutable metadata published with a job. The generation advances once in
/// SharedTable.beginSearch, never in a worker. Payload access uses the reviewed
/// SC protocol even for PV reconstruction and hashfull sampling.
pub const View = struct {
    clusters: []protocol.Cluster,
    generation: u8,
    policy: tt.Policy = .{},

    inline fn activePolicy(self: *const View) tt.Policy {
        if (comptime @import("build_options").tuning) return self.policy;
        return .{};
    }

    pub inline fn prefetch(self: *const View, key: u64) void {
        @prefetch(&self.clusters[tt.clusterIndex(key, self.clusters.len)], .{ .rw = .read, .locality = 3, .cache = .data });
    }

    pub inline fn lookup(self: *const View, key: u64) ?tt.Entry {
        return protocol.lookup(&self.clusters[tt.clusterIndex(key, self.clusters.len)], tt.tagFor(key, self.activePolicy()), self.generation);
    }

    /// The search's own probe (tt.TranspositionTable.probe).
    pub inline fn probe(self: *const View, key: u64) ?tt.Entry {
        const policy = self.activePolicy();
        return protocol.probe(&self.clusters[tt.clusterIndex(key, self.clusters.len)], tt.tagFor(key, policy), self.generation, policy.refresh_on_hit);
    }

    pub fn bestMove(self: *const View, key: u64) ?moves.Move {
        return tt.moveFromEntry(self.lookup(key) orelse return null);
    }

    pub inline fn storeWithOutcome(self: *const View, key: u64, depth: i16, score: i32, bound: tt.Bound, mv: ?moves.Move, static_eval: i16, was_pv: bool) tt.StoreOutcome {
        return self.storeResult(key, depth, score, bound, mv, static_eval, was_pv).outcome;
    }

    /// Keep skip reasons available to cold probes without shared hot counters.
    pub inline fn storeResult(self: *const View, key: u64, depth: i16, score: i32, bound: tt.Bound, mv: ?moves.Move, static_eval: i16, was_pv: bool) protocol.Result {
        return protocol.store(&self.clusters[tt.clusterIndex(key, self.clusters.len)], .{
            .key = key,
            .depth = depth,
            .score = score,
            .bound = bound,
            .mv = mv,
            .static_eval = static_eval,
            .was_pv = was_pv,
            .generation = self.generation,
        }, self.activePolicy());
    }

    pub fn hashfullPermille(self: *const View) u16 {
        const len: usize = @min(self.clusters.len, 1000);
        if (len == 0) return 0;
        var used: usize = 0;
        for (self.clusters[0..len]) |*cluster| used += protocol.occupied(cluster) orelse 0;
        return @intCast(used * 1000 / (len * tt.WAYS));
    }
};

fn clusterCount(hash_mb: u32) usize {
    return tt.clusterCountForHash(hash_mb);
}

test "shared table explicitly initializes empty payload on allocation clear and resize" {
    var table = try SharedTable.init(std.testing.allocator, 1);
    defer table.deinit();
    for (0..3) |pass| {
        var view = try table.beginSearch();
        errdefer if (table.active) table.endSearch();
        try std.testing.expect(view.lookup(0) == null);
        try std.testing.expectEqual(@as(u16, 0), view.hashfullPermille());
        for (view.clusters) |*cluster| {
            const slots = protocol.snapshot(cluster).?;
            for (slots.tags, slots.data) |tag, word| {
                try std.testing.expectEqual(@as(tt.Tag, 0), tag);
                try std.testing.expectEqual(@as(u64, 0), word);
            }
            try std.testing.expectEqual(@as(u32, 0), cluster.sequence);
        }
        try std.testing.expect(view.storeWithOutcome(0, 0, 42, .exact, null, 17, false).stored);
        try std.testing.expectEqual(@as(i32, 42), view.lookup(0).?.score);
        table.endSearch();
        if (pass == 0) try table.clear() else if (pass == 1) try table.resize(2);
    }
}

test "shared table owns generation once and refuses live lifecycle changes" {
    var table = try SharedTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var view = try table.beginSearch();
    errdefer if (table.active) table.endSearch();
    try std.testing.expectEqual(@as(u8, 1), view.generation);
    try std.testing.expectError(error.TableInUse, table.beginSearch());
    try std.testing.expectError(error.TableInUse, table.clear());
    try std.testing.expectError(error.TableInUse, table.resize(2));
    const borrowed = view;
    _ = view.storeWithOutcome(51, 4, 100, .exact, null, 23, true);
    try std.testing.expectEqual(@as(u8, 1), borrowed.lookup(51).?.generation);
    table.endSearch();
    for (0..255) |_| {
        _ = try table.beginSearch();
        table.endSearch();
    }
    try std.testing.expectEqual(@as(u8, 0), table.generation);
}

test "shared table failed allocation preserves the old resource" {
    // <2MB uses the real supplied allocator rather than OS mappings.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var table = SharedTable{ .allocator = failing.allocator() };
    // Begin with an injected small backing so resizing to 1MB must allocate.
    table.clusters = try table.allocator.alloc(protocol.Cluster, 1);
    table.clusters[0] = .{};
    table.configured_hash_mb = 1;
    defer table.deinit();
    var view = try table.beginSearch();
    _ = view.storeWithOutcome(7, 3, 12, .exact, null, 21, false);
    table.endSearch();
    const before = table.clusters.ptr;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, table.resize(1));
    try std.testing.expectEqual(before, table.clusters.ptr);
    try std.testing.expectEqual(@as(u8, 1), table.generation);
    try std.testing.expectEqual(@as(i32, 12), view.lookup(7).?.score);
}

test "shared table reports capacity instead of assuming equal Hash implies equal storage" {
    try std.testing.expectEqual(@as(usize, 12_288), clusterCount(1));
    try std.testing.expectEqual(@as(usize, 1_376_256), clusterCount(100));
    try std.testing.expectEqual(@as(usize, 3_145_728), clusterCount(256));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(protocol.Cluster));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(protocol.Cluster));
}

const Stress = struct {
    view: View,
    id: u64,
    gate: *@import("../util/search_runtime.zig").ResetEvent,
    failed: bool = false,

    fn run(self: *@This()) void {
        self.gate.wait();
        for (0..20000) |iteration| {
            // Each thread's 256 tags, distinct from the other threads', hit
            // the same 16 clusters; the score is the tag, so an entry found
            // under a tag must be the one stored under it.
            const tag: u16 = @intCast((self.id << 8) | (iteration & 255));
            const key = tt.keyFor(iteration & 15, self.view.clusters.len, tag);
            const score: i32 = tag;
            _ = self.view.storeWithOutcome(key, 3, score, .exact, null, @intCast(score + 1), true);
            if (self.view.lookup(key)) |entry| {
                if (entry.score != score or entry.static_eval != score + 1 or entry.depth != 3 or
                    entry.generation != self.view.generation or !entry.was_pv) self.failed = true;
            }
            if (self.view.hashfullPermille() > 1000) self.failed = true;
        }
    }
};

test "shared table views observe only coherent entries under contention" {
    const runtime = @import("../util/search_runtime.zig");
    var table = try SharedTable.init(std.testing.allocator, 1);
    defer table.deinit();
    const view = try table.beginSearch();
    defer table.endSearch();
    var gate = runtime.ResetEvent{};
    var tasks: [4]Stress = undefined;
    var threads: [4]runtime.Thread = undefined;
    var count: usize = 0;
    errdefer {
        gate.set();
        for (threads[0..count]) |thread| thread.join();
    }
    for (&tasks, 0..) |*task, i| {
        task.* = .{ .view = view, .id = i + 1, .gate = &gate };
        threads[i] = try runtime.Thread.spawn(.{}, Stress.run, .{task});
        count += 1;
    }
    gate.set();
    for (threads) |thread| thread.join();
    count = 0;
    for (tasks) |task| try std.testing.expect(!task.failed);
}
