//! G5 concurrency probe for the own Syzygy prober; never imported by the engine.
//! N worker threads probe WDL, DTZ and root rankings through registry leases
//! while the main thread, the registry's owner, swaps snapshots (SyzygyPath
//! changes: all tables, a subset, disabled) and collects retired ones. Workers
//! only ever release leases; every free happens on the main thread. Run under
//! ThreadSanitizer with TSAN_OPTIONS=halt_on_error=1:exitcode=66.
//!
//!   tb-swap-probe clean    <full path list> <subset path list> [storage] [swaps] [threads] [budget bytes]
//!   tb-swap-probe unleased <full path list> <subset path list> [storage]  (positive control: must race)
//!   tb-swap-probe canary                                                  (positive control: must race)
//!
//! A small budget (storage `budget`) sends most files to the positioned-read
//! fallback while others map, so both publish paths race on first touch.
const std = @import("std");
const tb = @import("tb/tb.zig");
const fen = @import("core/fen.zig");
const position = @import("core/position.zig");

// libc malloc so that ThreadSanitizer sees every free.
const gpa = std.heap.c_allocator;

const fens = [_][]const u8{
    "8/8/8/8/8/8/8/R3K2k w - - 0 1",
    "8/8/8/4k3/8/8/2Q4r/K7 w - - 0 1",
    "8/8/2p5/8/8/5P2/8/K6k b - - 0 1",
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "7k/P7/2K5/8/8/8/8/8 w - - 0 1",
    "8/2k3K1/8/8/3b4/2n5/1R6/7B w - - 0 1",
    "7b/3P4/2B2K2/8/N4k2/8/8/8 w - - 0 1",
    "8/8/4P3/8/1p1K4/8/2k4r/R7 w - - 0 1",
};

const Expected = struct {
    pos: position.Position,
    pieces: u32,
    wdl: tb.Wdl5,
    dtz: i32,
    root_count: u16,
    suggested_r: i32,
};

var canary_shared: u32 = 0;

fn canaryWorker() void {
    for (0..100_000) |_| {
        const p: *volatile u32 = &canary_shared;
        p.* +%= 1;
    }
}

