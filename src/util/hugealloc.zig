//! 2MB-huge-page backing for the large random-access hash tables (TT, rfp-hint,
//! continuation history). With 4KB pages a 64MB TT needs 16384 dTLB entries --
//! effectively every probe is a TLB miss even when the line is in L2/L3
//! (profiles flagged ~5% of endgame negamax samples as TLB-walk skid after the
//! paired TT/rfp-hint prefetches). 2MB pages cover the same table with 32
//! entries.
//!
//! Allocation ladder (Linux, size >= 2MB):
//!   1. mmap(MAP_HUGETLB)          -- pre-reserved huge pages (vm.nr_hugepages);
//!                                    usually fails without root/reservation.
//!   2. mmap + madvise(HUGEPAGE)   -- transparent huge pages; engages whenever
//!                                    THP is "always" or "madvise". Region is
//!                                    2MB-aligned (over-map + trim) so khugepaged
//!                                    /fault-in can actually use 2MB pages.
//!   3. fallback allocator         -- non-Linux, small sizes, or mmap failure.
//! Frees mirror the allocation method (sized munmap vs allocator.free).
//!
//! Allocation ladder (Windows, size >= 2MB):
//!   1. VirtualAlloc(MEM_LARGE_PAGES|MEM_RESERVE|MEM_COMMIT) -- real large pages
//!      (size rounded up to GetLargePageMinimum). Requires SeLockMemoryPrivilege
//!      ("Lock pages in memory"); we best-effort enable it once via
//!      OpenProcessToken + AdjustTokenPrivileges. Silently unavailable for
//!      unprivileged users.
//!   2. VirtualAlloc(MEM_RESERVE|MEM_COMMIT)                 -- regular 4KB pages.
//!   3. fallback allocator.
//! Frees mirror the method (VirtualFree MEM_RELEASE vs allocator.free).
//! `winStatusText()` reports which rung engaged for the startup info string.

const std = @import("std");
const builtin = @import("builtin");

pub const HUGE_PAGE_BYTES: usize = 2 * 1024 * 1024;

pub const Method = enum {
    /// mmap(MAP_HUGETLB): explicitly reserved 2MB pages.
    hugetlb,
    /// mmap + madvise(MADV_HUGEPAGE): transparent huge pages.
    thp_madvise,
    /// Windows VirtualAlloc(MEM_LARGE_PAGES): real large pages, memory locked.
    win_large,
    /// Windows VirtualAlloc with regular 4KB pages (privilege/large alloc failed).
    win_virtual,
    /// Plain fallback-allocator memory (small size, or every mapped rung failed).
    heap,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .hugetlb => "hugetlb",
            .thp_madvise => "thp_madvise",
            .win_large => "win_large",
            .win_virtual => "win_virtual",
            .heap => "heap",
        };
    }
};

pub fn Backed(comptime T: type) type {
    return BackedAligned(T, std.mem.Alignment.of(T));
}

/// Alignment-carrying variant for callers that need over-aligned slices (the
/// NNUE weight blocks are []align(64)). Mapped memory is page-aligned (>=4KB),
/// so any alignment <= the page size is satisfied on every rung.
///
/// CAUTION (Zig 0.15.2 codegen bug): a DIRECT scalar element access through an
/// over-aligned slice type (`items[i]` on []align(64) i16) is emitted with the
/// slice's alignment on the load/store instead of the element's true alignment
/// (`&items[i]` is *i16, i.e. align 2 — Sema gets it right, the LLVM lowering
/// of elem_val does not). LLVM may then legally widen e.g. an i16 load to 4
/// bytes, reading past the end of the mapping — a SIGSEGV when items.len bytes
/// is an exact 2MB multiple (no tail slack) and the next page is unmapped.
/// Sub-slicing first (`items[off..][0..k]`) or going through an element
/// pointer (`const p: *T = &items[i]; p.*`) lowers correctly; prefer those for
/// scalar access into over-aligned backed slices.
pub fn BackedAligned(comptime T: type, comptime alignment: std.mem.Alignment) type {
    return struct {
        items: []align(alignment.toByteUnits()) T = &.{},
        method: Method = .heap,
    };
}

/// WSL2's /init runs with prctl(PR_SET_THP_DISABLE) and the flag is INHERITED
/// by every descendant, so madvise(HUGEPAGE) is silently ignored (VmFlags shows
/// `hg`, but /proc/self/status THP_enabled stays 0 and thp_fault_alloc never
/// moves). A process may clear its OWN flag without privileges; do it once
/// before the first huge mapping. With THP policy "madvise" this still only
/// affects regions we explicitly advise.
var clear_thp_disable_once = std.once(clearThpDisable);

fn clearThpDisable() void {
    if (builtin.os.tag != .linux) return;
    _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_THP_DISABLE), 0, 0, 0, 0);
}

