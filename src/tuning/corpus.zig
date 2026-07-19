const std = @import("std");
const fen = @import("../core/fen.zig");
const position = @import("../core/position.zig");

pub const schema_name = "zigqueen-tuning-corpus-v1";
pub const default_validation_permille: u16 = 100;
pub const default_test_permille: u16 = 0;
pub const default_split_seed: u64 = 0;

pub const Result = enum {
    white_win,
    draw,
    black_win,
    unknown,

    pub fn parse(result_text: []const u8) !Result {
        if (std.mem.eql(u8, result_text, "1-0")) return .white_win;
        if (std.mem.eql(u8, result_text, "1/2-1/2")) return .draw;
        if (std.mem.eql(u8, result_text, "0-1")) return .black_win;
        if (std.mem.eql(u8, result_text, "result_unknown")) return .unknown;
        return error.InvalidCorpusResult;
    }

    pub fn text(self: Result) []const u8 {
        return switch (self) {
            .white_win => "1-0",
            .draw => "1/2-1/2",
            .black_win => "0-1",
            .unknown => "result_unknown",
        };
    }
};

pub const Split = enum {
    train,
    validation,
    @"test",
};

pub const SplitMode = enum {
    fen,
    game,
    source,
    source_family,

    pub fn parse(raw: []const u8) !SplitMode {
        if (std.mem.eql(u8, raw, "fen")) return .fen;
        if (std.mem.eql(u8, raw, "game")) return .game;
        if (std.mem.eql(u8, raw, "source")) return .source;
        if (std.mem.eql(u8, raw, "source_family")) return .source_family;
        return error.InvalidCorpusSplitMode;
    }

    pub fn text(self: SplitMode) []const u8 {
        return switch (self) {
            .fen => "fen",
            .game => "game",
            .source => "source",
            .source_family => "source_family",
        };
    }
};

pub const Record = struct {
    fen: []const u8,
    result: Result,
    source: ?[]const u8 = null,
    source_family: ?[]const u8 = null,
    game_id: ?[]const u8 = null,
    ply: ?u32 = null,
    target_slice: ?[]const u8 = null,
    search_white_pov_total: ?i32 = null,
};

const RawRecord = struct {
    fen: []const u8,
    result: []const u8,
    source: ?[]const u8 = null,
    source_family: ?[]const u8 = null,
    game_id: ?[]const u8 = null,
    ply: ?u32 = null,
    target_slice: ?[]const u8 = null,
    search_white_pov_total: ?i32 = null,
};

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Record {
    if (line.len == 0) return error.EmptyCorpusLine;

    const parsed = try std.json.parseFromSliceLeaky(RawRecord, allocator, line, .{});
    if (parsed.fen.len == 0) return error.InvalidCorpusFen;

    return .{
        .fen = parsed.fen,
        .result = try Result.parse(parsed.result),
        .source = parsed.source,
        .source_family = parsed.source_family,
        .game_id = parsed.game_id,
        .ply = parsed.ply,
        .target_slice = parsed.target_slice,
        .search_white_pov_total = parsed.search_white_pov_total,
    };
}

pub fn parsePosition(record: Record) !position.Position {
    return fen.parse(record.fen);
}

pub fn validateSplitPermille(validation_permille: u16, test_permille: u16) !void {
    if (@as(u32, validation_permille) + @as(u32, test_permille) > 1000) {
        return error.InvalidCorpusSplitPermille;
    }
}

pub fn assignSplit(record: Record, validation_permille: u16, test_permille: u16, seed: u64, mode: SplitMode) Split {
    validateSplitPermille(validation_permille, test_permille) catch unreachable;

    if (validation_permille == 0 and test_permille == 0) return .train;
    if (validation_permille >= 1000) return .validation;
    if (validation_permille == 0 and test_permille >= 1000) return .@"test";

    var hash = std.hash.Wyhash.init(seed);
    switch (mode) {
        .fen => hash.update(record.fen),
        .game => hashGameKey(&hash, record),
        .source => hashSourceKey(&hash, record),
        .source_family => hashSourceFamilyKey(&hash, record),
    }
    const bucket = hash.final() % 1000;
    if (bucket < validation_permille) return .validation;
    if (bucket < @as(u64, validation_permille) + @as(u64, test_permille)) return .@"test";
    return .train;
}

fn hashGameKey(hash: *std.hash.Wyhash, record: Record) void {
    if (record.source) |source| {
        hash.update(source);
        hash.update("\x1f");
    }
    if (record.game_id) |game_id| {
        hash.update(game_id);
        return;
    }
    hash.update(record.fen);
}

