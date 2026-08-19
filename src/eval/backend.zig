//! Engine evaluation backend: a single pure-NNUE evaluator.
//!
//! The engine evaluates exclusively with the bullet-trained Chess768 net in
//! `nnue768.zig`. Per-ply white/black accumulators are maintained incrementally
//! across make/unmake: `prepareRoot` does one full refresh at the root, then
//! `onMakeMove`/`onMakeNullMove` apply only the changed features, and `evaluate`
//! runs the output layer over the maintained accumulator. `nnue768.evaluate`
//! (full refresh) remains the bit-exact correctness reference.

const std = @import("std");
const builtin = @import("builtin");
const nnue768 = @import("nnue768.zig");
const position = @import("../core/position.zig");
const move_mod = @import("../core/move.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const search_stack = @import("../search/stack.zig");

pub const builtin_eval_file = "<builtin>";

comptime {
    // The v6 full-threat path stack must cover every search ply (nnue768 cannot
    // import the search stack — the modules would cycle — so bind them here).
    std.debug.assert(nnue768.FT_MAX_PLY >= search_stack.MAX_PLY);
}

/// Opt-in cross-check: when true (Debug only), every threats eval asserts the
/// incrementally-maintained accumulator matches a full refresh. Off by default
/// so search-logic unit tests can drive eval paths on an uninitialized root
/// accumulator (they assert on moves/scores, not eval magnitudes). The dedicated
/// `threats incremental == refresh` test flips this on and runs a real search
/// (with prepareRoot) across a battery of positions — that's the standing guard.
pub var verify_threats_incremental: bool = false;

/// Single source of truth for the default NNUE output scale (percent). Raw net output
/// is multiplied by net.scale * this/100 before search uses it; tuned per-net so the
/// engine's centipawn pruning margins read right. v3.1.1: 54 (readability, strength-
/// neutral). v4.4.0: 65 (the l16 layerstack net; implied 65.2). v4.0.6: 62 — the first principled look (working-band distribution match
/// vs the margin-tuned regime implied 58-63; probes on the SB1200 threats net read
/// s44 -3.1+/-9.3 / s62 +1.8+/-8.2 vs 54 = a shallow plateau, 62 the gentle top).
pub const default_nnue_scale_percent: u16 = 66;

/// v6 (ZQB9 full-threats) nets are calibrated at a DIFFERENT scale than the
/// ZQB1-8 family. Measured 2026-08-09 by fixed-nodes sweep on the v6 net:
/// 36 -> -3.5, 42 -> +52.2, 48 -> +52.9, 66 -> +15.5 Elo (plateau 42-48, cliff
/// below 40). Running a ZQB9 net at the inherited 66 costs ~35 Elo — three
/// quarters of the architecture's gain — so the scale must follow the NET, not
/// a global constant. An explicit `NNUE Scale Percent` still overrides.
pub const zqb9_nnue_scale_percent: u16 = 48;

/// The scale a net expects when the user has not chosen one.
pub fn autoScalePercent(net: *const nnue768.Net) u16 {
    return if (net.full_threats) zqb9_nnue_scale_percent else default_nnue_scale_percent;
}

/// The scale the ENGINE STARTS AT — derived at comptime from the embedded net's
/// magic, so the UCI-advertised default can never drift from what the engine
/// actually uses. (A GUI that echoes the advertised default back as a
/// `setoption` must not silently downgrade the engine.)
pub const builtin_nnue_scale_percent: u16 = if (std.mem.eql(u8, nnue768.default_net_bytes[0..4], nnue768.MAGIC9))
    zqb9_nnue_scale_percent
else
    default_nnue_scale_percent;

pub const Options = struct {
    nnue_scale_percent: u16 = builtin_nnue_scale_percent,
    eval_file_path: ?[]const u8 = null,
};

pub const EngineState = struct {
    allocator: std.mem.Allocator,
    nnue_scale_percent: u16 = builtin_nnue_scale_percent,
    /// True once the scale was chosen explicitly (UCI setoption / CLI); while
    /// false, loading a net adopts that net's `autoScalePercent`.
    scale_explicit: bool = false,
    /// The active net (a `ZQB1` Chess768 net). Always set after `init`.
    net: ?*nnue768.Net = null,
    /// Owned path of a file-loaded net; null when using the embedded default.
    net_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !EngineState {
        var state = EngineState{
            .allocator = allocator,
            .nnue_scale_percent = options.nnue_scale_percent,
            // A caller-supplied scale that differs from the family default is an
            // explicit choice and must survive the load-time adoption below.
            .scale_explicit = options.nnue_scale_percent != builtin_nnue_scale_percent,
        };
        errdefer state.deinit();
        try state.loadModelFile(options.eval_file_path orelse builtin_eval_file);
        return state;
    }

    pub fn deinit(self: *EngineState) void {
        self.unload();
    }

    pub fn setNnueScalePercent(self: *EngineState, nnue_scale_percent: u16) void {
        self.nnue_scale_percent = nnue_scale_percent;
        self.scale_explicit = true;
    }

    /// Adopt the loaded net's expected scale unless the user pinned one.
    fn adoptNetScale(self: *EngineState) void {
        if (self.scale_explicit) return;
        if (self.net) |net| self.nnue_scale_percent = autoScalePercent(net);
    }

    pub fn loadModelFile(self: *EngineState, path: []const u8) !void {
        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, builtin_eval_file)) {
            const net = try nnue768.loadDefault(self.allocator);
            errdefer net.destroy(self.allocator);
            self.unload();
            self.net = net;
            self.adoptNetScale();
            return;
        }

        const net = try nnue768.loadFile(self.allocator, trimmed);
        errdefer net.destroy(self.allocator);
        const stored_path = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(stored_path);
        self.unload();
        self.net = net;
        self.net_path = stored_path;
        self.adoptNetScale();
    }

    pub fn evalFilePath(self: *const EngineState) []const u8 {
        if (self.net_path) |p| return p;
        return builtin_eval_file;
    }

    /// Recompute both perspective accumulators at the search root, and invalidate
    /// the finny (accumulator-refresh) cache so this search starts cold. For v6
    /// full-threat (ZQB9) nets, also re-anchor the shared full-threat bitset state
    /// at the root (full enumeration, empty path stack, cold flip cache).
    pub fn prepareRoot(self: *const EngineState, stack: *search_stack.SearchStack, pos: *const position.Position, finny: *nnue768.FinnyTable, ft: *nnue768.FullThreatState) void {
        finny.reset();
        stack.clean_depth = 0;
        if (self.net) |net| {
            stack.entry(0).acc.refresh(net, pos);
            if (net.full_threats) ft.prepare(pos);
        }
    }

    /// LAZY (nps package, 2026-07-17; R4b reconstruction, 2026-07-18): record only
    /// the move and mark the child dirty — the 6KB+ accumulator update is deferred
    /// until an eval actually needs it (ensureMaterialized). Nodes that cut before
    /// evaluating (TT/RFP-hint cutoffs, TT-eval reuse) never pay the update at all.
    /// The POST-move boards applyMove needs are no longer snapshotted eagerly
    /// (~210B Position copy per make, a store-forward-stall family in the make
    /// path); they are reconstructed on demand at materialization time from the
    /// live position via unmake/re-make, using the parent stack entries' live
    /// StateInfos (each stays valid until its own unmake, which cannot precede
    /// any materialization inside its subtree).
    pub inline fn onMakeMove(
        self: *const EngineState,
        stack: *search_stack.SearchStack,
        mv: move_mod.Move,
        parent_ply: usize,
    ) void {
        if (self.net != null) {
            const child = stack.entry(parent_ply + 1);
            child.acc_state = .dirty_move;
            child.pending_mv = mv;
            // The clean prefix can never extend past this make's parent.
            if (stack.clean_depth > parent_ply) stack.clean_depth = parent_ply;
        }
    }

    /// A null move changes no pieces: defer the parent copy like any other make.
    pub fn onMakeNullMove(self: *const EngineState, stack: *search_stack.SearchStack, parent_ply: usize) void {
        if (self.net != null) {
            stack.entry(parent_ply + 1).acc_state = .dirty_null;
            if (stack.clean_depth > parent_ply) stack.clean_depth = parent_ply;
        }
    }

    /// Materialize the accumulator chain up to `ply`: walk up the CURRENT ancestor
    /// line to the nearest clean entry (the root is always clean via prepareRoot),
    /// then apply the deferred updates downward. Every pending entry was written
    /// by a make on the live line, so its move plus the PARENT entry's still-live
    /// StateInfo are exactly the eager path's inputs; the POST-move boards are
    /// reconstructed from the live `pos` (which IS the board at `ply`) by unmaking
    /// down to the first pending ply and re-making upward — make/unmake round
    /// trips are bit-exact (zobrist included), so the accumulators come out
    /// bit-identical to the eager path's, just computed only on the paths that
    /// actually evaluate. The common single-pending case touches no scratch board
    /// at all: `pos` is already the board applyMove needs.
    fn ensureMaterialized(self: *const EngineState, stack: *search_stack.SearchStack, ply: usize, pos: *const position.Position, finny: *nnue768.FinnyTable, ft: *nnue768.FullThreatState) void {
        const net = self.net orelse return;
        // The contiguous clean prefix is tracked, not rediscovered: `ply <=
        // clean_depth` means this entry is already this ply's accumulator, and
        // otherwise every entry in (clean_depth, ply] was dirtied by a make on the
        // live line, so clean_depth IS the walk's start. (Entries deeper than the
        // live ply may still read `.clean` from an abandoned sibling branch — the
        // old scan was safe only because it started at `ply` and stopped at the
        // first clean entry, which is exactly this same value.)
        if (ply <= stack.clean_depth) return;
        const top = stack.clean_depth;

        // Multi-ply chain: rewind a scratch copy of the live board to the first
        // pending ply's POST-move position (dirty flags still distinguish null
        // makes from real makes at this point — they are cleared only below).
        var scratch: position.Position = undefined;
        if (top + 1 < ply) {
            scratch = pos.*;
            var j = ply;
            while (j > top + 1) : (j -= 1) {
                if (stack.entry(j).acc_state == .dirty_null)
                    make_unmake.unmakeNullMove(&scratch, &stack.entry(j - 1).state)
                else
                    make_unmake.unmakeMove(&scratch, stack.entry(j).pending_mv, &stack.entry(j - 1).state);
            }
        }

        // v6 full threats (ZQB9): bring the SHARED bitset pair to this line's
        // state at `top` before the walk — it may sit deeper, or on an already-
        // unmade sibling branch whose per-ply records still describe its actual
        // path. The fused walk below then re-advances it move by move, so after
        // every materialization the bitsets' path == the stack's contiguous
        // clean prefix (which is why `top` is always a valid unwind target and
        // ft.depth >= top always holds). Plain-delta history unwinds exactly
        // (XOR toggles are self-inverse); a barrier in the unwound span (flip
        // refresh / delta overflow — not undoable in place) instead resets the
        // bitsets by full re-enumeration at the `top` board, reconstructed with
        // one extra unmake off the deepest scratch/live board (always possible:
        // `top` is on the live line). Records at or below `top` stay valid
        // either way (the re-enumerated bitsets are bit-identical to the
        // delta-maintained ones).
        if (net.full_threats and ft.depth > top) {
            if (ft.unwindNeedsReset(top)) {
                var base: position.Position = if (top + 1 < ply) scratch else pos.*;
                if (stack.entry(top + 1).acc_state == .dirty_null)
                    make_unmake.unmakeNullMove(&base, &stack.entry(top).state)
                else
                    make_unmake.unmakeMove(&base, stack.entry(top + 1).pending_mv, &stack.entry(top).state);
                ft.resetAt(&base, top);
            } else {
                ft.unwindTo(top);
            }
        }
        if (net.full_threats) std.debug.assert(ft.depth == top);

        var k = top + 1;
        while (true) : (k += 1) {
            const e = stack.entry(k);
            const parent = stack.entry(k - 1);
            const board: *const position.Position = if (k == ply) pos else &scratch;
            switch (e.acc_state) {
                .clean => {},
                .dirty_null => {
                    e.acc.copyFrom(&parent.acc, net);
                    if (net.full_threats) ft.advanceNull();
                },
                .dirty_move => {
                    // ONE decode of the move's piece feature list per materialized
                    // move, shared by the HalfKA update and the full-threat delta
                    // (they each used to decode it, and each copied the result out
                    // of a by-value aggregate — a store-to-load-forwarding stall
                    // that showed as ~2% of total cycles across the two sites).
                    var chg: [nnue768.MAX_MOVE_CHANGES]nnue768.Change = undefined;
                    const nchg = nnue768.decodeMoveChanges(e.pending_mv, &parent.state, &chg);
                    e.acc.applyMove(&parent.acc, net, e.pending_mv, &parent.state, board, finny, chg[0..nchg]);
                    if (net.full_threats) ft.advanceMove(net, &e.acc, &parent.acc, chg[0..nchg], board);
                },
            }
            e.acc_state = .clean;
            if (k == ply) break;
            // Advance the scratch board to the next pending ply — unless that ply
            // is `ply` itself, whose board is the live `pos`.
            if (k + 1 < ply) {
                var tmp: make_unmake.StateInfo = undefined;
                if (stack.entry(k + 1).acc_state == .dirty_null)
                    make_unmake.makeNullMove(&scratch, &tmp)
                else
                    _ = make_unmake.makeMove(&scratch, stack.entry(k + 1).pending_mv, &tmp);
            }
        }
        stack.clean_depth = ply;
    }

    /// Evaluate from the maintained accumulator at `ply` (output layer only),
    /// materializing any deferred updates first.
    pub fn evaluate(self: *const EngineState, stack: *search_stack.SearchStack, ply: usize, pos: *const position.Position, finny: *nnue768.FinnyTable, ft: *nnue768.FullThreatState) i32 {
        const net = self.net orelse return 0;
        self.ensureMaterialized(stack, ply, pos, finny, ft);
        // ZQB9 full threats FIRST (a ZQB9 net also sets net.threats — the lean
        // dispatch below would read unmaintained lean bitsets against full rows):
        // HalfKA halves + the separate threat halves + maintained PSQT scalars,
        // summed lane-wise into the layerstack readout.
        if (net.full_threats) {
            const inc = nnue768.evaluateFull9Incremental(net, &stack.entry(ply).acc, pos, self.nnue_scale_percent);
            if (builtin.mode == .Debug and verify_threats_incremental)
                std.debug.assert(inc == nnue768.evaluate(net, pos, self.nnue_scale_percent));
            return inc;
        }
        // ZQB5 threats: the accumulator is maintained incrementally (HalfKA + threats via
        // applyMove), so eval is just the readout + PSQT — no per-node copy or row-adds.
        // Debug builds cross-check every node against the full refresh (the correctness gate).
        if (net.threats) {
            const inc = nnue768.evaluateThreatsIncremental(net, &stack.entry(ply).acc, pos, self.nnue_scale_percent);
            if (builtin.mode == .Debug and verify_threats_incremental)
                std.debug.assert(inc == nnue768.evaluate(net, pos, self.nnue_scale_percent));
            return inc;
        }
        return nnue768.evaluateAcc(net, &stack.entry(ply).acc, pos.side_to_move, @popCount(pos.occupancy()), self.nnue_scale_percent);
    }

    pub fn hiddenSize(self: *const EngineState) usize {
        return if (self.net) |net| net.hidden else 0;
    }

    pub fn nnueScalePercent(self: *const EngineState) u16 {
        return self.nnue_scale_percent;
    }

    pub fn backendName(self: *const EngineState) []const u8 {
        _ = self;
        return "nnue768";
    }

    fn unload(self: *EngineState) void {
        if (self.net) |net| {
            net.destroy(self.allocator);
            self.net = null;
        }
        if (self.net_path) |p| {
            self.allocator.free(p);
            self.net_path = null;
        }
    }
};

