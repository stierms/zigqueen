//! Process-wide cold initialization. Freeze ZQ_TM_* before first use; changing
//! the environment concurrently with initialization is unsupported. The sole
//! owner performs only infallible work (environment errors retain defaults).
//! There is no reset/cancellation path. Later tuning writes require every
//! search and constructor in the process to be quiescent, with one writer.
const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
const builtin = @import("builtin");
const time = @import("time.zig");
const reductions = @import("reductions.zig");

const State = enum(u8) { cold, initializing, ready };
var state = std.atomic.Value(State).init(.cold);
var tm_snapshot: time.TmConfig = undefined;
var lmr_table: reductions.LmrTable = undefined;

pub fn isReady() bool {
    return state.load(.acquire) == .ready;
}

/// Called by every Engine constructor, cold TM APIs and tuning setters.
/// Calls only unguarded, data-building functions: neither calls ensure again.
pub fn ensure() void {
    if (isReady()) return;
    if (state.cmpxchgStrong(.cold, .initializing, .acq_rel, .acquire) == null) {
        tm_snapshot = time.loadTmConfigFromEnv();
        reductions.buildLmrTable(&lmr_table, reductions.LMR_BASE_100_DEFAULT, reductions.LMR_DIVISOR_100_DEFAULT);
        state.store(.ready, .release);
        return;
    }
    while (!isReady()) runtime.Thread.yield() catch {};
}

pub fn tmConfig() time.TmConfig {
    ensure();
    return tm_snapshot;
}

/// Hot reader: Engine construction (or explicit cold setup) has already
/// acquired publication. No once check or atomic instruction in release search.
pub fn lmrTable() *const reductions.LmrTable {
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
        std.debug.assert(isReady());
    return &lmr_table;
}

/// Quiescent-only mutation, not concurrent configuration support. The caller
/// must stop ALL process readers/constructors, not only one UCI worker.
pub fn applyLmrShape(base_100: i32, divisor_100: i32) void {
    ensure();
    reductions.buildLmrTable(&lmr_table, base_100, divisor_100);
}
