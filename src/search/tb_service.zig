//! Process-wide lifetime and probe-phase admission. Backend is private to the
//! singleton wrapper; fake backends test exclusion without touching Fathom.
const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const position = @import("../core/position.zig");

/// Writer-preferring admission, not a recursive lock. Existing lease holders
/// never reacquire the same gate. Counts and predicates are mutex-owned.
const Gate = struct {
    mutex: runtime.Mutex = .{},
    changed: runtime.Condition = .{},
    readers: usize = 0,
    waiting_writers: usize = 0,
    writing: bool = false,

    fn read(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.writing or self.waiting_writers != 0) self.changed.wait(&self.mutex);
        self.readers += 1;
    }
    fn unread(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.readers > 0 and !self.writing);
        self.readers -= 1;
        if (self.readers == 0) self.changed.broadcast();
    }
    fn write(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waiting_writers += 1;
        while (self.writing or self.readers != 0) self.changed.wait(&self.mutex);
        self.waiting_writers -= 1;
        self.writing = true;
    }
    fn unwrite(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.writing and self.readers == 0);
        self.writing = false;
        self.changed.broadcast();
    }
};

pub fn Service(comptime Backend: type) type {
    return struct {
        const Self = @This();
        backend: Backend = .{},
        lifetime: Gate = .{},
        probes: Gate = .{},
        // Metadata only: observing nonzero is not permission to call Fathom.
        // Every caller must acquire a lease and recheck under lifetime admission.
        largest: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        backend_live: bool = false,

        pub fn init(self: *Self, path: [:0]const u8) bool {
            self.lifetime.write();
            defer self.lifetime.unwrite();
            if (self.backend_live) self.backend.free();
            self.backend_live = self.backend.init(path);
            const limit = if (self.backend_live) self.backend.limit() else 0;
            self.largest.store(limit, .release);
            return limit != 0;
        }
        pub fn disable(self: *Self) void {
            self.lifetime.write();
            defer self.lifetime.unwrite();
            if (self.backend_live) self.backend.free();
            self.backend_live = false;
            self.largest.store(0, .release);
        }
        pub fn pieceLimit(self: *const Self) u32 {
            return self.largest.load(.acquire);
        }
        pub fn acquire(self: *Self) Lease {
            // A disabled job remains TB-disabled even if another thread enables
            // the service later. No Fathom memory is touched by this fast path.
            if (self.pieceLimit() == 0) return .{};
            self.lifetime.read();
            const limit = self.pieceLimit();
            if (limit == 0) {
                self.lifetime.unread();
                return .{};
            }
            return .{ .service = self, .largest = limit };
        }

        /// Move-only by contract. Its owner releases once, after all borrowed
        /// *const views return. Do not copy or retain a view beyond release.
        pub const Lease = struct {
            service: ?*Self = null,
            largest: u32 = 0,

            pub fn release(self: *Lease) void {
                if (self.service) |service| service.lifetime.unread();
                self.* = .{};
            }
            /// Side-effect-free WDL scope predicate: false exactly when wdl()
            /// would reject the position before admission (nonzero halfmove
            /// clock, piece count above the pinned limit, any castling right).
            /// Callers may use it as an inline per-node pre-filter; wdl()
            /// still applies it itself and remains the authority.
            pub inline fn wdlInScope(self: *const Lease, pos: *const position.Position) bool {
                return pos.halfmove_clock == 0 and inScope(pos, self.largest);
            }
            pub fn wdl(self: *const Lease, pos: *const position.Position) ?u32 {
                const service = self.service orelse return null;
                if (!self.wdlInScope(pos)) return null;
                service.probes.read();
                defer service.probes.unread();
                return service.backend.wdl(pos);
            }
            pub fn root(self: *const Lease, pos: *const position.Position) ?u32 {
                return self.rootWithMoves(pos, null);
            }
            /// Same exclusive root phase, optionally filling the backend's
            /// caller-owned, fixed-capacity per-move result buffer.
            pub fn rootWithMoves(self: *const Lease, pos: *const position.Position, results: ?[*]u32) ?u32 {
                const service = self.service orelse return null;
                if (!inScope(pos, self.largest)) return null;
                service.probes.write();
                defer service.probes.unwrite();
                return service.backend.root(pos, results);
            }
        };
    };
}

inline fn inScope(pos: *const position.Position, limit: u32) bool {
    if (@popCount(pos.occupied) > limit) return false;
    const cr = pos.castling_rights;
    return !(cr.white_king_side or cr.white_queen_side or cr.black_king_side or cr.black_queen_side);
}

