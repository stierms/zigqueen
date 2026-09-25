//! Load-time column pairing for exact saturating-byte dot products.
const std = @import("std");

/// Swap budget of the pair repair (unchanged since the pair-permutation patch).
const PAIR_SWAP_CAP: usize = 8;
/// Swap budget of the grouped (four-byte lane) repair.
const GROUP_SWAP_CAP: usize = 32;
/// Byte span of one grouped kernel step: two 32-byte vpmaddubsw chunks whose
/// i16 lane results are summed before the single vpmaddwd widening.
pub const GROUP_SPAN: usize = 64;

pub const Permutation = struct {
    const Swap = struct { a: u16, b: u16 };
    swaps: [GROUP_SWAP_CAP]Swap = undefined,
    count: u8 = 0,
    ready: bool = false,
    /// Set only by `repairGrouped`: every four-byte lane group (see
    /// `groupColumns`) is proven overflow-free for i16 summation, which
    /// implies every byte pair is saturation-safe as well.
    grouped: bool = false,

    /// Activations and weights undergo the same sequence of transpositions.
    pub inline fn apply(self: *const Permutation, activation: []u8) void {
        for (self.swaps[0..self.count]) |s| {
            std.mem.swap(u8, &activation[s.a], &activation[s.b]);
        }
    }
};

fn safe(weights: []const i8, width: usize, rows: usize, a: usize, b: usize) bool {
    for (0..rows) |row| {
        const x: i16 = weights[row * width + a];
        const y: i16 = weights[row * width + b];
        // Each unsigned activation can independently reach 0 or255. These
        // bounds put every pair sum inside [-32640,32640], without saturation.
        if (@max(x, 0) + @max(y, 0) > 128 or @min(x, 0) + @min(y, 0) < -128) return false;
    }
    return true;
}

/// Repairs a private weight copy. On failure the copy may be partly permuted;
/// ready=false means callers MUST use their untouched original weights.
pub fn repair(weights: []i8, width: usize, rows: usize) Permutation {
    var result: Permutation = .{};
    if (width == 0 or width % 2 != 0 or width > std.math.maxInt(u16) or rows == 0 or weights.len != width * rows) return result;
    var a: usize = 0;
    while (a < width) : (a += 2) {
        if (safe(weights, width, rows, a, a + 1)) continue;
        if (result.count == PAIR_SWAP_CAP) return result;
        var b: usize = 0;
        while (b < width) : (b += 2) {
            if (a == b or !safe(weights, width, rows, a, b + 1) or !safe(weights, width, rows, b, a + 1)) continue;
            for (0..rows) |row| std.mem.swap(i8, &weights[row * width + a + 1], &weights[row * width + b + 1]);
            result.swaps[result.count] = .{ .a = @intCast(a + 1), .b = @intCast(b + 1) };
            result.count += 1;
            break;
        } else return result;
    }
    result.ready = true;
    return result;
}

/// The four weight columns that share one i16 lane in the grouped AVX2 kernel:
/// inside each 64-byte block, lane j of the low 32-byte chunk (bytes 2j, 2j+1)
/// is added lane-wise to lane j of the high chunk (bytes 32+2j, 32+2j+1).
fn groupColumns(group: usize) [4]usize {
    const block = (group / 16) * GROUP_SPAN;
    const lane = group % 16;
    return .{ block + 2 * lane, block + 2 * lane + 1, block + 32 + 2 * lane, block + 32 + 2 * lane + 1 };
}

fn groupOf(column: usize) usize {
    return (column / GROUP_SPAN) * 16 + ((column % 32) / 2);
}

/// Total bound excess of one lane group over all rows (0 = safe). Every u8
/// activation lies in [0,255]: the lane's true value (and every partial sum of
/// it, including each vpmaddubsw byte pair) lies in [255*neg, 255*pos], which
/// is inside [-32640,32640] exactly when pos <= 128 and neg >= -128 — then
/// neither the saturating pair step nor the wrapping i16 add can alter it.
fn groupExcess(weights: []const i8, width: usize, rows: usize, group: usize) i32 {
    const cols = groupColumns(group);
    var excess: i32 = 0;
    for (0..rows) |row| {
        var pos: i32 = 0;
        var neg: i32 = 0;
        for (cols) |c| {
            const w: i32 = weights[row * width + c];
            pos += @max(w, 0);
            neg += @min(w, 0);
        }
        excess += @max(pos - 128, 0) + @max(-128 - neg, 0);
    }
    return excess;
}

fn groupSafe(weights: []const i8, width: usize, rows: usize, group: usize) bool {
    return groupExcess(weights, width, rows, group) == 0;
}

fn swapColumns(weights: []i8, width: usize, rows: usize, u: usize, v: usize) void {
    for (0..rows) |row| std.mem.swap(i8, &weights[row * width + u], &weights[row * width + v]);
}

