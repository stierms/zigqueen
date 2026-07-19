const piece = @import("piece.zig");

const VALUES = [_]i32{ 100, 320, 330, 500, 900, 0, 0 };

pub inline fn value(piece_type: piece.PieceType) i32 {
    return VALUES[@intFromEnum(piece_type)];
}

test "piece values match the engine material scale" {
    try @import("std").testing.expectEqual(@as(i32, 100), value(.pawn));
    try @import("std").testing.expectEqual(@as(i32, 320), value(.knight));
    try @import("std").testing.expectEqual(@as(i32, 330), value(.bishop));
    try @import("std").testing.expectEqual(@as(i32, 500), value(.rook));
    try @import("std").testing.expectEqual(@as(i32, 900), value(.queen));
}
