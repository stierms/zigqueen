const std = @import("std");

pub const MAX_HISTORY: usize = 1024;

pub const History = struct {
    keys: [MAX_HISTORY]u64 = [_]u64{0} ** MAX_HISTORY,
    count: usize = 0,
    /// Oldest index a repetition scan may compare against. A null move pushes
    /// its own key and raises the floor to that slot (`pushNullBoundary`): the
    /// board after a pass equals the board before it, so a tempo-losing odd
    /// cycle would otherwise let the pass child match a real pre-null position
    /// of the same side to move and score a draw that no legal line reaches.
    /// Cycles wholly after the pass still count.
    floor: usize = 0,
    /// Index of the search root's key; the engine sets it when a search
    /// starts. Keys below it are the game's history, keys from it on the line
    /// being searched (`repeatsOnlyBeforeRoot`).
    root: usize = 0,

    pub fn clear(self: *History) void {
        self.count = 0;
        self.floor = 0;
        self.root = 0;
    }

    /// Push the key of a null-move child and hide every earlier key from the
    /// repetition scans of the null subtree. Returns the floor to restore.
    pub fn pushNullBoundary(self: *History, key: u64) usize {
        const saved_floor = self.floor;
        self.push(key);
        self.floor = self.count - 1;
        return saved_floor;
    }

    /// Undo `pushNullBoundary` (nested boundaries restore in LIFO order).
    pub fn popNullBoundary(self: *History, saved_floor: usize) void {
        self.pop();
        self.floor = saved_floor;
    }

    pub fn push(self: *History, key: u64) void {
        std.debug.assert(self.count < self.keys.len);
        self.keys[self.count] = key;
        self.count += 1;
    }

    pub fn pop(self: *History) void {
        std.debug.assert(self.count > 0);
        self.count -= 1;
    }

    pub fn current(self: *const History) u64 {
        std.debug.assert(self.count > 0);
        return self.keys[self.count - 1];
    }

    // Search-style repetition detection: the same side-to-move key has already
    // appeared earlier inside the reversible window. One prior occurrence is
    // enough for this predicate; the search then asks `repeatsOnlyBeforeRoot`
    // whether that makes the node a draw or only lets the side to move take one.
    //
    // Same predicate as currentPriorOccurrenceCount(...) != 0, as an early-exit
    // scan. The counting form is a reduction LLVM vectorizes (strided gathers,
    // 4x unrolled ymm); inlined into every negamax/qsearch entry, that loop used
    // all sixteen vector registers, so on Windows x64 (xmm6-15 callee-saved)
    // both recursive functions saved and restored ten xmm registers per call
    // and realigned their frames to 32 bytes for the spills.
    pub fn isRepetition(self: *const History, halfmove_clock: u16) bool {
        if (self.count < 3 or halfmove_clock < 4) return false;

        const current_key = self.current();
        const max_back = @min(@as(usize, halfmove_clock), self.count - 1 - self.floor);
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            if (self.keys[self.count - 1 - back] == current_key) return true;
        }
        return false;
    }

    /// For a key `isRepetitionForKey` accepted: true when its only earlier
    /// occurrence in the reversible window lies before the search root.
    ///
    /// A position that returns to one of the search line itself (the root
    /// included) is a cycle both sides chose inside the search, and a third
    /// occurrence is a claimable draw: both stay draws. A second occurrence
    /// whose first is a game-history position is neither. Nobody can claim it,
    /// and either side may leave the cycle: after `7k/8/5KQ1/8/8/8/8/8 w` and
    /// Qh6+ Kg8 Qg6+, the reply Kh8 repeats the start position, where White
    /// mates with Qg7 instead of repeating (code-read finding 4, 2026-11-10).
    /// With the root side's opponent to move, the search scores such a node as
    /// the better of a draw and its search value (root.searchTwofold): the
    /// opponent takes the draw when it is worse off, so the root side still
    /// avoids walking back into old positions when it is ahead, but it no
    /// longer counts on a draw the opponent can decline. With the root side
    /// to move the node stays a draw: the root side does not count on more
    /// than a draw once the opponent can return to an old position, which is
    /// the other half of what keeps a won game moving. Searching both kinds
    /// cost conversion (52.8% against 54.1% at 5k nodes, 906 games); this
    /// form keeps it (54.4%).
    pub fn repeatsOnlyBeforeRoot(self: *const History, key: u64, halfmove_clock: u16) bool {
        // Same window and stride as isRepetition / isRepetitionKey.
        const pushed = self.count != 0 and self.current() == key;
        const top = if (pushed) self.count - 1 else self.count;
        if (top < 2 or top < self.floor) return false;
        const max_back = @min(@as(usize, halfmove_clock), top - self.floor);
        var matches: usize = 0;
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            const index = top - back;
            if (self.keys[index] != key) continue;
            if (index >= self.root) return false;
            matches += 1;
        }
        return matches == 1;
    }

    // Root adjudication must be stricter than interior search nodes. A root position
    // with one prior occurrence is only a twofold repetition; returning immediately
    // would skip search and choose the fallback first legal move. Claimable threefold
    // requires the current key plus at least two prior same-side occurrences.
    pub fn isClaimableCurrentRepetition(self: *const History, halfmove_clock: u16) bool {
        return self.currentPriorOccurrenceCount(halfmove_clock) >= 2;
    }

    pub fn currentPriorOccurrenceCount(self: *const History, halfmove_clock: u16) usize {
        if (self.count < 3 or halfmove_clock < 4) return 0;

        const current_key = self.current();
        const max_back = @min(@as(usize, halfmove_clock), self.count - 1 - self.floor);
        var matches: usize = 0;
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            if (self.keys[self.count - 1 - back] == current_key) matches += 1;
        }
        return matches;
    }

    pub fn currentPreviousCycleChildKey(self: *const History, halfmove_clock: u16) ?u64 {
        if (self.count < 3 or halfmove_clock < 4) return null;

        const current_key = self.current();
        const max_back = @min(@as(usize, halfmove_clock), self.count - 1 - self.floor);
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            const prior_index = self.count - 1 - back;
            if (self.keys[prior_index] == current_key) return self.keys[prior_index + 1];
        }
        return null;
    }

    // Probe a freshly reached child key before it is pushed into the history stack.
    // The lookup still only checks same-side parity within the reversible window.
    pub fn isRepetitionForKey(self: *const History, key: u64, halfmove_clock: u16) bool {
        if (self.count == 0) return false;
        if (self.current() == key) return self.isRepetition(halfmove_clock);
        return self.isRepetitionKey(key, halfmove_clock);
    }

    /// How often a freshly reached child key (not pushed yet) already occurred
    /// with the same side to move inside the reversible window, the same scan
    /// as `isRepetitionForKey`: 1 makes the child a twofold, 2 or more a third
    /// occurrence the opponent can claim as a draw. Root policy only.
    pub fn childOccurrences(self: *const History, key: u64, halfmove_clock: u16) usize {
        if (self.count < 2 or halfmove_clock < 4) return 0;

        const max_back = @min(@as(usize, halfmove_clock), self.count);
        var matches: usize = 0;
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            if (self.keys[self.count - back] == key) matches += 1;
        }
        return matches;
    }

    /// Whether some position of the reversible window ending at the current
    /// one (the last min(halfmove_clock, count - 1) plies and the current
    /// position) already occurs there twice or more, with the same side to
    /// move. Root policy only: then a later reply can complete a third
    /// occurrence the opponent may claim.
    pub fn windowHasRepetition(self: *const History, halfmove_clock: u16) bool {
        if (self.count < 3 or halfmove_clock < 4) return false;

        const first = self.count - 1 - @min(@as(usize, halfmove_clock), self.count - 1);
        var earlier = first;
        while (earlier + 2 < self.count) : (earlier += 1) {
            var later = earlier + 2;
            while (later < self.count) : (later += 2) {
                if (self.keys[later] == self.keys[earlier]) return true;
            }
        }
        return false;
    }

    fn isRepetitionKey(self: *const History, key: u64, halfmove_clock: u16) bool {
        if (self.count < 2 or halfmove_clock < 4) return false;

        const max_back = @min(@as(usize, halfmove_clock), self.count - self.floor);
        var back: usize = 2;
        while (back <= max_back) : (back += 2) {
            if (self.keys[self.count - back] == key) return true;
        }
        return false;
    }
};

