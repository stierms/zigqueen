const std = @import("std");
const context_mod = @import("context.zig");
const eval_backend = @import("../eval/backend.zig");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const stack = @import("stack.zig");
const types = @import("../core/types.zig");

/// Basin verification can deepen by one ply. Keep enough stack tail for that
/// path while sharing the same terminal-aware fallback with recursive qsearch.
pub const START: usize = stack.MAX_PLY - 4;

pub fn fallback(
    ctx: *context_mod.SearchContext,
    evaluator: *eval_backend.EngineState,
    pos: *position.Position,
    ply: usize,
    in_check_hint: ?bool,
) ?types.Score {
    if (ply < START) return null;

    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    var moves = move_mod.MoveList.init();
    legal.generateHinted(pos, &moves, in_check);
    if (moves.count == 0) {
        return if (in_check)
            -score_mod.MATE_SCORE + @as(types.Score, @intCast(ply))
        else
            ctx.drawScore(pos.side_to_move);
    }
    return evaluator.evaluate(&ctx.stack, ply, pos, &ctx.finny, &ctx.ft);
}

test "ply-limit fallback preserves mate and stalemate terminals" {
    const fen = @import("../core/fen.zig");
    const time = @import("time.zig");

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = context_mod.SearchContext{
        .repetition = .{},
        .control = time.Controller.init(&stop_flag, .{}),
    };
    // Terminal branches never evaluate, so a model-less backend isolates the
    // cap's legal-move classification from NNUE state.
    var evaluator = eval_backend.EngineState{ .allocator = std.testing.allocator };

    var mate = try fen.parse("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1");
    try std.testing.expectEqual(
        -score_mod.MATE_SCORE + @as(types.Score, @intCast(START)),
        fallback(&ctx, &evaluator, &mate, START, true).?,
    );

    ctx.contempt = 17;
    ctx.root_color = .white;
    var stalemate = try fen.parse("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1");
    try std.testing.expectEqual(@as(types.Score, 17), fallback(&ctx, &evaluator, &stalemate, START, false).?);
}
