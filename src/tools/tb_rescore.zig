//! Syzygy rescore of a packed bulletformat corpus (32-byte ChessBoard records).
//!
//! WHY: zigqueen selfplay at 6000 nodes frequently fails to CONVERT won
//! endgames. Every position of such a game is then labelled with the drawn game
//! result, and with a search score that never saw the win — so the corpus
//! teaches the net that won endgames are draws. Inside tablebase range the
//! game-theoretic value is knowable exactly, so those labels can be replaced
//! with truth instead of with the weak searcher's opinion.
//!
//! RECORD LAYOUT (bulletformat::ChessBoard, verified against the crate source):
//!   occ u64 | pcs[16] (4-bit nibbles, LSB-first over occ's set squares)
//!   | score i16 | result u8 | ksq u8 | opp_ksq u8 | extra[3]
//! The board is STM-NORMALISED: `from_str` vertically flips (sq ^ 56) and
//! colour-swaps when black is to move, so a decoded record is always "white to
//! move" with nibble bit 3 marking the side NOT to move. score and result are
//! therefore STM-relative, and score is in TRAINER units (engine cp * 100/48).
//!
//! WHAT THE PACKED FORM CANNOT CARRY: castling rights, en-passant square and
//! the halfmove clock are not stored. The probe is issued with none/none/0.
//! Castling rights and an ep square would both make the probe unsound; their
//! incidence is measured separately on the TEXT corpus (see the audit) and
//! reported as this pass's known error rate. A nonzero real halfmove clock can
//! turn a WDL win into a rule-50 draw; WDL tables ignore the clock by design.
//!
//! LABEL MAPPING (single-variable screen; both knobs are flags so a variant
//! costs one more pass):
//!   score  <- +win_cp / 0 / -win_cp  (STM-relative, trainer units)
//!   result <- 2 / 1 / 0              (STM-relative, --keep-result disables)
//! Default win_cp = 10000, the corpus band edge already present in the data, so
//! no value outside the existing range is introduced. The trainer's target is
//! sigmoid(score/400) blended with result, and sigmoid saturates by ~2500, so
//! any win_cp above that is numerically the same target.
const std = @import("std");
const piece_mod = @import("../core/piece.zig");
const position = @import("../core/position.zig");
const square_mod = @import("../core/square.zig");
const syzygy = @import("../search/syzygy.zig");
const zobrist = @import("../core/zobrist.zig");

pub const Options = struct {
    input_path: []const u8,
    output_path: []const u8,
    tb_path: []const u8,
    threads: u32,
    win_cp: i16,
    keep_result: bool,
    /// Report only: never write an output file.
    dry_run: bool,
};

pub const Stats = struct {
    records: u64 = 0,
    in_range: u64 = 0,
    probe_ok: u64 = 0,
    probe_fail: u64 = 0,
    decode_fail: u64 = 0,
    /// TB verdict (0 loss / 1 draw / 2 win) x recorded result (0/1/2)
    confusion: [3][3]u64 = .{.{0} ** 3} ** 3,
    score_changed: u64 = 0,
    result_changed: u64 = 0,
    sign_flips: u64 = 0,
    /// TB says win but the recorded game result was not a win, by men count.
    unconverted_by_men: [9]u64 = .{0} ** 9,
    tbwin_by_men: [9]u64 = .{0} ** 9,
    /// |original score| histogram for TB-win positions, trainer-cp decades.
    tbwin_absscore: [8]u64 = .{0} ** 8,

    fn merge(self: *Stats, o: *const Stats) void {
        self.records += o.records;
        self.in_range += o.in_range;
        self.probe_ok += o.probe_ok;
        self.probe_fail += o.probe_fail;
        self.decode_fail += o.decode_fail;
        self.score_changed += o.score_changed;
        self.result_changed += o.result_changed;
        self.sign_flips += o.sign_flips;
        for (0..3) |i| for (0..3) |j| {
            self.confusion[i][j] += o.confusion[i][j];
        };
        for (0..9) |i| {
            self.unconverted_by_men[i] += o.unconverted_by_men[i];
            self.tbwin_by_men[i] += o.tbwin_by_men[i];
        }
        for (0..8) |i| self.tbwin_absscore[i] += o.tbwin_absscore[i];
    }
};

