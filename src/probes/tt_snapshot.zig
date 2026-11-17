//! Shared access to a transposition-table cluster (tt.Cluster): a sequence
//! lock in the cluster's 32-bit sequence word around its five entries.
//! Every shared word is read and written atomically, seq_cst. Clear and
//! reinitialization require quiescence (shared_tt.zig).
//!
//! A reader takes the sequence, the tags and the entry words, and the sequence
//! again: an odd or changed sequence is a miss, never a retry. A writer makes
//! the sequence odd with one compare-and-swap (a lost race is a skipped
//! store), writes one tag and one word, and adds one more. The sequence wraps
//! modulo 2^32 with its parity intact; a reader is fooled only by exactly 2^31
//! completed stores to one cluster between its two reads of the sequence.
const std = @import("std");
const tt = @import("../search/tt.zig");
const moves = @import("../core/move.zig");

pub const Cluster = tt.Cluster;
pub const WAYS = tt.WAYS;

/// The cluster's entries as one coherent copy.
pub const Slots = struct {
    tags: [WAYS]tt.Tag,
    data: [WAYS]u64,
};

pub const Input = struct {
    key: u64,
    depth: i16,
    score: i32,
    bound: tt.Bound,
    mv: ?moves.Move,
    static_eval: i16,
    was_pv: bool,
    generation: u8,
};

pub const Result = struct {
    outcome: tt.StoreOutcome,
    skip: enum { none, contended, invalid_payload } = .none,
};

inline fn loadSlots(cluster: *const Cluster) Slots {
    var slots: Slots = undefined;
    inline for (0..WAYS) |way| {
        slots.tags[way] = @atomicLoad(tt.Tag, &cluster.tags[way], .seq_cst);
        slots.data[way] = @atomicLoad(u64, &cluster.data[way], .seq_cst);
    }
    return slots;
}

/// An occupied slot must hold a word the table wrote.
inline fn slotsAreValid(slots: *const Slots) bool {
    var valid = true;
    inline for (0..WAYS) |way| {
        valid = valid and (slots.tags[way] == 0 or tt.wordIsValid(slots.data[way]));
    }
    return valid;
}

/// No retry: an overlapping writer may turn a useful hit into a miss.
pub fn snapshot(cluster: *const Cluster) ?Slots {
    const before = @atomicLoad(u32, &cluster.sequence, .seq_cst);
    if (before & 1 != 0) return null;
    const slots = loadSlots(cluster);
    const after = @atomicLoad(u32, &cluster.sequence, .seq_cst);
    if (before != after) return null;
    if (!slotsAreValid(&slots)) return null;
    return slots;
}

/// The entry under `tag` in the cluster, read by a search of `generation`.
pub fn lookup(cluster: *const Cluster, tag: tt.Tag, generation: u8) ?tt.Entry {
    const slots = snapshot(cluster) orelse return null;
    inline for (0..WAYS) |way| {
        if (slots.tags[way] == tag) return tt.unpack(slots.data[way], generation);
    }
    return null;
}

/// `lookup` for a search's own probe: with `refresh`, an entry of an earlier
/// search becomes one of this search. One compare-and-swap of the entry's
/// word, outside the lock: it changes the generation bits of the word the
/// reader saw and nothing else, and fails if a writer has replaced the word
/// since (a word of this search never equals one of an earlier search).
pub fn probe(cluster: *Cluster, tag: tt.Tag, generation: u8, refresh: bool) ?tt.Entry {
    const slots = snapshot(cluster) orelse return null;
    inline for (0..WAYS) |way| {
        if (slots.tags[way] == tag) {
            const word = slots.data[way];
            if (refresh and tt.wordAge(word, generation) != 0) {
                _ = @cmpxchgStrong(u64, &cluster.data[way], word, tt.withGeneration(word, generation), .seq_cst, .seq_cst);
            }
            return tt.unpack(word, generation);
        }
    }
    return null;
}

