//! Storage backends of the own Syzygy prober (docs/SYZYGY_FORMAT.md §12). The
//! prober is instantiated per backend at comptime; every backend has the shape
//!
//!     init(gpa, files, options) !Backend
//!     deinit(*Backend, gpa) void
//!     view(*const Backend, file, offset, len, scratch) ProbeError![]const u8
//!
//! `view` returns a slice into a mapping or into `scratch`, filled by a
//! positioned read and zero-padded past the end of the file. Per-file state is
//! published once with atomics; nothing is unmapped while a snapshot lives, so
//! no reader can ever see an unmap. Address space comes back when the snapshot
//! is destroyed by its registry's owner thread, after its last lease.
//!
//! Mapping works on POSIX (mmap) and Windows (a read-only file mapping view).
//! A file that cannot be mapped is never lost and never fails silently: it is
//! read with positioned reads instead, and counted in `Stats`.
const std = @import("std");
const builtin = @import("builtin");
const ProbeError = @import("types.zig").ProbeError;

pub const Mode = enum { mmap_all, mmap_budget, pread };

pub const FileSet = struct {
    paths: []const [:0]const u8,
    sizes: []const u64,
};

pub const Options = struct {
    /// MmapBudget: bytes of table files that may be mapped. Null: `defaultBudget()`.
    budget: ?u64 = null,
};

pub const Stats = struct {
    mapped_files: u32 = 0,
    mapped_bytes: u64 = 0,
    /// Files read with positioned reads (Pread, or a mapping mode's fallback).
    pread_files: u32 = 0,
    /// Mapping attempts that failed and fell back to positioned reads.
    map_failures: u32 = 0,
};

const is_windows = builtin.os.tag == .windows;
const has_rlimit = !is_windows and builtin.os.tag != .wasi;
const can_map = builtin.os.tag != .wasi;

/// A budget that maps every file.
pub const unlimited: u64 = std.math.maxInt(u64);

/// Half of a finite RLIMIT_AS, so tables never take the address space the
/// engine's own allocations need. Without such a limit (and on Windows, which
/// has none) the budget is unlimited: every file is mapped, and only a file
/// whose mapping fails is read with positioned reads.
pub fn defaultBudget() u64 {
    if (comptime !has_rlimit) return unlimited;
    const limit = std.posix.getrlimit(.AS) catch return unlimited;
    if (limit.cur == std.posix.RLIM.INFINITY) return unlimited;
    return limit.cur / 2;
}

/// Let every table file be held open at once. Called when a snapshot is built,
/// never on the probe path. Best effort: failure leaves the limit unchanged and
/// a later open failure is a probe error, never a draw.
fn ensureFileLimit(count: usize) void {
    if (comptime !has_rlimit) return;
    const want: u64 = count + 256;
    const limit = std.posix.getrlimit(.NOFILE) catch return;
    if (limit.cur >= want or limit.cur == std.posix.RLIM.INFINITY) return;
    std.posix.setrlimit(.NOFILE, .{ .cur = @min(want, limit.max), .max = limit.max }) catch {};
}

// ---------------------------------------------------------------------------
// Lazily opened handles

const Handle = std.fs.File.Handle;

fn encodeHandle(h: Handle) usize {
    return if (builtin.os.tag == .windows) @intFromPtr(h) else @as(usize, @intCast(h)) + 1;
}
fn decodeHandle(v: usize) Handle {
    return if (builtin.os.tag == .windows) @ptrFromInt(v) else @intCast(v - 1);
}

const Handles = struct {
    /// 0: not opened yet; otherwise an encoded handle, published once.
    slots: []std.atomic.Value(usize),

    fn init(gpa: std.mem.Allocator, count: usize) !Handles {
        const slots = try gpa.alloc(std.atomic.Value(usize), count);
        for (slots) |*s| s.* = .init(0);
        return .{ .slots = slots };
    }
    fn deinit(self: *Handles, gpa: std.mem.Allocator) void {
        for (self.slots) |*s| {
            const v = s.load(.acquire);
            if (v != 0) (std.fs.File{ .handle = decodeHandle(v) }).close();
        }
        gpa.free(self.slots);
    }
    fn get(self: *const Handles, files: FileSet, file: u32) ProbeError!std.fs.File {
        const v = self.slots[file].load(.acquire);
        if (v != 0) return .{ .handle = decodeHandle(v) };
        const opened = std.fs.cwd().openFileZ(files.paths[file], .{}) catch return error.Io;
        if (self.slots[file].cmpxchgStrong(0, encodeHandle(opened.handle), .acq_rel, .acquire)) |winner| {
            opened.close();
            return .{ .handle = decodeHandle(winner) };
        }
        return opened;
    }
};

