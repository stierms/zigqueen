//! Read-only byte blobs shared by every process of one user on the machine.
//!
//! Why: zigqueen keeps about 90 MB of load-time-transformed NNUE weights. With
//! one private copy per process, eight engines on one 32 MB L3 stream eight
//! copies from DRAM, and nps under load collapses (perf phase 1,
//! artifacts/research/perf-session-20261015/PHASE1.md). A blob is the one
//! machine-wide copy: the first process that needs a key builds and publishes
//! it, every later process maps the same pages read-only.
//!
//! Contract: the caller supplies the content (`Content.fill`) and the
//! acceptance test (`Content.verify`, run on the mapped read-only bytes before
//! `acquire` returns). A blob is therefore only ever used after the caller has
//! seen that it holds exactly the bytes it wants: a stale, foreign, colliding
//! or corrupt blob can cost sharing, never correctness. Every failure is an
//! error; callers keep their private copy and report why.
//!
//! Linux: one sealed memfd per key. The registry is a per-user directory
//! (`/tmp/<namespace>-<euid>`, mode 0700, owner checked, no symlinks) holding
//!   - `registry.lock`: flock(LOCK_EX) rendezvous for lookup and publication;
//!     never unlinked, so it can never split into two locks;
//!   - one holder record per mapping process, `w-<key>-<len>-<pid>-<fd>`,
//!     flock(LOCK_EX)-held by its owner for as long as it maps the blob.
//! A newcomer under the rendezvous lock drops every record whose lock it can
//! take (its holder died), then opens a live holder's memfd through
//! `/proc/<pid>/fd/<fd>`, checks size, seals and header, maps it read-only and
//! runs `verify`. With no usable holder it creates the memfd, fills it through
//! a temporary writable mapping, seals it (SHRINK|GROW|FUTURE_WRITE|SEAL, so
//! nobody can resize or write it again) and maps it read-only like everyone
//! else. The rendezvous wait is bounded (LOCK_WAIT_MS): a wedged or stopped
//! lock holder costs sharing, never a hung engine start. The
//! kernel frees the memfd when its last mapping and descriptor go away, so a
//! crash never leaks the blob; only a few-byte stale record remains until the
//! next lookup removes it. Mappings are 2 MB aligned; MADV_HUGEPAGE plus
//! MADV_COLLAPSE (kernel >= 6.1) put the shmem pages on 2 MB pages even with
//! `shmem_enabled=never`, and older kernels keep 4 KB pages.
//!
//! Windows: one named section `Local\<namespace>-w-<key>-<len>` (pagefile
//! backed, SEC_COMMIT) whose creation is serialized by the named mutex of the
//! same name plus `-lock`. SEC_LARGE_PAGES and FILE_MAP_LARGE_PAGES are used
//! only when SeLockMemoryPrivilege is held (the same rung as hugealloc's
//! large pages), otherwise 4 KB pages. Views are read-only except the
//! creator's fill view, which is unmapped before the mutex is released. The
//! section dies with its last handle, so nothing outlives the last process.
//!
//! Neither path runs during search: acquire/release are load-time only.

const std = @import("std");
const builtin = @import("builtin");
const hugealloc = @import("hugealloc.zig");

pub const HUGE_PAGE_BYTES: usize = hugealloc.HUGE_PAGE_BYTES;
/// The blob header occupies the first page of the mapping; the payload starts
/// right after it (page aligned, so every payload offset keeps its alignment
/// up to 4096).
pub const HEADER_BYTES: usize = 4096;
/// Blob header layout version. Bump when `Header` changes meaning.
pub const FORMAT_VERSION: u32 = 1;
const MAGIC = "ZQBLOB01".*;
const READY: u32 = 0x5245_4459; // "REDY"

pub const Error = error{
    /// Not Linux or Windows.
    Unsupported,
    /// The registry directory could not be created or opened.
    RegistryUnavailable,
    /// The registry directory is not a plain 0700 directory owned by us.
    RegistryUnsafe,
    /// The rendezvous lock could not be taken (or timed out on Windows).
    LockFailed,
    /// memfd_create / ftruncate / CreateFileMapping failed.
    CreateFailed,
    /// mmap / MapViewOfFile failed.
    MapFailed,
    /// The memfd could not be sealed against writes.
    SealFailed,
    /// The holder record could not be created or locked.
    RegisterFailed,
    /// An existing section had a wrong or incomplete header (Windows; Linux
    /// skips such holders and creates its own blob instead).
    HeaderMismatch,
    /// The mapped bytes failed the caller's verification.
    VerifyFailed,
    /// Payload too large or namespace too long.
    InvalidRequest,
};

/// How the payload is produced and checked. `fill` writes exactly the payload
/// (the buffer arrives zeroed); `verify` must return true only when the mapped
/// read-only payload is byte-for-byte what the caller would have used.
pub const Content = struct {
    ctx: *const anyopaque,
    fill: *const fn (ctx: *const anyopaque, dst: []u8) void,
    verify: *const fn (ctx: *const anyopaque, src: []const u8) bool,
};

pub const Config = struct {
    /// Names the registry (Linux: `/tmp/<namespace>-<euid>`; Windows: the
    /// `Local\<namespace>-w-...` object names). Tests use their own.
    namespace: []const u8 = "zigqueen",
    /// Windows: create large-page sections when the privilege allows. Tests
    /// turn it off to exercise the 4 KB section path on a privileged box.
    allow_large_pages: bool = true,
};

pub const Origin = enum { created, attached };

/// Page size actually backing the blob in this process, for the info string.
pub const PageReport = struct {
    /// Bytes of the mapping on 2 MB / large pages, when known.
    huge_bytes: usize = 0,
    /// False when the page size could not be determined.
    known: bool = false,
    /// Windows: the memory manager reports the view's pages as large pages.
    large_view: bool = false,
};

pub const Blob = struct {
    /// The verified read-only payload.
    payload: []const u8,
    /// Whole mapping (header + payload + tail slack), HUGE_PAGE_BYTES multiple.
    map_len: usize,
    key: u64,
    origin: Origin,
    pages: PageReport,
    os: OsState,
};

