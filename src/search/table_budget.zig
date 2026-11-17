//! How UCI Hash is divided. Hash is the memory of the engine's Hash-sized
//! tables together: the transposition table and the raw-eval caches (one per
//! search thread). Nothing else is sized from it.

const std = @import("std");
const hugealloc = @import("../util/hugealloc.zig");

const KIB: u64 = 1024;
const MIB: u64 = 1024 * KIB;

/// Search threads the engine supports (parallel_pool.MAX_THREADS); the
/// budget holds for every Hash at every count up to it.
pub const MAX_THREADS: u32 = 32;

/// The eval caches' share of Hash is Hash / EVAL_SHARE_DIVISOR, rounded down
/// to a power of two, at most EVAL_MAX_KB. The share buys speed only (a hit
/// saves one network evaluation); the rest of Hash buys table entries. A
/// quarter, up to 64 MB, is what the caches had before they were counted
/// inside Hash; at 30M nodes per move half of that costs 2.2% more
/// evaluations and twice it saves 0.9% (docs/research/roadmap-20261111/table.md).
pub const EVAL_SHARE_DIVISOR: u64 = 4;
pub const EVAL_MAX_KB: u32 = 64 * 1024;
/// The smallest cache there is (64 sets). No supported setting needs it: the
/// smallest share, Hash 1 split among MAX_THREADS engines, is 8 KB each.
pub const EVAL_MIN_KB: u32 = 4;

/// Kilobytes of all eval caches together at this Hash.
pub fn evalKbTotal(hash_mb: u32) u32 {
    const share_kb = @as(u64, hash_mb) * KIB / EVAL_SHARE_DIVISOR;
    return @intCast(std.math.floorPowerOfTwo(u64, std.math.clamp(share_kb, EVAL_MIN_KB, EVAL_MAX_KB)));
}

/// Kilobytes of one engine's eval cache when `threads` engines search: an
/// equal share of the total, rounded down to a power of two, so all of them
/// together never take more than the total.
pub fn evalKbPerEngine(hash_mb: u32, threads: u32) u32 {
    const share = evalKbTotal(hash_mb) / @max(threads, 1);
    return std.math.floorPowerOfTwo(u32, @max(share, EVAL_MIN_KB));
}

/// Bytes of the transposition table at this Hash, whatever the thread count:
/// Hash less the eval caches' total, and from one huge page on rounded down
/// to whole huge pages, because that is how the allocator backs it
/// (hugealloc.backedBytes): the table is exactly what is mapped. Up to one
/// huge page of Hash stays unused where the rest is not a whole number of
/// them (Hash 3, 4, 6 and the odd values from 9); below one huge page the
/// table is an ordinary allocation of whole clusters.
pub fn ttBytes(hash_mb: u32) u64 {
    const rest = @as(u64, hash_mb) * MIB - @as(u64, evalKbTotal(hash_mb)) * KIB;
    return if (rest >= hugealloc.HUGE_PAGE_BYTES) rest - rest % hugealloc.HUGE_PAGE_BYTES else rest;
}

test "Hash is the transposition table plus the eval caches" {
    const cases = [_]struct { hash: u32, eval_kb: u32, tt_kb: u32 }{
        .{ .hash = 1, .eval_kb = 256, .tt_kb = 768 },
        .{ .hash = 2, .eval_kb = 512, .tt_kb = 1536 },
        .{ .hash = 3, .eval_kb = 512, .tt_kb = 2 * 1024 }, // 2.5 MB of rest, two whole huge pages of it
        .{ .hash = 4, .eval_kb = 1024, .tt_kb = 2 * 1024 },
        .{ .hash = 8, .eval_kb = 2 * 1024, .tt_kb = 6 * 1024 },
        .{ .hash = 12, .eval_kb = 2 * 1024, .tt_kb = 10 * 1024 },
        .{ .hash = 16, .eval_kb = 4 * 1024, .tt_kb = 12 * 1024 },
        .{ .hash = 64, .eval_kb = 16 * 1024, .tt_kb = 48 * 1024 },
        .{ .hash = 100, .eval_kb = 16 * 1024, .tt_kb = 84 * 1024 },
        .{ .hash = 255, .eval_kb = 32 * 1024, .tt_kb = 222 * 1024 }, // 223 MB of rest
        .{ .hash = 256, .eval_kb = 64 * 1024, .tt_kb = 192 * 1024 },
        .{ .hash = 1024, .eval_kb = 64 * 1024, .tt_kb = 960 * 1024 },
        .{ .hash = 4096, .eval_kb = 64 * 1024, .tt_kb = 4032 * 1024 },
        .{ .hash = 65_536, .eval_kb = 64 * 1024, .tt_kb = 65_472 * 1024 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.eval_kb, evalKbTotal(c.hash));
        try std.testing.expectEqual(c.eval_kb, evalKbPerEngine(c.hash, 1));
        try std.testing.expectEqual(@as(u64, c.tt_kb) * KIB, ttBytes(c.hash));
    }
    try std.testing.expectEqual(@as(u32, 16 * 1024), evalKbPerEngine(1024, 4));
    try std.testing.expectEqual(@as(u32, 16 * 1024), evalKbPerEngine(1024, 3));
    try std.testing.expectEqual(@as(u32, 2 * 1024), evalKbPerEngine(2048, 32));
    try std.testing.expectEqual(@as(u32, 128), evalKbPerEngine(16, 32));
    try std.testing.expectEqual(@as(u32, 64), evalKbPerEngine(1, 4));
    try std.testing.expectEqual(@as(u32, 8), evalKbPerEngine(1, 32));
}

test "what the tables really map never exceeds Hash, for every Hash and thread count" {
    var mb: u32 = 1;
    while (mb <= 65_536) : (mb += 1) {
        const budget = @as(u64, mb) * MIB;
        const tt = ttBytes(mb);
        // The table is exactly what the allocator maps for it, a whole number
        // of 64-byte clusters, and less than a huge page short of three
        // quarters of Hash at worst. (It is not monotonic in Hash: where the
        // caches' share doubles, at Hash 32 for one, the table steps down.)
        try std.testing.expectEqual(tt, hugealloc.backedBytes(tt));
        try std.testing.expectEqual(@as(u64, 0), tt % 64);
        try std.testing.expect(tt + hugealloc.HUGE_PAGE_BYTES > budget - budget / EVAL_SHARE_DIVISOR);
        var threads: u32 = 1;
        while (threads <= MAX_THREADS) : (threads += 1) {
            const per = evalKbPerEngine(mb, threads);
            try std.testing.expect(std.math.isPowerOfTwo(per) and per >= EVAL_MIN_KB);
            // No floor wins anywhere in the supported range: the caches
            // together stay inside their share, and with the table inside Hash.
            try std.testing.expect(threads * per <= evalKbTotal(mb));
            const caches = threads * hugealloc.backedBytes(@as(u64, per) * KIB);
            try std.testing.expect(tt + caches <= budget);
        }
    }
}