const REC = 32;

pub fn run(progress: *std.Io.Writer, opts: Options) !void {
    @import("../search/startup.zig").ensure();
    if (opts.threads == 0 or opts.threads > 512) return error.InvalidThreadCount;

    const tb_pathz = try std.heap.page_allocator.dupeZ(u8, opts.tb_path);
    defer std.heap.page_allocator.free(tb_pathz);
    if (!syzygy.init(tb_pathz)) return error.SyzygyInitFailed;
    defer syzygy.disable();

    const in_file = try std.fs.cwd().openFile(opts.input_path, .{});
    defer in_file.close();
    const size = try in_file.getEndPos();
    if (size % REC != 0) return error.NotAPackedCorpus;
    const total = size / REC;

    try progress.print("tb_rescore start: records {d} tb_largest {d} threads {d} win_cp {d} keep_result {} dry_run {}\n", .{
        total, syzygy.pieceLimit(), opts.threads, opts.win_cp, opts.keep_result, opts.dry_run,
    });
    try progress.flush();

    var shared = Shared{ .progress = progress, .total = total, .timer = try std.time.Timer.start() };

    const allocator = std.heap.page_allocator;
    const ctxs = try allocator.alloc(Worker, opts.threads);
    defer allocator.free(ctxs);
    var made: usize = 0;
    defer for (ctxs[0..made]) |c| if (c.out_path) |p| allocator.free(p);

    for (ctxs, 0..) |*c, k| {
        c.* = .{
            .shared = &shared,
            .opts = opts,
            .first = @as(u64, k) * total / opts.threads,
            .last = (@as(u64, k) + 1) * total / opts.threads,
            .out_path = if (opts.dry_run) null else try std.fmt.allocPrint(allocator, "{s}.p{d}", .{ opts.output_path, k }),
        };
        made += 1;
    }

    const handles = try allocator.alloc(std.Thread, opts.threads);
    defer allocator.free(handles);
    var spawned: usize = 0;
    for (handles, ctxs) |*h, *c| {
        h.* = std.Thread.spawn(.{}, workerMain, .{c}) catch break;
        spawned += 1;
    }
    for (handles[0..spawned]) |h| h.join();
    if (shared.failed.load(.acquire)) return error.TbRescoreWorkerFailed;

    var st = Stats{};
    for (ctxs) |*c| st.merge(&c.stats);
    const el = @as(f64, @floatFromInt(shared.timer.read())) / std.time.ns_per_s;
    try report(progress, &st, el);
}

fn report(w: *std.Io.Writer, st: *const Stats, elapsed_s: f64) !void {
    const pct = struct {
        fn f(x: u64, n: u64) f64 {
            return if (n == 0) 0 else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(n));
        }
    }.f;
    try w.print("\nTBSTATS records={d} in_range={d} ({d:.4}%) probe_ok={d} probe_fail={d} decode_fail={d}\n", .{
        st.records, st.in_range, pct(st.in_range, st.records), st.probe_ok, st.probe_fail, st.decode_fail,
    });
    try w.print("TBSTATS score_changed={d} ({d:.4}% of probed) result_changed={d} ({d:.4}%) sign_flips={d} ({d:.4}%)\n", .{
        st.score_changed,  pct(st.score_changed, st.probe_ok),
        st.result_changed, pct(st.result_changed, st.probe_ok),
        st.sign_flips,     pct(st.sign_flips, st.probe_ok),
    });
    try w.print("CONFUSION rows=TB(loss,draw,win) cols=recorded_result(loss,draw,win)\n", .{});
    const names = [_][]const u8{ "loss", "draw", "win " };
    for (0..3) |i| {
        try w.print("  TB {s} | {d:>12} {d:>12} {d:>12}\n", .{ names[i], st.confusion[i][0], st.confusion[i][1], st.confusion[i][2] });
    }
    var tbwin_total: u64 = 0;
    var unconv_total: u64 = 0;
    for (0..9) |m| {
        tbwin_total += st.tbwin_by_men[m];
        unconv_total += st.unconverted_by_men[m];
    }
    try w.print("UNCONVERTED tb_wins={d} not_recorded_as_win={d} ({d:.3}%)\n", .{
        tbwin_total, unconv_total, pct(unconv_total, tbwin_total),
    });
    for (2..9) |m| {
        if (st.tbwin_by_men[m] == 0) continue;
        try w.print("  men={d}: tb_wins={d} unconverted={d} ({d:.3}%)\n", .{
            m, st.tbwin_by_men[m], st.unconverted_by_men[m], pct(st.unconverted_by_men[m], st.tbwin_by_men[m]),
        });
    }
    const bands = [_][]const u8{ "0-99", "100-299", "300-599", "600-999", "1000-1999", "2000-3999", "4000-7999", "8000+" };
    try w.print("TBWIN original |score| (trainer cp) distribution:\n", .{});
    for (bands, 0..) |b, i| {
        try w.print("  {s:<10} {d:>12} ({d:.3}%)\n", .{ b, st.tbwin_absscore[i], pct(st.tbwin_absscore[i], tbwin_total) });
    }
    try w.print("TBSTATS elapsed_s={d:.1} rec_per_sec={d:.0}\n", .{
        elapsed_s, if (elapsed_s > 0) @as(f64, @floatFromInt(st.records)) / elapsed_s else 0,
    });
    try w.flush();
}

