const std = @import("std");
const piece = @import("piece.zig");
const square = @import("square.zig");

pub const MoveFlag = enum(u4) {
    quiet = 0,
    capture = 1,
    double_push = 2,
    castle = 3,
    en_passant = 4,
    promo_knight = 5,
    promo_bishop = 6,
    promo_rook = 7,
    promo_queen = 8,
    promo_knight_capture = 9,
    promo_bishop_capture = 10,
    promo_rook_capture = 11,
    promo_queen_capture = 12,
};

pub const Move = packed struct(u16) {
    from: square.Square,
    to: square.Square,
    flag: MoveFlag,

    pub inline fn init(from: square.Square, to: square.Square, flag: MoveFlag) Move {
        return .{ .from = from, .to = to, .flag = flag };
    }

    pub inline fn isPromotion(self: Move) bool {
        return @intFromEnum(self.flag) >= @intFromEnum(MoveFlag.promo_knight);
    }

    pub inline fn isCapture(self: Move) bool {
        const flag = @intFromEnum(self.flag);
        return flag == @intFromEnum(MoveFlag.capture) or
            flag == @intFromEnum(MoveFlag.en_passant) or
            flag >= @intFromEnum(MoveFlag.promo_knight_capture);
    }

    pub inline fn promotionPieceType(self: Move) ?piece.PieceType {
        return switch (self.flag) {
            .promo_knight, .promo_knight_capture => .knight,
            .promo_bishop, .promo_bishop_capture => .bishop,
            .promo_rook, .promo_rook_capture => .rook,
            .promo_queen, .promo_queen_capture => .queen,
            else => null,
        };
    }

    pub fn toUci(self: Move, buffer: *[5]u8) []const u8 {
        const from_chars = self.from.chars();
        const to_chars = self.to.chars();
        buffer[0] = from_chars[0];
        buffer[1] = from_chars[1];
        buffer[2] = to_chars[0];
        buffer[3] = to_chars[1];

        if (self.promotionPieceType()) |promo| {
            buffer[4] = switch (promo) {
                .knight => 'n',
                .bishop => 'b',
                .rook => 'r',
                .queen => 'q',
                else => unreachable,
            };
            return buffer[0..5];
        }

        return buffer[0..4];
    }

    pub fn writeUci(self: Move, writer: anytype) !void {
        var buffer: [5]u8 = undefined;
        try writer.writeAll(self.toUci(&buffer));
    }
};

pub const MAX_MOVES: usize = 256;

pub const MoveList = struct {
    moves: [MAX_MOVES]Move = undefined,
    count: usize = 0,

    pub inline fn init() MoveList {
        // NOT `return .{};`: the aggregate literal materializes the `undefined`
        // moves array as a 512-byte zero-store per call (8 zmm stores in
        // negamax/qsearch, visible in perf annotate). Only `count` needs
        // initializing; entries past `count` are never read.
        var list: MoveList = undefined;
        list.count = 0;
        return list;
    }

    pub fn clear(self: *MoveList) void {
        self.count = 0;
    }

    pub inline fn add(self: *MoveList, mv: Move) void {
        std.debug.assert(self.count < MAX_MOVES);
        self.moves[self.count] = mv;
        self.count += 1;
    }

    pub inline fn slice(self: *const MoveList) []const Move {
        return self.moves[0..self.count];
    }
};

test "move helper classification works" {
    const quiet = Move.init(.e2, .e4, .quiet);
    const capture = Move.init(.e4, .d5, .capture);
    const promo = Move.init(.a7, .a8, .promo_queen);
    const promo_capture = Move.init(.a7, .b8, .promo_knight_capture);

    try std.testing.expect(!quiet.isCapture());
    try std.testing.expect(!quiet.isPromotion());
    try std.testing.expect(capture.isCapture());
    try std.testing.expect(!capture.isPromotion());
    try std.testing.expect(promo.isPromotion());
    try std.testing.expectEqual(piece.PieceType.queen, promo.promotionPieceType().?);
    try std.testing.expect(promo_capture.isCapture());
    try std.testing.expectEqual(piece.PieceType.knight, promo_capture.promotionPieceType().?);
}

test "move list stores moves without allocation" {
    var list = MoveList.init();
    list.add(Move.init(.e2, .e4, .quiet));
    list.add(Move.init(.g1, .f3, .quiet));

    try std.testing.expectEqual(@as(usize, 2), list.count);
    try std.testing.expectEqual(Move.init(.e2, .e4, .quiet), list.slice()[0]);
    try std.testing.expectEqual(Move.init(.g1, .f3, .quiet), list.slice()[1]);
}

test "move writes uci text" {
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try Move.init(.a7, .a8, .promo_queen).writeUci(&sink.writer);
    try std.testing.expectEqualStrings("a7a8q", sink.written());
}
