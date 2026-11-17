const eval_backend = @import("../eval/backend.zig");

pub fn write(writer: anytype, evaluator: *const eval_backend.EngineState) !void {
    try writer.print("backend {s}\n", .{evaluator.backendName()});
    try writer.print("eval_file {s}\n", .{evaluator.evalFilePath()});
    try writer.print("nnue_scale_percent {d}\n", .{evaluator.nnueScalePercent()});
    var weights_buf: [160]u8 = undefined;
    try writer.print("nnue_weights {s}\n", .{evaluator.weights.describe(&weights_buf)});
    // Vanished values of the layers after the first that were read as zero
    // (nnue768.readTailF32): a net exported cleanly reports 0.
    if (evaluator.net) |net| try writer.print("nnue_tail_flushed {d}\n", .{net.tail_flushed});
}