fn hashSourceKey(hash: *std.hash.Wyhash, record: Record) void {
    if (record.source) |source| {
        hash.update(source);
        return;
    }
    hashGameKey(hash, record);
}

fn hashSourceFamilyKey(hash: *std.hash.Wyhash, record: Record) void {
    if (record.source_family) |source_family| {
        hash.update(source_family);
        return;
    }
    if (record.source) |source| {
        hash.update(source);
        return;
    }
    hashGameKey(hash, record);
}

test "corpus line parser accepts the canonical JSONL shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 w - - 0 1","result":"1/2-1/2","source":"sample","source_family":"sample-family","game_id":"g1","ply":42,"target_slice":"general"}
    ;
    const record = try parseLine(arena.allocator(), line);
    try std.testing.expectEqualStrings("4k3/8/8/8/8/8/8/4K3 w - - 0 1", record.fen);
    try std.testing.expectEqual(Result.draw, record.result);
    try std.testing.expectEqualStrings("sample", record.source.?);
    try std.testing.expectEqualStrings("sample-family", record.source_family.?);
    try std.testing.expectEqualStrings("g1", record.game_id.?);
    try std.testing.expectEqual(@as(?u32, 42), record.ply);
    try std.testing.expectEqualStrings("general", record.target_slice.?);
    try std.testing.expectEqual(@as(?i32, null), record.search_white_pov_total);
}

test "corpus line parser accepts optional search teacher score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 w - - 0 1","result":"1/2-1/2","search_white_pov_total":37}
    ;
    const record = try parseLine(arena.allocator(), line);
    try std.testing.expectEqual(@as(?i32, 37), record.search_white_pov_total);
}

test "corpus line parser accepts result_unknown as neutral resultless target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        \\{"fen":"4k3/8/8/8/8/8/8/4K3 w - - 0 1","result":"result_unknown","search_white_pov_total":37}
    ;
    const record = try parseLine(arena.allocator(), line);
    try std.testing.expectEqual(Result.unknown, record.result);
    try std.testing.expectEqualStrings("result_unknown", record.result.text());
    try std.testing.expectEqual(@as(?i32, 37), record.search_white_pov_total);
}

test "corpus split assignment is deterministic for a given seed" {
    const record = Record{ .fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1", .result = .draw };
    const first = assignSplit(record, 100, 100, 7, .fen);
    const second = assignSplit(record, 100, 100, 7, .fen);
    try std.testing.expectEqual(first, second);
}

test "split permille validation rejects impossible totals" {
    try std.testing.expectError(error.InvalidCorpusSplitPermille, validateSplitPermille(900, 200));
}

test "game split mode keeps same game together regardless of ply fen" {
    const first = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
        .result = .draw,
        .source = "sample",
        .game_id = "g1",
        .ply = 10,
    };
    const second = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 b - - 0 1",
        .result = .draw,
        .source = "sample",
        .game_id = "g1",
        .ply = 20,
    };
    try std.testing.expectEqual(assignSplit(first, 100, 100, 7, .game), assignSplit(second, 100, 100, 7, .game));
}

test "source split mode keeps same source together across games" {
    const first = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
        .result = .draw,
        .source = "artifact-a/match.pgn",
        .game_id = "g1",
    };
    const second = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 b - - 0 1",
        .result = .draw,
        .source = "artifact-a/match.pgn",
        .game_id = "g2",
    };
    try std.testing.expectEqual(assignSplit(first, 100, 100, 7, .source), assignSplit(second, 100, 100, 7, .source));
}

test "source-family split mode keeps same family together across sources" {
    const first = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
        .result = .draw,
        .source = "artifacts/external-roundrobin-6-r6-time-headroom-2026-04-17-201148/match.pgn",
        .source_family = "external-roundrobin-6-r6-time-headroom",
        .game_id = "g1",
    };
    const second = Record{
        .fen = "4k3/8/8/8/8/8/8/4K3 b - - 0 1",
        .result = .draw,
        .source = "artifacts/external-roundrobin-6-r6-time-headroom-2026-04-18-001122/match.pgn",
        .source_family = "external-roundrobin-6-r6-time-headroom",
        .game_id = "g3",
    };
    try std.testing.expectEqual(assignSplit(first, 100, 100, 7, .source_family), assignSplit(second, 100, 100, 7, .source_family));
}