const Shared = struct {
    progress: *std.Io.Writer,
    mutex: std.Thread.Mutex = .{},
    done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    total: u64,
    timer: std.time.Timer,
};

const Worker = struct {
    shared: *Shared,
    opts: Options,
    first: u64,
    last: u64,
    out_path: ?[]u8,
    stats: Stats = .{},
};

fn workerMain(c: *Worker) void {
    workerRun(c) catch |err| {
        c.shared.failed.store(true, .release);
        c.shared.mutex.lock();
        defer c.shared.mutex.unlock();
        c.shared.progress.print("tb_rescore worker error: {s}\n", .{@errorName(err)}) catch {};
        c.shared.progress.flush() catch {};
    };
}

fn workerRun(c: *Worker) !void {
    const allocator = std.heap.page_allocator;
    const CHUNK: usize = 1 << 16; // 65536 records = 2 MiB
    const buf = try allocator.alloc(u8, CHUNK * REC);
    defer allocator.free(buf);

    var in_file = try std.fs.cwd().openFile(c.opts.input_path, .{});
    defer in_file.close();
    try in_file.seekTo(c.first * REC);

    var out_file: ?std.fs.File = null;
    defer if (out_file) |f| f.close();
    if (c.out_path) |p| out_file = try std.fs.cwd().createFile(p, .{ .truncate = true });

    var remaining = c.last - c.first;
    var since_report: u64 = 0;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, CHUNK));
        const got = try in_file.readAll(buf[0 .. want * REC]);
        const n = got / REC;
        if (n == 0) break;

        for (0..n) |i| {
            rescoreOne(buf[i * REC ..][0..REC], &c.stats, &c.opts);
        }
        if (out_file) |f| try f.writeAll(buf[0 .. n * REC]);

        remaining -= n;
        since_report += n;
        if (since_report >= 1 << 21) {
            const done = c.shared.done.fetchAdd(since_report, .monotonic) + since_report;
            since_report = 0;
            if (c.shared.mutex.tryLock()) {
                defer c.shared.mutex.unlock();
                const el = @as(f64, @floatFromInt(c.shared.timer.read())) / std.time.ns_per_s;
                c.shared.progress.print("tb_rescore progress: {d}/{d} ({d:.2}%) rec_per_sec {d:.0}\n", .{
                    done,                                                                            c.shared.total,
                    100.0 * @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(c.shared.total)), if (el > 0) @as(f64, @floatFromInt(done)) / el else 0,
                }) catch {};
                c.shared.progress.flush() catch {};
            }
        }
    }
    _ = c.shared.done.fetchAdd(since_report, .monotonic);
}

fn absBand(v: i16) usize {
    const a: u32 = @intCast(@abs(@as(i32, v)));
    if (a < 100) return 0;
    if (a < 300) return 1;
    if (a < 600) return 2;
    if (a < 1000) return 3;
    if (a < 2000) return 4;
    if (a < 4000) return 5;
    if (a < 8000) return 6;
    return 7;
}

