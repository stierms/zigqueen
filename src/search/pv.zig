const std = @import("std");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");
const progress = @import("progress.zig");
const repetition = @import("repetition.zig");
const stack = @import("stack.zig");
const tt = @import("tt.zig");

pub const MAX_PV: usize = stack.MAX_PLY;
pub const DEFAULT_ENGINE_PV_LIMIT: usize = 16;

pub const Line = struct {
    moves: [MAX_PV]move_mod.Move = undefined,
    len: usize = 0,

    pub fn clear(self: *Line) void {
        self.len = 0;
    }

    pub fn push(self: *Line, mv: move_mod.Move) void {
        std.debug.assert(self.len < self.moves.len);
        self.moves[self.len] = mv;
        self.len += 1;
    }

    pub fn slice(self: *const Line) []const move_mod.Move {
        return self.moves[0..self.len];
    }

    pub fn eql(a: *const Line, b: *const Line) bool {
        return a.len == b.len and std.mem.eql(move_mod.Move, a.slice(), b.slice());
    }

    pub fn writeUci(self: *const Line, writer: anytype) !void {
        for (self.slice(), 0..) |mv, index| {
            if (index != 0) try writer.writeByte(' ');
            try mv.writeUci(writer);
        }
    }
};

pub fn isLegal(pos: *const position.Position, history: *const repetition.History, line: *const Line) bool {
    var temp = pos.*;
    var temp_history = history.*;
    for (line.slice()) |mv| {
        if (!legal.isLegalMove(&temp, mv)) return false;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&temp, mv, &state);
        if (temp_history.count >= temp_history.keys.len) return false;
        temp_history.push(temp.zobrist_key);
    }
    return true;
}

/// `context` is the table context of the search that wrote the line
/// (SearchContext.table_context; `.{}` for a search without the clock pressure).
pub fn reconstructFromRootMove(
    pos: *const position.Position,
    history: *const repetition.History,
    table: anytype,
    context: progress.TableContext,
    root_move: ?move_mod.Move,
    out: *Line,
) void {
    reconstructFromRootMoveLimited(pos, history, table, context, root_move, out, MAX_PV);
}

pub fn reconstructFromRootMoveLimited(
    pos: *const position.Position,
    history: *const repetition.History,
    table: anytype,
    context: progress.TableContext,
    root_move: ?move_mod.Move,
    out: *Line,
    max_len: usize,
) void {
    out.clear();
    if (max_len == 0) return;

    const mv = root_move orelse return;
    if (!legal.isLegalMove(pos, mv)) return;

    out.push(mv);
    if (out.len >= max_len) return;

    var temp = pos.*;
    var temp_history = history.*;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&temp, mv, &state);
    if (temp_history.count >= temp_history.keys.len) return;
    temp_history.push(temp.zobrist_key);
    if (temp.halfmove_clock >= 100 or temp_history.isRepetition(temp.halfmove_clock)) return;

    var tail = Line{};
    reconstructLimited(&temp, &temp_history, table, context, &tail, max_len - out.len);
    for (tail.slice()) |tail_move| {
        if (out.len >= max_len or out.len >= out.moves.len) break;
        out.push(tail_move);
    }
}

pub fn reconstruct(
    pos: *const position.Position,
    history: *const repetition.History,
    table: anytype,
    context: progress.TableContext,
    out: *Line,
) void {
    reconstructLimited(pos, history, table, context, out, MAX_PV);
}

/// Follows the table's moves from `pos`: the entries of `context` first; a
/// position that context has no entry for continues with the entry of the
/// context without the pressure (the line is for display and the ponder
/// move; no score is read).
pub fn reconstructLimited(
    pos: *const position.Position,
    history: *const repetition.History,
    table: anytype,
    context: progress.TableContext,
    out: *Line,
    max_len: usize,
) void {
    out.clear();

    var temp = pos.*;
    var temp_history = history.*;
    if (temp.halfmove_clock >= 100 or temp_history.isRepetition(temp.halfmove_clock)) return;

    var ply: usize = 0;
    const limit = @min(max_len, MAX_PV);
    while (ply < limit) : (ply += 1) {
        const mv = table.bestMove(temp.zobrist_key ^ context.key(temp.halfmove_clock)) orelse
            (if (context.base != 0) table.bestMove(temp.zobrist_key) else null) orelse break;
        if (!legal.isLegalMove(&temp, mv)) break;

        out.push(mv);

        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&temp, mv, &state);
        if (temp_history.count < temp_history.keys.len) temp_history.push(temp.zobrist_key) else break;

        if (temp.halfmove_clock >= 100 or temp_history.isRepetition(temp.halfmove_clock)) break;

        var moves = move_mod.MoveList.init();
        legal.generate(&temp, &moves);
        if (moves.count == 0) break;
    }
}