const OsState = switch (builtin.os.tag) {
    .linux => struct {
        map_ptr: [*]align(std.heap.page_size_min) const u8,
        memfd: i32,
        dir_fd: i32,
        record_fd: i32,
        record_name: [RECORD_NAME_MAX]u8,
        record_len: usize,
    },
    .windows => struct {
        view: *anyopaque,
        section: std.os.windows.HANDLE,
    },
    else => struct {},
};

/// First page of every blob.
const Header = extern struct {
    magic: [8]u8,
    version: u32,
    header_bytes: u32,
    key: u64,
    payload_bytes: u64,
    map_bytes: u64,
    /// READY once the payload is complete (written last by the creator).
    ready: u32,
    _pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Header) <= HEADER_BYTES);
}

/// Total mapping length for a payload: header page + payload, rounded up to
/// 2 MB with at least one page of tail slack (an over-wide vector or
/// mis-aligned scalar load past the last array stays inside the mapping).
pub fn mapLength(payload_len: usize) usize {
    return std.mem.alignForward(usize, HEADER_BYTES + payload_len + 4096, HUGE_PAGE_BYTES);
}

fn headerFor(key: u64, payload_len: usize, map_len: usize) Header {
    return .{
        .magic = MAGIC,
        .version = FORMAT_VERSION,
        .header_bytes = HEADER_BYTES,
        .key = key,
        .payload_bytes = payload_len,
        .map_bytes = map_len,
        .ready = 0,
    };
}

fn headerMatches(map: []const u8, key: u64, payload_len: usize, map_len: usize) bool {
    if (map.len < HEADER_BYTES) return false;
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), map[0..@sizeOf(Header)]);
    var want = headerFor(key, payload_len, map_len);
    want.ready = READY;
    return std.mem.eql(u8, std.mem.asBytes(&h), std.mem.asBytes(&want));
}

fn writeHeader(map: []u8, key: u64, payload_len: usize, map_len: usize, ready: bool) void {
    var h = headerFor(key, payload_len, map_len);
    if (ready) h.ready = READY;
    @memcpy(map[0..@sizeOf(Header)], std.mem.asBytes(&h));
}

/// Find or publish the blob for `key` and map it read-only. On success the
/// payload passed `content.verify`. Release with `release`.
pub fn acquire(config: Config, key: u64, payload_len: usize, content: Content) Error!Blob {
    if (config.namespace.len == 0 or config.namespace.len > NAMESPACE_MAX) return error.InvalidRequest;
    for (config.namespace) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidRequest;
    if (payload_len == 0 or payload_len > (1 << 40)) return error.InvalidRequest;
    return switch (builtin.os.tag) {
        .linux => linux_impl.acquire(config, key, payload_len, content),
        .windows => windows_impl.acquire(config, key, payload_len, content),
        else => error.Unsupported,
    };
}

pub fn release(blob: *Blob) void {
    switch (builtin.os.tag) {
        .linux => linux_impl.release(blob),
        .windows => windows_impl.release(blob),
        else => {},
    }
    blob.* = undefined;
}

const NAMESPACE_MAX: usize = 48;
/// Longest wait for the rendezvous lock. A holder publishes ~90 MB in about a
/// tenth of a second and an attach takes a few tens of milliseconds, so ten
/// seconds means the holder is stopped or wedged: private weights then.
const LOCK_WAIT_MS: u32 = 10_000;
const RECORD_NAME_MAX: usize = 96;

// ---- Linux -----------------------------------------------------------------

