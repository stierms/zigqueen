const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");

const KNIGHT_PHASE: i32 = 1;
const BISHOP_PHASE: i32 = 1;
const ROOK_PHASE: i32 = 2;
const QUEEN_PHASE: i32 = 4;
const TOTAL_PHASE: i32 = KNIGHT_PHASE * 4 + BISHOP_PHASE * 4 + ROOK_PHASE * 4 + QUEEN_PHASE * 2;

pub fn phase256(pos: *const position.Position) u16 {
    return phase256FromCounts(
        pos.countPieces(.white, .knight) + pos.countPieces(.black, .knight),
        pos.countPieces(.white, .bishop) + pos.countPieces(.black, .bishop),
        pos.countPieces(.white, .rook) + pos.countPieces(.black, .rook),
        pos.countPieces(.white, .queen) + pos.countPieces(.black, .queen),
    );
}

pub fn phase256FromCounts(knights: u8, bishops: u8, rooks: u8, queens: u8) u16 {
    var phase = TOTAL_PHASE;
    phase -= @as(i32, knights) * KNIGHT_PHASE;
    phase -= @as(i32, bishops) * BISHOP_PHASE;
    phase -= @as(i32, rooks) * ROOK_PHASE;
    phase -= @as(i32, queens) * QUEEN_PHASE;
    if (phase < 0) phase = 0;
    if (phase > TOTAL_PHASE) phase = TOTAL_PHASE;
    return @intCast(@divTrunc(phase * 256 + TOTAL_PHASE / 2, TOTAL_PHASE));
}

test "phase moves from opening toward endgame as pieces disappear" {
    const fen = @import("../core/fen.zig");

    const opening = try fen.startpos();
    const endgame = try fen.parse("8/8/8/8/8/8/4K3/4k3 w - - 0 1");

    try @import("std").testing.expect(phase256(&opening) < phase256(&endgame));
}

test "phase is clamped for promotion-rich positions" {
    const fen = @import("../core/fen.zig");
    const pos = try fen.parse("3b2k1/8/2n1q3/p2p2pr/2pPb3/2P2NB1/1rPQB1P1/q1R2RK1 w - - 0 37");
    try @import("std").testing.expectEqual(@as(u16, 0), phase256(&pos));
}