test "history detects repeated side-to-move keys" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(1);
    history.push(2);
    history.push(1);

    try std.testing.expect(history.isRepetition(4));
}

test "a single earlier occurrence before the root is told apart from a cycle and a third occurrence" {
    var history = History{};
    // Game history 1 2 3 4, root at key 5 (index 4).
    for ([_]u64{ 1, 2, 3, 4, 5 }) |key| history.push(key);
    history.root = 4;
    // The search plays into key 2 and then key 1: second occurrence of a game position.
    history.push(2);
    history.push(1);
    try std.testing.expect(history.isRepetitionForKey(1, 8));
    try std.testing.expect(history.repeatsOnlyBeforeRoot(1, 8));
    // Not pushed yet: the same answer for the child key.
    history.pop();
    try std.testing.expect(history.isRepetitionForKey(1, 8));
    try std.testing.expect(history.repeatsOnlyBeforeRoot(1, 8));
    history.push(1);
    // The search line returns to the root's key: a cycle inside the search.
    history.push(6);
    history.push(5);
    try std.testing.expect(history.isRepetitionForKey(5, 8));
    try std.testing.expect(!history.repeatsOnlyBeforeRoot(5, 8));
    // A key the search line itself already visited (index 6) and the game too (index 0).
    history.push(7);
    history.push(1);
    try std.testing.expect(!history.repeatsOnlyBeforeRoot(1, 10));

    // Two game-history occurrences: the third occurrence is claimable.
    var third = History{};
    for ([_]u64{ 1, 2, 1, 2, 3 }) |key| third.push(key);
    third.root = 4;
    third.push(4);
    third.push(1);
    try std.testing.expect(third.isRepetitionForKey(1, 8));
    try std.testing.expect(!third.repeatsOnlyBeforeRoot(1, 8));
    // Outside the reversible window the older occurrence does not count.
    try std.testing.expect(third.repeatsOnlyBeforeRoot(1, 4));

    // Without a root set (root 0) every occurrence is part of the search line.
    var plain = History{};
    for ([_]u64{ 1, 2, 1 }) |key| plain.push(key);
    try std.testing.expect(plain.isRepetitionForKey(1, 4));
    try std.testing.expect(!plain.repeatsOnlyBeforeRoot(1, 4));
}

