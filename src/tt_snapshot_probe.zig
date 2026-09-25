const std = @import("std");
const proto = @import("probes/tt_snapshot.zig");
const tt = @import("search/tt.zig");
const moves = @import("core/move.zig");

test "snapshot packing retains full ranges and rejects invalid encodings" {
    for ([_]i32{ std.math.minInt(i32), -29000, -1, 0, 29000, std.math.maxInt(i32) }) |score| {
        for ([_]i16{ std.math.minInt(i16), -1, 0, 128, std.math.maxInt(i16) }) |depth| {
            for ([_]i16{ tt.STATIC_EVAL_NONE, -1, 0, std.math.maxInt(i16) }) |eval| {
                for (0..3) |bound| {
                    const e = tt.Entry{ .key = std.math.maxInt(u64), .score = score, .depth = depth, .static_eval = eval, .bound = @enumFromInt(bound), .generation = 255, .was_pv = true, .move_bits = 0xcfff };
                    try std.testing.expectEqualDeep(e, proto.Packed.encode(e).decode().?);
                }
            }
        }
    }
    for (0..65536) |raw| {
        const e = tt.Entry{ .move_bits = @intCast(raw) };
        const decoded = proto.Packed.encode(e).decode();
        if (raw >> 12 <= 12) try std.testing.expectEqualDeep(e, decoded.?) else try std.testing.expect(decoded == null);
    }
    var encoded = proto.Packed.encode(.{});
    encoded.b |= @as(u64, 3) << 24;
    try std.testing.expect(encoded.decode() == null);
    encoded = proto.Packed.encode(.{});
    encoded.b |= @as(u64, 1) << 63;
    try std.testing.expect(encoded.decode() == null);
}

fn inputFor(marker: u32) proto.Input {
    return .{
        .key = 0x1234_ffff_5678_aaaa,
        .depth = 100,
        .score = @intCast(marker),
        .bound = @enumFromInt(marker % 3),
        .mv = @bitCast(@as(u16, @intCast(marker & 4095))),
        .static_eval = @intCast(marker & 32767),
        .was_pv = marker & 1 != 0,
        .generation = @truncate(marker >> 8),
    };
}

test "snapshot replacement and diagnostics match serial TT across generation wraps" {
    var serial = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer serial.deinit();
    var cluster = proto.Cluster{};
    var rng = std.Random.DefaultPrng.init(0x5ea1_c0de);
    const r = rng.random();
    for (0..20000) |step| {
        if (step % 19 == 0) serial.newSearch();
        const in = proto.Input{
            .key = @as(u64, r.uintLessThan(u8, 5)) * serial.entries.len,
            .depth = r.intRangeAtMost(i16, -1, 128),
            .score = r.int(i32),
            .bound = @enumFromInt(r.uintLessThan(u2, 3)),
            .mv = if (step % 3 == 0) null else moves.Move.init(.a1, .b1, .quiet),
            .static_eval = if (step % 2 == 0) tt.STATIC_EVAL_NONE else r.int(i16),
            .was_pv = r.boolean(),
            .generation = serial.generation,
        };
        const expected = serial.storeWithOutcome(in.key, in.depth, in.score, in.bound, in.mv, in.static_eval, in.was_pv);
        const actual = cluster.store(in);
        try std.testing.expectEqual(.none, actual.skip);
        try std.testing.expectEqualDeep(expected, actual.outcome);
        try std.testing.expectEqualDeep(serial.entries[0].entries, cluster.snapshot().?);
        try std.testing.expectEqualDeep(serial.lookup(in.key), cluster.lookup(in.key));
    }
}

test "snapshot contention retirement and invalid-payload paths remain bounded" {
    var cluster = proto.Cluster{};
    try std.testing.expect(cluster.lookup(0) == null);
    _ = cluster.store(inputFor(1));
    const old = cluster.snapshot().?;
    cluster.sequence.store(3, .seq_cst); // Simulate a paused owner; never spin.
    try std.testing.expect(cluster.snapshot() == null);
    try std.testing.expectEqual(.contended, cluster.store(inputFor(2)).skip);
    cluster.sequence.store(std.math.maxInt(u64) - 3, .seq_cst);
    try std.testing.expect(cluster.store(inputFor(3)).outcome.stored);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, cluster.sequence.load(.seq_cst));
    const last = cluster.snapshot().?;
    try std.testing.expectEqual(.retired, cluster.store(inputFor(4)).skip);
    try std.testing.expectEqualDeep(last, cluster.snapshot().?);
    try std.testing.expect(old[0].score != last[0].score);
    // Quiescent reset only. No generation reuse while a reader can be alive.
    cluster = .{};
    cluster.slots[0].b.store(@as(u64, 1) << 63, .seq_cst);
    try std.testing.expect(cluster.snapshot() == null);
    try std.testing.expectEqual(.invalid_payload, cluster.store(inputFor(1)).skip);
    try std.testing.expectEqual(@as(u64, 0), cluster.sequence.load(.seq_cst) & 1);
}

const ThreadState = struct {
    cluster: *proto.Cluster,
    start: *std.atomic.Value(bool),
    ready: *std.atomic.Value(u32),
    id: u32,
    accepted: usize = 0,
    skipped: usize = 0,
    failed: bool = false,

    fn run(self: *ThreadState) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        for (0..20000) |step| {
            if (self.id < 4) {
                const in = inputFor(@intCast(1 + self.id * 20000 + step));
                const result = self.cluster.store(in);
                if (result.outcome.stored) self.accepted += 1 else self.skipped += 1;
                if (result.skip != .none and result.skip != .contended) self.failed = true;
            } else {
                const e = self.cluster.lookup(inputFor(1).key) orelse {
                    self.skipped += 1;
                    continue;
                };
                self.accepted += 1;
                if (e.score <= 0 or e.score > 80000) {
                    self.failed = true;
                    continue;
                }
                const in = inputFor(@intCast(e.score));
                if (e.key != in.key or e.depth != in.depth or e.bound != in.bound or
                    e.move_bits != @as(u16, @bitCast(in.mv.?)) or e.static_eval != in.static_eval or
                    e.generation != in.generation or e.was_pv != in.was_pv) self.failed = true;
            }
        }
    }
};

test "snapshot contended writers never publish accepted mixed records" {
    var cluster = proto.Cluster{};
    _ = cluster.store(inputFor(1));
    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u32).init(0);
    var state: [8]ThreadState = undefined;
    var threads: [8]?std.Thread = @splat(null);
    defer {
        start.store(true, .release);
        for (threads) |thread| if (thread) |t| t.join();
    }
    for (&threads, &state, 0..) |*thread, *s, id| {
        s.* = .{ .cluster = &cluster, .start = &start, .ready = &ready, .id = @intCast(id) };
        thread.* = try std.Thread.spawn(.{}, ThreadState.run, .{s});
    }
    while (ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
    start.store(true, .release);
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    var reads: usize = 0;
    var writes: usize = 0;
    for (state) |s| {
        try std.testing.expect(!s.failed);
        if (s.id < 4) writes += s.accepted else reads += s.accepted;
    }
    try std.testing.expect(reads > 0 and writes > 0);
    try std.testing.expectEqual(@as(u64, 0), cluster.sequence.load(.seq_cst) & 1);
    std.debug.print(" accepted_reads={d} successful_writes={d}\n", .{ reads, writes });
}
