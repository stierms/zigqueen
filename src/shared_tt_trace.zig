//! Explanatory shared-table contention trace; not an engine strength test.
const std = @import("std");
const runtime = @import("util/search_runtime.zig");
const shared = @import("search/shared_tt.zig");

const Task = struct {
    view: shared.View,
    gate: *runtime.ResetEvent,
    id: u64,
    operations: usize,
    contended: bool,
    stores: usize = 0,
    skipped: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
    invalid: bool = false,

    fn run(self: *@This()) void {
        self.gate.wait();
        var state = 0x6a09e667f3bcc909 ^ self.id;
        for (0..self.operations) |_| {
            state +%= 0x9e3779b97f4a7c15;
            var mixed = (state ^ (state >> 30)) *% 0xbf58476d1ce4e5b9;
            mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
            const raw = mixed ^ (mixed >> 31);
            // Contended trace compresses indexing into sixteen clusters while
            // retaining varied full keys; uniform trace spans the whole table.
            const key = if (self.contended) raw & (~self.view.mask | 15) else raw;
            const value: i32 = @intCast((key >> 32) & 32767);
            const result = self.view.storeResult(key, 3, value, .exact, null, @intCast(value), true);
            if (result.skip == .none) self.stores += 1 else self.skipped += 1;
            if (self.view.lookup(key)) |entry| {
                self.hits += 1;
                if (entry.key != key or entry.score != value or entry.static_eval != value or
                    entry.generation != self.view.generation) self.invalid = true;
            } else self.misses += 1;
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 4) return error.UsageThreadsUniformOrContendedOperations;
    const threads_count = try std.fmt.parseInt(usize, args[1], 10);
    if (threads_count == 0 or threads_count > 16) return error.InvalidThreads;
    const contended = std.mem.eql(u8, args[2], "contended");
    if (!contended and !std.mem.eql(u8, args[2], "uniform")) return error.InvalidGeometry;
    const operations = try std.fmt.parseInt(usize, args[3], 10);
    if (operations == 0 or operations > 10000000) return error.InvalidOperations;
    var table = try shared.SharedTable.init(allocator, 64);
    defer table.deinit();
    const view = try table.beginSearch();
    defer table.endSearch();
    var gate = runtime.ResetEvent{};
    var tasks: [16]Task = undefined;
    var threads: [16]runtime.Thread = undefined;
    var created: usize = 0;
    errdefer {
        gate.set();
        for (threads[0..created]) |thread| thread.join();
    }
    for (0..threads_count) |i| {
        tasks[i] = .{ .view = view, .gate = &gate, .id = i + 1, .operations = operations, .contended = contended };
        threads[i] = try runtime.Thread.spawn(.{}, Task.run, .{&tasks[i]});
        created += 1;
    }
    var timer = try runtime.Timer.start();
    gate.set();
    for (threads[0..created]) |thread| thread.join();
    created = 0;
    const elapsed = timer.read();
    var stores: usize = 0;
    var skipped: usize = 0;
    var hits: usize = 0;
    var misses: usize = 0;
    for (tasks[0..threads_count]) |task| {
        if (task.invalid) return error.IncoherentEntry;
        stores += task.stores;
        skipped += task.skipped;
        hits += task.hits;
        misses += task.misses;
    }
    std.debug.print("threads={d} geometry={s} operations={d} stores={d} skipped={d} hits={d} misses={d} elapsed_ns={d}\n", .{
        threads_count, args[2], operations * threads_count, stores, skipped, hits, misses, elapsed,
    });
}