test "claimable current repetition requires two prior same-side occurrences" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(1);

    try std.testing.expect(history.isRepetition(4));
    try std.testing.expect(!history.isClaimableCurrentRepetition(4));

    history.push(2);
    history.push(1);
    try std.testing.expect(history.isClaimableCurrentRepetition(4));
}

test "child occurrences count same-side keys inside the reversible window" {
    var history = History{};
    for ([_]u64{ 1, 2, 3, 4, 1, 2, 3, 4 }) |key| history.push(key);
    // The child of the current position (key 4) lands with key 1's side to move.
    try std.testing.expectEqual(@as(usize, 2), history.childOccurrences(1, 8));
    try std.testing.expectEqual(@as(usize, 1), history.childOccurrences(1, 4));
    try std.testing.expectEqual(@as(usize, 0), history.childOccurrences(1, 3));
    // Wrong side to move, or a key never seen.
    try std.testing.expectEqual(@as(usize, 0), history.childOccurrences(2, 8));
    try std.testing.expectEqual(@as(usize, 0), history.childOccurrences(9, 8));
    // Agrees with the search's one-occurrence predicate.
    try std.testing.expect(history.isRepetitionForKey(1, 8));
    try std.testing.expect(!history.isRepetitionForKey(9, 8));
}

test "window repetition finds any same-side key repeated inside the reversible window" {
    var history = History{};
    for ([_]u64{ 1, 2, 3, 4, 1, 5, 6 }) |key| history.push(key);
    // Key 1 at indices 0 and 4: inside the window from clock 6 on.
    try std.testing.expect(history.windowHasRepetition(6));
    try std.testing.expect(history.windowHasRepetition(100));
    try std.testing.expect(!history.windowHasRepetition(5));
    try std.testing.expect(!history.windowHasRepetition(3));
    // Opposite side to move (odd distance) is no repetition.
    var parity = History{};
    for ([_]u64{ 1, 2, 3, 1, 5 }) |key| parity.push(key);
    try std.testing.expect(!parity.windowHasRepetition(100));
    // The current position itself counts, as the later occurrence.
    var current = History{};
    for ([_]u64{ 7, 2, 3, 4, 7 }) |key| current.push(key);
    try std.testing.expect(current.windowHasRepetition(4));
    // Agrees with a brute-force pair count over random short histories.
    var prng = std.Random.DefaultPrng.init(0x51de_3a7c);
    const rand = prng.random();
    for (0..4000) |_| {
        var random = History{};
        const len = rand.intRangeAtMost(usize, 0, 40);
        for (0..len) |_| random.push(rand.intRangeAtMost(u64, 1, 6));
        const clock = rand.intRangeAtMost(u16, 0, 50);
        var expected = false;
        if (random.count >= 3 and clock >= 4) {
            const first = random.count - 1 - @min(@as(usize, clock), random.count - 1);
            for (first..random.count) |i| {
                for (i + 1..random.count) |j| {
                    if ((j - i) % 2 == 0 and random.keys[i] == random.keys[j]) expected = true;
                }
            }
        }
        try std.testing.expectEqual(expected, random.windowHasRepetition(clock));
    }
}

