const std = @import("std");

pub const Color = enum(u1) {
    white = 0,
    black = 1,

    pub inline fn other(self: Color) Color {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
};

pub const Score = i32;

test "color other flips side" {
    try std.testing.expectEqual(Color.black, Color.white.other());
    try std.testing.expectEqual(Color.white, Color.black.other());
}
