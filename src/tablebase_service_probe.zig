//! Bounded standalone admission probe, never imported by the engine.
const std = @import("std");
const runtime = @import("util/search_runtime.zig");
const syzygy = @import("search/syzygy.zig");
const fen = @import("core/fen.zig");
const position = @import("core/position.zig");
const timeout = 20 * std.time.ns_per_s;
const fens = [_][]const u8{
    "4k3/8/8/8/8/8/3Q4/4K3 w - - 0 1",
    "4k3/8/8/8/8/8/3Q4/4K3 b - - 0 1",
    "4k3/8/8/8/8/8/3R4/4K3 w - - 0 1",
    "4k3/8/8/8/8/8/3BN3/4K3 w - - 0 1",
    "7k/P7/2K5/8/8/8/8/8 w - - 0 1",
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "4k3/8/8/8/8/8/3Q3r/4K3 w - - 0 1",
    "4k3/8/8/8/8/8/3B4/4K3 w - - 0 1",
    "4k3/8/8/8/8/8/3Q4/4K3 w - - 99 1",
    "4k3/8/8/8/8/8/8/4K2R w K - 0 1",
    "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1",
    "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1",
};
const Case = struct { pos: position.Position, wdl: ?syzygy.Wdl, root: ?syzygy.RootVerdict };
const Worker = struct {
    cases: *const [fens.len]Case,
    go: *runtime.ResetEvent,
    ready: runtime.ResetEvent = .{},
    done: runtime.ResetEvent = .{},
    failed: bool = false,
    fn run(self: *Worker) void {
        var job = syzygy.beginJob();
        defer job.deinit();
        self.ready.set();
        self.go.wait();
        if (!job.enabled()) self.failed = true;
        for (0..16) |_| for (self.cases) |*c| {
            if (job.probeWdl(&c.pos) != c.wdl or !std.meta.eql(job.probeRoot(&c.pos), c.root)) self.failed = true;
        };
        self.done.set();
    }
};
const Reload = struct {
    path: [:0]const u8,
    started: runtime.ResetEvent = .{},
    done: runtime.ResetEvent = .{},
    ok: bool = false,
    fn run(self: *Reload) void {
        self.started.set();
        self.ok = syzygy.init(self.path);
        self.done.set();
    }
};
pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    const path = try std.heap.page_allocator.dupeZ(u8, args.next() orelse return error.MissingPath);
    defer std.heap.page_allocator.free(path);
    if (!syzygy.init(path) or syzygy.pieceLimit() < 5) return error.TablesUnavailable;
    defer syzygy.disable();
    var cases: [fens.len]Case = undefined;
    for (fens, &cases) |text, *c| {
        c.pos = try fen.parse(text);
        c.wdl = syzygy.probeWdl(&c.pos);
        c.root = syzygy.probeRoot(&c.pos);
    }
    // Require substantive hits, not merely matching failure from both paths.
    if (cases[0].wdl != .win or cases[0].root == null or cases[1].wdl != .loss or cases[7].wdl != .draw) return error.BadOracle;
    if (cases[8].wdl != null or cases[9].wdl != null or cases[9].root != null or cases[10].root != null or cases[11].root != null) return error.BadPrecondition;
    for (0..3) |_| {
        syzygy.disable();
        if (!syzygy.init(path)) return error.ReinitFailed;
        var go = runtime.ResetEvent{};
        var workers: [4]Worker = undefined;
        var threads: [4]runtime.Thread = undefined;
        var started: usize = 0;
        defer {
            go.set();
            for (threads[0..started]) |t| t.join();
        }
        for (&workers, 0..) |*worker, i| {
            worker.* = .{ .cases = &cases, .go = &go };
            threads[i] = try runtime.Thread.spawn(.{}, Worker.run, .{worker});
            started += 1;
        }
        for (&workers) |*worker| try worker.ready.timedWait(timeout);
        var reload = Reload{ .path = path };
        const reloader = try runtime.Thread.spawn(.{}, Reload.run, .{&reload});
        var joined = false;
        defer if (!joined) {
            go.set();
            reloader.join();
        };
        try reload.started.timedWait(timeout);
        if (reload.done.timedWait(20 * std.time.ns_per_ms)) |_| return error.ReloadBypassedJobs else |err| if (err != error.Timeout) return err;
        go.set();
        for (&workers) |*worker| try worker.done.timedWait(timeout);
        for (threads[0..started]) |t| t.join();
        started = 0;
        try reload.done.timedWait(timeout);
        reloader.join();
        joined = true;
        if (!reload.ok) return error.ReloadFailed;
        for (workers) |worker| if (worker.failed) return error.ProbeMismatch;
    }
    syzygy.disable();
    if (syzygy.enabled() or syzygy.probeWdl(&cases[0].pos) != null) return error.DisableFailed;
    if (syzygy.init("/nonexistent-zigqueen-tb-service-fixture") or syzygy.pieceLimit() != 0) return error.MissingTablesEnabled;
    std.debug.print("TB_SERVICE_PASS fixtures={d} workers=4 cold_cycles=3 pairs=2304 reloads_blocked=3\n", .{fens.len});
}
