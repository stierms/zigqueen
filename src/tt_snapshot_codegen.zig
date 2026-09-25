//! Stable symbols for inspecting this isolated prototype's atomic lowering.
const proto = @import("probes/tt_snapshot.zig");
const tt = @import("search/tt.zig");

export fn snapshot_store(cluster: *proto.Cluster, input: *const proto.Input) bool {
    return cluster.store(input.*).outcome.stored;
}

export fn snapshot_load(cluster: *const proto.Cluster, key: u64, output: *tt.Entry) bool {
    const entry = cluster.lookup(key) orelse return false;
    output.* = entry;
    return true;
}