const TestBackend = struct {
    state: ?*TestState = null,
    fn init(self: *@This(), path: [:0]const u8) bool {
        const s = self.state.?;
        s.checkExclusive();
        s.live = !std.mem.eql(u8, path, "fail");
        s.limit = if (std.mem.eql(u8, path, "empty")) 0 else if (std.mem.eql(u8, path, "three")) 3 else 5;
        return s.live;
    }
    fn free(self: *@This()) void {
        const s = self.state.?;
        s.checkExclusive();
        if (!s.live) _ = s.violations.fetchAdd(1, .monotonic);
        s.live = false;
        _ = s.frees.fetchAdd(1, .monotonic);
    }
    fn limit(self: *@This()) u32 {
        return self.state.?.limit;
    }
    fn wdl(self: *@This(), _: *const position.Position) u32 {
        const s = self.state.?;
        _ = s.active_wdl.fetchAdd(1, .seq_cst);
        defer _ = s.active_wdl.fetchSub(1, .seq_cst);
        if (!s.live or s.active_root.load(.seq_cst) != 0) _ = s.violations.fetchAdd(1, .monotonic);
        _ = s.wdl_entered.fetchAdd(1, .seq_cst);
        if (s.hold_wdl) s.release_wdl.wait();
        return 4;
    }
    fn root(self: *@This(), _: *const position.Position, _: ?[*]u32) u32 {
        const s = self.state.?;
        const prior = s.active_root.fetchAdd(1, .seq_cst);
        defer _ = s.active_root.fetchSub(1, .seq_cst);
        if (!s.live or prior != 0 or s.active_wdl.load(.seq_cst) != 0) _ = s.violations.fetchAdd(1, .monotonic);
        s.root_entered.set();
        if (s.hold_root) s.release_root.wait();
        return 17;
    }
};
const TestState = struct {
    live: bool = false,
    limit: u32 = 0,
    hold_wdl: bool = false,
    hold_root: bool = false,
    active_wdl: std.atomic.Value(u32) = .init(0),
    active_root: std.atomic.Value(u32) = .init(0),
    wdl_entered: std.atomic.Value(u32) = .init(0),
    violations: std.atomic.Value(u32) = .init(0),
    frees: std.atomic.Value(u32) = .init(0),
    root_entered: runtime.ResetEvent = .{},
    release_wdl: runtime.ResetEvent = .{},
    release_root: runtime.ResetEvent = .{},
    fn checkExclusive(self: *TestState) void {
        if (self.active_wdl.load(.seq_cst) != 0 or self.active_root.load(.seq_cst) != 0)
            _ = self.violations.fetchAdd(1, .monotonic);
    }
};
const TestService = Service(TestBackend);
const deadline_ns = 5 * std.time.ns_per_s;

fn waitWriters(gate: *Gate) !void {
    var timer = try runtime.Timer.start();
    while (timer.read() < deadline_ns) {
        gate.mutex.lock();
        const queued = gate.waiting_writers;
        gate.mutex.unlock();
        if (queued > 0) return;
        runtime.Thread.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}
fn waitCounter(counter: *const std.atomic.Value(u32), n: u32) !void {
    var timer = try runtime.Timer.start();
    while (counter.load(.seq_cst) != n) {
        if (timer.read() >= deadline_ns) return error.Timeout;
        runtime.Thread.sleep(std.time.ns_per_ms);
    }
}
const TestProbe = struct {
    service: *TestService,
    root: bool,
    done: runtime.ResetEvent = .{},
    result: ?u32 = null,
    fn run(self: *TestProbe) void {
        var lease = self.service.acquire();
        defer lease.release();
        const pos = @import("../core/fen.zig").parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1") catch unreachable;
        self.result = if (self.root) lease.root(&pos) else lease.wdl(&pos);
        self.done.set();
    }
};

test "TB service WDL overlaps while root excludes readers and queued writers prevent new readers" {
    var state = TestState{ .hold_wdl = true, .hold_root = true };
    var service = TestService{ .backend = .{ .state = &state } };
    try std.testing.expect(service.init("five"));
    defer service.disable();
    var probes = [_]TestProbe{
        .{ .service = &service, .root = false }, .{ .service = &service, .root = false },
        .{ .service = &service, .root = true },  .{ .service = &service, .root = false },
    };
    var threads: [4]runtime.Thread = undefined;
    var started: usize = 0;
    defer {
        state.release_wdl.set();
        state.release_root.set();
        for (threads[0..started]) |t| t.join();
    }
    for (0..2) |i| {
        threads[i] = try runtime.Thread.spawn(.{}, TestProbe.run, .{&probes[i]});
        started += 1;
    }
    try waitCounter(&state.wdl_entered, 2);
    try std.testing.expectEqual(@as(u32, 2), state.active_wdl.load(.seq_cst));
    threads[2] = try runtime.Thread.spawn(.{}, TestProbe.run, .{&probes[2]});
    started += 1;
    try waitWriters(&service.probes);
    threads[3] = try runtime.Thread.spawn(.{}, TestProbe.run, .{&probes[3]});
    started += 1;
    state.release_wdl.set();
    try state.root_entered.timedWait(deadline_ns);
    try std.testing.expectEqual(@as(u32, 2), state.wdl_entered.load(.seq_cst));
    try std.testing.expectError(error.Timeout, probes[3].done.timedWait(10 * std.time.ns_per_ms));
    state.release_root.set();
    for (&probes) |*probe| try probe.done.timedWait(deadline_ns);
    for (threads[0..started]) |t| t.join();
    started = 0;
    try std.testing.expectEqual(@as(u32, 3), state.wdl_entered.load(.seq_cst));
    for (probes) |probe| try std.testing.expectEqual(@as(?u32, if (probe.root) 17 else 4), probe.result);
    try std.testing.expectEqual(@as(u32, 0), state.violations.load(.seq_cst));
}

test "TB service job pins configuration and can still probe while reconfiguration waits" {
    var state = TestState{};
    var service = TestService{ .backend = .{ .state = &state } };
    try std.testing.expect(service.init("five"));
    defer service.disable();
    var lease = service.acquire();
    defer lease.release();
    const Change = struct {
        service: *TestService,
        done: runtime.ResetEvent = .{},
        result: bool = false,
        fn run(self: *@This()) void {
            self.result = self.service.init("three");
            self.done.set();
        }
    };
    var change = Change{ .service = &service };
    const thread = try runtime.Thread.spawn(.{}, Change.run, .{&change});
    defer {
        lease.release();
        thread.join();
    }
    try waitWriters(&service.lifetime);
    try std.testing.expectEqual(@as(u32, 0), state.frees.load(.seq_cst));
    const pos = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1");
    try std.testing.expectEqual(@as(?u32, 4), lease.wdl(&pos));
    try std.testing.expectEqual(@as(?u32, 17), lease.root(&pos));
    try std.testing.expectEqual(@as(u32, 5), lease.largest);
    lease.release();
    try change.done.timedWait(deadline_ns);
    try std.testing.expect(change.result);
    var next = service.acquire();
    defer next.release();
    try std.testing.expectEqual(@as(u32, 3), next.largest);
    try std.testing.expectEqual(@as(u32, 1), state.frees.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), state.violations.load(.seq_cst));
}

