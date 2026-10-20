//! Table registry (docs/SYZYGY_FORMAT.md §12): a directory scan builds an
//! immutable Snapshot with every header parsed eagerly; a SyzygyPath change
//! builds a new snapshot and swaps it in. A search pins the snapshot with a
//! lease, so probes need no lock and no allocation. Releasing a lease never
//! frees anything: a replaced snapshot is retired and freed by the registry's
//! owner thread (the UCI thread) once its last lease is gone.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const format = @import("format.zig");
const storage = @import("storage.zig");

const MaterialKey = types.MaterialKey;

pub const path_separator: u8 = if (builtin.os.tag == .windows) ';' else ':';

/// v1 loads tables of at most this many pieces (Q2: 7-man unsupported).
pub const supported_pieces = 6;

pub const TableRef = struct {
    table: *const format.Table,
    /// Index into the snapshot's file set.
    file: u32,
    /// The file frame (§3.4) is the colour mirror of the entry key's orientation.
    frame_mirrored: bool,
};

pub const Entry = struct {
    /// Material in the canonical file-name orientation.
    key: MaterialKey,
    pieces: u8,
    symmetric: bool,
    wdl: ?TableRef = null,
    dtz: ?TableRef = null,
};

const Lookup = struct {
    key: MaterialKey,
    entry: u32,
    mirrored: bool,

    fn lessThan(_: void, a: Lookup, b: Lookup) bool {
        return a.key < b.key;
    }
};

pub const Hit = struct {
    entry: *const Entry,
    /// The position's white material is the entry key's black.
    mirrored: bool,
};

pub const BuildStats = struct {
    wdl_files: u32 = 0,
    dtz_files: u32 = 0,
    /// Files that failed header validation (§4.6) or could not be read.
    rejected: u32 = 0,
    /// Table files with more than `supported_pieces` pieces.
    skipped_large: u32 = 0,
    /// Same file name found again in a later directory (first wins).
    duplicates: u32 = 0,
    header_bytes: u64 = 0,
    nanoseconds: u64 = 0,
};

pub fn Snapshot(comptime Backend: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        entries: []const Entry,
        lookup: []const Lookup,
        files: storage.FileSet,
        io: Backend,
        /// Largest piece count with a WDL file; 0 means no tables.
        max_pieces: u8,
        /// Live leases. A retired snapshot is freed only when this is 0.
        leases: std.atomic.Value(u32) = .init(0),
        /// Next snapshot in the registry's retired list.
        next_retired: ?*Self = null,
        stats: BuildStats,

        pub fn find(self: *const Self, key: MaterialKey) ?Hit {
            var lo: usize = 0;
            var hi: usize = self.lookup.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const k = self.lookup[mid].key;
                if (k == key) return .{ .entry = &self.entries[self.lookup[mid].entry], .mirrored = self.lookup[mid].mirrored };
                if (k < key) lo = mid + 1 else hi = mid;
            }
            return null;
        }

        /// Frees a snapshot nobody else can reach: one built for private use
        /// (tools, tests), or one the registry retired with no lease left.
        pub fn destroy(self: *Self) void {
            std.debug.assert(self.leases.load(.acquire) == 0);
            const gpa = self.gpa;
            self.io.deinit(gpa);
            self.arena.deinit();
            gpa.destroy(self);
        }

        pub fn ioStats(self: *const Self) storage.Stats {
            return self.io.stats();
        }
    };
}

const Candidate = struct {
    path: [:0]const u8,
    name: []const u8,
    material: types.Material,
    metric: types.Metric,
};

/// File names are matched exactly, except on Windows, whose file systems
/// ignore case: there a name is first spelled canonically.
const case_insensitive_names = builtin.os.tag == .windows;

/// The canonical spelling of a table file name in any letter case: piece
/// letters upper case, the side separator `v` and the extension lower case.
/// Null when it does not fit `buf`. Only the spelling changes; parseFileName
/// still decides whether the name is a table.
pub fn canonicalName(name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    const stem_len = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    for (name, 0..) |ch, i| {
        const lower = std.ascii.toLower(ch);
        buf[i] = if (i >= stem_len or lower == 'v') lower else std.ascii.toUpper(ch);
    }
    return buf[0..name.len];
}