test "current repetition exposes previous cycle child key" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(3);
    history.push(4);
    history.push(1);

    try std.testing.expectEqual(@as(?u64, 2), history.currentPreviousCycleChildKey(8));
    try std.testing.expectEqual(@as(?u64, null), history.currentPreviousCycleChildKey(2));
}

test "early-exit repetition scan matches the prior-occurrence count" {
    var prng = std.Random.DefaultPrng.init(0x7e9e_7171);
    const rand = prng.random();
    for (0..4000) |_| {
        var history = History{};
        const len = rand.intRangeAtMost(usize, 0, 96);
        // Few distinct keys, so repetitions at every distance and parity occur.
        for (0..len) |_| history.push(rand.intRangeAtMost(u64, 1, 4));
        const halfmove_clock = rand.intRangeAtMost(u16, 0, 120);
        try std.testing.expectEqual(
            history.currentPriorOccurrenceCount(halfmove_clock) != 0,
            history.isRepetition(halfmove_clock),
        );
    }
}

test "history ignores positions beyond halfmove window" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(1);
    history.push(2);
    history.push(1);

    try std.testing.expect(!history.isRepetition(2));
}

test "history can test an explicit current key without pushing it" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(1);
    history.push(2);

    try std.testing.expect(history.isRepetitionForKey(1, 4));
    try std.testing.expect(!history.isRepetitionForKey(3, 4));
}

test "history repetition ignores opposite-side parity matches" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(3);
    history.push(1);

    try std.testing.expect(!history.isRepetition(6));
}