// ---- Windows large pages ---------------------------------------------------
// std.os.windows lacks the token-privilege API surface; declare exactly what we
// need. These externs are only *referenced* inside `builtin.os.tag == .windows`
// branches, so non-Windows builds emit no advapi32/kernel32 dependency.

const windows = std.os.windows;

extern "kernel32" fn GetLargePageMinimum() callconv(.winapi) usize;

const LUID = extern struct { LowPart: windows.DWORD, HighPart: windows.LONG };
const LUID_AND_ATTRIBUTES = extern struct { Luid: LUID, Attributes: windows.DWORD };
const TOKEN_PRIVILEGES = extern struct {
    PrivilegeCount: windows.DWORD,
    Privileges: [1]LUID_AND_ATTRIBUTES,
};
const SE_PRIVILEGE_ENABLED: windows.DWORD = 0x0000_0002;
const TOKEN_ADJUST_PRIVILEGES: windows.DWORD = 0x0020;
const TOKEN_QUERY: windows.DWORD = 0x0008;

extern "advapi32" fn OpenProcessToken(
    ProcessHandle: windows.HANDLE,
    DesiredAccess: windows.DWORD,
    TokenHandle: *windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn LookupPrivilegeValueW(
    lpSystemName: ?windows.LPCWSTR,
    lpName: windows.LPCWSTR,
    lpLuid: *LUID,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn AdjustTokenPrivileges(
    TokenHandle: windows.HANDLE,
    DisableAllPrivileges: windows.BOOL,
    NewState: ?*const TOKEN_PRIVILEGES,
    BufferLength: windows.DWORD,
    PreviousState: ?*TOKEN_PRIVILEGES,
    ReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// Outcome of the Windows large-page ladder, for the startup info string.
pub const WinLargePageStatus = enum {
    /// No allocation >= 2MB has gone through the ladder yet.
    untried,
    /// MEM_LARGE_PAGES engaged for at least one table (sticky).
    locked,
    /// SeLockMemoryPrivilege could not be enabled -> regular VirtualAlloc.
    no_privilege,
    /// GetLargePageMinimum() == 0: OS/hardware has no large-page support.
    unsupported,
    /// Privilege held but the large-page allocation itself failed
    /// (physically contiguous memory exhausted / fragmented).
    alloc_failed,
};

var win_status: WinLargePageStatus = .untried;
var win_large_min: usize = 0; // GetLargePageMinimum(); 0 => unsupported
var win_privilege_ok: bool = false;
var win_privilege_once = std.once(enableLockMemoryPrivilege);

pub fn winLargePageStatus() WinLargePageStatus {
    return win_status;
}

/// Human-readable rung report for the startup `info string large_pages: ...`.
pub fn winStatusText() []const u8 {
    return switch (win_status) {
        .untried => "untried (no allocation >= 2MB yet)",
        .locked => "locked",
        .no_privilege => "fallback (SeLockMemoryPrivilege unavailable)",
        .unsupported => "fallback (large pages unsupported on this system)",
        .alloc_failed => "fallback (large-page allocation failed; memory fragmented -- a reboot can help)",
    };
}

/// One-time best-effort enable of SeLockMemoryPrivilege on our own token.
/// AdjustTokenPrivileges returns TRUE even when it assigned NOTHING; the real
/// verdict is GetLastError(): ERROR_SUCCESS vs ERROR_NOT_ALL_ASSIGNED (1300).
/// The privilege must be granted to the user account ("Lock pages in memory")
/// for the enable to stick -- otherwise we silently stay on regular pages.
fn enableLockMemoryPrivilege() void {
    if (builtin.os.tag != .windows) return;
    win_large_min = GetLargePageMinimum();
    if (win_large_min == 0) return;

    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(
        windows.GetCurrentProcess(),
        TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
        &token,
    ) == 0) return;
    defer windows.CloseHandle(token);

    var luid: LUID = undefined;
    const priv_name = std.unicode.utf8ToUtf16LeStringLiteral("SeLockMemoryPrivilege");
    if (LookupPrivilegeValueW(null, priv_name, &luid) == 0) return;

    var tp: TOKEN_PRIVILEGES = .{
        .PrivilegeCount = 1,
        .Privileges = .{.{ .Luid = luid, .Attributes = SE_PRIVILEGE_ENABLED }},
    };
    if (AdjustTokenPrivileges(token, windows.FALSE, &tp, 0, null, null) == 0) return;
    win_privilege_ok = windows.GetLastError() == .SUCCESS;
}

/// VirtualAlloc rung 1: MEM_LARGE_PAGES. Requires size to be a multiple of
/// GetLargePageMinimum() and the enabled SeLockMemoryPrivilege; the returned
/// base is large-page aligned (>= 64KB granularity in any case).
fn winMapLarge(byte_len: usize) ?[]align(std.heap.page_size_min) u8 {
    if (!win_privilege_ok or win_large_min == 0) return null;
    const map_len = std.mem.alignForward(usize, byte_len, win_large_min);
    const ptr = windows.VirtualAlloc(
        null,
        map_len,
        windows.MEM_RESERVE | windows.MEM_COMMIT | windows.MEM_LARGE_PAGES,
        windows.PAGE_READWRITE,
    ) catch return null;
    const base: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(ptr));
    return base[0..map_len];
}

/// VirtualAlloc rung 2: regular pages. Base is 64KB-allocation-granularity
/// aligned, so every alignment guarantee (64B for the NNUE blocks) holds.
fn winMapRegular(byte_len: usize) ?[]align(std.heap.page_size_min) u8 {
    const ptr = windows.VirtualAlloc(
        null,
        byte_len,
        windows.MEM_RESERVE | windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    ) catch return null;
    const base: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(ptr));
    return base[0..byte_len];
}