fn scanDirectory(arena: std.mem.Allocator, gpa: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList(Candidate), seen: *std.StringHashMap(void), stats: *BuildStats) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    var spelled: [64]u8 = undefined;
    while (it.next() catch return) |item| {
        switch (item.kind) {
            .file, .sym_link, .unknown => {},
            else => continue,
        }
        const canonical = if (case_insensitive_names) canonicalName(item.name, &spelled) orelse continue else item.name;
        const parsed = format.parseFileName(canonical) orelse continue;
        if (parsed.material.pieces() > supported_pieces) {
            stats.skipped_large += 1;
            continue;
        }
        if (seen.contains(canonical)) {
            stats.duplicates += 1;
            continue;
        }
        const name = try arena.dupe(u8, canonical);
        try seen.put(name, {});
        const path = try std.fs.path.joinZ(arena, &.{ dir_path, item.name });
        try out.append(gpa, .{ .path = path, .name = name, .material = parsed.material, .metric = parsed.metric });
    }
}

/// Header of one file, parsed into `arena`. Null when the file is unreadable
/// or fails validation.
fn loadTable(arena: std.mem.Allocator, buffer: *std.ArrayList(u8), gpa: std.mem.Allocator, c: Candidate, stats: *BuildStats) !?struct { table: *const format.Table, size: u64 } {
    const file = std.fs.cwd().openFileZ(c.path, .{}) catch return null;
    defer file.close();
    const size = (file.stat() catch return null).size;
    var want: usize = @intCast(@min(size, 64 * 1024));
    while (true) {
        try buffer.resize(gpa, want);
        const got = file.preadAll(buffer.items, 0) catch return null;
        if (got != want) return null;
        const table = format.parse(arena, buffer.items, size, c.metric, c.material) catch |err| switch (err) {
            error.Truncated => {
                if (want >= size or want >= 64 << 20) return null;
                want = @intCast(@min(size, 2 * @as(u64, want)));
                continue;
            },
            error.CorruptTable => return null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const stored = try arena.create(format.Table);
        stored.* = table;
        stats.header_bytes += table.header_len;
        return .{ .table = stored, .size = size };
    }
}

/// Build a snapshot from a path list (`:`-separated, `;` on Windows). Off the
/// search path. Files that fail validation are rejected one by one and counted;
/// the rest load.
pub fn build(comptime Backend: type, gpa: std.mem.Allocator, path_list: []const u8, options: storage.Options) !*Snapshot(Backend) {
    const Snap = Snapshot(Backend);
    var timer = std.time.Timer.start() catch null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var stats = BuildStats{};

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(gpa);
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var dirs = std.mem.tokenizeScalar(u8, path_list, path_separator);
    while (dirs.next()) |dir| try scanDirectory(arena, gpa, dir, &candidates, &seen, &stats);

    // Deterministic order: by name (so file indices do not depend on readdir).
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var entries: std.ArrayList(Entry) = .empty;
    var by_key = std.AutoHashMap(MaterialKey, u32).init(gpa);
    defer by_key.deinit();
    var paths: std.ArrayList([:0]const u8) = .empty;
    var sizes: std.ArrayList(u64) = .empty;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    for (candidates.items) |c| {
        const loaded = (try loadTable(arena, &buffer, gpa, c, &stats)) orelse {
            stats.rejected += 1;
            continue;
        };
        const key = c.material.key();
        const slot = try by_key.getOrPut(key);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(entries.items.len);
            try entries.append(arena, .{ .key = key, .pieces = c.material.pieces(), .symmetric = c.material.symmetric() });
        }
        const entry = &entries.items[slot.value_ptr.*];
        const ref = TableRef{
            .table = loaded.table,
            .file = @intCast(paths.items.len),
            .frame_mirrored = loaded.table.frame_key != key,
        };
        try paths.append(arena, c.path);
        try sizes.append(arena, loaded.size);
        switch (c.metric) {
            .wdl => {
                entry.wdl = ref;
                stats.wdl_files += 1;
            },
            .dtz => {
                entry.dtz = ref;
                stats.dtz_files += 1;
            },
        }
    }

    var lookup: std.ArrayList(Lookup) = .empty;
    var max_pieces: u8 = 0;
    for (entries.items, 0..) |e, i| {
        try lookup.append(arena, .{ .key = e.key, .entry = @intCast(i), .mirrored = false });
        if (!e.symmetric) try lookup.append(arena, .{ .key = types.mirrorKey(e.key), .entry = @intCast(i), .mirrored = true });
        if (e.wdl != null) max_pieces = @max(max_pieces, e.pieces);
    }
    std.mem.sort(Lookup, lookup.items, {}, Lookup.lessThan);

    const files = storage.FileSet{ .paths = paths.items, .sizes = sizes.items };
    const snap = try gpa.create(Snap);
    errdefer gpa.destroy(snap);
    var io = try Backend.init(gpa, files, options);
    errdefer io.deinit(gpa);
    if (timer) |*t| stats.nanoseconds = t.read();
    snap.* = .{
        .gpa = gpa,
        .arena = arena_state,
        .entries = entries.items,
        .lookup = lookup.items,
        .files = files,
        .io = io,
        .max_pieces = max_pieces,
        .stats = stats,
    };
    return snap;
}