/// Fill `out` from `offset`; bytes past the end of the file read as zero.
fn readAt(file: std.fs.File, size: u64, offset: u64, out: []u8) ProbeError!void {
    const avail: usize = if (offset >= size) 0 else @intCast(@min(out.len, size - offset));
    var done: usize = 0;
    while (done < avail) {
        const n = file.pread(out[done..avail], offset + done) catch return error.Io;
        if (n == 0) return error.Io;
        done += n;
    }
    @memset(out[avail..], 0);
}

/// Address of a read-only mapping of the whole file, or null when it cannot be
/// mapped. No handle outlives the call: the mapping keeps the file open until
/// it is unmapped.
fn mapWhole(path: [:0]const u8, size: u64) ?usize {
    if (comptime !can_map) return null;
    const len = std.math.cast(usize, size) orelse return null;
    if (len == 0) return null;
    if (comptime is_windows) return mapWindows(path, size);
    const file = std.fs.cwd().openFileZ(path, .{}) catch return null;
    defer file.close();
    const mem = std.posix.mmap(null, len, std.posix.PROT.READ, .{ .TYPE = .SHARED }, file.handle, 0) catch return null;
    std.posix.madvise(mem.ptr, mem.len, std.posix.MADV.RANDOM) catch {};
    return @intFromPtr(mem.ptr);
}

const win32 = struct {
    const w = std.os.windows;
    extern "kernel32" fn CreateFileMappingW(file: w.HANDLE, attributes: ?*w.SECURITY_ATTRIBUTES, protect: w.DWORD, size_high: w.DWORD, size_low: w.DWORD, name: ?w.LPCWSTR) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn MapViewOfFile(mapping: w.HANDLE, access: w.DWORD, offset_high: w.DWORD, offset_low: w.DWORD, bytes: w.SIZE_T) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) w.BOOL;
    const FILE_MAP_READ: w.DWORD = 0x0004;
};

/// The file opened read-only and shared for reading (a GUI or another engine
/// may open the same tables), a read-only mapping of exactly `size` bytes
/// (64-bit, split into high and low halves) and one view of all of it. A
/// relative path is resolved against the working directory, as the directory
/// scan and the positioned reads (std.fs.cwd()) resolve it.
fn mapWindows(path: [:0]const u8, size: u64) ?usize {
    const w = std.os.windows;
    const cwd = std.fs.cwd().fd;
    const path_w = w.sliceToPrefixedFileW(cwd, path) catch return null;
    const file = w.OpenFile(path_w.span(), .{
        .dir = cwd,
        .access_mask = w.SYNCHRONIZE | w.GENERIC_READ,
        .share_access = w.FILE_SHARE_READ,
        .creation = w.FILE_OPEN,
    }) catch return null;
    defer w.CloseHandle(file);
    const mapping = win32.CreateFileMappingW(file, null, w.PAGE_READONLY, @truncate(size >> 32), @truncate(size), null) orelse return null;
    defer w.CloseHandle(mapping);
    const view = win32.MapViewOfFile(mapping, win32.FILE_MAP_READ, 0, 0, 0) orelse return null;
    return @intFromPtr(view);
}

fn unmap(base: usize, size: u64) void {
    if (comptime !can_map) return;
    if (comptime is_windows) {
        _ = win32.UnmapViewOfFile(@ptrFromInt(base));
        return;
    }
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(base);
    std.posix.munmap(ptr[0..@intCast(size)]);
}

inline fn mappedSlice(base: usize, size: u64, offset: u64, len: usize) ProbeError![]const u8 {
    if (offset > size or len > size - offset) return error.CorruptTable;
    const ptr: [*]const u8 = @ptrFromInt(base);
    return ptr[@intCast(offset)..][0..len];
}

// ---------------------------------------------------------------------------
// Backends

