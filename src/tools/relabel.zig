//! Re-search existing datagen corpus lines at a chosen node budget and emit a
//! label-disagreement record per position.
//!
//! INPUT  : bullet text, exactly what src/tools/datagen.zig writes —
//!            `<FEN> | <white_pov_engine_cp> | <result>`
//! OUTPUT : CSV, one row per input line, carrying the ORIGINAL label beside the
//!          fresh one plus enough position descriptors to slice the audit
//!          afterwards (phase by piece count, material balance, score band).
//!
//! REGIME FIDELITY — what this reproduces and what it cannot:
//!   * engine entry point, node budget, hash size and eval options are matched
//!     to datagen (`Engine.search`, `Engine.initWithSharedNet`). The engine has
//!     no opening-book shortcut. Relabel never
//!     enables tablebases. GEN-1 production datagen is TB-on, so that difference
//!     is deliberate for blind-injection audits: a TB-enabled relabel would
//!     leak the independent truth source into the labeler being measured.
//!   * datagen calls `engine.reset()` ONCE PER GAME, then plays every move of
//!     that game against the accumulated TT / eval-cache / rfp-hint / history
//!     tables, and passes the game's full repetition history into each search.
//!     A per-position relabel has none of that: it resets before every position
//!     and knows only the single root key. So relabelling at the ORIGINAL node
//!     count is NOT expected to reproduce the original score bit-exactly — the
//!     divergence it measures is "same budget, cold state" and is the control
//!     arm the deeper-search reading must be judged against, not a bug.
//!   * `--warm` disables the per-position reset so a run can measure how much of
//!     that divergence is carried state rather than budget.
//!
//! THREADING mirrors datagen: one shared read-only net, N private engines,
//! worker k takes a contiguous row range and writes `<out>.w<k>`. Rows are
//! independent (reset per position), so output is thread-count-invariant.
const std = @import("std");
const fen = @import("../core/fen.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_engine = @import("../search/engine.zig");
const time = @import("../search/time.zig");
const types = @import("../core/types.zig");

pub const Options = struct {
    input_path: []const u8,
    out_path: []const u8,
    nodes: u64,
    hash_mb: u32,
    threads: u32,
    tag: []const u8,
    /// Skip the per-position engine.reset() (measures carried-state effect).
    warm: bool,
};

pub const csv_header = "tag,row,men,stm,hmc,fmn,wP,wN,wB,wR,wQ,bP,bN,bB,bR,bQ,result,old,new,nodes,depth,seldepth\n";

pub fn run(progress: *std.Io.Writer, opts: Options) !void {
    @import("../search/startup.zig").ensure();
    if (opts.nodes == 0) return error.InvalidNodeLimit;
    if (opts.threads == 0 or opts.threads > 512) return error.InvalidThreadCount;
    if (opts.hash_mb == 0 or opts.hash_mb > 65_536) return error.InvalidHashSize;

    const allocator = std.heap.page_allocator;

    const data = try std.fs.cwd().readFileAlloc(allocator, opts.input_path, 8 << 30);
    defer allocator.free(data);

    // Index the lines once so workers can take contiguous, equal ranges.
    var offsets = std.ArrayList(u32){};
    defer offsets.deinit(allocator);
    var lengths = std.ArrayList(u32){};
    defer lengths.deinit(allocator);
    {
        var pos_i: usize = 0;
        while (pos_i < data.len) {
            const nl = std.mem.indexOfScalarPos(u8, data, pos_i, '\n') orelse data.len;
            var end = nl;
            if (end > pos_i and data[end - 1] == '\r') end -= 1;
            if (end > pos_i) {
                try offsets.append(allocator, @intCast(pos_i));
                try lengths.append(allocator, @intCast(end - pos_i));
            }
            pos_i = nl + 1;
        }
    }
    const row_count = offsets.items.len;
    if (row_count == 0) return error.EmptyInput;

    try progress.print("relabel start: rows {d} nodes {d} hash_mb {d} threads {d} warm {} tag {s}\n", .{
        row_count, opts.nodes, opts.hash_mb, opts.threads, opts.warm, opts.tag,
    });
    try progress.flush();

    const net = try search_engine.loadDefaultNet(allocator);
    defer net.destroy(allocator);

    var shared = Shared{
        .progress = progress,
        .rows_total = row_count,
        .timer = try std.time.Timer.start(),
    };

    const contexts = try allocator.alloc(Worker, opts.threads);
    defer allocator.free(contexts);
    var paths_made: usize = 0;
    defer for (contexts[0..paths_made]) |ctx| allocator.free(ctx.out_path);
    for (contexts, 0..) |*ctx, k| {
        ctx.* = .{
            .shared = &shared,
            .net = net,
            .opts = opts,
            .data = data,
            .offsets = offsets.items,
            .lengths = lengths.items,
            .first_row = k * row_count / opts.threads,
            .last_row = (k + 1) * row_count / opts.threads,
            .out_path = try std.fmt.allocPrint(allocator, "{s}.w{d}", .{ opts.out_path, k }),
        };
        paths_made += 1;
    }

    const handles = try allocator.alloc(std.Thread, opts.threads);
    defer allocator.free(handles);
    var spawned: usize = 0;
    for (handles, contexts) |*h, *ctx| {
        h.* = std.Thread.spawn(.{}, workerMain, .{ctx}) catch break;
        spawned += 1;
    }
    for (handles[0..spawned]) |h| h.join();
    if (shared.failed.load(.acquire)) return error.RelabelWorkerFailed;

    const done = shared.rows_done.load(.monotonic);
    const skipped = shared.rows_skipped.load(.monotonic);
    const elapsed_s = @as(f64, @floatFromInt(shared.timer.read())) / std.time.ns_per_s;
    try progress.print("relabel done: rows {d} written {d} skipped {d} elapsed_s {d:.1} rows_per_sec {d:.1}\n", .{
        row_count,                                                           done - skipped, skipped, elapsed_s,
        if (elapsed_s > 0) @as(f64, @floatFromInt(done)) / elapsed_s else 0,
    });
    try progress.flush();
}

const Shared = struct {
    progress: *std.Io.Writer,
    mutex: std.Thread.Mutex = .{},
    rows_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    rows_skipped: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rows_total: usize,
    timer: std.time.Timer,
};

const Worker = struct {
    shared: *Shared,
    net: *const search_engine.Net,
    opts: Options,
    data: []const u8,
    offsets: []const u32,
    lengths: []const u32,
    first_row: usize,
    last_row: usize,
    out_path: []u8,
};

fn workerMain(ctx: *Worker) void {
    workerRun(ctx) catch |err| {
        ctx.shared.failed.store(true, .release);
        ctx.shared.mutex.lock();
        defer ctx.shared.mutex.unlock();
        ctx.shared.progress.print("relabel worker error: {s}: {s}\n", .{ ctx.out_path, @errorName(err) }) catch {};
        ctx.shared.progress.flush() catch {};
    };
}

fn workerRun(ctx: *Worker) !void {
    const allocator = std.heap.page_allocator;

    var engine = try search_engine.Engine.initWithSharedNet(allocator, ctx.opts.hash_mb, ctx.net);
    defer engine.deinit();

    var out_file = try std.fs.cwd().createFile(ctx.out_path, .{ .truncate = true });
    defer out_file.close();
    var out_buffer: [1 << 20]u8 = undefined;
    var file_writer = out_file.writer(&out_buffer);
    const out = &file_writer.interface;

    const limits = time.Limits{ .node_limit = ctx.opts.nodes };
    var stop_flag = std.atomic.Value(bool).init(false);

    var local_done: usize = 0;
    var row = ctx.first_row;
    while (row < ctx.last_row) : (row += 1) {
        const line = ctx.data[ctx.offsets[row]..][0..ctx.lengths[row]];
        const parsed = parseLine(line) orelse {
            _ = ctx.shared.rows_skipped.fetchAdd(1, .monotonic);
            _ = ctx.shared.rows_done.fetchAdd(1, .monotonic);
            continue;
        };

        if (!ctx.opts.warm) engine.reset();
        var history = repetition.History{};
        history.push(parsed.pos.zobrist_key);
        const res = engine.search(&parsed.pos, &history, limits, &stop_flag);
        const new_white_pov: i32 = switch (parsed.pos.side_to_move) {
            .white => res.score,
            .black => -res.score,
        };

        const c = counts(&parsed.pos);
        try out.print(
            "{s},{d},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{s},{d},{d},{d},{d},{d}\n",
            .{
                ctx.opts.tag,                                        row,                       c.men,
                if (parsed.pos.side_to_move == .white) "w" else "b", parsed.pos.halfmove_clock, parsed.pos.fullmove_number,
                c.wp,                                                c.wn,                      c.wb,
                c.wr,                                                c.wq,                      c.bp,
                c.bn,                                                c.bb,                      c.br,
                c.bq,                                                parsed.result,             parsed.old_score,
                new_white_pov,                                       res.nodes,                 res.depth,
                res.seldepth,
            },
        );

        local_done += 1;
        if (local_done % 2000 == 0) {
            const total = ctx.shared.rows_done.fetchAdd(2000, .monotonic) + 2000;
            if (total % 50_000 < 2000) {
                ctx.shared.mutex.lock();
                defer ctx.shared.mutex.unlock();
                const el = @as(f64, @floatFromInt(ctx.shared.timer.read())) / std.time.ns_per_s;
                ctx.shared.progress.print("relabel progress: rows {d}/{d} rows_per_sec {d:.1}\n", .{
                    total, ctx.shared.rows_total, if (el > 0) @as(f64, @floatFromInt(total)) / el else 0,
                }) catch {};
                ctx.shared.progress.flush() catch {};
            }
            local_done = 0;
        }
    }
    _ = ctx.shared.rows_done.fetchAdd(local_done, .monotonic);
    try out.flush();
}

const Parsed = struct {
    pos: position.Position,
    old_score: i32,
    result: []const u8,
};

fn parseLine(line: []const u8) ?Parsed {
    var it = std.mem.splitSequence(u8, line, " | ");
    const fen_text = it.next() orelse return null;
    const score_text = it.next() orelse return null;
    const result_text = it.next() orelse return null;
    const pos = fen.parse(fen_text) catch return null;
    const score = std.fmt.parseInt(i32, std.mem.trim(u8, score_text, " "), 10) catch return null;
    return .{ .pos = pos, .old_score = score, .result = result_text };
}

const Counts = struct { men: u32, wp: u32, wn: u32, wb: u32, wr: u32, wq: u32, bp: u32, bn: u32, bb: u32, br: u32, bq: u32 };

fn counts(pos: *const position.Position) Counts {
    return .{
        .men = @popCount(pos.occupied),
        .wp = @popCount(pos.pieceBitboard(.white, .pawn)),
        .wn = @popCount(pos.pieceBitboard(.white, .knight)),
        .wb = @popCount(pos.pieceBitboard(.white, .bishop)),
        .wr = @popCount(pos.pieceBitboard(.white, .rook)),
        .wq = @popCount(pos.pieceBitboard(.white, .queen)),
        .bp = @popCount(pos.pieceBitboard(.black, .pawn)),
        .bn = @popCount(pos.pieceBitboard(.black, .knight)),
        .bb = @popCount(pos.pieceBitboard(.black, .bishop)),
        .br = @popCount(pos.pieceBitboard(.black, .rook)),
        .bq = @popCount(pos.pieceBitboard(.black, .queen)),
    };
}

test "relabel parses a datagen line" {
    const line = "4k3/8/8/4P3/8/8/8/4K3 w - - 0 20 | 123 | 1.0";
    const p = parseLine(line) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(i32, 123), p.old_score);
    try std.testing.expectEqualStrings("1.0", p.result);
    try std.testing.expectEqual(@as(u32, 3), counts(&p.pos).men);
    try std.testing.expectEqual(types.Color.white, p.pos.side_to_move);
}

test "relabel rejects malformed lines" {
    try std.testing.expect(parseLine("garbage") == null);
    try std.testing.expect(parseLine("4k3/8/8/4P3/8/8/8/4K3 w - - 0 20 | notanumber | 1.0") == null);
}
