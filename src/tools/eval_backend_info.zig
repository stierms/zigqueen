const eval_backend = @import("../eval/backend.zig");

pub fn write(writer: anytype, evaluator: *const eval_backend.EngineState) !void {
    try writer.print("backend {s}\n", .{evaluator.backendName()});
    try writer.print("eval_file {s}\n", .{evaluator.evalFilePath()});
    try writer.print("nnue_scale_percent {d}\n", .{evaluator.nnueScalePercent()});
}
