const std = @import("std");
const attack_tables = @import("magic_attack_tables.zig");
const bitboard = @import("../core/bitboard.zig");
const square = @import("../core/square.zig");

pub const MagicEntry = struct {
    mask: bitboard.Bitboard,
    magic: u64,
    shift: u6,
    offset: u32,
};

const Slider = enum {
    bishop,
    rook,
};

// Clean-room generated locally by brute-force search over relevant occupancies.
pub const BISHOP_MAGIC_NUMBERS = [64]u64{
    0x8204410821011200,
    0x0020085100408110,
    0x08101400a0201110,
    0x1004051204400130,
    0x8001104000900800,
    0x0488221010005000,
    0x100100e82008005a,
    0x2004d28210026001,
    0x2800048802040404,
    0x002010a400809200,
    0x0486102100451001,
    0x000009040d000000,
    0x2004045041061809,
    0x802002084aa80090,
    0x1004204430080840,
    0x0800218404090542,
    0x20080020200400b0,
    0x000c0010300244d0,
    0x0450200208820008,
    0x4008008088210000,
    0x0081001811400808,
    0x002b010610020100,
    0x1020801100901180,
    0x220100a600a08418,
    0x0008080006103040,
    0x0401208208084901,
    0x0088080041020127,
    0x3004004204010002,
    0x4021004044004040,
    0x82480040020100c0,
    0x04a0940003114800,
    0x4022122000441a04,
    0x001202a048400900,
    0x6842100406102110,
    0x8004004800104088,
    0x4100020080080080,
    0x6004004010040100,
    0x1220004080010088,
    0x0401210200810820,
    0x6a08008080110450,
    0xc008088451000400,
    0x000200b004208800,
    0x0103018050004109,
    0x00028bc050424200,
    0x8001480100440c08,
    0x0522300206822808,
    0x00200800a0800100,
    0x4302548401004183,
    0x4500840420050005,
    0x0040440441080220,
    0x5102042a01100240,
    0x0710000820880800,
    0x6003001002020400,
    0x0040041042020800,
    0x24a0200410988001,
    0x2220090405005540,
    0x8020828405203200,
    0x00d00080a0882010,
    0x1800890114012401,
    0x00800410c4421208,
    0x0904100040038200,
    0x0862880920240420,
    0x2001606102020048,
    0x0008010404004200,
};

pub const ROOK_MAGIC_NUMBERS = [64]u64{
    0x2200102081020040,
    0x1040400020001000,
    0x4100100900200044,
    0xc100040810010020,
    0x0200040200102008,
    0x3200040810010200,
    0x0480088002000900,
    0x0280050010634080,
    0x2004802880004000,
    0x6004802008804000,
    0x0000802000801008,
    0x2014800801801004,
    0x2101001008000500,
    0x0010804200240080,
    0x01020028490a0014,
    0x080200004400892a,
    0x0020208000400088,
    0x2080404000201000,
    0x0005010040142000,
    0x0100808010000802,
    0x0200818008000c00,
    0x0002008002800400,
    0x2020240098101221,
    0x2a02020000a04401,
    0x0000400080208000,
    0x8010004140006000,
    0x4030200080100080,
    0x1002900280080080,
    0xa202004600082010,
    0x0201008900040002,
    0x4003040101000200,
    0x0181244a00042189,
    0x0140004080800030,
    0x0150002000404010,
    0x0000200084801000,
    0x0340090021001000,
    0x0200800800800400,
    0x4002000802001004,
    0x4000d00104004208,
    0x220b003041000082,
    0x428000412000c012,
    0x12100848200d4000,
    0x504a002080120040,
    0x0208010200101000,
    0x4602002108120004,
    0x10104004a0080110,
    0x0034010230040048,
    0x0000004c81060014,
    0x1401002050800100,
    0x0000200040100040,
    0x0002842010460200,
    0x8090801000080080,
    0x0800040080080080,
    0x0084800200040080,
    0xb104021008418400,
    0x000002840a610200,
    0x0248102108800041,
    0x5102c11102002482,
    0x0084400c11002001,
    0x0170a10085100009,
    0x0a21000204080011,
    0x080300840008120b,
    0x000020c801100204,
    0x000004840420410a,
};

pub const BISHOP_MAGICS = initMagicEntries(.bishop, BISHOP_MAGIC_NUMBERS);
pub const ROOK_MAGICS = initMagicEntries(.rook, ROOK_MAGIC_NUMBERS);
pub const BISHOP_ATTACKS = attack_tables.BISHOP_ATTACKS;
pub const ROOK_ATTACKS = attack_tables.ROOK_ATTACKS;

pub inline fn bishopAttacks(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    const entry = BISHOP_MAGICS[sq.index()];
    return BISHOP_ATTACKS[@as(usize, entry.offset) + magicIndex(entry, occupied)];
}

pub inline fn rookAttacks(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    const entry = ROOK_MAGICS[sq.index()];
    return ROOK_ATTACKS[@as(usize, entry.offset) + magicIndex(entry, occupied)];
}