/// Positioned reads on lazily opened, cached handles. No shared cache in v1;
/// the OS page cache does the caching.
pub const Pread = struct {
    files: FileSet,
    handles: Handles,

    pub fn init(gpa: std.mem.Allocator, files: FileSet, _: Options) !Pread {
        ensureFileLimit(files.paths.len);
        return .{ .files = files, .handles = try Handles.init(gpa, files.paths.len) };
    }
    pub fn deinit(self: *Pread, gpa: std.mem.Allocator) void {
        self.handles.deinit(gpa);
    }
    pub fn view(self: *const Pread, file: u32, offset: u64, len: usize, scratch: []u8) ProbeError![]const u8 {
        std.debug.assert(len <= scratch.len);
        const handle = try self.handles.get(self.files, file);
        try readAt(handle, self.files.sizes[file], offset, scratch[0..len]);
        return scratch[0..len];
    }
    pub fn stats(self: *const Pread) Stats {
        var s = Stats{};
        for (self.handles.slots) |*slot| s.pread_files += @intFromBool(slot.load(.acquire) != 0);
        return s;
    }
};

/// Map every file whole on first touch and keep it until the snapshot dies.
pub const MmapAll = Mapped(false);

/// Map files whole while the mapped total stays within the budget
/// (`defaultBudget()` unless given); a file that does not fit is read with
/// positioned reads instead. No table is ever lost to the budget.
pub const MmapBudget = Mapped(true);

/// Both mapping modes. A file whose mapping fails (for example under
/// RLIMIT_AS) falls back to positioned reads for the snapshot's lifetime and is
/// counted in `map_failures` and `pread_files`.
fn Mapped(comptime bounded: bool) type {
    return struct {
        const Self = @This();
        const use_pread: usize = 1; // never a mapping address

        files: FileSet,
        /// 0: untouched; `use_pread`; otherwise the mapping's base address, published once.
        maps: []std.atomic.Value(usize),
        budget: u64,
        counters: *Counters,
        fallback: Pread,

        const Counters = struct {
            used: std.atomic.Value(u64) = .init(0),
            failures: std.atomic.Value(u32) = .init(0),
        };

        pub fn init(gpa: std.mem.Allocator, files: FileSet, options: Options) !Self {
            const maps = try gpa.alloc(std.atomic.Value(usize), files.paths.len);
            errdefer gpa.free(maps);
            for (maps) |*m| m.* = .init(0);
            const counters = try gpa.create(Counters);
            errdefer gpa.destroy(counters);
            counters.* = .{};
            const fallback = try Pread.init(gpa, files, options);
            return .{
                .files = files,
                .maps = maps,
                .budget = if (bounded) options.budget orelse defaultBudget() else unlimited,
                .counters = counters,
                .fallback = fallback,
            };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.maps, 0..) |*m, i| {
                const base = m.load(.acquire);
                if (base > use_pread) unmap(base, self.files.sizes[i]);
            }
            gpa.free(self.maps);
            gpa.destroy(self.counters);
            self.fallback.deinit(gpa);
        }
        pub fn view(self: *const Self, file: u32, offset: u64, len: usize, scratch: []u8) ProbeError![]const u8 {
            var base = self.maps[file].load(.acquire);
            if (base == 0) base = self.touch(file);
            if (base == use_pread) return self.fallback.view(file, offset, len, scratch);
            return mappedSlice(base, self.files.sizes[file], offset, len);
        }
        /// Map every untouched file now, smallest first, as the budget allows:
        /// under a finite budget the many small tables (all of 3-4-5) are
        /// mapped before large 6-man files. File indices do not change. The
        /// engine calls this once per SyzygyPath change on the UCI thread,
        /// after the previous snapshot was released; O(files²) comparisons
        /// and no allocation.
        pub fn mapAll(self: *const Self) void {
            while (true) {
                var next: ?usize = null;
                for (self.maps, self.files.sizes, 0..) |*m, size, i| {
                    if (m.load(.acquire) != 0) continue;
                    if (next == null or size < self.files.sizes[next.?]) next = i;
                }
                _ = self.touch(@intCast(next orelse return));
            }
        }
        /// Whether `file` is read through a mapping (false: untouched, or on
        /// positioned reads).
        pub fn isMapped(self: *const Self, file: u32) bool {
            return self.maps[file].load(.acquire) > use_pread;
        }
        fn touch(self: *const Self, file: u32) usize {
            const size = self.files.sizes[file];
            var base: usize = use_pread;
            const prior = self.counters.used.fetchAdd(size, .monotonic);
            if (prior +| size <= self.budget) {
                if (mapWhole(self.files.paths[file], size)) |mapped| {
                    base = mapped;
                } else {
                    _ = self.counters.failures.fetchAdd(1, .monotonic);
                }
            }
            if (base == use_pread) _ = self.counters.used.fetchSub(size, .monotonic);
            if (self.maps[file].cmpxchgStrong(0, base, .acq_rel, .acquire)) |winner| {
                if (base != use_pread) {
                    unmap(base, size);
                    _ = self.counters.used.fetchSub(size, .monotonic);
                }
                return winner;
            }
            return base;
        }
        pub fn stats(self: *const Self) Stats {
            var s = Stats{ .map_failures = self.counters.failures.load(.monotonic) };
            for (self.maps, 0..) |*m, i| {
                const base = m.load(.acquire);
                if (base == use_pread) s.pread_files += 1;
                if (base > use_pread) {
                    s.mapped_files += 1;
                    s.mapped_bytes += self.files.sizes[i];
                }
            }
            return s;
        }
    };
}

