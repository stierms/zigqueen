//! Engine evaluation backend: a single pure-NNUE evaluator.
//!
//! The engine evaluates exclusively with the bullet-trained net in
//! `nnue768.zig` (ZQB container formats, currently a ZQB8 HalfKA + threats +
//! layerstack net). Per-ply white/black accumulators are maintained
//! incrementally across make/unmake: `prepareRoot` does one full refresh at
//! the root, then make/unmake record feature deltas that are materialized
//! lazily — only when a node actually evaluates — and `evaluate` runs the
//! readout over the materialized accumulator. `nnue768.evaluate` (full
//! refresh) remains the bit-exact correctness reference.

const std = @import("std");
const builtin = @import("builtin");
const nnue768 = @import("nnue768.zig");
const position = @import("../core/position.zig");
const move_mod = @import("../core/move.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const search_stack = @import("../search/stack.zig");

pub const builtin_eval_file = "<builtin>";

/// Opt-in cross-check: when true (Debug only), every threats eval asserts the
/// incrementally-maintained accumulator matches a full refresh. Off by default
/// so search-logic unit tests can drive eval paths on an uninitialized root
/// accumulator (they assert on moves/scores, not eval magnitudes). The dedicated
/// `threats incremental == refresh` test flips this on and runs a real search
/// (with prepareRoot) across a battery of positions — that's the standing guard.
pub var verify_threats_incremental: bool = false;

/// Single source of truth for the default NNUE output scale (percent). Raw net
/// output is multiplied by net.scale * this/100 before search uses it. The value
/// is calibrated per shipped net (distribution-matched to the centipawn regime
/// the search's pruning margins were tuned against), so it changes across
/// releases with the net.
pub const default_nnue_scale_percent: u16 = 66;

pub const Options = struct {
    nnue_scale_percent: u16 = default_nnue_scale_percent,
    eval_file_path: ?[]const u8 = null,
};

pub const EngineState = struct {
    allocator: std.mem.Allocator,
    nnue_scale_percent: u16 = default_nnue_scale_percent,
    /// The active net (any supported ZQB format). Always set after `init`.
    net: ?*nnue768.Net = null,
    /// Owned path of a file-loaded net; null when using the embedded default.
    net_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !EngineState {
        var state = EngineState{
            .allocator = allocator,
            .nnue_scale_percent = options.nnue_scale_percent,
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
    }

    pub fn loadModelFile(self: *EngineState, path: []const u8) !void {
        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, builtin_eval_file)) {
            const net = try nnue768.loadDefault(self.allocator);
            errdefer net.destroy(self.allocator);
            self.unload();
            self.net = net;
            return;
        }

        const net = try nnue768.loadFile(self.allocator, trimmed);
        errdefer net.destroy(self.allocator);
        const stored_path = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(stored_path);
        self.unload();
        self.net = net;
        self.net_path = stored_path;
    }

    pub fn evalFilePath(self: *const EngineState) []const u8 {
        if (self.net_path) |p| return p;
        return builtin_eval_file;
    }

    /// Recompute both perspective accumulators at the search root, and invalidate
    /// the finny (accumulator-refresh) cache so this search starts cold.
    pub fn prepareRoot(self: *const EngineState, stack: *search_stack.SearchStack, pos: *const position.Position, finny: *nnue768.FinnyTable) void {
        finny.reset();
        if (self.net) |net| stack.entry(0).acc.refresh(net, pos);
    }

    /// LAZY: record only
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
        }
    }

    /// A null move changes no pieces: defer the parent copy like any other make.
    pub fn onMakeNullMove(self: *const EngineState, stack: *search_stack.SearchStack, parent_ply: usize) void {
        if (self.net != null) {
            stack.entry(parent_ply + 1).acc_state = .dirty_null;
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
    fn ensureMaterialized(self: *const EngineState, stack: *search_stack.SearchStack, ply: usize, pos: *const position.Position, finny: *nnue768.FinnyTable) void {
        const net = self.net orelse return;
        if (stack.entry(ply).acc_state == .clean) return;
        var top = ply;
        while (top > 0 and stack.entry(top).acc_state != .clean) top -= 1;

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

        var k = top + 1;
        while (true) : (k += 1) {
            const e = stack.entry(k);
            const parent = stack.entry(k - 1);
            const board: *const position.Position = if (k == ply) pos else &scratch;
            switch (e.acc_state) {
                .clean => {},
                .dirty_null => e.acc.copyFrom(&parent.acc, net.hidden),
                .dirty_move => e.acc.applyMove(&parent.acc, net, e.pending_mv, &parent.state, board, finny),
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
    }

    /// Evaluate from the maintained accumulator at `ply` (output layer only),
    /// materializing any deferred updates first.
    pub fn evaluate(self: *const EngineState, stack: *search_stack.SearchStack, ply: usize, pos: *const position.Position, finny: *nnue768.FinnyTable) i32 {
        const net = self.net orelse return 0;
        self.ensureMaterialized(stack, ply, pos, finny);
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
