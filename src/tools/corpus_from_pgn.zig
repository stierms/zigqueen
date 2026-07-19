const std = @import("std");
const corpus = @import("../tuning/corpus.zig");
const fen = @import("../core/fen.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const position = @import("../core/position.zig");

const Game = struct {
    result_text: ?[]const u8 = null,
    start_fen: ?[]const u8 = null,
    round_text: ?[]const u8 = null,
    move_started: bool = false,
    position_state: position.Position = undefined,
    ply: u32 = 0,

    fn reset(self: *Game) void {
        self.* = .{};
    }
};

pub fn run(writer: anytype, path: []const u8, min_ply: u32, stride: u32) !void {
    const data = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 512 << 20);
    defer std.heap.page_allocator.free(data);

    const source = try std.heap.page_allocator.dupe(u8, path);
    defer std.heap.page_allocator.free(source);
    const source_family = try deriveSourceFamily(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(source_family);

    var game = Game{};
    var game_index: usize = 0;
    var in_comment = false;
    var stripped = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer stripped.deinit();

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try parseTagLine(line, &game);
            continue;
        }

        if (!game.move_started) {
            game.position_state = if (game.start_fen) |start_fen| try fen.parse(start_fen) else try fen.startpos();
            game.move_started = true;
            game_index += 1;
        }

        const text = try stripComments(line, &stripped, &in_comment);
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r");
        while (tokens.next()) |token| {
            if (token.len == 0) continue;
            if (isMoveNumberToken(token)) continue;
            if (token[0] == '$') continue;
            if (isResultToken(token)) {
                if (game.result_text) |tag_result| {
                    if (!std.mem.eql(u8, tag_result, token)) return error.PgnResultMismatch;
                } else {
                    game.result_text = token;
                }
                game.reset();
                break;
            }

            const mv = try parseUciLegalMove(&game.position_state, token);
            var state = make_unmake.StateInfo{};
            _ = make_unmake.makeMove(&game.position_state, mv, &state);
            game.ply += 1;

            if (game.result_text == null) return error.MissingPgnResultTag;
            if (game.ply < min_ply) continue;
            if (stride > 1 and ((game.ply - min_ply) % stride) != 0) continue;
            try emitRecord(writer, &game.position_state, source, source_family, game.round_text, game_index, game.ply, game.result_text.?);
        }
    }
}

fn parseTagLine(line: []const u8, game: *Game) !void {
    if (line.len < 5 or line[0] != '[' or line[line.len - 1] != ']') return error.InvalidPgnTagLine;

    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    const space_index = std.mem.indexOfScalar(u8, inner, ' ') orelse return error.InvalidPgnTagLine;
    const key = inner[0..space_index];
    const raw_value = std.mem.trim(u8, inner[space_index + 1 ..], " \t\r");
    if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.InvalidPgnTagLine;
    const value = raw_value[1 .. raw_value.len - 1];

    if (std.mem.eql(u8, key, "Result")) {
        game.result_text = value;
    } else if (std.mem.eql(u8, key, "FEN")) {
        game.start_fen = value;
    } else if (std.mem.eql(u8, key, "Round")) {
        game.round_text = value;
    }
}

fn stripComments(line: []const u8, buffer: anytype, in_comment: *bool) ![]const u8 {
    buffer.clearRetainingCapacity();
    for (line) |ch| {
        if (in_comment.*) {
            if (ch == '}') in_comment.* = false;
            continue;
        }
        if (ch == '{') {
            in_comment.* = true;
            continue;
        }
        if (ch == ';') break;
        try buffer.append(ch);
    }
    return buffer.items;
}

fn isMoveNumberToken(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '.') == null) return false;
    for (token) |ch| {
        if ((ch >= '0' and ch <= '9') or ch == '.') continue;
        return false;
    }
    return true;
}

fn isResultToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "1-0") or std.mem.eql(u8, token, "0-1") or std.mem.eql(u8, token, "1/2-1/2") or std.mem.eql(u8, token, "*");
}

