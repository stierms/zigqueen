const std = @import("std");
const legal = @import("../movegen/legal.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");

pub fn run(writer: anytype, pos: *const position.Position) !void {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);

    try writer.print("legal_moves {d}\n", .{moves.count});
    for (moves.slice()) |mv| {
        var move_buffer: [5]u8 = undefined;
        const move_text = mv.toUci(&move_buffer);
        try writer.print("{s} flag={s} capture={any} promotion={any}\n", .{
            move_text,
            @tagName(mv.flag),
            mv.isCapture(),
            mv.isPromotion(),
        });
    }
}

test "move diag prints move count" {
    const fen = @import("../core/fen.zig");

    const pos = try fen.startpos();
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, &pos);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "legal_moves 20") != null);
}