const linux_impl = struct {
    const linux = std.os.linux;
    const F_ADD_SEALS: i32 = 1024 + 9;
    const F_GET_SEALS: i32 = 1024 + 10;
    const SEAL_SEAL: usize = 0x1;
    const SEAL_SHRINK: usize = 0x2;
    const SEAL_GROW: usize = 0x4;
    const SEAL_WRITE: usize = 0x8;
    const SEAL_FUTURE_WRITE: usize = 0x10;
    /// Size can never change (no SIGBUS from a shrink) and no seal can be
    /// added or lifted. The write seal is FUTURE_WRITE (Linux >= 5.1): it
    /// refuses write() and every new writable mapping, but unlike F_SEAL_WRITE
    /// still allows read-only MAP_SHARED mappings before Linux 6.7, which
    /// return EPERM for F_SEAL_WRITE memfds. The creator seals only after
    /// unmapping its own fill mapping, and is the only process that ever holds
    /// a writable descriptor.
    const REQUIRED_SEALS: usize = SEAL_SEAL | SEAL_SHRINK | SEAL_GROW;
    const WRITE_SEALS: usize = SEAL_WRITE | SEAL_FUTURE_WRITE;
    const MADV_COLLAPSE: u32 = 25;
    const LOCK_SH: i32 = 1;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    const MAX_RECORDS: usize = 256;
    /// Distinct holder inodes tried before giving up on attaching.
    const MAX_ATTEMPTS: usize = 4;

    fn errno(rc: usize) linux.E {
        return linux.E.init(rc);
    }

    fn ok(rc: usize) bool {
        return errno(rc) == .SUCCESS;
    }

    fn closeFd(fd: i32) void {
        _ = linux.close(fd);
    }

    fn flockRetry(fd: i32, op: i32) bool {
        while (true) {
            const rc = linux.flock(fd, op);
            switch (errno(rc)) {
                .SUCCESS => return true,
                .INTR => continue,
                else => return false,
            }
        }
    }

    /// flock(LOCK_EX) with a deadline: non-blocking attempts, 1 ms apart.
    fn lockWithin(fd: i32, wait_ms: u32) bool {
        var timer = std.time.Timer.start() catch return flockRetry(fd, LOCK_EX);
        while (true) {
            const rc = linux.flock(fd, LOCK_EX | LOCK_NB);
            switch (errno(rc)) {
                .SUCCESS => return true,
                .INTR => continue,
                .AGAIN => {},
                else => return false,
            }
            if (timer.read() >= @as(u64, wait_ms) * std.time.ns_per_ms) return false;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }

    /// `/tmp/<namespace>-<euid>`: created 0700; an existing entry must be a
    /// real directory (no symlink), owned by us, without group/other access.
    fn openRegistry(config: Config) Error!i32 {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/{s}-{d}", .{ config.namespace, linux.geteuid() }) catch return error.InvalidRequest;
        const mk = linux.mkdirat(linux.AT.FDCWD, path, 0o700);
        if (!ok(mk) and errno(mk) != .EXIST) return error.RegistryUnavailable;
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (!ok(rc)) return if (errno(rc) == .LOOP or errno(rc) == .NOTDIR) error.RegistryUnsafe else error.RegistryUnavailable;
        const fd: i32 = @intCast(rc);
        var st: linux.Stat = undefined;
        if (!ok(linux.fstat(fd, &st))) {
            closeFd(fd);
            return error.RegistryUnavailable;
        }
        if (!linux.S.ISDIR(st.mode) or st.uid != linux.geteuid() or (st.mode & 0o077) != 0) {
            closeFd(fd);
            return error.RegistryUnsafe;
        }
        return fd;
    }

    const Record = struct { key: u64, map_len: usize, pid: i32, fd: i32 };

    fn formatRecord(buf: *[RECORD_NAME_MAX]u8, r: Record) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "w-{x:0>16}-{x}-{d}-{d}", .{ r.key, r.map_len, r.pid, r.fd }) catch unreachable;
    }

    fn parseRecord(name: []const u8) ?Record {
        if (!std.mem.startsWith(u8, name, "w-")) return null;
        var it = std.mem.splitScalar(u8, name[2..], '-');
        const k = it.next() orelse return null;
        const l = it.next() orelse return null;
        const p = it.next() orelse return null;
        const f = it.next() orelse return null;
        if (it.next() != null or k.len != 16) return null;
        return .{
            .key = std.fmt.parseInt(u64, k, 16) catch return null,
            .map_len = std.fmt.parseInt(usize, l, 16) catch return null,
            .pid = std.fmt.parseInt(i32, p, 10) catch return null,
            .fd = std.fmt.parseInt(i32, f, 10) catch return null,
        };
    }

    /// True when the record's owner still holds its lock. A record whose lock
    /// we can take belongs to a dead (or exited) process and is removed.
    fn recordLive(dir_fd: i32, name: [:0]const u8) bool {
        const rc = linux.openat(dir_fd, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (!ok(rc)) return false;
        const fd: i32 = @intCast(rc);
        defer closeFd(fd);
        while (true) {
            const lr = linux.flock(fd, LOCK_SH | LOCK_NB);
            switch (errno(lr)) {
                .SUCCESS => {
                    _ = linux.unlinkat(dir_fd, name, 0);
                    return false;
                },
                .INTR => continue,
                // AGAIN == WOULDBLOCK: the owner holds LOCK_EX.
                .AGAIN => return true,
                else => return false,
            }
        }
    }

    /// Sweep stale records of every key; collect live holders of ours.
    fn collectHolders(dir_fd: i32, key: u64, map_len: usize, out: *[MAX_RECORDS]Record) usize {
        var names: [MAX_RECORDS]Record = undefined;
        var count: usize = 0;
        var dir = std.fs.Dir{ .fd = dir_fd };
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (count == names.len) break;
            const r = parseRecord(entry.name) orelse continue;
            names[count] = r;
            count += 1;
        }
        var live: usize = 0;
        for (names[0..count]) |r| {
            var buf: [RECORD_NAME_MAX]u8 = undefined;
            if (!recordLive(dir_fd, formatRecord(&buf, r))) continue;
            if (r.key == key and r.map_len == map_len) {
                out[live] = r;
                live += 1;
            }
        }
        return live;
    }

    /// Reserve len + 2 MB of address space, then map the file at the first
    /// 2 MB boundary inside it, so a 2 MB page can back every 2 MB of the blob.
    fn mapAligned(fd: i32, len: usize, prot: usize) ?[*]align(std.heap.page_size_min) u8 {
        const total = len + HUGE_PAGE_BYTES;
        const rrc = linux.mmap(null, total, linux.PROT.NONE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (!ok(rrc)) return null;
        const base: usize = rrc;
        const aligned = std.mem.alignForward(usize, base, HUGE_PAGE_BYTES);
        const mrc = linux.mmap(@ptrFromInt(aligned), len, prot, .{ .TYPE = .SHARED, .FIXED = true }, fd, 0);
        if (!ok(mrc) or mrc != aligned) {
            _ = linux.munmap(@ptrFromInt(base), total);
            return null;
        }
        if (aligned > base) _ = linux.munmap(@ptrFromInt(base), aligned - base);
        const tail = base + total - (aligned + len);
        if (tail != 0) _ = linux.munmap(@ptrFromInt(aligned + len), tail);
        return @ptrFromInt(aligned);
    }

    /// Ask for 2 MB pages and report what backs the mapping.
    fn hugify(ptr: [*]align(std.heap.page_size_min) u8, len: usize) PageReport {
        hugealloc.ensureThpAllowed();
        _ = linux.madvise(ptr, len, linux.MADV.HUGEPAGE);
        _ = linux.madvise(ptr, len, MADV_COLLAPSE);
        if (pmdMappedBytes(@intFromPtr(ptr))) |bytes| return .{ .huge_bytes = bytes, .known = true };
        return .{};
    }

    /// `ShmemPmdMapped` of the VMA starting at `start`, from /proc/self/smaps.
    fn pmdMappedBytes(start: usize) ?usize {
        const file = std.fs.openFileAbsolute("/proc/self/smaps", .{}) catch return null;
        defer file.close();
        var prefix_buf: [32]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{x}-", .{start}) catch return null;
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);
        var in_vma = false;
        while (true) {
            // takeDelimiter consumes the newline; null at end of file.
            const line = (reader.interface.takeDelimiter('\n') catch return null) orelse return null;
            if (std.mem.startsWith(u8, line, prefix)) {
                in_vma = true;
                continue;
            }
            if (!in_vma) continue;
            // The next VMA starts: our VMA had no ShmemPmdMapped line.
            if (isVmaHeader(line)) return 0;
            if (std.mem.startsWith(u8, line, "ShmemPmdMapped:")) {
                var tokens = std.mem.tokenizeScalar(u8, line["ShmemPmdMapped:".len..], ' ');
                const kb = std.fmt.parseInt(usize, tokens.next() orelse return null, 10) catch return null;
                return kb * 1024;
            }
        }
    }

    /// VMA header lines start with a lowercase-hex start address and '-';
    /// field lines start with a capitalized name ("AnonHugePages:", ...).
    fn isVmaHeader(line: []const u8) bool {
        var i: usize = 0;
        while (i < line.len and (std.ascii.isDigit(line[i]) or (line[i] >= 'a' and line[i] <= 'f'))) i += 1;
        return i > 0 and i < line.len and line[i] == '-';
    }

    const Mapped = struct {
        memfd: i32,
        ptr: [*]align(std.heap.page_size_min) u8,
        pages: PageReport,
    };

    /// Map a sealed blob fd read-only and accept it only if the size, seals,
    /// header and the caller's verification all agree. Takes ownership of
    /// `memfd` (closed on failure).
    fn mapVerified(memfd: i32, key: u64, payload_len: usize, map_len: usize, content: Content) ?Mapped {
        var st: linux.Stat = undefined;
        if (!ok(linux.fstat(memfd, &st)) or !linux.S.ISREG(st.mode) or st.size != @as(i64, @intCast(map_len))) {
            closeFd(memfd);
            return null;
        }
        const seals = linux.fcntl(memfd, F_GET_SEALS, 0);
        if (!ok(seals) or (seals & REQUIRED_SEALS) != REQUIRED_SEALS) {
            closeFd(memfd);
            return null;
        }
        const ptr = mapAligned(memfd, map_len, linux.PROT.READ) orelse {
            closeFd(memfd);
            return null;
        };
        const map = ptr[0..map_len];
        if (headerMatches(map, key, payload_len, map_len)) {
            const pages = hugify(ptr, map_len);
            if (content.verify(content.ctx, map[HEADER_BYTES..][0..payload_len])) {
                return .{ .memfd = memfd, .ptr = ptr, .pages = pages };
            }
        }
        _ = linux.munmap(ptr, map_len);
        closeFd(memfd);
        return null;
    }

    fn openHolder(r: Record) ?i32 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/fd/{d}", .{ r.pid, r.fd }) catch return null;
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (!ok(rc)) return null;
        return @intCast(rc);
    }

    fn createSealed(key: u64, payload_len: usize, map_len: usize, content: Content) Error!i32 {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "zigqueen-w-{x:0>16}", .{key}) catch unreachable;
        const rc = linux.memfd_create(name, linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (!ok(rc)) return error.CreateFailed;
        const fd: i32 = @intCast(rc);
        errdefer closeFd(fd);
        if (!ok(linux.ftruncate(fd, @intCast(map_len)))) return error.CreateFailed;
        const w = mapAligned(fd, map_len, linux.PROT.READ | linux.PROT.WRITE) orelse return error.MapFailed;
        hugealloc.ensureThpAllowed();
        _ = linux.madvise(w, map_len, linux.MADV.HUGEPAGE);
        const map = w[0..map_len];
        writeHeader(map, key, payload_len, map_len, false);
        content.fill(content.ctx, map[HEADER_BYTES..][0..payload_len]);
        writeHeader(map, key, payload_len, map_len, true);
        _ = linux.munmap(w, map_len);
        // No writable mapping remains. Kernels before 5.1 lack FUTURE_WRITE:
        // they keep the size seals only (attachers open the memfd read-only).
        if (!ok(linux.fcntl(fd, F_ADD_SEALS, REQUIRED_SEALS | SEAL_FUTURE_WRITE)) and
            !ok(linux.fcntl(fd, F_ADD_SEALS, REQUIRED_SEALS))) return error.SealFailed;
        return fd;
    }

    fn register(dir_fd: i32, r: Record, blob_os: *OsState) Error!void {
        const name = formatRecord(&blob_os.record_name, r);
        blob_os.record_len = name.len;
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const rc = linux.openat(dir_fd, name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
            if (ok(rc)) {
                const fd: i32 = @intCast(rc);
                if (!flockRetry(fd, LOCK_EX | LOCK_NB)) {
                    closeFd(fd);
                    _ = linux.unlinkat(dir_fd, name, 0);
                    return error.RegisterFailed;
                }
                blob_os.record_fd = fd;
                return;
            }
            if (errno(rc) != .EXIST) return error.RegisterFailed;
            // A leftover of a dead process that had our pid and fd number.
            _ = linux.unlinkat(dir_fd, name, 0);
        }
        return error.RegisterFailed;
    }

    fn acquire(config: Config, key: u64, payload_len: usize, content: Content) Error!Blob {
        const map_len = mapLength(payload_len);
        const dir_fd = try openRegistry(config);
        errdefer closeFd(dir_fd);

        const lrc = linux.openat(dir_fd, "registry.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
        if (!ok(lrc)) return error.LockFailed;
        const lock_fd: i32 = @intCast(lrc);
        // Closing the descriptor drops the flock.
        defer closeFd(lock_fd);
        if (!lockWithin(lock_fd, LOCK_WAIT_MS)) return error.LockFailed;

        var holders: [MAX_RECORDS]Record = undefined;
        const n = collectHolders(dir_fd, key, map_len, &holders);
        var failed_inodes: [MAX_ATTEMPTS]u64 = undefined;
        var failed: usize = 0;
        var mapped: ?Mapped = null;
        var origin: Origin = .attached;
        for (holders[0..n]) |h| {
            if (failed == MAX_ATTEMPTS) break;
            const fd = openHolder(h) orelse continue;
            var st: linux.Stat = undefined;
            if (!ok(linux.fstat(fd, &st))) {
                closeFd(fd);
                continue;
            }
            if (std.mem.indexOfScalar(u64, failed_inodes[0..failed], st.ino) != null) {
                closeFd(fd);
                continue;
            }
            mapped = mapVerified(fd, key, payload_len, map_len, content);
            if (mapped != null) break;
            failed_inodes[failed] = st.ino;
            failed += 1;
        }
        if (mapped == null) {
            const fd = try createSealed(key, payload_len, map_len, content);
            mapped = mapVerified(fd, key, payload_len, map_len, content) orelse return error.VerifyFailed;
            origin = .created;
        }
        const m = mapped.?;
        var blob = Blob{
            .payload = m.ptr[HEADER_BYTES..][0..payload_len],
            .map_len = map_len,
            .key = key,
            .origin = origin,
            .pages = m.pages,
            .os = .{
                .map_ptr = m.ptr,
                .memfd = m.memfd,
                .dir_fd = dir_fd,
                .record_fd = -1,
                .record_name = undefined,
                .record_len = 0,
            },
        };
        register(dir_fd, .{ .key = key, .map_len = map_len, .pid = linux.getpid(), .fd = m.memfd }, &blob.os) catch |err| {
            _ = linux.munmap(m.ptr, map_len);
            closeFd(m.memfd);
            return err;
        };
        return blob;
    }

    fn release(blob: *Blob) void {
        const os = &blob.os;
        // Record first: a newcomer must not pick a holder that is going away.
        // No rendezvous lock is needed: a scanner that races us either sees
        // our lock held (and opens a memfd that is still valid or fails
        // cleanly) or finds the record stale and drops it.
        var name_z: [RECORD_NAME_MAX + 1]u8 = undefined;
        @memcpy(name_z[0..os.record_len], os.record_name[0..os.record_len]);
        name_z[os.record_len] = 0;
        _ = linux.unlinkat(os.dir_fd, name_z[0..os.record_len :0], 0);
        closeFd(os.record_fd);
        _ = linux.munmap(os.map_ptr, blob.map_len);
        closeFd(os.memfd);
        closeFd(os.dir_fd);
    }
};

