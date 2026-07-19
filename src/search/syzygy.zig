//! Syzygy tablebase probing via Fathom (deps/fathom, BSD). Disabled unless a
//! SyzygyPath is set — with no path, probeWdl always returns null and play is
//! bit-identical to a TB-less build.
const std = @import("std");
const position = @import("../core/position.zig");
const score_mod = @import("score.zig");
const types = @import("../core/types.zig");

extern fn tb_init(path: [*:0]const u8) bool;
extern fn tb_free() void;
extern var TB_LARGEST: c_uint;
extern fn tb_probe_wdl_impl(
    white: u64,
    black: u64,
    kings: u64,
    queens: u64,
    rooks: u64,
    bishops: u64,
    knights: u64,
    pawns: u64,
    ep: c_uint,
    turn: bool,
) c_uint;

const TB_LOSS: c_uint = 0;
const TB_BLESSED_LOSS: c_uint = 1;
const TB_DRAW: c_uint = 2;
const TB_CURSED_WIN: c_uint = 3;
const TB_WIN: c_uint = 4;
const TB_RESULT_FAILED: c_uint = 0xFFFFFFFF;

/// Clearly above any eval, clearly below the mate band (MATE_SCORE 29_000,
/// threshold 28_872): a proven TB win outranks judgment, never masquerades
/// as a concrete mate.
pub const TB_WIN_SCORE: types.Score = 28_000;

var initialized: bool = false;
var largest: u32 = 0;

pub fn init(path: [:0]const u8) bool {
    if (initialized) tb_free();
    initialized = tb_init(path.ptr);
    largest = if (initialized) @intCast(TB_LARGEST) else 0;
    if (largest == 0) initialized = false;
    return initialized;
}

pub fn disable() void {
    if (initialized) tb_free();
    initialized = false;
    largest = 0;
}

pub fn enabled() bool {
    return initialized;
}

pub fn pieceLimit() u32 {
    return largest;
}

pub const Wdl = enum { loss, draw, win };

/// WDL probe. Null when disabled, position out of TB scope, or probing is
/// unsound (castling rights, nonzero halfmove clock — Fathom's WDL tables
/// assume a fresh rule-50 counter). Cursed wins / blessed losses collapse to
/// draw (the 50-move rule saves/dooms them).
pub fn probeWdl(pos: *const position.Position) ?Wdl {
    if (!initialized) return null;
    if (@popCount(pos.occupied) > largest) return null;
    const cr = pos.castling_rights;
    if (cr.white_king_side or cr.white_queen_side or cr.black_king_side or cr.black_queen_side) return null;
    if (pos.halfmove_clock != 0) return null;

    const ep: c_uint = if (pos.en_passant) |sq| @intFromEnum(sq) else 0;
    const result = tb_probe_wdl_impl(
        pos.occupancyFor(.white),
        pos.occupancyFor(.black),
        pos.pieceBitboard(.white, .king) | pos.pieceBitboard(.black, .king),
        pos.pieceBitboard(.white, .queen) | pos.pieceBitboard(.black, .queen),
        pos.pieceBitboard(.white, .rook) | pos.pieceBitboard(.black, .rook),
        pos.pieceBitboard(.white, .bishop) | pos.pieceBitboard(.black, .bishop),
        pos.pieceBitboard(.white, .knight) | pos.pieceBitboard(.black, .knight),
        pos.pieceBitboard(.white, .pawn) | pos.pieceBitboard(.black, .pawn),
        ep,
        pos.side_to_move == .white,
    );
    return switch (result) {
        TB_WIN => .win,
        TB_LOSS => .loss,
        TB_DRAW, TB_CURSED_WIN, TB_BLESSED_LOSS => .draw,
        else => null,
    };
}

/// Side-to-move-relative score for a TB verdict, ply-adjusted so nearer
/// conversions rank higher, mirroring mate-score conventions.
pub fn wdlScore(wdl: Wdl, ply: usize) types.Score {
    return switch (wdl) {
        .win => TB_WIN_SCORE - @as(types.Score, @intCast(ply)),
        .loss => -TB_WIN_SCORE + @as(types.Score, @intCast(ply)),
        .draw => 0,
    };
}

test "syzygy init smoke (opt-in via ZQ_TB_PATH)" {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return;
    defer std.testing.allocator.free(path);
    const pathz = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(pathz);
    const ok = init(pathz);
    std.debug.print("\nsyzygy init ok={} largest={}\n", .{ ok, pieceLimit() });
    try std.testing.expect(ok);
    try std.testing.expect(pieceLimit() >= 5);
    disable();
}