/// One CAS attempt, no cancellation/IO/allocation while owned.
pub fn store(cluster: *Cluster, in: Input, policy: tt.Policy) Result {
    var result = Result{ .outcome = .{
        .current_generation = in.generation,
        .new_bound = in.bound,
        .new_had_move = in.mv != null,
    } };
    const before = @atomicLoad(u32, &cluster.sequence, .seq_cst);
    if (before & 1 != 0) {
        result.skip = .contended;
        return result;
    }
    if (@cmpxchgStrong(u32, &cluster.sequence, before, before +% 1, .seq_cst, .seq_cst) != null) {
        result.skip = .contended;
        return result;
    }
    defer @atomicStore(u32, &cluster.sequence, before +% 2, .seq_cst);
    // Read/select only AFTER taking ownership, including preserved static eval.
    const slots = loadSlots(cluster);
    if (!slotsAreValid(&slots)) {
        result.skip = .invalid_payload;
        return result;
    }
    const tag = tt.tagFor(in.key, policy);
    // The serial table's replacement rule; no shared access in it.
    const way = tt.chooseWay(&slots.tags, &slots.data, tag, tt.packedDepth(in.depth), in.generation, &result.outcome) orelse return result;
    const word = tt.wordFor(.{
        .move_bits = if (in.mv) |m| @bitCast(m) else 0,
        .score = in.score,
        .depth = in.depth,
        .bound = in.bound,
        .static_eval = in.static_eval,
        .was_pv = in.was_pv,
        .generation = in.generation,
    }, result.outcome.same_key, slots.data[way], policy.keep_move);
    @atomicStore(u64, &cluster.data[way], word, .seq_cst);
    @atomicStore(tt.Tag, &cluster.tags[way], tag, .seq_cst);
    return result;
}

/// Occupied slots of the cluster, or null while a writer owns it.
pub fn occupied(cluster: *const Cluster) ?usize {
    const slots = snapshot(cluster) orelse return null;
    var used: usize = 0;
    inline for (0..WAYS) |way| used += @intFromBool(slots.tags[way] != 0);
    return used;
}

fn testInput(tag: u16, step: usize, generation: u8) Input {
    return .{
        .key = tt.keyFor(0, 1, tag),
        .depth = @intCast(step % 50),
        // The score and the eval name the tag: an entry found under a tag
        // must carry them, whichever store wrote it.
        .score = tag,
        .bound = @enumFromInt(step % 3),
        .mv = if (step % 4 == 0) null else @bitCast(@as(u16, @intCast(1 + step % 4095))),
        .static_eval = @intCast(tag + 1),
        .was_pv = step & 1 != 0,
        .generation = generation,
    };
}

test "shared cluster stores match the serial table, outcome and contents, across generation wraps" {
    try expectSharedMatchesSerial(.{});
}

test "shared cluster stores match the serial table under the other keep_move policy (tuning flavour)" {
    // The serial table reads its policy in the tuning flavour only; the
    // release flavour has the default whatever the policy says.
    const tuning = @import("build_options").tuning;
    try expectSharedMatchesSerial(.{ .keep_move = if (tuning) !tt.KEEP_MOVE_DEFAULT else tt.KEEP_MOVE_DEFAULT });
}

