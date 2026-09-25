//! Standalone test root: force worker test discovery when filtering for TSAN.
comptime {
    _ = @import("uci/worker.zig");
}