/// Build-option spelling of a mode: "budget", "mmap" or "pread".
pub fn modeFromName(comptime name: []const u8) Mode {
    if (std.mem.eql(u8, name, "budget")) return .mmap_budget;
    if (std.mem.eql(u8, name, "mmap")) return .mmap_all;
    if (std.mem.eql(u8, name, "pread")) return .pread;
    @compileError("tb-storage must be budget, mmap or pread");
}

pub fn Backend(comptime mode: Mode) type {
    return switch (mode) {
        .mmap_all => MmapAll,
        .mmap_budget => MmapBudget,
        .pread => Pread,
    };
}

test "positioned reads zero-fill past the end of the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.bin", .data = "abcdefgh" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "t.bin");
    defer std.testing.allocator.free(path);
    const pathz = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(pathz);
    const paths = [_][:0]const u8{pathz};
    const sizes = [_]u64{8};
    const files = FileSet{ .paths = &paths, .sizes = &sizes };
    inline for (.{ Pread, MmapAll, MmapBudget }) |B| {
        var io = try B.init(std.testing.allocator, files, .{ .budget = 1 << 20 });
        defer io.deinit(std.testing.allocator);
        var scratch: [16]u8 = undefined;
        try std.testing.expectEqualStrings("cdef", try io.view(0, 2, 4, &scratch));
        if (B == Pread) {
            const tail = try io.view(0, 6, 4, &scratch);
            try std.testing.expectEqualSlices(u8, "gh\x00\x00", tail);
        } else {
            // Both mapping modes really map on every OS we build for.
            const s = io.stats();
            try std.testing.expectEqual(@as(u32, 1), s.mapped_files);
            try std.testing.expectEqual(@as(u32, 0), s.pread_files + s.map_failures);
        }
    }
    // A zero budget sends every file to positioned reads.
    var budget = try MmapBudget.init(std.testing.allocator, files, .{ .budget = 0 });
    defer budget.deinit(std.testing.allocator);
    var scratch: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ab", try budget.view(0, 0, 2, &scratch));
    try std.testing.expectEqual(@as(u32, 1), budget.stats().pread_files);
    try std.testing.expectEqual(@as(u32, 0), budget.stats().mapped_files);
    // mapAll maps up front what a view would map on first touch.
    var eager = try MmapBudget.init(std.testing.allocator, files, .{});
    defer eager.deinit(std.testing.allocator);
    eager.mapAll();
    try std.testing.expectEqual(@as(u32, 1), eager.stats().mapped_files);
    try std.testing.expectEqualStrings("cdef", try eager.view(0, 2, 4, &scratch));
    var none = try MmapBudget.init(std.testing.allocator, files, .{ .budget = 0 });
    defer none.deinit(std.testing.allocator);
    none.mapAll();
    try std.testing.expectEqual(@as(u32, 1), none.stats().pread_files);
}