// ---- Windows ---------------------------------------------------------------

const windows_impl = struct {
    const win = std.os.windows;
    const PAGE_READWRITE: win.DWORD = 0x04;
    const SEC_COMMIT: win.DWORD = 0x0800_0000;
    const SEC_LARGE_PAGES: win.DWORD = 0x8000_0000;
    const FILE_MAP_WRITE: win.DWORD = 0x0002;
    const FILE_MAP_READ: win.DWORD = 0x0004;
    const FILE_MAP_LARGE_PAGES: win.DWORD = 0x2000_0000;
    const WAIT_OBJECT_0: win.DWORD = 0x0000_0000;
    const WAIT_ABANDONED: win.DWORD = 0x0000_0080;

    extern "kernel32" fn CreateFileMappingW(
        hFile: win.HANDLE,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: win.DWORD,
        dwMaximumSizeHigh: win.DWORD,
        dwMaximumSizeLow: win.DWORD,
        lpName: ?win.LPCWSTR,
    ) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: win.HANDLE,
        dwDesiredAccess: win.DWORD,
        dwFileOffsetHigh: win.DWORD,
        dwFileOffsetLow: win.DWORD,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) win.BOOL;
    extern "kernel32" fn CreateMutexW(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: win.BOOL,
        lpName: ?win.LPCWSTR,
    ) callconv(.winapi) ?win.HANDLE;
    extern "kernel32" fn ReleaseMutex(hMutex: win.HANDLE) callconv(.winapi) win.BOOL;
    /// PSAPI_WORKING_SET_EX_INFORMATION: the page's attributes as a bitfield
    /// (bit 0 Valid, bit 15 Shared, bit 23 LargePage).
    const WorkingSetExInfo = extern struct { virtual_address: ?*anyopaque, attributes: usize };
    extern "kernel32" fn K32QueryWorkingSetEx(hProcess: win.HANDLE, pv: *anyopaque, cb: win.DWORD) callconv(.winapi) win.BOOL;

    /// Ask the memory manager what backs the (already touched) first page of
    /// the view, instead of trusting the requested flags.
    fn pageReport(view: [*]const u8) PageReport {
        var info = WorkingSetExInfo{ .virtual_address = @ptrCast(@constCast(view)), .attributes = 0 };
        if (K32QueryWorkingSetEx(win.GetCurrentProcess(), &info, @sizeOf(WorkingSetExInfo)) == 0) return .{};
        const valid = info.attributes & 1 != 0;
        const large = info.attributes & (1 << 23) != 0;
        if (!valid) return .{};
        return .{ .known = true, .large_view = large };
    }

    /// ASCII object name -> NUL-terminated UTF-16.
    fn wideName(buf: []u16, comptime fmt: []const u8, args: anytype) ?[:0]const u16 {
        var ascii: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&ascii, fmt, args) catch return null;
        if (s.len + 1 > buf.len) return null;
        for (s, 0..) |c, i| buf[i] = c;
        buf[s.len] = 0;
        return buf[0..s.len :0];
    }

    fn mapView(section: win.HANDLE, access: win.DWORD, len: usize) ?[*]u8 {
        const p = MapViewOfFile(section, access, 0, 0, len) orelse return null;
        return @ptrCast(p);
    }

    fn acquire(config: Config, key: u64, payload_len: usize, content: Content) Error!Blob {
        const map_len = mapLength(payload_len);
        var section_buf: [128]u16 = undefined;
        var mutex_buf: [128]u16 = undefined;
        const section_name = wideName(&section_buf, "Local\\{s}-w-{x:0>16}-{x}", .{ config.namespace, key, map_len }) orelse return error.InvalidRequest;
        const mutex_name = wideName(&mutex_buf, "Local\\{s}-w-{x:0>16}-{x}-lock", .{ config.namespace, key, map_len }) orelse return error.InvalidRequest;

        const mutex = CreateMutexW(null, win.FALSE, mutex_name.ptr) orelse return error.LockFailed;
        defer win.CloseHandle(mutex);
        const wait = win.kernel32.WaitForSingleObjectEx(mutex, LOCK_WAIT_MS, win.FALSE);
        // WAIT_ABANDONED: the previous owner died holding the lock; we own it
        // now. A section it was filling dies with its handles (nobody else may
        // open it before READY), or fails the header check below.
        if (wait != WAIT_OBJECT_0 and wait != WAIT_ABANDONED) return error.LockFailed;
        defer _ = ReleaseMutex(mutex);

        const large_min = if (config.allow_large_pages) hugealloc.winLargePageMinimum() else 0;
        const want_large = large_min != 0 and map_len % large_min == 0;
        const hi: win.DWORD = @truncate(@as(u64, map_len) >> 32);
        const lo: win.DWORD = @truncate(@as(u64, map_len));
        var large = false;
        var existed = false;
        var section: ?win.HANDLE = null;
        if (want_large) {
            section = CreateFileMappingW(win.INVALID_HANDLE_VALUE, null, PAGE_READWRITE | SEC_COMMIT | SEC_LARGE_PAGES, hi, lo, section_name.ptr);
            if (section != null) {
                existed = win.GetLastError() == .ALREADY_EXISTS;
                large = !existed;
            }
        }
        if (section == null) {
            section = CreateFileMappingW(win.INVALID_HANDLE_VALUE, null, PAGE_READWRITE | SEC_COMMIT, hi, lo, section_name.ptr);
            if (section != null) existed = win.GetLastError() == .ALREADY_EXISTS;
        }
        const handle = section orelse return error.CreateFailed;
        errdefer win.CloseHandle(handle);

        if (!existed) {
            const w = mapView(handle, FILE_MAP_WRITE | @as(win.DWORD, if (large) FILE_MAP_LARGE_PAGES else 0), map_len) orelse return error.MapFailed;
            const map = w[0..map_len];
            writeHeader(map, key, payload_len, map_len, false);
            content.fill(content.ctx, map[HEADER_BYTES..][0..payload_len]);
            writeHeader(map, key, payload_len, map_len, true);
            _ = UnmapViewOfFile(w);
        }
        // Read-only view. A large-page section (ours, or an existing one made
        // by a privileged process of this user) needs FILE_MAP_LARGE_PAGES.
        const view = (if (large or (existed and large_min != 0)) mapView(handle, FILE_MAP_READ | FILE_MAP_LARGE_PAGES, map_len) else null) orelse
            mapView(handle, FILE_MAP_READ, map_len) orelse return error.MapFailed;
        errdefer _ = UnmapViewOfFile(@ptrCast(view));
        const map = view[0..map_len];
        if (!headerMatches(map, key, payload_len, map_len)) return error.HeaderMismatch;
        if (!content.verify(content.ctx, map[HEADER_BYTES..][0..payload_len])) return error.VerifyFailed;
        var pages = pageReport(view + HEADER_BYTES);
        if (pages.large_view) pages.huge_bytes = map_len;
        return .{
            .payload = map[HEADER_BYTES..][0..payload_len],
            .map_len = map_len,
            .key = key,
            .origin = if (existed) .attached else .created,
            .pages = pages,
            .os = .{ .view = @ptrCast(view), .section = handle },
        };
    }

    fn release(blob: *Blob) void {
        _ = UnmapViewOfFile(blob.os.view);
        win.CloseHandle(blob.os.section);
    }
};

