//! Search lifecycle/clock boundary for the current Zig 0.15.2 toolchain.
//! These are exact aliases, not a scheduler or a second worker pool. Thread
//! creation, stack defaults, synchronization and Timer failure semantics stay
//! unchanged. A future std.Io adaptation must establish an explicit runtime
//! owner/lifetime here; no 0.16 compatibility is claimed by this module.
const std = @import("std");

pub const Thread = std.Thread;
pub const Mutex = std.Thread.Mutex;
pub const Condition = std.Thread.Condition;
pub const Timer = std.time.Timer;
pub const ResetEvent = std.Thread.ResetEvent;
pub const once = std.once;

/// One control-thread-owned runtime lifetime per pool. Zig0.15.2 needs no
/// external I/O service, but every owned OS thread must join before this owner
/// dies. Workers never mutate this accounting. A later std.Io port can own its
/// service here without changing that lifetime contract.
pub const Owner = struct {
    live_threads: usize = 0,
    alive: bool = true,

    pub fn spawn(self: *Owner, config: Thread.SpawnConfig, comptime function: anytype, args: anytype) !Thread {
        std.debug.assert(self.alive);
        const thread = try Thread.spawn(config, function, args);
        self.live_threads += 1;
        return thread;
    }

    pub fn join(self: *Owner, thread: Thread) void {
        std.debug.assert(self.alive and self.live_threads > 0);
        thread.join();
        self.live_threads -= 1;
    }

    pub fn deinit(self: *Owner) void {
        std.debug.assert(self.alive and self.live_threads == 0);
        self.alive = false;
    }
};

test {
    _ = @import("search_runtime_test.zig");
}