/// Process-level owner of the current snapshot. `acquire` pins a snapshot for
/// a job; `swap` publishes a new one and retires the old one. `swap` and
/// `collect` belong to one owner thread (the UCI thread); only they free
/// snapshots, so a search thread never does. Probes never touch the registry.
pub fn Registry(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Snap = Snapshot(Backend);

        mutex: std.Thread.Mutex = .{},
        current: ?*Snap = null,
        /// Replaced snapshots, freed by `collect` once their last lease is gone.
        retired: ?*Snap = null,
        /// Metadata for the disabled fast path; never a substitute for a lease.
        limit: std.atomic.Value(u32) = .init(0),

        /// Move-only by contract: release once, after every borrowed view returns.
        pub const Lease = struct {
            snap: ?*Snap = null,
            largest: u32 = 0,

            /// Never frees: a retired snapshot waits for the owner's `collect`.
            pub fn release(self: *Lease) void {
                if (self.snap) |s| _ = s.leases.fetchSub(1, .release);
                self.* = .{};
            }
        };

        pub fn acquire(self: *Self) Lease {
            if (self.limit.load(.acquire) == 0) return .{};
            self.mutex.lock();
            defer self.mutex.unlock();
            const snap = self.current orelse return .{};
            if (snap.max_pieces == 0) return .{};
            _ = snap.leases.fetchAdd(1, .monotonic);
            return .{ .snap = snap, .largest = snap.max_pieces };
        }

        /// Owner thread only. Publish `next` (or disable with null), retire the
        /// previous snapshot and free every retired snapshot without a lease.
        pub fn swap(self: *Self, next: ?*Snap) void {
            self.mutex.lock();
            if (self.current) |old| {
                old.next_retired = self.retired;
                self.retired = old;
            }
            self.current = next;
            self.limit.store(if (next) |n| n.max_pieces else 0, .release);
            self.mutex.unlock();
            self.collect();
        }

        /// Owner thread only: free the retired snapshots whose last lease is
        /// gone. A retired snapshot can gain no new lease, so 0 is final.
        pub fn collect(self: *Self) void {
            var free: ?*Snap = null;
            self.mutex.lock();
            var link = &self.retired;
            while (link.*) |snap| {
                if (snap.leases.load(.acquire) == 0) {
                    link.* = snap.next_retired;
                    snap.next_retired = free;
                    free = snap;
                } else link = &snap.next_retired;
            }
            self.mutex.unlock();
            while (free) |snap| {
                free = snap.next_retired;
                snap.destroy();
            }
        }

        /// Retired snapshots still waiting for a lease to go.
        pub fn retiredCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            var n: usize = 0;
            var it = self.retired;
            while (it) |snap| : (it = snap.next_retired) n += 1;
            return n;
        }

        pub fn pieceLimit(self: *const Self) u32 {
            return self.limit.load(.acquire);
        }
    };
}