/// Test support for callers' tests (net_share, backend): a unique namespace
/// per test, holder-record counting and registry removal.
pub const test_support = struct {
    pub fn namespace(buf: []u8, tag: []const u8) []const u8 {
        const pid: i64 = if (builtin.os.tag == .linux) std.os.linux.getpid() else if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else 0;
        const ts: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        return std.fmt.bufPrint(buf, "zqt-{s}-{d}-{x}", .{ tag, pid, ts & 0xffffff }) catch unreachable;
    }

    /// Live and stale holder records in the Linux registry (0 elsewhere).
    pub fn recordCount(ns: []const u8) usize {
        if (builtin.os.tag != .linux) return 0;
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/{s}-{d}", .{ ns, std.os.linux.geteuid() }) catch return 0;
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next() catch null) |e| {
            if (std.mem.startsWith(u8, e.name, "w-")) n += 1;
        }
        return n;
    }

    pub fn removeRegistry(ns: []const u8) void {
        if (builtin.os.tag != .linux) return;
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/{s}-{d}", .{ ns, std.os.linux.geteuid() }) catch return;
        std.fs.deleteTreeAbsolute(path) catch {};
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// Deterministic test payload: byte i = (i * 31 + seed) mod 251.
const TestContent = struct {
    seed: u8,
    len: usize,
    verifies: bool = true,

    fn byteAt(self: *const TestContent, i: usize) u8 {
        return @truncate((i *% 31 +% self.seed) % 251);
    }

    fn fill(ctx: *const anyopaque, dst: []u8) void {
        const self: *const TestContent = @ptrCast(@alignCast(ctx));
        for (dst, 0..) |*b, i| b.* = self.byteAt(i);
    }

    fn verify(ctx: *const anyopaque, src: []const u8) bool {
        const self: *const TestContent = @ptrCast(@alignCast(ctx));
        if (!self.verifies or src.len != self.len) return false;
        for (src, 0..) |b, i| if (b != self.byteAt(i)) return false;
        return true;
    }

    fn content(self: *const TestContent) Content {
        return .{ .ctx = self, .fill = fill, .verify = verify };
    }
};

const testNamespace = test_support.namespace;
const removeTestRegistry = test_support.removeRegistry;
const countRecords = test_support.recordCount;

fn sameObject(a: *const Blob, b: *const Blob) bool {
    if (builtin.os.tag != .linux) return true;
    var sa: std.os.linux.Stat = undefined;
    var sb: std.os.linux.Stat = undefined;
    if (std.os.linux.E.init(std.os.linux.fstat(a.os.memfd, &sa)) != .SUCCESS) return false;
    if (std.os.linux.E.init(std.os.linux.fstat(b.os.memfd, &sb)) != .SUCCESS) return false;
    return sa.ino == sb.ino and sa.dev == sb.dev;
}

test "shared blob: first acquire creates, second attaches to the same object" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "basic");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 7, .len = 3 * HUGE_PAGE_BYTES + 123 };
    var a = try acquire(.{ .namespace = ns }, 0x1234, tc.len, tc.content());
    try testing.expectEqual(Origin.created, a.origin);
    var b = try acquire(.{ .namespace = ns }, 0x1234, tc.len, tc.content());
    try testing.expectEqual(Origin.attached, b.origin);
    try testing.expect(TestContent.verify(&tc, b.payload));
    if (builtin.os.tag == .linux) {
        try testing.expect(sameObject(&a, &b));
        // 2 MB aligned mapping: the payload starts one header page in.
        try testing.expectEqual(@as(usize, HEADER_BYTES), @intFromPtr(a.payload.ptr) % HUGE_PAGE_BYTES);
        try testing.expectEqual(@as(usize, 2), countRecords(ns));
    }
    release(&a);
    release(&b);
    try testing.expectEqual(@as(usize, 0), countRecords(ns));
    // The last holder is gone, so the next acquire publishes afresh.
    var c = try acquire(.{ .namespace = ns }, 0x1234, tc.len, tc.content());
    defer release(&c);
    try testing.expectEqual(Origin.created, c.origin);
}