fn initMagicEntries(comptime slider: Slider, comptime magic_numbers: [64]u64) [64]MagicEntry {
    @setEvalBranchQuota(200_000);
    var entries: [64]MagicEntry = undefined;
    var offset: u32 = 0;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        const mask = relevantMask(slider, sq);
        const relevant_bits = bitboard.popCount(mask);
        entries[idx] = .{
            .mask = mask,
            .magic = magic_numbers[idx],
            .shift = @intCast(64 - relevant_bits),
            .offset = offset,
        };
        offset += @as(u32, 1) << @intCast(relevant_bits);
    }

    return entries;
}

inline fn magicIndex(entry: MagicEntry, occupied: bitboard.Bitboard) usize {
    const masked = occupied & entry.mask;
    return @intCast((masked *% entry.magic) >> entry.shift);
}

fn relevantMask(comptime slider: Slider, sq: square.Square) bitboard.Bitboard {
    return switch (slider) {
        .bishop => rayMaskRelevant(sq, 1, 1) |
            rayMaskRelevant(sq, -1, 1) |
            rayMaskRelevant(sq, 1, -1) |
            rayMaskRelevant(sq, -1, -1),
        .rook => rayMaskRelevant(sq, 1, 0) |
            rayMaskRelevant(sq, -1, 0) |
            rayMaskRelevant(sq, 0, 1) |
            rayMaskRelevant(sq, 0, -1),
    };
}

fn rayMaskRelevant(sq: square.Square, file_delta: i8, rank_delta: i8) bitboard.Bitboard {
    var file: i8 = @intCast(sq.file());
    var rank: i8 = @intCast(sq.rank());
    var attacks: bitboard.Bitboard = 0;

    while (true) {
        const next_file = file + file_delta;
        const next_rank = rank + rank_delta;
        if (!isOnBoard(next_file, next_rank)) break;
        file = next_file;
        rank = next_rank;

        if (!isOnBoard(file + file_delta, rank + rank_delta)) break;
        const target = square.Square.fromCoords(@intCast(file), @intCast(rank));
        attacks |= bitboard.bit(target);
    }

    return attacks;
}

fn bishopAttacksReference(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    return rayAttacksReference(sq, occupied, 1, 1) |
        rayAttacksReference(sq, occupied, -1, 1) |
        rayAttacksReference(sq, occupied, 1, -1) |
        rayAttacksReference(sq, occupied, -1, -1);
}

fn rookAttacksReference(sq: square.Square, occupied: bitboard.Bitboard) bitboard.Bitboard {
    return rayAttacksReference(sq, occupied, 1, 0) |
        rayAttacksReference(sq, occupied, -1, 0) |
        rayAttacksReference(sq, occupied, 0, 1) |
        rayAttacksReference(sq, occupied, 0, -1);
}

fn rayAttacksReference(sq: square.Square, occupied: bitboard.Bitboard, file_delta: i8, rank_delta: i8) bitboard.Bitboard {
    var file: i8 = @intCast(sq.file());
    var rank: i8 = @intCast(sq.rank());
    var attacks: bitboard.Bitboard = 0;

    while (true) {
        file += file_delta;
        rank += rank_delta;
        if (!isOnBoard(file, rank)) break;

        const target = square.Square.fromCoords(@intCast(file), @intCast(rank));
        const mask = bitboard.bit(target);
        attacks |= mask;
        if ((occupied & mask) != 0) break;
    }

    return attacks;
}

fn isOnBoard(file: i8, rank: i8) bool {
    return file >= 0 and file < 8 and rank >= 0 and rank < 8;
}

test "bishop magic attacks match step reference" {
    var seed: u64 = 0x9e37_79b9_7f4a_7c15;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        var sample: usize = 0;
        while (sample < 128) : (sample += 1) {
            seed ^= seed << 7;
            seed ^= seed >> 9;
            seed ^= seed << 8;
            const occupied: bitboard.Bitboard = seed;
            try std.testing.expectEqual(bishopAttacksReference(sq, occupied), bishopAttacks(sq, occupied));
        }
    }
}

test "rook magic attacks match step reference" {
    var seed: u64 = 0x517c_c1b7_2722_0a95;

    for (0..64) |idx| {
        const sq = square.Square.fromIndex(@intCast(idx));
        var sample: usize = 0;
        while (sample < 128) : (sample += 1) {
            seed ^= seed << 7;
            seed ^= seed >> 9;
            seed ^= seed << 8;
            const occupied: bitboard.Bitboard = seed;
            try std.testing.expectEqual(rookAttacksReference(sq, occupied), rookAttacks(sq, occupied));
        }
    }
}

test "relevant mask sizes match expected extremes" {
    try std.testing.expectEqual(@as(u8, 12), bitboard.popCount(relevantMask(.rook, .a1)));
    try std.testing.expectEqual(@as(u8, 10), bitboard.popCount(relevantMask(.rook, .d4)));
    try std.testing.expectEqual(@as(u8, 6), bitboard.popCount(relevantMask(.bishop, .a1)));
    try std.testing.expectEqual(@as(u8, 9), bitboard.popCount(relevantMask(.bishop, .d4)));
}