test "a file that cannot be mapped falls back to counted positioned reads in every mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // An empty file cannot be mapped; its reads come back zero-filled.
    try tmp.dir.writeFile(.{ .sub_path = "empty.bin", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "empty.bin");
    defer std.testing.allocator.free(path);
    const pathz = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(pathz);
    const paths = [_][:0]const u8{pathz};
    const sizes = [_]u64{0};
    const files = FileSet{ .paths = &paths, .sizes = &sizes };
    inline for (.{ MmapAll, MmapBudget }) |B| {
        var io = try B.init(std.testing.allocator, files, .{});
        defer io.deinit(std.testing.allocator);
        var scratch: [4]u8 = undefined;
        try std.testing.expectEqualSlices(u8, "\x00\x00", try io.view(0, 0, 2, &scratch));
        const s = io.stats();
        try std.testing.expectEqual(@as(u32, 1), s.map_failures);
        try std.testing.expectEqual(@as(u32, 1), s.pread_files);
        try std.testing.expectEqual(@as(u32, 0), s.mapped_files);
    }
}

test "the default budget is unlimited without an address-space limit" {
    if (comptime !has_rlimit) return std.testing.expectEqual(unlimited, defaultBudget());
    const limit = try std.posix.getrlimit(.AS);
    const want = if (limit.cur == std.posix.RLIM.INFINITY) unlimited else limit.cur / 2;
    try std.testing.expectEqual(want, defaultBudget());
}

test "mapping modes map files named relative to the working directory" {
    // Review finding 1 (phase 3): on Windows a cwd-relative SyzygyPath loaded,
    // then every mapping failed (ReleaseSafe: a panic). tmpDir lives under the
    // working directory, so its sub-path spells a relative path.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.bin", .data = "abcdefgh" });
    const a = std.testing.allocator;
    const dir = ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str;
    const spellings = [_][]const u8{ "{s}{s}/t.bin", "./{s}{s}/t.bin", "{s}{s}" ++ std.fs.path.sep_str ++ "t.bin", "." ++ std.fs.path.sep_str ++ "{s}{s}" ++ std.fs.path.sep_str ++ "t.bin" };
    inline for (spellings) |spelling| {
        const pathz = try std.fmt.allocPrintSentinel(a, spelling, .{ dir, &tmp.sub_path }, 0);
        defer a.free(pathz);
        const paths = [_][:0]const u8{pathz};
        const sizes = [_]u64{8};
        const files = FileSet{ .paths = &paths, .sizes = &sizes };
        inline for (.{ MmapAll, MmapBudget }) |B| {
            var io = try B.init(a, files, .{});
            defer io.deinit(a);
            var scratch: [8]u8 = undefined;
            try std.testing.expectEqualStrings("cdef", try io.view(0, 2, 4, &scratch));
            const s = io.stats();
            try std.testing.expectEqual(@as(u32, 1), s.mapped_files);
            try std.testing.expectEqual(@as(u32, 0), s.map_failures + s.pread_files);
        }
    }
}

test "mapAll maps the smallest files first under a finite budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    // File order (as the registry sorts names) is not size order.
    const data = [_][]const u8{ "x" ** 30, "x" ** 10, "x" ** 20, "x" ** 5 };
    var names: [data.len][:0]u8 = undefined;
    var sizes: [data.len]u64 = undefined;
    for (data, 0..) |bytes, i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}", .{i});
        try tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
        const full = try tmp.dir.realpathAlloc(a, name);
        defer a.free(full);
        names[i] = try a.dupeZ(u8, full);
        sizes[i] = bytes.len;
    }
    defer for (names) |n| a.free(n);
    var paths: [data.len][:0]const u8 = undefined;
    for (names, 0..) |n, i| paths[i] = n;
    const files = FileSet{ .paths = &paths, .sizes = &sizes };
    // Budget 35: smallest first maps 5 + 10 + 20; the 30-byte file, first in
    // file order, falls back to positioned reads.
    for (0..2) |_| {
        var io = try MmapBudget.init(a, files, .{ .budget = 35 });
        defer io.deinit(a);
        io.mapAll();
        try std.testing.expect(!io.isMapped(0));
        try std.testing.expect(io.isMapped(1) and io.isMapped(2) and io.isMapped(3));
        const s = io.stats();
        try std.testing.expectEqual(@as(u32, 3), s.mapped_files);
        try std.testing.expectEqual(@as(u64, 35), s.mapped_bytes);
        try std.testing.expectEqual(@as(u32, 1), s.pread_files);
        try std.testing.expectEqual(@as(u32, 0), s.map_failures);
        var scratch: [4]u8 = undefined;
        try std.testing.expectEqualStrings("xxxx", try io.view(0, 26, 4, &scratch));
    }
}