test "shared blob: the mapping is read-only and sealed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "seal");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 9, .len = 4096 };
    var a = try acquire(.{ .namespace = ns }, 0x99, tc.len, tc.content());
    defer release(&a);
    const linux = std.os.linux;
    const seals = linux.fcntl(a.os.memfd, linux_impl.F_GET_SEALS, 0);
    try testing.expectEqual(linux_impl.REQUIRED_SEALS, seals & linux_impl.REQUIRED_SEALS);
    // Size seals: the blob can never shrink under a mapping.
    try testing.expect(linux.E.init(linux.ftruncate(a.os.memfd, 4096)) != .SUCCESS);
    if (seals & linux_impl.WRITE_SEALS != 0) {
        // Write-sealed: neither a writable shared mapping nor write() works,
        // even through the creator's read-write descriptor.
        const rc = linux.mmap(null, a.map_len, linux.PROT.READ | linux.PROT.WRITE, .{ .TYPE = .SHARED }, a.os.memfd, 0);
        try testing.expect(linux.E.init(rc) != .SUCCESS);
        const byte = [1]u8{0x55};
        try testing.expect(linux.E.init(linux.pwrite(a.os.memfd, &byte, 1, HEADER_BYTES)) != .SUCCESS);
    }
    try testing.expectEqual(a.payload[0], tc.byteAt(0));
}

