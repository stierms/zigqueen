//! Fresh-process startup checks. Separate executable: the ordinary unit suite
//! may already have initialized globals. Never reset production once state.
const std = @import("std");
const startup = @import("search/startup.zig");
const engine_mod = @import("search/engine.zig");
const reductions = @import("search/reductions.zig");
const time = @import("search/time.zig");
const tunables = @import("search/tunables.zig");
const fen = @import("core/fen.zig");
const repetition = @import("search/repetition.zig");
const allocator = std.heap.page_allocator;
const expect = std.testing.expect;

fn searchTwice(engine: *engine_mod.Engine) !void {
    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    const stop = std.atomic.Value(bool).init(false);
    const first = engine.search(&pos, &history, .{ .depth = 4 }, &stop);
    engine.reset();
    const second = engine.search(&pos, &history, .{ .depth = 4 }, &stop);
    try expect(first.best_move != null);
    try expect(first.best_move == second.best_move and first.score == second.score);
    try expect(first.depth == second.depth and first.seldepth == second.seldepth and first.nodes == second.nodes);
    try std.testing.expectEqualSlices(@import("core/move.zig").Move, first.pv.slice(), second.pv.slice());
}

const Start = struct {
    ready: std.atomic.Value(usize) = .init(0),
    go: std.Thread.ResetEvent = .{},
};
const Participant = struct {
    start: *Start,
    net: *const engine_mod.Net,
    index: usize,
    tm_first: bool,
    failure: ?anyerror = null,
    table: reductions.LmrTable = undefined,
    config: time.TmConfig = undefined,

    fn run(self: *Participant) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn check(self: *Participant) !void {
        _ = self.start.ready.fetchAdd(1, .release);
        try self.start.go.timedWait(10 * std.time.ns_per_s);
        if (self.tm_first) self.config = time.tmConfig();
        var engine = switch (self.index % 3) {
            0 => try engine_mod.Engine.initWithSharedNet(allocator, 1, self.net),
            1 => try engine_mod.Engine.init(allocator, 1),
            else => try engine_mod.Engine.initWithOptions(allocator, 1, .{}),
        };
        defer engine.deinit();
        try expect(startup.isReady());
        self.config = time.tmConfig();
        self.table = startup.lmrTable().*;
        try searchTwice(&engine);
    }
};

fn concurrent(net: *const engine_mod.Net, tm_first: bool) !void {
    var start = Start{};
    var participants: [4]Participant = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer {
        start.go.set(); // Release and join even if a later spawn fails.
        for (threads[0..started]) |thread| thread.join();
    }
    for (&participants, 0..) |*participant, index| {
        participant.* = .{ .start = &start, .net = net, .index = index, .tm_first = tm_first };
        threads[index] = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, Participant.run, .{participant});
        started += 1;
    }
    var timer = try std.time.Timer.start();
    while (start.ready.load(.acquire) != participants.len) {
        if (timer.read() > 10 * std.time.ns_per_s) return error.StartTimeout;
        std.Thread.yield() catch {};
    }
    try expect(!startup.isReady());
    start.go.set();
    for (threads) |thread| thread.join();
    started = 0;
    var expected_table: reductions.LmrTable = undefined;
    reductions.buildLmrTable(&expected_table, reductions.LMR_BASE_100_DEFAULT, reductions.LMR_DIVISOR_100_DEFAULT);
    for (&participants) |*participant| {
        if (participant.failure) |err| return err;
        try std.testing.expectEqualDeep(participants[0].config, participant.config);
        try std.testing.expectEqualDeep(expected_table, participant.table);
        try std.testing.expectEqualDeep(time.loadTmConfigFromEnv(), participant.config);
    }
}

fn tuning(net: *const engine_mod.Net) !void {
    try expect(tunables.set("LmrDivisor100", 150)); // first initialized caller
    const before = startup.lmrTable().*;
    var engine = try engine_mod.Engine.initWithSharedNet(allocator, 1, net);
    defer engine.deinit();
    try std.testing.expectEqualDeep(before, startup.lmrTable().*);
    try searchTwice(&engine);
    // All searches are finished. The writer owns process-wide quiescence.
    try expect(tunables.set("LmrBase100", 100));
    const after = startup.lmrTable().*;
    try expect(!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after)));
    var second = try engine_mod.Engine.initWithSharedNet(allocator, 1, net);
    defer second.deinit();
    try std.testing.expectEqualDeep(after, startup.lmrTable().*);
    try searchTwice(&second);
    tunables.reset();
    var defaults: reductions.LmrTable = undefined;
    reductions.buildLmrTable(&defaults, reductions.LMR_BASE_100_DEFAULT, reductions.LMR_DIVISOR_100_DEFAULT);
    try std.testing.expectEqualDeep(defaults, startup.lmrTable().*);
}

fn failureRetry(net: *const engine_mod.Net) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    if (engine_mod.Engine.initWithSharedNet(failing.allocator(), 1, net)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedAllocationFailure;
    } else |err| try expect(err == error.OutOfMemory);
    try expect(failing.has_induced_failure);
    try expect(startup.isReady()); // published before the fallible constructor
    try expect(failing.allocated_bytes == failing.freed_bytes);
    var engine = try engine_mod.Engine.initWithSharedNet(allocator, 1, net);
    defer engine.deinit();
    try searchTwice(&engine);
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const net = try engine_mod.loadDefaultNet(allocator);
    defer net.destroy(allocator);
    try expect(!startup.isReady());
    if (std.mem.eql(u8, mode, "constructors")) {
        try concurrent(net, false);
    } else if (std.mem.eql(u8, mode, "tm-first")) {
        try concurrent(net, true);
    } else if (std.mem.eql(u8, mode, "tuning")) {
        try tuning(net);
    } else if (std.mem.eql(u8, mode, "failure-retry")) {
        try failureRetry(net);
    } else return error.UnknownMode;
    std.debug.print("search_init {s} PASS\n", .{mode});
}
