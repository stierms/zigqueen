const history_mod = @import("../search/history.zig");

pub fn write(writer: anytype, history: *const history_mod.HistoryTable) !void {
    const snapshot = history.snapshot();
    try writer.print("history_table_entries {d}\n", .{snapshot.total_entries});
    try writer.print("history_table_positive_entries {d}\n", .{snapshot.positive_entries});
    try writer.print("history_table_negative_entries {d}\n", .{snapshot.negative_entries});
    try writer.print("history_table_zero_entries {d}\n", .{snapshot.zero_entries});
    try writer.print("history_table_max_positive {d}\n", .{snapshot.max_positive});
    try writer.print("history_table_min_negative {d}\n", .{snapshot.min_negative});
    try writer.print("history_table_max_abs {d}\n", .{snapshot.max_abs});
    try writer.print("history_table_abs_sum {d}\n", .{snapshot.abs_sum});

    inline for (history_mod.HISTORY_SNAPSHOT_BUCKET_NAMES, 0..) |name, index| {
        const count = snapshot.bucket_counts[index];
        try writer.print("history_table_bucket name {s} count {d} permille {d}\n", .{ name, count, ratioPermille(count, snapshot.total_entries) });
    }

    inline for (history_mod.HISTORY_SNAPSHOT_SIDE_NAMES, 0..) |side_name, side_index| {
        inline for (history_mod.HISTORY_SNAPSHOT_PIECE_NAMES, 0..) |piece_name, piece_index| {
            const stats = snapshot.side_piece_stats[side_index][piece_index];
            try writer.print(
                "history_table_side_piece side {s} piece {s} positive {d} negative {d} zero {d} max_positive {d} min_negative {d} max_abs {d} abs_sum {d}\n",
                .{ side_name, piece_name, stats.positive_entries, stats.negative_entries, stats.zero_entries, stats.max_positive, stats.min_negative, stats.max_abs, stats.abs_sum },
            );
        }
    }

    const counter = history.countermoveSnapshot();
    const overwrite_total = counter.overwrite_same + counter.overwrite_different;
    try writer.print("countermove_table_slots {d}\n", .{counter.total_slots});
    try writer.print("countermove_table_occupied {d}\n", .{counter.occupied_slots});
    try writer.print("countermove_table_empty {d}\n", .{counter.empty_slots});
    try writer.print("countermove_table_occupied_permille {d}\n", .{ratioPermille(counter.occupied_slots, counter.total_slots)});
    try writer.print("countermove_table_remember_calls {d}\n", .{counter.remember_calls});
    try writer.print("countermove_table_overwrite_same {d}\n", .{counter.overwrite_same});
    try writer.print("countermove_table_overwrite_different {d}\n", .{counter.overwrite_different});
    try writer.print("countermove_table_overwrite_total {d}\n", .{overwrite_total});
    try writer.print("countermove_table_overwrite_permille {d}\n", .{ratioPermille64(overwrite_total, counter.remember_calls)});
    inline for (history_mod.HISTORY_SNAPSHOT_SIDE_NAMES, 0..) |side_name, side_index| {
        inline for (history_mod.HISTORY_SNAPSHOT_PIECE_NAMES, 0..) |piece_name, piece_index| {
            const stats = counter.side_piece_stats[side_index][piece_index];
            try writer.print("countermove_table_side_piece side {s} piece {s} occupied {d}\n", .{ side_name, piece_name, stats.occupied_entries });
        }
    }
}

fn ratioPermille(numerator: u16, denominator: u16) u16 {
    if (denominator == 0) return 0;
    return @intCast((@as(u32, numerator) * 1000) / denominator);
}

fn ratioPermille64(numerator: u64, denominator: u64) u16 {
    if (denominator == 0) return 0;
    return @intCast((numerator * 1000) / denominator);
}

test "history report prints table distribution" {
    const std = @import("std");
    const square = @import("../core/square.zig");

    var history = history_mod.HistoryTable{};
    history.bonus(.white, .knight, square.Square.f3, 8);

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try write(&sink.writer, &history);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "history_table_entries 768") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "history_table_bucket name zero") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "history_table_side_piece side white piece knight") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "countermove_table_slots 768") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "countermove_table_empty 768") != null);
}
