//! Stable symbols for inspecting the shared cluster protocol's atomic lowering.
const proto = @import("probes/tt_snapshot.zig");
const tt = @import("search/tt.zig");

export fn snapshot_store(cluster: *proto.Cluster, input: *const proto.Input) bool {
    return proto.store(cluster, input.*, .{}).outcome.stored;
}

export fn snapshot_load(cluster: *const proto.Cluster, key: u64, generation: u8, output: *tt.Entry) bool {
    const entry = proto.lookup(cluster, tt.tagOf(key), generation) orelse return false;
    output.* = entry;
    return true;
}
