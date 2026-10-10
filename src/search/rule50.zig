const context_mod = @import("context.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

/// A move that mates ends the game at once, before any fifty-move claim can
/// exist. A position whose clock reached 100 is therefore a draw only when the
/// side to move is not already checkmated.
pub fn isCheckmated(pos: *const position.Position, in_check_hint: ?bool) bool {
    const in_check = in_check_hint orelse legal.isInCheck(pos, pos.side_to_move);
    if (!in_check) return false;
    var moves = move_mod.MoveList.init();
    legal.generateHinted(pos, &moves, true);
    return moves.count == 0;
}

/// Interior score for a node at halfmove clock >= 100. The negamax and qsearch
/// entries keep their inline clock test; this body is separate and cold so its
/// move list stays out of both recursive frames (same reason as ply_limit.zig).
pub noinline fn interiorScore(
    ctx: *const context_mod.SearchContext,
    pos: *const position.Position,
    ply: usize,
    in_check_hint: ?bool,
) types.Score {
    @branchHint(.cold);
    if (isCheckmated(pos, in_check_hint)) return -score_mod.MATE_SCORE + @as(types.Score, @intCast(ply));
    return ctx.drawScore(pos.side_to_move);
}

/// First legal root move that checkmates, for a root that is already past the
/// fifty-move clock: every other move there is a claimable draw, this one wins.
pub fn matingMove(pos: *const position.Position, allowed: ?*const move_mod.MoveList) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        if (allowed) |list| {
            var listed = false;
            for (list.slice()) |candidate| {
                if (candidate == mv) listed = true;
            }
            if (!listed) continue;
        }
        var child = pos.*;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&child, mv, &state);
        if (isCheckmated(&child, null)) return mv;
    }
    return null;
}