fn expectSharedMatchesSerial(policy: tt.Policy) !void {
    var serial = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer serial.deinit();
    serial.policy = policy;
    var cluster = Cluster{};
    var rng = std.Random.DefaultPrng.init(0x5ea1_c0de);
    const r = rng.random();
    const count = serial.clusters.len;
    for (0..40_000) |step| {
        if (step % 19 == 0) serial.newSearch();
        const in = Input{
            // Nine positions compete for the five slots of cluster 0.
            .key = tt.keyFor(0, count, 1 + r.uintLessThan(u16, 9)),
            .depth = r.intRangeAtMost(i16, -1, 300),
            .score = r.intRangeAtMost(i32, -29_000, 29_000),
            .bound = @enumFromInt(r.uintLessThan(u2, 3)),
            .mv = if (step % 3 == 0) null else moves.Move.init(.a1, .b1, .quiet),
            .static_eval = if (step % 2 == 0) tt.STATIC_EVAL_NONE else r.intRangeAtMost(i16, -32_700, 32_700),
            .was_pv = r.boolean(),
            .generation = serial.generation,
        };
        const expected = serial.storeWithOutcome(in.key, in.depth, in.score, in.bound, in.mv, in.static_eval, in.was_pv);
        const actual = store(&cluster, in, policy);
        try std.testing.expectEqual(.none, actual.skip);
        try std.testing.expectEqualDeep(expected, actual.outcome);
        const slots = snapshot(&cluster).?;
        try std.testing.expectEqualSlices(tt.Tag, &serial.clusters[0].tags, &slots.tags);
        try std.testing.expectEqualSlices(u64, &serial.clusters[0].data, &slots.data);
        try std.testing.expectEqualDeep(serial.lookup(in.key), lookup(&cluster, tt.tagOf(in.key), in.generation));
    }
    // The serial table never touches the sequence word; every shared store
    // left it even.
    try std.testing.expectEqual(@as(u32, 0), serial.clusters[0].sequence);
    try std.testing.expectEqual(@as(u32, 0), cluster.sequence & 1);
}

test "a shared cluster stays bounded under an owner, at the sequence wrap and with a foreign word" {
    var cluster = Cluster{};
    const first = testInput(1000, 7, 5);
    try std.testing.expect(lookup(&cluster, 1000, 5) == null);
    try std.testing.expect(store(&cluster, first, .{}).outcome.stored);
    try std.testing.expectEqual(@as(i32, 1000), lookup(&cluster, 1000, 5).?.score);
    const before = cluster.data;
    // A paused owner: readers miss, writers skip, nobody spins or writes.
    @atomicStore(u32, &cluster.sequence, 3, .seq_cst);
    try std.testing.expect(snapshot(&cluster) == null);
    try std.testing.expect(lookup(&cluster, 1000, 5) == null);
    try std.testing.expect(probe(&cluster, 1000, 6, true) == null);
    try std.testing.expect(occupied(&cluster) == null);
    try std.testing.expectEqual(.contended, store(&cluster, testInput(1001, 8, 5), .{}).skip);
    try std.testing.expectEqualSlices(u64, &before, &cluster.data);
    try std.testing.expectEqual(@as(u32, 3), cluster.sequence);
    // The sequence wraps with its parity: the last even value is followed by 0.
    @atomicStore(u32, &cluster.sequence, std.math.maxInt(u32) - 1, .seq_cst);
    try std.testing.expect(store(&cluster, testInput(1001, 8, 5), .{}).outcome.stored);
    try std.testing.expectEqual(@as(u32, 0), cluster.sequence);
    try std.testing.expect(store(&cluster, testInput(1002, 9, 5), .{}).outcome.stored);
    try std.testing.expectEqual(@as(u32, 2), cluster.sequence);
    try std.testing.expectEqual(@as(?usize, 3), occupied(&cluster));
    try std.testing.expectEqual(@as(i32, 1002), lookup(&cluster, 1002, 5).?.score);
    // A probe of a later search: the entry comes back as it was found, and
    // only with `refresh` is it one of that search afterwards. The sequence
    // word is not touched.
    try std.testing.expectEqual(@as(u8, 5), probe(&cluster, 1002, 7, false).?.generation);
    try std.testing.expectEqual(@as(u8, 5), lookup(&cluster, 1002, 7).?.generation);
    try std.testing.expectEqual(@as(u8, 5), probe(&cluster, 1002, 7, true).?.generation);
    try std.testing.expectEqual(@as(u8, 7), lookup(&cluster, 1002, 7).?.generation);
    try std.testing.expectEqual(@as(i32, 1002), lookup(&cluster, 1002, 7).?.score);
    try std.testing.expectEqual(@as(u8, 5), lookup(&cluster, 1001, 7).?.generation);
    try std.testing.expectEqual(@as(u32, 2), cluster.sequence);
    // A word no store wrote (a bound that does not exist) in an occupied
    // slot: a miss for readers, a skip for writers, and the lock is released.
    cluster = .{};
    cluster.tags[2] = 7;
    cluster.data[2] = @as(u64, 3) << tt.BOUND_SHIFT;
    try std.testing.expect(snapshot(&cluster) == null);
    try std.testing.expectEqual(.invalid_payload, store(&cluster, first, .{}).skip);
    try std.testing.expectEqual(@as(u32, 2), cluster.sequence);
    // The same word in an empty slot is no entry.
    cluster.tags[2] = 0;
    try std.testing.expect(snapshot(&cluster) != null);
    try std.testing.expect(store(&cluster, first, .{}).outcome.stored);
}

