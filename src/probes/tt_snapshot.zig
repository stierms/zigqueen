//! Isolated correctness prototype; not imported by the engine build.
//! Every shared word is seq_cst. Clear/reinitialization require quiescence.
const std = @import("std");
const tt = @import("../search/tt.zig");
const moves = @import("../core/move.zig");
const Word = std.atomic.Value(u64);

pub const Packed = struct {
    key: u64,
    a: u64,
    b: u64,

    pub fn encode(e: tt.Entry) Packed {
        return .{
            .key = e.key,
            .a = @as(u32, @bitCast(e.score)) |
                (@as(u64, @as(u16, @bitCast(e.depth))) << 32) |
                (@as(u64, e.move_bits) << 48),
            .b = @as(u16, @bitCast(e.static_eval)) |
                (@as(u64, e.generation) << 16) |
                (@as(u64, @intFromEnum(e.bound)) << 24) |
                (@as(u64, @intFromBool(e.was_pv)) << 26),
        };
    }

    pub fn decode(p: Packed) ?tt.Entry {
        const bound: u2 = @truncate(p.b >> 24);
        const move_bits: u16 = @truncate(p.a >> 48);
        if (p.b >> 27 != 0 or bound == 3 or move_bits >> 12 > 12) return null;
        return .{
            .key = p.key,
            .score = @bitCast(@as(u32, @truncate(p.a))),
            .depth = @bitCast(@as(u16, @truncate(p.a >> 32))),
            .move_bits = move_bits,
            .static_eval = @bitCast(@as(u16, @truncate(p.b))),
            .generation = @truncate(p.b >> 16),
            .bound = @enumFromInt(bound),
            .was_pv = ((p.b >> 26) & 1) != 0,
        };
    }
};

const AtomicEntry = extern struct {
    key: Word = Word.init(0),
    a: Word = Word.init(Packed.encode(.{}).a),
    b: Word = Word.init(Packed.encode(.{}).b),

    fn load(self: *const AtomicEntry) Packed {
        return .{ .key = self.key.load(.seq_cst), .a = self.a.load(.seq_cst), .b = self.b.load(.seq_cst) };
    }

    fn store(self: *AtomicEntry, p: Packed) void {
        self.key.store(p.key, .seq_cst);
        self.a.store(p.a, .seq_cst);
        self.b.store(p.b, .seq_cst);
    }
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
    skip: enum { none, contended, retired, invalid_payload } = .none,
};

pub const Cluster = extern struct {
    sequence: Word align(64) = Word.init(0),
    slots: [2]AtomicEntry = .{ .{}, .{} },
    padding: u64 = 0,

    /// No retry: an overlapping writer may turn a useful hit into a miss.
    pub fn snapshot(self: *const Cluster) ?[2]tt.Entry {
        const before = self.sequence.load(.seq_cst);
        if (before & 1 != 0) return null;
        const raw = [2]Packed{ self.slots[0].load(), self.slots[1].load() };
        const after = self.sequence.load(.seq_cst);
        if (before != after) return null;
        return .{ raw[0].decode() orelse return null, raw[1].decode() orelse return null };
    }

    pub fn lookup(self: *const Cluster, key: u64) ?tt.Entry {
        const entries = self.snapshot() orelse return null;
        for (entries) |e| if (e.key == key and e.depth >= 0) return e;
        return null;
    }

    /// One CAS attempt, no cancellation/IO/allocation while owned.
    pub fn store(self: *Cluster, in: Input) Result {
        var result = Result{ .outcome = .{
            .current_generation = in.generation,
            .new_bound = in.bound,
            .new_had_move = in.mv != null,
        } };
        const before = self.sequence.load(.seq_cst);
        if (before & 1 != 0) {
            result.skip = .contended;
            return result;
        }
        if (before == std.math.maxInt(u64) - 1) {
            result.skip = .retired;
            return result;
        }
        if (self.sequence.cmpxchgStrong(before, before + 1, .seq_cst, .seq_cst) != null) {
            result.skip = .contended;
            return result;
        }
        defer self.sequence.store(before + 2, .seq_cst);
        // Read/select only AFTER taking ownership, including preserved static eval.
        var entries: [2]tt.Entry = undefined;
        for (&entries, &self.slots) |*entry, *slot| {
            entry.* = slot.load().decode() orelse {
                result.skip = .invalid_payload;
                return result;
            };
        }
        const victim_index = selectAndReplace(&entries, in, &result.outcome);
        if (victim_index) |i| self.slots[i].store(Packed.encode(entries[i]));
        return result;
    }
};

/// Matches the existing serial replacement policy; no shared access here.
fn selectAndReplace(entries: *[2]tt.Entry, in: Input, outcome: *tt.StoreOutcome) ?usize {
    var replacement: usize = 0;
    for (entries, 0..) |entry, i| {
        if (entry.key == in.key) {
            if (entry.generation == in.generation and entry.depth > in.depth) {
                outcome.skipped_same_generation_deeper = true;
                outcome.same_key = true;
                outcome.victim_generation = entry.generation;
                outcome.victim_depth = entry.depth;
                outcome.victim_bound = entry.bound;
                outcome.victim_had_move = entry.move_bits != 0;
                return null;
            }
            replacement = i;
            break;
        }
        if (entry.depth < 0) {
            replacement = i;
            break;
        }
        if (entry.generation != in.generation) {
            if (entries[replacement].generation == in.generation or entry.depth < entries[replacement].depth) replacement = i;
        } else if (entries[replacement].generation == in.generation and entry.depth < entries[replacement].depth) replacement = i;
    }
    const victim = entries[replacement];
    outcome.stored = true;
    outcome.same_key = victim.depth >= 0 and victim.key == in.key;
    outcome.empty_slot = victim.depth < 0;
    outcome.replaced_occupied = victim.depth >= 0 and !outcome.same_key;
    if (victim.depth >= 0) {
        outcome.victim_generation = victim.generation;
        outcome.victim_depth = victim.depth;
        outcome.victim_bound = victim.bound;
        outcome.victim_had_move = victim.move_bits != 0;
    }
    entries[replacement] = .{
        .key = in.key,
        .move_bits = if (in.mv) |m| @bitCast(m) else 0,
        .score = in.score,
        .depth = in.depth,
        .generation = in.generation,
        .bound = in.bound,
        .static_eval = if (in.static_eval == tt.STATIC_EVAL_NONE and outcome.same_key) victim.static_eval else in.static_eval,
        .was_pv = in.was_pv,
    };
    return replacement;
}

comptime {
    std.debug.assert(@sizeOf(AtomicEntry) == 24);
    std.debug.assert(@sizeOf(Cluster) == 64 and @alignOf(Cluster) == 64);
    std.debug.assert(@offsetOf(Cluster, "sequence") == 0 and @offsetOf(Cluster, "slots") == 8);
}