fn Stress(comptime B: type) type {
    return struct {
        const Reg = tb.Registry(B);
        const P = tb.Prober(B);

        const Shared = struct {
            reg: Reg = .{},
            expected: [fens.len]Expected = undefined,
            stop: std.atomic.Value(bool) = .init(false),
            failures: std.atomic.Value(u32) = .init(0),
            probes: std.atomic.Value(u64) = .init(0),
            disabled_leases: std.atomic.Value(u64) = .init(0),
            leased: bool = true,
        };

        fn check(snap: *const Reg.Snap, e: *const Expected, largest: u32, shared: *Shared) void {
            if (e.pieces > largest) {
                // A smaller snapshot must refuse, never answer.
                if (P.wdl(snap, &e.pos)) |_| {
                    _ = shared.failures.fetchAdd(1, .monotonic);
                } else |err| if (err != error.OutOfScope) {
                    _ = shared.failures.fetchAdd(1, .monotonic);
                }
                return;
            }
            const w = P.wdl(snap, &e.pos) catch {
                _ = shared.failures.fetchAdd(1, .monotonic);
                return;
            };
            const d = P.dtz(snap, &e.pos) catch {
                _ = shared.failures.fetchAdd(1, .monotonic);
                return;
            };
            var ranking: tb.RootRanking = .{};
            P.rankRoot(snap, &e.pos, 0, &ranking) catch {
                _ = shared.failures.fetchAdd(1, .monotonic);
                return;
            };
            const sugg = if (ranking.suggested) |i| ranking.records[i].r else 0;
            if (w != e.wdl or d.plies != e.dtz or ranking.count != e.root_count or sugg != e.suggested_r)
                _ = shared.failures.fetchAdd(1, .monotonic);
            _ = shared.probes.fetchAdd(1, .monotonic);
        }

        fn worker(shared: *Shared, seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const rnd = prng.random();
            while (!shared.stop.load(.acquire)) {
                if (shared.leased) {
                    var lease = shared.reg.acquire();
                    defer lease.release();
                    const snap = lease.snap orelse {
                        _ = shared.disabled_leases.fetchAdd(1, .monotonic);
                        std.Thread.yield() catch {};
                        continue;
                    };
                    for (0..4) |_| check(snap, &shared.expected[rnd.uintLessThan(usize, fens.len)], lease.largest, shared);
                } else {
                    // Positive control: no lease, so a swap may free the snapshot mid-probe.
                    const snap = @as(*volatile ?*Reg.Snap, &shared.reg.current).* orelse continue;
                    check(snap, &shared.expected[rnd.uintLessThan(usize, fens.len)], snap.max_pieces, shared);
                }
            }
        }

        fn run(mode: []const u8, full: []const u8, subset: []const u8, swaps: u32, threads: u32, options: tb.storage.Options) !void {
            var shared = Shared{ .leased = std.mem.eql(u8, mode, "clean") };
            // Expected values from a private snapshot of every table.
            const ref = try tb.registry.build(B, gpa, full, .{});
            for (fens, &shared.expected) |text, *e| {
                e.pos = try fen.parse(text);
                e.pieces = @popCount(e.pos.occupied);
                e.wdl = try P.wdl(ref, &e.pos);
                e.dtz = (try P.dtz(ref, &e.pos)).plies;
                var ranking: tb.RootRanking = .{};
                try P.rankRoot(ref, &e.pos, 0, &ranking);
                e.root_count = ranking.count;
                e.suggested_r = if (ranking.suggested) |i| ranking.records[i].r else 0;
            }
            ref.destroy();
            shared.reg.swap(try tb.registry.build(B, gpa, full, options));
            var pool: [16]std.Thread = undefined;
            const n = @min(threads, pool.len);
            for (pool[0..n], 0..) |*t, i| t.* = try std.Thread.spawn(.{}, worker, .{ &shared, 0x9e37 + i });
            var kinds = [_]u32{ 0, 0, 0 };
            var max_retired: usize = 0;
            var pread_files: u64 = 0;
            var mapped_files: u64 = 0;
            for (0..swaps) |i| {
                const kind = i % 3;
                kinds[kind] += 1;
                const next: ?*Reg.Snap = switch (kind) {
                    0 => try tb.registry.build(B, gpa, subset, options),
                    1 => null,
                    else => try tb.registry.build(B, gpa, full, options),
                };
                if (shared.reg.current) |old| {
                    const io = old.ioStats();
                    pread_files += io.pread_files;
                    mapped_files += io.mapped_files;
                }
                shared.reg.swap(next);
                max_retired = @max(max_retired, shared.reg.retiredCount());
                std.Thread.sleep(2 * std.time.ns_per_ms);
                // What the UCI thread does on isready / ucinewgame.
                shared.reg.collect();
            }
            shared.stop.store(true, .release);
            for (pool[0..n]) |t| t.join();
            shared.reg.swap(null);
            const left = shared.reg.retiredCount();
            const failures = shared.failures.load(.monotonic);
            std.debug.print("G5 mode={s} storage={s} budget={?d} threads={d} swaps={d} (subset {d}, disabled {d}, full {d}) checked_probes={d} disabled_leases={d} failures={d} max_retired={d} retired_left={d} replaced_snapshots_pread_files={d} mapped_files={d}\n", .{
                mode, @typeName(B), options.budget, n, swaps, kinds[0], kinds[1], kinds[2], shared.probes.load(.monotonic), shared.disabled_leases.load(.monotonic), failures, max_retired, left, pread_files, mapped_files,
            });
            if (failures != 0) return error.ProbeMismatch;
            if (left != 0) return error.SnapshotLeak;
            if (shared.leased) std.debug.print("G5_PASS\n", .{});
        }
    };
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (std.mem.eql(u8, mode, "canary")) {
        const a = try std.Thread.spawn(.{}, canaryWorker, .{});
        const b = try std.Thread.spawn(.{}, canaryWorker, .{});
        a.join();
        b.join();
        std.debug.print("canary done {d}\n", .{canary_shared});
        return;
    }
    const full = args.next() orelse return error.MissingPaths;
    const subset = args.next() orelse return error.MissingPaths;
    const storage = args.next() orelse "budget";
    const swaps = std.fmt.parseInt(u32, args.next() orelse "60", 10) catch 60;
    const threads = std.fmt.parseInt(u32, args.next() orelse "4", 10) catch 4;
    const options = tb.storage.Options{ .budget = if (args.next()) |b| try std.fmt.parseInt(u64, b, 10) else null };
    if (std.mem.eql(u8, storage, "budget")) return Stress(tb.storage.MmapBudget).run(mode, full, subset, swaps, threads, options);
    if (std.mem.eql(u8, storage, "mmap")) return Stress(tb.storage.MmapAll).run(mode, full, subset, swaps, threads, options);
    if (std.mem.eql(u8, storage, "pread")) return Stress(tb.storage.Pread).run(mode, full, subset, swaps, threads, options);
    return error.BadStorage;
}