const ContendedTask = struct {
    cluster: *Cluster,
    start: *std.atomic.Value(bool),
    ready: *std.atomic.Value(u32),
    id: u32,
    accepted: usize = 0,
    skipped: usize = 0,
    failed: bool = false,

    const GENERATION: u8 = 9;
    const TAGS: u16 = 16;

    fn run(self: *ContendedTask) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        for (0..20_000) |step| {
            const tag: u16 = 1000 + @as(u16, @intCast((step * 7 + self.id) % TAGS));
            if (self.id < 4) {
                // Half the writers store as the search before the readers',
                // whose refreshing probes then race with the stores.
                const result = store(self.cluster, testInput(tag, step, GENERATION - @as(u8, @intCast(self.id & 1))), .{});
                if (result.skip == .none) self.accepted += 1 else self.skipped += 1;
                if (result.skip == .invalid_payload) self.failed = true;
            } else {
                const e = probe(self.cluster, tag, GENERATION, true) orelse {
                    self.skipped += 1;
                    continue;
                };
                self.accepted += 1;
                if (e.score != tag or e.static_eval != tag + 1 or e.depth >= 50 or
                    (e.generation != GENERATION and e.generation != GENERATION - 1)) self.failed = true;
            }
        }
    }
};

test "contended writers of sixteen positions never publish a tag with another position's entry" {
    var cluster = Cluster{};
    // Something to find before the first writer runs: on one busy core the
    // readers can finish their loops first.
    for (0..WAYS) |i| _ = store(&cluster, testInput(@intCast(1000 + i), i, ContendedTask.GENERATION - 1), .{});
    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u32).init(0);
    var tasks: [8]ContendedTask = undefined;
    var threads: [8]?std.Thread = @splat(null);
    defer {
        start.store(true, .release);
        for (threads) |thread| if (thread) |t| t.join();
    }
    for (&threads, &tasks, 0..) |*thread, *task, id| {
        task.* = .{ .cluster = &cluster, .start = &start, .ready = &ready, .id = @intCast(id) };
        thread.* = try std.Thread.spawn(.{}, ContendedTask.run, .{task});
    }
    while (ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
    start.store(true, .release);
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    var writes: usize = 0;
    for (tasks) |task| {
        try std.testing.expectEqual(false, task.failed);
        if (task.id < 4) writes += task.accepted;
    }
    // Some store always gets the lock. How many probes get through is the
    // scheduler's: a reader can run its whole loop while a descheduled writer
    // holds the lock, so the readers' count is not asserted; the probes below
    // are.
    try std.testing.expect(writes > 0);
    try std.testing.expectEqual(@as(u32, 0), cluster.sequence & 1);
    // Quiescent: every slot is occupied, holds its own position's entry, and
    // a probe finds it.
    const slots = snapshot(&cluster).?;
    for (slots.tags, slots.data) |tag, word| {
        try std.testing.expect(tag != 0);
        try std.testing.expectEqual(@as(i32, @intCast(tag)), tt.unpack(word, ContendedTask.GENERATION).score);
        try std.testing.expectEqual(@as(i32, @intCast(tag)), probe(&cluster, tag, ContendedTask.GENERATION, true).?.score);
    }
}