test "shared blob: different keys never share" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "keys");
    defer removeTestRegistry(ns);
    const t1 = TestContent{ .seed = 1, .len = 10_000 };
    const t2 = TestContent{ .seed = 2, .len = 10_000 };
    var a = try acquire(.{ .namespace = ns }, 0xA, t1.len, t1.content());
    defer release(&a);
    var b = try acquire(.{ .namespace = ns }, 0xB, t2.len, t2.content());
    defer release(&b);
    try testing.expectEqual(Origin.created, b.origin);
    try testing.expect(builtin.os.tag != .linux or !sameObject(&a, &b));
    try testing.expect(TestContent.verify(&t2, b.payload));
}

test "shared blob: a holder whose bytes fail verification is never used" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "mismatch");
    defer removeTestRegistry(ns);
    // Same key and length, different bytes: a 64-bit key collision, or a
    // corrupt publisher. The second process must build its own blob.
    const t1 = TestContent{ .seed = 1, .len = 50_000 };
    const t2 = TestContent{ .seed = 2, .len = 50_000 };
    var a = try acquire(.{ .namespace = ns }, 0xC0FFEE, t1.len, t1.content());
    defer release(&a);
    if (builtin.os.tag == .windows) {
        // One section per name: the colliding process cannot publish its own
        // and must stay private.
        try testing.expectError(error.VerifyFailed, acquire(.{ .namespace = ns }, 0xC0FFEE, t2.len, t2.content()));
        try testing.expect(TestContent.verify(&t1, a.payload));
        return;
    }
    var b = try acquire(.{ .namespace = ns }, 0xC0FFEE, t2.len, t2.content());
    defer release(&b);
    try testing.expectEqual(Origin.created, b.origin);
    try testing.expect(!sameObject(&a, &b));
    try testing.expect(TestContent.verify(&t2, b.payload));
    try testing.expect(TestContent.verify(&t1, a.payload));
}

test "shared blob: Windows sections on 4 KB pages and, when privileged, large pages" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "winpages");
    const tc = TestContent{ .seed = 12, .len = 3 * HUGE_PAGE_BYTES };
    var small = try acquire(.{ .namespace = ns, .allow_large_pages = false }, 0x4b, tc.len, tc.content());
    defer release(&small);
    try testing.expectEqual(Origin.created, small.origin);
    try testing.expect(small.pages.known and !small.pages.large_view);
    var small2 = try acquire(.{ .namespace = ns, .allow_large_pages = true }, 0x4b, tc.len, tc.content());
    defer release(&small2);
    try testing.expectEqual(Origin.attached, small2.origin);
    try testing.expect(!small2.pages.large_view);
    var large = try acquire(.{ .namespace = ns }, 0x4c, tc.len, tc.content());
    defer release(&large);
    try testing.expectEqual(hugealloc.winLargePageMinimum() != 0, large.pages.large_view);
}

test "shared blob: a verifier that rejects everything fails cleanly" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "reject");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 3, .len = 8192, .verifies = false };
    try testing.expectError(error.VerifyFailed, acquire(.{ .namespace = ns }, 0x55, tc.len, tc.content()));
    try testing.expectEqual(@as(usize, 0), countRecords(ns));
}

test "shared blob: an unsafe registry directory falls back" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "unsafe");
    defer removeTestRegistry(ns);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}-{d}", .{ ns, std.os.linux.geteuid() });
    try std.fs.makeDirAbsolute(path);
    try std.posix.fchmodat(std.fs.cwd().fd, path, 0o755, 0);
    const tc = TestContent{ .seed = 4, .len = 4096 };
    try testing.expectError(error.RegistryUnsafe, acquire(.{ .namespace = ns }, 0x1, tc.len, tc.content()));
    try std.posix.fchmodat(std.fs.cwd().fd, path, 0o700, 0);
    var ok_blob = try acquire(.{ .namespace = ns }, 0x1, tc.len, tc.content());
    release(&ok_blob);
}

test "shared blob: a symlinked registry is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "symlink");
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}-{d}", .{ ns, std.os.linux.geteuid() });
    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/tmp/{s}-target", .{ns});
    try std.fs.makeDirAbsolute(target);
    defer std.fs.deleteTreeAbsolute(target) catch {};
    try std.posix.symlink(target, path);
    defer std.fs.deleteFileAbsolute(path) catch {};
    const tc = TestContent{ .seed = 4, .len = 4096 };
    try testing.expectError(error.RegistryUnsafe, acquire(.{ .namespace = ns }, 0x1, tc.len, tc.content()));
}

test "shared blob: invalid requests are rejected before touching the OS" {
    const tc = TestContent{ .seed = 1, .len = 16 };
    try testing.expectError(error.InvalidRequest, acquire(.{ .namespace = "" }, 1, tc.len, tc.content()));
    try testing.expectError(error.InvalidRequest, acquire(.{ .namespace = "../etc" }, 1, tc.len, tc.content()));
    try testing.expectError(error.InvalidRequest, acquire(.{ .namespace = "ok" }, 1, 0, tc.content()));
}