test "table names are spelled canonically before parsing" {
    var buf: [32]u8 = undefined;
    for ([_][2][]const u8{
        .{ "KQvK.rtbw", "KQvK.rtbw" },
        .{ "kqvk.RTBW", "KQvK.rtbw" },
        .{ "KQVK.RTBZ", "KQvK.rtbz" },
        .{ "krpVkr.Rtbz", "KRPvKR.rtbz" },
    }) |case| try std.testing.expectEqualStrings(case[1], canonicalName(case[0], &buf).?);
    try std.testing.expect(canonicalName("KQvK.rtbw" ** 4, &buf) == null);
}

/// Storage stand-in for registry tests: records which thread freed it.
const TestIo = struct {
    freed_by: *?std.Thread.Id,

    var last_freed_by: ?std.Thread.Id = null;

    pub fn init(_: std.mem.Allocator, _: storage.FileSet, _: storage.Options) !TestIo {
        return .{ .freed_by = &last_freed_by };
    }
    pub fn deinit(self: *TestIo, _: std.mem.Allocator) void {
        self.freed_by.* = std.Thread.getCurrentId();
    }
    pub fn view(_: *const TestIo, _: u32, _: u64, _: usize, _: []u8) types.ProbeError![]const u8 {
        return error.Io;
    }
    pub fn stats(_: *const TestIo) storage.Stats {
        return .{};
    }
};

test "a lease released on a search thread never frees; the owner's collect does" {
    const Reg = Registry(TestIo);
    const gpa = std.testing.allocator;
    var reg: Reg = .{};
    const first = try build(TestIo, gpa, "", .{});
    first.max_pieces = 3; // a stand-in table set
    reg.swap(first);
    const owner = std.Thread.getCurrentId();

    // A search pins the snapshot, then a SyzygyPath change replaces it.
    var lease = reg.acquire();
    try std.testing.expect(lease.snap == first and lease.largest == 3);
    const second = try build(TestIo, gpa, "", .{});
    second.max_pieces = 4;
    TestIo.last_freed_by = null;
    reg.swap(second);
    try std.testing.expectEqual(@as(u32, 4), reg.pieceLimit());
    try std.testing.expectEqual(@as(usize, 1), reg.retiredCount());
    try std.testing.expectEqual(@as(?std.Thread.Id, null), TestIo.last_freed_by);

    // The last lease goes on another thread: nothing is freed there.
    const Search = struct {
        fn run(l: *Reg.Lease) void {
            l.release();
        }
    };
    const thread = try std.Thread.spawn(.{}, Search.run, .{&lease});
    thread.join();
    try std.testing.expectEqual(@as(?std.Thread.Id, null), TestIo.last_freed_by);
    try std.testing.expectEqual(@as(usize, 1), reg.retiredCount());

    // The owner frees it.
    reg.collect();
    try std.testing.expectEqual(@as(?std.Thread.Id, owner), TestIo.last_freed_by);
    try std.testing.expectEqual(@as(usize, 0), reg.retiredCount());

    // An unleased snapshot is freed by the swap itself; disabling leaves none.
    TestIo.last_freed_by = null;
    reg.swap(null);
    try std.testing.expectEqual(@as(?std.Thread.Id, owner), TestIo.last_freed_by);
    try std.testing.expectEqual(@as(usize, 0), reg.retiredCount());
    try std.testing.expectEqual(@as(u32, 0), reg.pieceLimit());
    var disabled = reg.acquire();
    try std.testing.expect(disabled.snap == null);
    disabled.release();
}