test "explicit child-key repetition probe follows same-side parity" {
    var history = History{};
    history.push(1);
    history.push(2);
    history.push(3);
    history.push(4);

    try std.testing.expect(history.isRepetitionForKey(1, 6));
    try std.testing.expect(!history.isRepetitionForKey(2, 6));
}

test "null boundary hides pre-null keys and restores them, nested" {
    var history = History{};
    for ([_]u64{ 10, 11, 12, 13, 14, 15 }) |key| history.push(key);
    // The unpushed pass child of 15 carries key 10 (an odd cycle): the scan
    // matches it against slot 0, a position before the pass.
    try std.testing.expect(history.isRepetitionForKey(10, 6));

    const outer = history.pushNullBoundary(10);
    try std.testing.expectEqual(@as(usize, 0), outer);
    try std.testing.expect(!history.isRepetitionForKey(10, 7));
    try std.testing.expect(!history.isRepetition(7));
    try std.testing.expectEqual(@as(usize, 0), history.currentPriorOccurrenceCount(7));
    // A cycle wholly after the pass still repeats: pass child -> 21 -> 10.
    history.push(21);
    try std.testing.expect(history.isRepetitionForKey(10, 9));
    history.push(10);
    try std.testing.expect(history.isRepetition(9));

    // A second pass inside the first subtree hides the first one's slots too.
    history.push(22);
    // Key 10 sits two plies back (slot 8): visible without the inner floor.
    const inner = history.pushNullBoundary(10);
    try std.testing.expectEqual(@as(usize, 6), inner);
    try std.testing.expect(!history.isRepetitionForKey(10, 11));
    history.popNullBoundary(inner);
    try std.testing.expectEqual(@as(usize, 6), history.floor);
    history.pop();
    try std.testing.expect(history.isRepetition(9));

    history.pop();
    history.pop();
    history.popNullBoundary(outer);
    try std.testing.expectEqual(@as(usize, 0), history.floor);
    try std.testing.expectEqual(@as(usize, 6), history.count);
    try std.testing.expect(history.isRepetitionForKey(10, 6));
}

test "null boundary on a real odd cycle: the pass child is not a repetition" {
    const fen = @import("../core/fen.zig");
    const legal = @import("../movegen/legal.zig");
    const make_unmake = @import("../movegen/make_unmake.zig");
    const move_mod = @import("../core/move.zig");

    // Rook 3-cycle while the king shuffles: after the pass, the board and side
    // to move equal the start position (judge C repro, key 672636ef6c95ffa0).
    var pos = try fen.parse("7k/8/8/8/8/8/8/KR6 b - - 0 1");
    var history = History{};
    history.push(pos.zobrist_key);
    const start_key = pos.zobrist_key;
    for ([_][]const u8{ "h8g8", "a1a2", "g8h7", "a2a1", "h7h8" }) |text| {
        var moves = move_mod.MoveList.init();
        legal.generate(&pos, &moves);
        var played = false;
        for (moves.slice()) |mv| {
            var buffer: [5]u8 = undefined;
            if (std.mem.eql(u8, mv.toUci(&buffer), text)) {
                var state = make_unmake.StateInfo{};
                history.push(make_unmake.makeMove(&pos, mv, &state));
                played = true;
                break;
            }
        }
        try std.testing.expect(played);
    }
    try std.testing.expect(!history.isRepetition(pos.halfmove_clock));

    var null_state = make_unmake.StateInfo{};
    make_unmake.makeNullMove(&pos, &null_state);
    try std.testing.expectEqual(start_key, pos.zobrist_key);
    // Without the boundary the pass child "repeats" the start position.
    try std.testing.expect(history.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock));

    const saved = history.pushNullBoundary(pos.zobrist_key);
    try std.testing.expect(!history.isRepetitionForKey(pos.zobrist_key, pos.halfmove_clock));
    history.popNullBoundary(saved);
    make_unmake.unmakeNullMove(&pos, &null_state);
    try std.testing.expectEqual(@as(usize, 6), history.count);
}