test "engine state loads the builtin default net and evaluates out-of-the-box" {
    const fen = @import("../core/fen.zig");
    var state = try EngineState.init(std.testing.allocator, .{});
    defer state.deinit();
    try std.testing.expectEqualStrings(builtin_eval_file, state.evalFilePath());
    try std.testing.expect(state.net != null);

    // Eval via the full-refresh reference (the search path uses the incremental
    // accumulator; nnue768 has dedicated bit-exactness + accumulator tests).
    const start = try fen.startpos();
    const up_queen = try fen.parse("rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    try std.testing.expect(@abs(nnue768.evaluate(state.net.?, &start, default_nnue_scale_percent)) < 120);
    try std.testing.expect(nnue768.evaluate(state.net.?, &up_queen, default_nnue_scale_percent) > 300);
}

test "nnue scale percent rescales the evaluation magnitude" {
    const fen = @import("../core/fen.zig");
    const up_queen = try fen.parse("rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    var state = try EngineState.init(std.testing.allocator, .{});
    defer state.deinit();
    try std.testing.expect(nnue768.evaluate(state.net.?, &up_queen, 100) > nnue768.evaluate(state.net.?, &up_queen, 50));
}

/// ZQB9 walk harness: drives legal-move trees through the REAL backend plumbing —
/// makeMove into the stack entry's StateInfo (exactly the search's wiring),
/// onMakeMove/onMakeNullMove lazy marking, and EngineState.evaluate (which runs
/// ensureMaterialized: the fused HalfKA walk + FullThreatState unwind/advance).
/// Every checked node asserts incremental == evaluateFull9 refresh (via
/// nnue768.evaluate's full_threats dispatch). `eval_every=false` evaluates only
/// a sparse subset of nodes, so materializations regularly start several plies
/// up and after sibling-branch bitset excursions — the path-stack unwind (and
/// its barrier-reset fallback) is exactly what that stresses.
const Zqb9Walker = struct {
    state: *const EngineState,
    stack: *search_stack.SearchStack,
    finny: *nnue768.FinnyTable,
    ft: *nnue768.FullThreatState,
    eval_every: bool,
    counter: u32 = 0,

    fn checkEval(self: *Zqb9Walker, pos: *const position.Position, ply: usize) !void {
        const net = self.state.net.?;
        const inc = self.state.evaluate(self.stack, ply, pos, self.finny, self.ft);
        try std.testing.expectEqual(nnue768.evaluate(net, pos, self.state.nnue_scale_percent), inc);
    }

    fn walk(self: *Zqb9Walker, pos: *position.Position, ply: usize, depth: u8) !void {
        const legal = @import("../movegen/legal.zig");
        self.counter +%= 1;
        if (self.eval_every or self.counter % 4 == 0)
            try self.checkEval(pos, ply);
        if (depth == 0) return;

        // Null-move probe (not in check — the search's null gate): exercises
        // dirty_null materialization + the empty full-threat path record.
        if (!legal.isInCheck(pos, pos.side_to_move)) {
            make_unmake.makeNullMove(pos, &self.stack.entry(ply).state);
            self.state.onMakeNullMove(self.stack, ply);
            try self.checkEval(pos, ply + 1);
            make_unmake.unmakeNullMove(pos, &self.stack.entry(ply).state);
        }

        var moves = move_mod.MoveList.init();
        legal.generate(pos, &moves);
        for (moves.slice()) |mv| {
            _ = make_unmake.makeMove(pos, mv, &self.stack.entry(ply).state);
            self.state.onMakeMove(self.stack, mv, ply);
            try self.walk(pos, ply + 1, depth - 1);
            make_unmake.unmakeMove(pos, mv, &self.stack.entry(ply).state);
        }
    }
};

const Zqb9Fixture = struct {
    state: EngineState,
    stack: *search_stack.SearchStack,
    finny: *nnue768.FinnyTable,
    ft: *nnue768.FullThreatState,

    fn init(allocator: std.mem.Allocator) !Zqb9Fixture {
        const blob = try nnue768.buildZqb9TestBlob(allocator);
        defer allocator.free(blob);
        const net = try nnue768.loadFromBytes(allocator, blob);
        errdefer net.destroy(allocator);
        const stack = try allocator.create(search_stack.SearchStack);
        errdefer allocator.destroy(stack);
        stack.* = .{};
        const finny = try allocator.create(nnue768.FinnyTable);
        errdefer allocator.destroy(finny);
        finny.* = .{};
        const ft = try allocator.create(nnue768.FullThreatState);
        errdefer allocator.destroy(ft);
        ft.* = .{};
        return .{
            .state = EngineState{ .allocator = allocator, .nnue_scale_percent = 100, .net = net },
            .stack = stack,
            .finny = finny,
            .ft = ft,
        };
    }

    fn deinit(self: *Zqb9Fixture) void {
        const allocator = self.state.allocator;
        self.state.deinit(); // destroys the net
        allocator.destroy(self.stack);
        allocator.destroy(self.finny);
        allocator.destroy(self.ft);
    }

    fn run(self: *Zqb9Fixture, fen_text: []const u8, depth: u8, eval_every: bool) !void {
        const fen = @import("../core/fen.zig");
        var pos = try fen.parse(fen_text);
        self.stack.* = .{}; // fresh acc_state/pending per position, like a new search context
        self.state.prepareRoot(self.stack, &pos, self.finny, self.ft);
        var walker = Zqb9Walker{
            .state = &self.state,
            .stack = self.stack,
            .finny = self.finny,
            .ft = self.ft,
            .eval_every = eval_every,
        };
        try walker.walk(&pos, 0, depth);
    }
};

test "backend ZQB9 full-threats incremental matches refresh over game trees" {
    // The Block B correctness gate: depth-3 trees through the real backend
    // (make, unmake, re-make down different branches, EP, castling, promotions,
    // mirror-flip crossings, null moves), incremental == evaluateFull9 at EVERY
    // node. Positions: startpos; kiwipete (castling both sides + e/d-file king
    // moves = flip barriers); a promotion tangle; a mixed-flip endgame (Ka5
    // flip 0 vs Kh4 flip 7, king walks crossing d/e).
    var fx = try Zqb9Fixture.init(std.testing.allocator);
    defer fx.deinit();
    try fx.run("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 3, true);
    try fx.run("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3, true);
    try fx.run("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 3, true);
    try fx.run("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 3, true);
}

test "backend ZQB9 full-threats lazy materialization matches refresh" {
    // Sparse-eval mirror of the lean path's lazy guard (engine.zig's real-search
    // test): only ~1/4 of nodes evaluate, so ensureMaterialized routinely starts
    // multi-ply dirty chains and must first unwind the shared bitsets off
    // already-abandoned sibling branches — including THROUGH flip barriers
    // (the re-enumeration reset path).
    var fx = try Zqb9Fixture.init(std.testing.allocator);
    defer fx.deinit();
    try fx.run("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3, false);
    try fx.run("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 3, false);
    try fx.run("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 3, false);
}
