//! zigqueen's own Syzygy WDL/DTZ prober, implemented from
//! docs/SYZYGY_FORMAT.md. Module layout as in the spec's §12:
//! types, index (comptime tables), format (headers), decode (§6), storage
//! (MmapAll, MmapBudget, Pread), registry (snapshots), probe (§7-§9).
pub const types = @import("types.zig");
pub const index = @import("index.zig");
pub const format = @import("format.zig");
pub const decode = @import("decode.zig");
pub const storage = @import("storage.zig");
pub const registry = @import("registry.zig");
pub const probe = @import("probe.zig");

pub const Wdl5 = types.Wdl5;
pub const Dtz = types.Dtz;
pub const ProbeError = types.ProbeError;
pub const RootRanking = types.RootRanking;
pub const RootRecord = types.RootRecord;
pub const Registry = registry.Registry;
pub const Snapshot = registry.Snapshot;
pub const Prober = probe.Prober;

test {
    _ = types;
    _ = index;
    _ = format;
    _ = decode;
    _ = storage;
    _ = registry;
    _ = probe;
    _ = @import("tb_test.zig");
}