/// Allocate `n` items of `T`, huge-page backed when possible. NOTE: like the
/// plain allocator path, the returned memory is NOT guaranteed zeroed (mmap
/// memory is, heap memory isn't) -- callers must clear it themselves.
pub fn alloc(comptime T: type, fallback: std.mem.Allocator, n: usize) std.mem.Allocator.Error!Backed(T) {
    return allocAligned(T, std.mem.Alignment.of(T), fallback, n);
}

pub fn free(comptime T: type, fallback: std.mem.Allocator, backed: Backed(T)) void {
    freeAligned(T, std.mem.Alignment.of(T), fallback, backed);
}

pub fn allocAligned(
    comptime T: type,
    comptime alignment: std.mem.Alignment,
    fallback: std.mem.Allocator,
    n: usize,
) std.mem.Allocator.Error!BackedAligned(T, alignment) {
    const byte_len = n * @sizeOf(T);
    const huge_candidate = byte_len >= HUGE_PAGE_BYTES and
        comptime (alignment.toByteUnits() <= std.heap.page_size_min);
    if (builtin.os.tag == .linux and huge_candidate) {
        clear_thp_disable_once.call();
        const map_len = std.mem.alignForward(usize, byte_len, HUGE_PAGE_BYTES);
        if (mapHugetlb(map_len)) |bytes| return .{ .items = itemsFromBytes(T, alignment, bytes, n), .method = .hugetlb };
        if (mapThpAligned(map_len)) |bytes| return .{ .items = itemsFromBytes(T, alignment, bytes, n), .method = .thp_madvise };
    }
    if (builtin.os.tag == .windows and huge_candidate) {
        win_privilege_once.call();
        if (winMapLarge(byte_len)) |bytes| {
            win_status = .locked;
            return .{ .items = itemsFromBytes(T, alignment, bytes, n), .method = .win_large };
        }
        // Record why rung 1 missed (sticky once locked: a later fragmented
        // resize must not erase the "large pages engaged" verdict).
        if (win_status != .locked) {
            win_status = if (win_large_min == 0)
                .unsupported
            else if (!win_privilege_ok)
                .no_privilege
            else
                .alloc_failed;
        }
        if (winMapRegular(byte_len)) |bytes| return .{ .items = itemsFromBytes(T, alignment, bytes, n), .method = .win_virtual };
    }
    return .{ .items = try fallback.alignedAlloc(T, alignment, n), .method = .heap };
}

pub fn freeAligned(
    comptime T: type,
    comptime alignment: std.mem.Alignment,
    fallback: std.mem.Allocator,
    backed: BackedAligned(T, alignment),
) void {
    if (backed.items.len == 0) return;
    switch (backed.method) {
        .heap => fallback.free(backed.items),
        // Mapped methods only ever come out of the Linux mmap ladder in `allocAligned`.
        .hugetlb, .thp_madvise => if (builtin.os.tag == .linux) {
            const byte_len = backed.items.len * @sizeOf(T);
            const map_len = std.mem.alignForward(usize, byte_len, HUGE_PAGE_BYTES);
            const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@ptrCast(backed.items.ptr));
            std.posix.munmap(ptr[0..map_len]);
        } else unreachable,
        // Windows VirtualAlloc rungs: MEM_RELEASE frees the whole reservation
        // from its base and requires dwSize == 0.
        .win_large, .win_virtual => if (builtin.os.tag == .windows) {
            windows.VirtualFree(@ptrCast(backed.items.ptr), 0, windows.MEM_RELEASE);
        } else unreachable,
    }
}

/// The box's THP policy string, e.g. "always [madvise] never". Null off-Linux
/// or when the sysfs file is unreadable.
pub fn thpEnabledSetting(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const file = std.fs.openFileAbsolute("/sys/kernel/mm/transparent_hugepage/enabled", .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \n");
}

fn itemsFromBytes(
    comptime T: type,
    comptime alignment: std.mem.Alignment,
    bytes: []align(std.heap.page_size_min) u8,
    n: usize,
) []align(alignment.toByteUnits()) T {
    const ptr: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0..n];
}

