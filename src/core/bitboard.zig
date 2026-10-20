const std = @import("std");
const square_mod = @import("square.zig");

pub const Bitboard = u64;
pub const EMPTY: Bitboard = 0;
pub const FULL: Bitboard = std.math.maxInt(Bitboard);
pub const FILE_A_MASK: Bitboard = 0x0101_0101_0101_0101;
pub const DARK_SQUARES: Bitboard = 0xAA55_AA55_AA55_AA55;
pub const LIGHT_SQUARES: Bitboard = 0x55AA_55AA_55AA_55AA;

pub inline fn fileMask(file: u3) Bitboard {
    return FILE_A_MASK << file;
}

pub inline fn bit(square: square_mod.Square) Bitboard {
    return @as(Bitboard, 1) << @intFromEnum(square);
}

pub inline fn contains(bb: Bitboard, square: square_mod.Square) bool {
    return (bb & bit(square)) != 0;
}

pub inline fn set(bb: *Bitboard, square: square_mod.Square) void {
    bb.* |= bit(square);
}

pub inline fn clear(bb: *Bitboard, square: square_mod.Square) void {
    bb.* &= ~bit(square);
}

pub inline fn popCount(bb: Bitboard) u8 {
    return @intCast(@popCount(bb));
}

pub inline fn lsb(bb: Bitboard) ?square_mod.Square {
    if (bb == 0) return null;
    return @enumFromInt(@as(u6, @intCast(@ctz(bb))));
}

pub inline fn msb(bb: Bitboard) ?square_mod.Square {
    if (bb == 0) return null;
    return @enumFromInt(@as(u6, @intCast(63 - @clz(bb))));
}

pub inline fn popLsbIndex(bb: *Bitboard) ?u6 {
    const value = bb.*;
    if (value == 0) return null;
    const idx: u6 = @intCast(@ctz(value));
    bb.* = value & (value - 1);
    return idx;
}

pub inline fn popLsb(bb: *Bitboard) ?square_mod.Square {
    const idx = popLsbIndex(bb) orelse return null;
    return square_mod.Square.fromIndex(idx);
}

/// The lowest square of a NON-EMPTY `bb`, removed from it. The hot loops use
/// `while (bb != 0) { const sq = popLsbUnchecked(&bb); ... }` instead of
/// `while (popLsb(&bb)) |sq|`: the optional ?Square result (an i6 payload)
/// left LLVM a spill slot it could not promote (i6 store, i8 load) in every
/// loop it was inlined into; the builtins here keep the square in a register.
pub inline fn popLsbUnchecked(bb: *Bitboard) square_mod.Square {
    const value = bb.*;
    std.debug.assert(value != 0);
    bb.* = value & (value - 1);
    return @enumFromInt(@as(u6, @intCast(@ctz(value))));
}

test "bitboard set clear and contains behave as expected" {
    var bb: Bitboard = EMPTY;
    set(&bb, .e4);
    set(&bb, .a1);
    try std.testing.expect(contains(bb, .e4));
    try std.testing.expect(contains(bb, .a1));
    try std.testing.expectEqual(@as(u8, 2), popCount(bb));
    clear(&bb, .e4);
    try std.testing.expect(!contains(bb, .e4));
    try std.testing.expect(contains(bb, .a1));
}

test "bitboard lsb and popLsb iterate low bits first" {
    var bb: Bitboard = EMPTY;
    set(&bb, .h8);
    set(&bb, .b2);
    set(&bb, .a1);

    try std.testing.expectEqual(square_mod.Square.a1, lsb(bb).?);
    try std.testing.expectEqual(square_mod.Square.h8, msb(bb).?);
    try std.testing.expectEqual(square_mod.Square.a1, popLsb(&bb).?);
    try std.testing.expectEqual(square_mod.Square.b2, popLsb(&bb).?);
    try std.testing.expectEqual(square_mod.Square.h8, popLsb(&bb).?);
    try std.testing.expectEqual(@as(?square_mod.Square, null), popLsb(&bb));
    try std.testing.expectEqual(@as(?square_mod.Square, null), msb(EMPTY));
}