test "pv reconstruction follows legal tt moves" {
    const fen = @import("../core/fen.zig");

    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);

    const first = move_mod.Move.init(.e2, .e4, .double_push);
    const second = move_mod.Move.init(.e7, .e5, .double_push);

    table.store(pos.zobrist_key, 2, 0, .exact, first);

    var next = pos;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&next, first, &state);
    table.store(next.zobrist_key, 1, 0, .exact, second);

    var line = Line{};
    reconstruct(&pos, &history, &table, .{}, &line);

    try std.testing.expectEqual(@as(usize, 2), line.len);
    try std.testing.expectEqual(first, line.slice()[0]);
    try std.testing.expectEqual(second, line.slice()[1]);
    try std.testing.expect(isLegal(&pos, &history, &line));
}

test "root-preserving pv reconstruction keeps chosen best move first" {
    const fen = @import("../core/fen.zig");

    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);

    const first = move_mod.Move.init(.d2, .d4, .double_push);
    const child = move_mod.Move.init(.d7, .d5, .double_push);
    table.store(pos.zobrist_key, 4, 0, .exact, move_mod.Move.init(.e2, .e4, .double_push));

    var next = pos;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&next, first, &state);
    table.store(next.zobrist_key, 3, 0, .exact, child);

    var line = Line{};
    reconstructFromRootMoveLimited(&pos, &history, &table, .{}, first, &line, 2);

    try std.testing.expectEqual(first, line.slice()[0]);
    try std.testing.expectEqual(child, line.slice()[1]);
}

test "pv reconstruction reads the line of its table context and falls back to the plain one" {
    const fen = @import("../core/fen.zig");

    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    const pos = try fen.startpos();
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    const context = progress.TableContext.of(true, .white, 16);

    const plain_first = move_mod.Move.init(.e2, .e4, .double_push);
    const context_first = move_mod.Move.init(.d2, .d4, .double_push);
    const reply = move_mod.Move.init(.d7, .d5, .double_push);
    table.store(pos.zobrist_key, 2, 0, .exact, plain_first);
    table.store(pos.zobrist_key ^ context.key(pos.halfmove_clock), 2, 0, .exact, context_first);
    var next = pos;
    var state = make_unmake.StateInfo{};
    _ = make_unmake.makeMove(&next, context_first, &state);
    // The reply exists only as an entry of the plain context.
    table.store(next.zobrist_key, 1, 0, .exact, reply);

    var line = Line{};
    reconstruct(&pos, &history, &table, context, &line);
    try std.testing.expectEqual(@as(usize, 2), line.len);
    try std.testing.expectEqual(context_first, line.slice()[0]);
    try std.testing.expectEqual(reply, line.slice()[1]);

    reconstruct(&pos, &history, &table, .{}, &line);
    try std.testing.expectEqual(plain_first, line.slice()[0]);
}

test "pv reconstruction stops immediately in drawn positions" {
    const fen = @import("../core/fen.zig");

    var table = try tt.TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();

    var pos = try fen.parse("4k3/8/8/8/8/8/4N3/4K3 w - - 100 1");
    var history = repetition.History{};
    history.push(pos.zobrist_key);
    table.store(pos.zobrist_key, 1, 0, .exact, move_mod.Move.init(.e2, .f4, .quiet));

    var line = Line{};
    reconstruct(&pos, &history, &table, .{}, &line);
    try std.testing.expectEqual(@as(usize, 0), line.len);
}