fn mapHugetlb(map_len: usize) ?[]align(std.heap.page_size_min) u8 {
    if (comptime !@hasField(std.posix.MAP, "HUGETLB")) return null;
    var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    flags.HUGETLB = true;
    return std.posix.mmap(
        null,
        map_len,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        flags,
        -1,
        0,
    ) catch null;
}

/// Plain anonymous mapping, trimmed to a 2MB-aligned base so THP can back it
/// with real 2MB pages, then advised MADV_HUGEPAGE.
fn mapThpAligned(map_len: usize) ?[]align(std.heap.page_size_min) u8 {
    const total = map_len + HUGE_PAGE_BYTES;
    const raw = std.posix.mmap(
        null,
        total,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;

    const base = @intFromPtr(raw.ptr);
    const aligned = std.mem.alignForward(usize, base, HUGE_PAGE_BYTES);
    const head_len = aligned - base;
    if (head_len != 0) std.posix.munmap(raw[0..head_len]);
    const tail_len = total - head_len - map_len;
    const body_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(aligned);
    if (tail_len != 0) {
        const tail_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(aligned + map_len);
        std.posix.munmap(tail_ptr[0..tail_len]);
    }

    std.posix.madvise(body_ptr, map_len, std.posix.MADV.HUGEPAGE) catch {};
    return body_ptr[0..map_len];
}

test "small allocations fall back to the heap path" {
    const backed = try alloc(u64, std.testing.allocator, 16);
    defer free(u64, std.testing.allocator, backed);
    try std.testing.expectEqual(@as(usize, 16), backed.items.len);
    try std.testing.expectEqual(Method.heap, backed.method);
}

test "large allocations are usable end-to-end whatever path engages" {
    const n = (4 * HUGE_PAGE_BYTES) / @sizeOf(u64);
    var backed = try alloc(u64, std.testing.allocator, n);
    defer free(u64, std.testing.allocator, backed);
    try std.testing.expectEqual(n, backed.items.len);

    @memset(backed.items, 0);
    backed.items[0] = 0xDEAD;
    backed.items[n - 1] = 0xBEEF;
    try std.testing.expectEqual(@as(u64, 0xDEAD), backed.items[0]);
    try std.testing.expectEqual(@as(u64, 0xBEEF), backed.items[n - 1]);
    try std.testing.expectEqual(@as(u64, 0), backed.items[n / 2]);

    // Whichever mmap rung engaged, its base must be 2MB-aligned (hugetlb by the
    // kernel, thp_madvise by the over-map-and-trim dance).
    if (backed.method != .heap) {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(backed.items.ptr) % HUGE_PAGE_BYTES);
    }
}

test "aligned allocations keep the 64-byte guarantee on every path" {
    // Small (heap rung) and large (mmap rung on Linux) both must satisfy align(64).
    const small = try allocAligned(i16, .@"64", std.testing.allocator, 32);
    defer freeAligned(i16, .@"64", std.testing.allocator, small);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(small.items.ptr) % 64);

    const n = (3 * HUGE_PAGE_BYTES) / @sizeOf(i16);
    const large = try allocAligned(i16, .@"64", std.testing.allocator, n);
    defer freeAligned(i16, .@"64", std.testing.allocator, large);
    try std.testing.expectEqual(n, large.items.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(large.items.ptr) % 64);
    @memset(large.items, 7);
    // Read the last element through a natural-align element pointer: a direct
    // `large.items[n - 1]` load is miscompiled by Zig 0.15.2 (the load carries
    // the slice's align 64 at an offset that is only 2-aligned, so LLVM widens
    // the i16 load to 4 bytes — 2 bytes past this exactly-6MB mapping, SIGSEGV
    // whenever the next page is unmapped). See the CAUTION on BackedAligned.
    const last: *const i16 = &large.items[n - 1];
    try std.testing.expectEqual(@as(i16, 7), last.*);
}

test "windows large-page status is inert off-windows" {
    if (builtin.os.tag != .windows) {
        // The Windows ladder must never engage on other targets, whatever
        // allocations the surrounding tests performed.
        try std.testing.expectEqual(WinLargePageStatus.untried, winLargePageStatus());
    }
    try std.testing.expect(winStatusText().len > 0);
}

test "thp setting is readable on linux" {
    var buf: [128]u8 = undefined;
    const setting = thpEnabledSetting(&buf);
    if (builtin.os.tag == .linux) {
        // May legitimately be null in odd sandboxes; when present it is non-empty.
        if (setting) |s| try std.testing.expect(s.len > 0);
    } else {
        try std.testing.expect(setting == null);
    }
}
