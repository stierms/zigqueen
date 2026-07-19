const position = @import("position.zig");
const square = @import("square.zig");
const types = @import("types.zig");
const piece = @import("piece.zig");

pub const PIECE_KEYS = initPieceKeys();
pub const PIECE_SQUARE_KEYS = initPieceSquareKeys();
pub const CASTLING_KEYS = initCastlingKeys();
pub const EN_PASSANT_FILE_KEYS = initEpFileKeys();
pub const SIDE_TO_MOVE_KEY = initSideToMoveKey();

pub fn hashPosition(pos: *const position.Position) u64 {
    var key: u64 = 0;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        const p = pos.pieceAt(sq);
        if (p == .none) continue;
        key ^= PIECE_SQUARE_KEYS[@intFromEnum(p)][idx];
    }

    key ^= CASTLING_KEYS[castlingIndex(pos.castling_rights)];
    if (pos.en_passant) |ep| key ^= EN_PASSANT_FILE_KEYS[ep.file()];
    if (pos.side_to_move == .black) key ^= SIDE_TO_MOVE_KEY;
    return key;
}

pub inline fn castlingIndex(rights: position.CastlingRights) usize {
    return @as(u4, @bitCast(rights));
}

fn initPieceKeys() [2][6][64]u64 {
    @setEvalBranchQuota(20_000);
    var seed: u64 = 0x9E37_79B9_7F4A_7C15;
    var table: [2][6][64]u64 = undefined;
    for (0..2) |side| {
        for (0..6) |piece_type| {
            for (0..64) |sq| {
                table[side][piece_type][sq] = nextRandom(&seed);
            }
        }
    }
    return table;
}

fn initPieceSquareKeys() [13][64]u64 {
    @setEvalBranchQuota(20_000);
    var table = [_][64]u64{[_]u64{0} ** 64} ** 13;
    for (0..2) |side| {
        for (0..6) |piece_type| {
            const p = piece.Piece.make(@enumFromInt(side), @enumFromInt(piece_type));
            table[@intFromEnum(p)] = PIECE_KEYS[side][piece_type];
        }
    }
    return table;
}

fn initCastlingKeys() [16]u64 {
    @setEvalBranchQuota(20_000);
    var seed: u64 = 0x243F_6A88_85A3_08D3;
    var table: [16]u64 = undefined;
    for (0..16) |i| table[i] = nextRandom(&seed);
    return table;
}

fn initEpFileKeys() [8]u64 {
    @setEvalBranchQuota(20_000);
    var seed: u64 = 0x1319_8A2E_0370_7344;
    var table: [8]u64 = undefined;
    for (0..8) |i| table[i] = nextRandom(&seed);
    return table;
}

fn initSideToMoveKey() u64 {
    var seed: u64 = 0xA409_3822_299F_31D0;
    return nextRandom(&seed);
}

fn nextRandom(seed: *u64) u64 {
    seed.* +%= 0x9E37_79B9_7F4A_7C15;
    var z = seed.*;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

test "zobrist distinguishes side to move" {
    const fen = @import("fen.zig");
    const white = try fen.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1");
    const black = try fen.parse("4k3/8/8/8/8/8/8/4K3 b - - 0 1");
    try @import("std").testing.expect(white.zobrist_key != black.zobrist_key);
}
