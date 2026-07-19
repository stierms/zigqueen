const std = @import("std");
const square_mod = @import("square.zig");

pub const Bitboard = u64;
pub const EMPTY: Bitboard = 0;

pub inline fn bit(square: square_mod.Square) Bitboard {
    return @as(Bitboard, 1) << square.index();
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
    const idx: u6 = @intCast(@ctz(bb));
    return square_mod.Square.fromIndex(idx);
}

pub inline fn msb(bb: Bitboard) ?square_mod.Square {
    if (bb == 0) return null;
    const idx: u6 = @intCast(63 - @clz(bb));
    return square_mod.Square.fromIndex(idx);
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