fn parseUciLegalMove(pos: *const position.Position, text: []const u8) !move_mod.Move {
    var list = move_mod.MoveList.init();
    legal.generate(pos, &list);
    var buffer: [5]u8 = undefined;
    for (list.slice()) |mv| {
        if (std.mem.eql(u8, mv.toUci(&buffer), text)) return mv;
    }
    return error.InvalidPgnUciMove;
}

fn emitRecord(
    writer: anytype,
    pos: *const position.Position,
    source: []const u8,
    source_family: []const u8,
    round_text: ?[]const u8,
    game_index: usize,
    ply: u32,
    result_text: []const u8,
) !void {
    const result = try corpus.Result.parse(result_text);
    const fen_text = try fen.format(std.heap.page_allocator, pos);
    defer std.heap.page_allocator.free(fen_text);

    var game_id_buffer: [128]u8 = undefined;
    const game_id = if (round_text) |round| try std.fmt.bufPrint(&game_id_buffer, "g{d}-r{s}", .{ game_index, round }) else try std.fmt.bufPrint(&game_id_buffer, "g{d}", .{game_index});

    const row = struct {
        fen: []const u8,
        result: []const u8,
        source: []const u8,
        source_family: []const u8,
        game_id: []const u8,
        ply: u32,
    }{
        .fen = fen_text,
        .result = result.text(),
        .source = source,
        .source_family = source_family,
        .game_id = game_id,
        .ply = ply,
    };

    try writer.print("{f}\n", .{std.json.fmt(row, .{})});
}

fn deriveSourceFamily(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const parent_component = if (std.fs.path.dirname(path)) |dir_name| std.fs.path.basename(dir_name) else null;
    const family_seed = if (parent_component) |parent| blk: {
        if (parent.len != 0 and !std.mem.eql(u8, parent, ".")) break :blk parent;
        break :blk baseStem(path);
    } else baseStem(path);
    return allocator.dupe(u8, trimTimestampSuffix(family_seed));
}

fn baseStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot_index = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    if (dot_index == 0) return basename;
    return basename[0..dot_index];
}

fn trimTimestampSuffix(text: []const u8) []const u8 {
    if (text.len < 18) return text;
    const suffix = text[text.len - 18 ..];
    if (suffix[0] != '-') return text;
    if (!isDigits(suffix[1..5])) return text;
    if (suffix[5] != '-') return text;
    if (!isDigits(suffix[6..8])) return text;
    if (suffix[8] != '-') return text;
    if (!isDigits(suffix[9..11])) return text;
    if (suffix[11] != '-') return text;
    if (!isDigits(suffix[12..18])) return text;
    return text[0 .. text.len - 18];
}

fn isDigits(text: []const u8) bool {
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

test "corpus from pgn converts a tiny uci-movetext game into labeled JSONL rows" {
    const temp_name = "zigqueen-corpus-from-pgn-test.pgn";
    const pgn =
        \\[Event "Fastchess Tournament"]
        \\[Round "1"]
        \\[Result "1-0"]
        \\
        \\1. e2e4 {book} e7e5 {book} 2. g1f3 b8c6 3. f1b5 a7a6 1-0
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_name, .data = pgn });
    defer std.fs.cwd().deleteFile(temp_name) catch {};

    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();

    try run(&sink.writer, temp_name, 2, 2);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"result\":\"1-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"ply\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"ply\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"source\":\"zigqueen-corpus-from-pgn-test.pgn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "\"source_family\":\"zigqueen-corpus-from-pgn-test\"") != null);
}

test "corpus from pgn derives source family from artifact directory name" {
    const family = try deriveSourceFamily(std.testing.allocator, "artifacts/external-roundrobin-6-r6-time-headroom-2026-04-17-201148/match.pgn");
    defer std.testing.allocator.free(family);
    try std.testing.expectEqualStrings("external-roundrobin-6-r6-time-headroom", family);
}
