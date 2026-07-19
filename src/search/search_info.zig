const move_mod = @import("../core/move.zig");
const Move = move_mod.Move;

/// How a reported score relates to the true score. `exact` is a fully-resolved
/// iteration; `lower`/`upper` are aspiration-window fail-high/fail-low partials
/// (UCI `lowerbound`/`upperbound`).
pub const ScoreBound = enum { exact, lower, upper };

/// A single `info depth ... pv ...` line produced after a completed iteration
/// (or an aspiration fail). `pv[0]` is expected to equal `best_move` when set.
pub const IterationInfo = struct {
    depth: u16,
    seldepth: u16,
    score: i32,
    bound: ScoreBound = .exact,
    nodes: u64,
    time_ms: u64,
    hashfull: u16,
    best_move: ?Move,
    pv: []const Move,
};

/// An `info depth ... currmove ... currmovenumber ...` progress line.
pub const CurrMoveInfo = struct {
    depth: u16,
    move: Move,
    move_number: u16,
    time_ms: u64,
};

pub const InfoMessage = union(enum) {
    iteration: IterationInfo,
    currmove: CurrMoveInfo,
};

/// A type-erased sink the search layer calls to stream UCI info lines. The UCI
/// worker supplies the implementation; tools/tests leave it null (no output,
/// search is byte-for-byte identical).
pub const InfoEmitter = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, msg: InfoMessage) void,

    pub fn emit(self: InfoEmitter, msg: InfoMessage) void {
        self.emit_fn(self.ctx, msg);
    }
};
