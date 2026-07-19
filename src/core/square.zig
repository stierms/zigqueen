const std = @import("std");

pub const ParseSquareError = error{InvalidSquare};

pub const Square = enum(u6) {
    a1 = 0,
    b1,
    c1,
    d1,
    e1,
    f1,
    g1,
    h1,
    a2,
    b2,
    c2,
    d2,
    e2,
    f2,
    g2,
    h2,
    a3,
    b3,
    c3,
    d3,
    e3,
    f3,
    g3,
    h3,
    a4,
    b4,
    c4,
    d4,
    e4,
    f4,
    g4,
    h4,
    a5,
    b5,
    c5,
    d5,
    e5,
    f5,
    g5,
    h5,
    a6,
    b6,
    c6,
    d6,
    e6,
    f6,
    g6,
    h6,
    a7,
    b7,
    c7,
    d7,
    e7,
    f7,
    g7,
    h7,
    a8,
    b8,
    c8,
    d8,
    e8,
    f8,
    g8,
    h8,

    pub fn fromIndex(square_index: u6) Square {
        return @enumFromInt(square_index);
    }

    pub fn fromCoords(file_index: u3, rank_index: u3) Square {
        const idx: u6 = @intCast(@as(u8, rank_index) * 8 + @as(u8, file_index));
        return @enumFromInt(idx);
    }

    pub fn parse(text: []const u8) ParseSquareError!Square {
        if (text.len != 2) return error.InvalidSquare;
        const file_char = text[0];
        const rank_char = text[1];
        if (file_char < 'a' or file_char > 'h') return error.InvalidSquare;
        if (rank_char < '1' or rank_char > '8') return error.InvalidSquare;
        const file_index: u3 = @intCast(file_char - 'a');
        const rank_index: u3 = @intCast(rank_char - '1');
        return fromCoords(file_index, rank_index);
    }

    pub fn index(self: Square) u6 {
        return @intFromEnum(self);
    }

    pub fn file(self: Square) u3 {
        return @intCast(@intFromEnum(self) % 8);
    }

    pub fn rank(self: Square) u3 {
        return @intCast(@intFromEnum(self) / 8);
    }

    pub fn chars(self: Square) [2]u8 {
        return .{
            @as(u8, 'a') + @as(u8, self.file()),
            @as(u8, '1') + @as(u8, self.rank()),
        };
    }
};

test "square parse and format work on board corners" {
    try std.testing.expectEqual(Square.a1, try Square.parse("a1"));
    try std.testing.expectEqual(Square.h8, try Square.parse("h8"));
    try std.testing.expectEqual(@as([2]u8, .{ 'a', '1' }), Square.a1.chars());
    try std.testing.expectEqual(@as([2]u8, .{ 'h', '8' }), Square.h8.chars());
}

test "square coordinate helpers are consistent" {
    const sq = Square.fromCoords(4, 3);
    try std.testing.expectEqual(Square.e4, sq);
    try std.testing.expectEqual(@as(u3, 4), sq.file());
    try std.testing.expectEqual(@as(u3, 3), sq.rank());
    try std.testing.expectEqual(@as(u6, 28), sq.index());
}
