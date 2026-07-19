const std = @import("std");

pub const MAX_HISTORY: usize = 1024;

pub const History = struct {
    keys: [MAX_HISTORY]u64 = [_]u64{0} ** MAX_HISTORY,
    count: usize = 0,

    pub fn clear(self: *History) void {
        self.count = 0;
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

    // Search-style repetition detection: treat the current node as drawn once the
    // same side-to-move key has already appeared earlier inside the reversible window.
    // This is intentionally "one prior occurrence is enough" rather than a strict
    // game-history threefold claim test.
    pub fn isRepetition(self: *const History, halfmove_clock: u16) bool {
        return self.currentPriorOccurrenceCount(halfmove_clock) != 0;
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
        const max_back = @min(@as(usize, halfmove_clock), self.count - 1);
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
        const max_back = @min(@as(usize, halfmove_clock), self.count - 1);
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

    fn isRepetitionKey(self: *const History, key: u64, halfmove_clock: u16) bool {
        if (self.count < 2 or halfmove_clock < 4) return false;

        const max_back = @min(@as(usize, halfmove_clock), self.count);
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