test "shared blob: records of dead holders are swept and their memfd is gone" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "crash");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 5, .len = HUGE_PAGE_BYTES + 77 };
    const linux = std.os.linux;
    // A child publishes the blob, registers, and dies without any cleanup
    // (SIGKILL-equivalent: _exit skips release).
    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = acquire(.{ .namespace = ns }, 0xDEAD, tc.len, tc.content()) catch linux.exit_group(2);
        linux.exit_group(0);
    }
    const res = std.posix.waitpid(pid, 0);
    try testing.expectEqual(@as(u32, 0), res.status);
    // Its record is left behind, its lock is gone with it.
    try testing.expectEqual(@as(usize, 1), countRecords(ns));
    var b = try acquire(.{ .namespace = ns }, 0xDEAD, tc.len, tc.content());
    defer release(&b);
    // The dead holder's memfd died with it: we had to publish a new one, and
    // the stale record was removed (only ours remains).
    try testing.expectEqual(Origin.created, b.origin);
    try testing.expectEqual(@as(usize, 1), countRecords(ns));
}

test "shared blob: a dead holder does not strand live sharers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "survive");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 6, .len = 70_000 };
    var a = try acquire(.{ .namespace = ns }, 0xBEEF, tc.len, tc.content());
    defer release(&a);
    // A child attaches and dies without releasing.
    const pid = try std.posix.fork();
    if (pid == 0) {
        const b = acquire(.{ .namespace = ns }, 0xBEEF, tc.len, tc.content()) catch std.os.linux.exit_group(2);
        std.os.linux.exit_group(if (b.origin == .attached) 0 else 3);
    }
    const res = std.posix.waitpid(pid, 0);
    try testing.expectEqual(@as(u32, 0), res.status);
    var c = try acquire(.{ .namespace = ns }, 0xBEEF, tc.len, tc.content());
    defer release(&c);
    try testing.expectEqual(Origin.attached, c.origin);
    try testing.expect(sameObject(&a, &c));
}

test "shared blob: 16 processes starting at once share one object" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "storm");
    defer removeTestRegistry(ns);
    const tc = TestContent{ .seed = 11, .len = 5 * HUGE_PAGE_BYTES + 5 };
    const linux = std.os.linux;
    const N = 16;
    // Children report (origin, inode) through a pipe, then wait for the
    // parent's go before releasing, so all 16 hold the blob at once.
    const report = try std.posix.pipe();
    const go = try std.posix.pipe();
    var pids: [N]std.posix.pid_t = undefined;
    for (&pids) |*p| {
        p.* = try std.posix.fork();
        if (p.* == 0) {
            std.posix.close(report[0]);
            std.posix.close(go[1]);
            var b = acquire(.{ .namespace = ns }, 0x5707, tc.len, tc.content()) catch linux.exit_group(2);
            var st: linux.Stat = undefined;
            if (linux.E.init(linux.fstat(b.os.memfd, &st)) != .SUCCESS) linux.exit_group(3);
            if (!TestContent.verify(&tc, b.payload)) linux.exit_group(4);
            var msg: [16]u8 = undefined;
            std.mem.writeInt(u64, msg[0..8], @intFromEnum(b.origin), .little);
            std.mem.writeInt(u64, msg[8..16], st.ino, .little);
            _ = std.posix.write(report[1], &msg) catch linux.exit_group(5);
            var one: [1]u8 = undefined;
            _ = std.posix.read(go[0], &one) catch {};
            release(&b);
            linux.exit_group(0);
        }
    }
    std.posix.close(report[1]);
    std.posix.close(go[0]);
    var created: usize = 0;
    var inode: ?u64 = null;
    var same = true;
    for (0..N) |_| {
        var msg: [16]u8 = undefined;
        var got: usize = 0;
        while (got < msg.len) {
            const r = try std.posix.read(report[0], msg[got..]);
            if (r == 0) break;
            got += r;
        }
        try testing.expectEqual(msg.len, got);
        if (std.mem.readInt(u64, msg[0..8], .little) == @intFromEnum(Origin.created)) created += 1;
        const ino = std.mem.readInt(u64, msg[8..16], .little);
        if (inode) |i| same = same and i == ino else inode = ino;
    }
    try testing.expectEqual(@as(usize, N), countRecords(ns));
    std.posix.close(go[1]); // EOF releases every child
    std.posix.close(report[0]);
    for (pids) |p| {
        const res = std.posix.waitpid(p, 0);
        try testing.expectEqual(@as(u32, 0), res.status);
    }
    try testing.expectEqual(@as(usize, 1), created);
    try testing.expect(same);
    try testing.expectEqual(@as(usize, 0), countRecords(ns));
}

test "shared blob: a rendezvous lock held elsewhere times out instead of hanging" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var ns_buf: [64]u8 = undefined;
    const ns = testNamespace(&ns_buf, "wedged");
    defer removeTestRegistry(ns);
    const dir_fd = try linux_impl.openRegistry(.{ .namespace = ns });
    defer linux_impl.closeFd(dir_fd);
    const rc = linux.openat(dir_fd, "registry.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    try testing.expectEqual(linux.E.SUCCESS, linux.E.init(rc));
    const held: i32 = @intCast(rc);
    var held_open = true;
    defer if (held_open) linux_impl.closeFd(held);
    try testing.expect(linux_impl.flockRetry(held, linux_impl.LOCK_EX));
    // A second description of the same file contends like another process.
    const rc2 = linux.openat(dir_fd, "registry.lock", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.E.init(rc2));
    const waiter: i32 = @intCast(rc2);
    defer linux_impl.closeFd(waiter);
    var timer = try std.time.Timer.start();
    try testing.expect(!linux_impl.lockWithin(waiter, 50));
    try testing.expect(timer.read() >= 50 * std.time.ns_per_ms);
    linux_impl.closeFd(held);
    held_open = false;
    try testing.expect(linux_impl.lockWithin(waiter, 50));
}

test "shared blob: smaps reader finds no PMD bytes for an unknown address" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try testing.expect(linux_impl.pmdMappedBytes(0x1000) == null);
}
