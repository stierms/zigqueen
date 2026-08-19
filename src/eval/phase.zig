const piece = @import("../core/piece.zig");
const position = @import("../core/position.zig");

const KNIGHT_PHASE: i32 = 1;
const BISHOP_PHASE: i32 = 1;
const ROOK_PHASE: i32 = 2;
const QUEEN_PHASE: i32 = 4;
const TOTAL_PHASE: i32 = KNIGHT_PHASE * 4 + BISHOP_PHASE * 4 + ROOK_PHASE * 4 + QUEEN_PHASE * 2;

pub const PhaseScore = struct {
    mg: i32 = 0,
    eg: i32 = 0,

    pub inline fn add(self: *PhaseScore, mg: i32, eg: i32) void {
        self.mg += mg;
        self.eg += eg;
    }

    pub inline fn sub(self: *PhaseScore, other: PhaseScore) void {
        self.mg -= other.mg;
        self.eg -= other.eg;
    }

    pub inline fn blended(self: PhaseScore, phase_256: u16) i32 {
        return blend(self.mg, self.eg, phase_256);
    }
};

pub inline fn blend(mg: i32, eg: i32, phase_256: u16) i32 {
    const phase_i32 = @as(i32, phase_256);
    return @divTrunc(mg * 256 + (eg - mg) * phase_i32, 256);
}

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

test "phase blend favors endgame score as phase increases" {
    try @import("std").testing.expect(blend(100, 20, 0) > blend(100, 20, 256));
    try @import("std").testing.expect(blend(20, 100, 0) < blend(20, 100, 256));
}

test "phase is clamped for promotion-rich positions" {
    const fen = @import("../core/fen.zig");
    const pos = try fen.parse("3b2k1/8/2n1q3/p2p2pr/2pPb3/2P2NB1/1rPQB1P1/q1R2RK1 w - - 0 37");
    try @import("std").testing.expectEqual(@as(u16, 0), phase256(&pos));
}
