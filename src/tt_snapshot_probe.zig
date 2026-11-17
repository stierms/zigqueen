//! Root for running the shared cluster protocol's tests alone, with the
//! build's options module: `zig test --dep build_options
//! -Mroot=src/tt_snapshot_probe.zig -Mbuild_options=<options.zig>`. They also
//! run in `zig build test`.
test {
    _ = @import("probes/tt_snapshot.zig");
}