/// Repairs a private weight copy so that EVERY four-byte lane group is safe
/// (first-fit column transpositions, deterministic). A safe group implies both
/// of its byte pairs are safe, so the result is also a valid pair permutation.
/// On failure the copy may be partly permuted; ready=false means callers MUST
/// restore their original weights before using any other repair.
pub fn repairGrouped(weights: []i8, width: usize, rows: usize) Permutation {
    var result: Permutation = .{};
    if (width == 0 or width % GROUP_SPAN != 0 or width > std.math.maxInt(u16) or rows == 0 or weights.len != width * rows) return result;
    const groups = width / 4;
    for (0..groups) |g| {
        while (true) {
            const before = groupExcess(weights, width, rows, g);
            if (before == 0) break;
            if (result.count == GROUP_SWAP_CAP) return result;
            // Pass 0: first swap that makes g safe outright. Pass 1: first swap
            // that strictly lowers g's excess. Either way the partner group
            // must end safe, so already-repaired groups never regress, and the
            // strictly falling excess bounds the loop (with the swap cap).
            var found = false;
            pass: for (0..2) |pass| {
                for (groupColumns(g)) |u| {
                    for (0..width) |v| {
                        const h = groupOf(v);
                        if (h == g) continue;
                        swapColumns(weights, width, rows, u, v);
                        const after = groupExcess(weights, width, rows, g);
                        const accept = if (pass == 0) after == 0 else after < before;
                        if (accept and groupSafe(weights, width, rows, h)) {
                            result.swaps[result.count] = .{ .a = @intCast(u), .b = @intCast(v) };
                            result.count += 1;
                            found = true;
                            break :pass;
                        }
                        swapColumns(weights, width, rows, u, v);
                    }
                }
            }
            if (!found) return result;
        }
    }
    result.ready = true;
    result.grouped = true;
    return result;
}

test "byte-pair permutation preserves dots at all two-input extrema" {
    const original = [_]i8{ 127, 127, -128, -128, -128, -1, 127, 1 };
    var weights = original;
    const p = repair(&weights, 4, 2);
    try std.testing.expect(p.ready);
    try std.testing.expectEqual(@as(u8, 1), p.count);
    for (0..16) |mask| {
        var x: [4]u8 = undefined;
        for (&x, 0..) |*v, i| v.* = if (mask & (@as(usize, 1) << @intCast(i)) != 0) 255 else 0;
        const before = x;
        p.apply(&x);
        for (0..2) |row| {
            var expected: i32 = 0;
            var actual: i32 = 0;
            for (0..4) |i| {
                expected += @as(i32, before[i]) * original[row * 4 + i];
                actual += @as(i32, x[i]) * weights[row * 4 + i];
            }
            try std.testing.expectEqual(expected, actual);
            try std.testing.expect(safe(&weights, 4, 2, 0, 1));
            try std.testing.expect(safe(&weights, 4, 2, 2, 3));
        }
    }
}

test "unsafe byte-pair layouts fail closed and safe layouts need no swaps" {
    var impossible = [_]i8{127} ** 32;
    try std.testing.expect(!repair(&impossible, 32, 1).ready);
    var already_safe = [_]i8{ 127, -128, -128, 127 };
    const p = repair(&already_safe, 4, 1);
    try std.testing.expect(p.ready);
    try std.testing.expectEqual(@as(u8, 0), p.count);
    try std.testing.expect(!repair(&already_safe, 3, 1).ready);
}

test "byte-pair repair obeys its fixed swap capacity" {
    var weights: [36]i8 = undefined;
    for (&weights, 0..) |*w, i| w.* = if (i < 18) 127 else -128;
    const p = repair(&weights, 36, 1);
    try std.testing.expect(!p.ready);
    try std.testing.expectEqual(@as(u8, 8), p.count);
}

test "grouped repair makes every lane group safe and preserves dots at extremes" {
    const width = 128;
    const rows = 3;
    var original: [width * rows]i8 = undefined;
    for (0..rows) |row| {
        for (0..width) |i| original[row * width + i] = @intCast(@as(i32, @intCast((i * 13 + row * 5) % 9)) - 4);
    }
    // Force several unsafe groups: large same-sign weights sharing a lane
    // (each alone fits beside three small weights, so a repair exists).
    original[0] = 100;
    original[1] = 60;
    original[32] = 90;
    original[width + 2] = -100;
    original[width + 34] = -90;
    original[2 * width + 64] = 110;
    original[2 * width + 96] = 110;
    var weights = original;
    const p = repairGrouped(&weights, width, rows);
    try std.testing.expect(p.ready and p.grouped);
    for (0..width / 4) |g| try std.testing.expect(groupSafe(&weights, width, rows, g));
    var a: usize = 0;
    while (a < width) : (a += 2) try std.testing.expect(safe(&weights, width, rows, a, a + 1));
    for (0..8) |trial| {
        var x: [width]u8 = undefined;
        for (&x, 0..) |*v, i| v.* = if (trial == 0) 0 else if (trial == 1) 255 else @intCast((i * 151 + trial * 37) % 256);
        const before = x;
        p.apply(&x);
        for (0..rows) |row| {
            var expected: i32 = 0;
            var actual: i32 = 0;
            for (0..width) |i| {
                expected += @as(i32, before[i]) * original[row * width + i];
                actual += @as(i32, x[i]) * weights[row * width + i];
            }
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "grouped repair fails closed on impossible or misaligned layouts" {
    var impossible = [_]i8{127} ** 64;
    try std.testing.expect(!repairGrouped(&impossible, 64, 1).ready);
    var misaligned = [_]i8{1} ** 96;
    try std.testing.expect(!repairGrouped(&misaligned, 96, 1).ready);
    var already_safe = [_]i8{3} ** 64;
    const p = repairGrouped(&already_safe, 64, 1);
    try std.testing.expect(p.ready and p.grouped);
    try std.testing.expectEqual(@as(u8, 0), p.count);
}