fn rescoreOne(rec: []u8, st: *Stats, opts: *const Options) void {
    st.records += 1;
    const occ = std.mem.readInt(u64, rec[0..8], .little);
    const men = @popCount(occ);
    if (men > syzygy.pieceLimit()) return;
    st.in_range += 1;

    var pos = decode(rec, occ) orelse {
        st.decode_fail += 1;
        return;
    };
    pos.zobrist_key = zobrist.hashPosition(&pos);

    const wdl = syzygy.probeWdl(&pos) orelse {
        st.probe_fail += 1;
        return;
    };
    st.probe_ok += 1;

    const old_score = std.mem.readInt(i16, rec[24..26], .little);
    const old_result: u8 = rec[26];
    const tb_idx: usize = switch (wdl) {
        .loss => 0,
        .draw => 1,
        .win => 2,
    };
    if (old_result < 3) st.confusion[tb_idx][old_result] += 1;

    const men_i: usize = @min(men, 8);
    if (wdl == .win) {
        st.tbwin_by_men[men_i] += 1;
        if (old_result != 2) st.unconverted_by_men[men_i] += 1;
        st.tbwin_absscore[absBand(old_score)] += 1;
    }

    const new_score: i16 = switch (wdl) {
        .win => opts.win_cp,
        .loss => -opts.win_cp,
        .draw => 0,
    };
    const new_result: u8 = switch (wdl) {
        .win => 2,
        .draw => 1,
        .loss => 0,
    };
    if (new_score != old_score) st.score_changed += 1;
    if (new_result != old_result) st.result_changed += 1;
    if ((old_score > 0 and new_score < 0) or (old_score < 0 and new_score > 0)) st.sign_flips += 1;

    std.mem.writeInt(i16, rec[24..26], new_score, .little);
    if (!opts.keep_result) rec[26] = new_result;
}

/// Decode an STM-normalised ChessBoard into a white-to-move Position.
/// Nibble = (colour_bit << 3) | piece_index, colour bit set = side NOT to move.
fn decode(rec: []const u8, occ_in: u64) ?position.Position {
    var pos = position.Position.empty();
    pos.side_to_move = .white;
    pos.castling_rights = .{};
    pos.en_passant = null;
    pos.halfmove_clock = 0;
    pos.fullmove_number = 1;

    var occ = occ_in;
    var idx: usize = 0;
    var kings: u32 = 0;
    while (occ != 0) : (idx += 1) {
        const sq: u6 = @intCast(@ctz(occ));
        occ &= occ - 1;
        if (idx >= 32) return null;
        const nib: u8 = (rec[8 + idx / 2] >> @intCast(4 * (idx & 1))) & 0xF;
        const pt_idx: u8 = nib & 0x7;
        if (pt_idx > 5) return null;
        const color: @import("../core/types.zig").Color = if ((nib & 0x8) != 0) .black else .white;
        const pt: piece_mod.PieceType = @enumFromInt(pt_idx);
        if (pt == .king) kings += 1;
        pos.setPieceOnEmpty(@enumFromInt(sq), piece_mod.Piece.make(color, pt));
    }
    if (kings != 2) return null;
    return pos;
}

test "decode round-trips a hand-built record" {
    // White Kd1, white Qd8, black Kh8 — white to move, STM-normalised already.
    var rec = [_]u8{0} ** REC;
    const d1: u6 = @intFromEnum(square_mod.Square.d1);
    const d8: u6 = @intFromEnum(square_mod.Square.d8);
    const h8: u6 = @intFromEnum(square_mod.Square.h8);
    const occ = (@as(u64, 1) << d1) | (@as(u64, 1) << d8) | (@as(u64, 1) << h8);
    std.mem.writeInt(u64, rec[0..8], occ, .little);
    // LSB-first over occ: d1 (white king=5), d8 (white queen=4), h8 (black king=8|5=13)
    rec[8] = 5 | (4 << 4);
    rec[9] = 13;
    const pos = decode(&rec, occ) orelse return error.TestDecodeFailed;
    try std.testing.expectEqual(@as(u32, 3), @popCount(pos.occupied));
    try std.testing.expectEqual(piece_mod.Piece.white_king, pos.pieceAt(.d1));
    try std.testing.expectEqual(piece_mod.Piece.white_queen, pos.pieceAt(.d8));
    try std.testing.expectEqual(piece_mod.Piece.black_king, pos.pieceAt(.h8));
}