test "TB service handles disabled empty failed and repeated lifecycle without leaking backend ownership" {
    var state = TestState{};
    var service = TestService{ .backend = .{ .state = &state } };
    var disabled = service.acquire();
    defer disabled.release();
    try std.testing.expect(!service.init("empty"));
    try std.testing.expectEqual(@as(u32, 0), service.pieceLimit());
    service.disable();
    service.disable();
    try std.testing.expectEqual(@as(u32, 1), state.frees.load(.seq_cst));
    try std.testing.expect(!service.init("fail"));
    service.disable();
    try std.testing.expectEqual(@as(u32, 1), state.frees.load(.seq_cst));
    try std.testing.expect(service.init("five"));
    defer service.disable();
    const pos = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1");
    // A previously captured disabled job never becomes enabled mid-search.
    try std.testing.expectEqual(@as(?u32, null), disabled.wdl(&pos));
    var lease = service.acquire();
    defer lease.release();
    var clocked = pos;
    clocked.halfmove_clock = 1;
    try std.testing.expectEqual(@as(?u32, null), lease.wdl(&clocked));
    try std.testing.expectEqual(@as(?u32, 17), lease.root(&clocked));
    var castle = pos;
    castle.castling_rights.white_king_side = true;
    try std.testing.expectEqual(@as(?u32, null), lease.wdl(&castle));
    try std.testing.expectEqual(@as(?u32, null), lease.root(&castle));
    const start = try @import("../core/fen.zig").startpos();
    try std.testing.expectEqual(@as(?u32, null), lease.wdl(&start));
    try std.testing.expectEqual(@as(u32, 0), state.wdl_entered.load(.seq_cst));
    // The inline per-node pre-filter agrees with wdl() admission exactly,
    // including the piece-count boundary at the pinned limit (5 here).
    const five = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/1PPQ4/4K3 w - - 0 1");
    const six = try @import("../core/fen.zig").parse("4k3/8/8/8/8/8/PPPQ4/4K3 w - - 0 1");
    const scoped = [_]struct { pos: position.Position, admitted: bool }{
        .{ .pos = clocked, .admitted = false }, .{ .pos = castle, .admitted = false },
        .{ .pos = start, .admitted = false },   .{ .pos = six, .admitted = false },
        .{ .pos = pos, .admitted = true },      .{ .pos = five, .admitted = true },
    };
    for (scoped) |case| {
        const entered = state.wdl_entered.load(.seq_cst);
        try std.testing.expectEqual(case.admitted, lease.wdlInScope(&case.pos));
        try std.testing.expectEqual(case.admitted, lease.wdl(&case.pos) != null);
        try std.testing.expectEqual(entered + @intFromBool(case.admitted), state.wdl_entered.load(.seq_cst));
    }
    try std.testing.expect(!disabled.wdlInScope(&pos));
}
