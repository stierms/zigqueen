const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const fen = @import("../core/fen.zig");
const hugealloc = @import("../util/hugealloc.zig");
const legal = @import("../movegen/legal.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const move_mod = @import("../core/move.zig");
const options_mod = @import("options.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const basin = @import("../search/basin.zig");
const search_time = @import("../search/time.zig");
const tunables = @import("../search/tunables.zig");
const worker_mod = @import("worker.zig");

pub const UciError = error{
    InvalidCommand,
    InvalidPosition,
    InvalidMove,
};

const PositionCommandResult = struct {
    position: position.Position,
    history: repetition.History,
};

const UciState = struct {
    current_position: position.Position,
    history: repetition.History,
    options: options_mod.Options,
    worker: worker_mod.Worker,

    fn init(self: *UciState, output: worker_mod.OutputSink) !void {
        const start_position = fen.startpos() catch unreachable;
        var history = repetition.History{};
        history.push(start_position.zobrist_key);
        const options = options_mod.Options{};

        self.* = .{
            .current_position = start_position,
            .history = history,
            .options = options,
            .worker = try worker_mod.Worker.initWithOptions(output, options.hash_mb, options.evalOptions()),
        };
        try self.worker.start();
    }

    fn deinit(self: *UciState) void {
        self.worker.deinit();
    }
};

const StdoutOutput = struct {
    mutex: std.Thread.Mutex = .{},
    file: std.fs.File,

    fn init() StdoutOutput {
        return .{ .file = std.fs.File.stdout() };
    }

    fn sink(self: *StdoutOutput) worker_mod.OutputSink {
        return .{ .ctx = self, .write_fn = write };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *StdoutOutput = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.file.writeAll(bytes);
    }
};

pub fn run() !void {
    var stdout_output = StdoutOutput.init();
    var state: UciState = undefined;
    try state.init(stdout_output.sink());
    defer state.deinit();

    // Windows: report which large-page rung engaged for the startup tables
    // (TT + net blocks are allocated during init above), so the user can verify
    // the SeLockMemoryPrivilege setup on their box. Linux builds report via the
    // search_profile hugepages line instead.
    if (builtin.os.tag == .windows) {
        try state.worker.output.print("info string large_pages: {s}\n", .{hugealloc.winStatusText()});
    }

    var line_buffer: [4096]u8 = undefined;
    const stdin = std.fs.File.stdin();

    var line_len: usize = 0;
    var byte_buffer: [1]u8 = undefined;
    var should_quit = false;

    while (!should_quit) {
        const bytes_read = try stdin.read(&byte_buffer);
        if (bytes_read == 0) {
            if (line_len != 0) {
                const line = std.mem.trimRight(u8, line_buffer[0..line_len], "\r");
                should_quit = try handleCommand(&state, line);
            }
            break;
        }

        const byte = byte_buffer[0];
        if (byte == '\n') {
            const line = std.mem.trimRight(u8, line_buffer[0..line_len], "\r");
            should_quit = try handleCommand(&state, line);
            line_len = 0;
            continue;
        }

        if (line_len >= line_buffer.len) return error.StreamTooLong;
        line_buffer[line_len] = byte;
        line_len += 1;
    }
}

fn handleCommand(state: *UciState, line: []const u8) !bool {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const command = tokens.next() orelse return false;

    if (std.mem.eql(u8, command, "uci")) {
        try state.worker.output.print("id name zigqueen {s}\n", .{build_options.version});
        try state.worker.output.writeAll("id author Matthias Stier\n");
        try state.options.writeUciOptions(state.worker.output);
        try state.worker.output.writeAll("uciok\n");
        announceEvalFile(state);
        return false;
    }

    if (std.mem.eql(u8, command, "isready")) {
        try state.worker.output.writeAll("readyok\n");
        return false;
    }

    if (std.mem.eql(u8, command, "setoption")) {
        state.worker.stopAndWait();
        const previous = state.options;
        const apply_result = state.options.applySetOptionLine(line) catch |err| {
            if (evalFileSetOptionValue(line)) |value| fatalEvalFile(state, value, @errorName(err));
            return false;
        };
        if (apply_result == .applied) {
            if (state.options.hash_mb != previous.hash_mb) {
                state.worker.resizeHash(state.options.hash_mb) catch {
                    state.options = previous;
                    return false;
                };
            }
            if (state.options.evalFileChanged(previous)) {
                state.worker.loadNnueFile(state.options.evalFilePath()) catch |err| {
                    fatalEvalFile(state, state.options.evalFilePath(), @errorName(err));
                };
                announceEvalFile(state);
            }
            if (state.options.contempt_cp != previous.contempt_cp) {
                state.worker.setContempt(state.options.contempt_cp);
            }
            if (state.options.syzygyPathChanged(previous)) {
                if (!state.worker.setSyzygyPath(state.options.syzygyPath())) {
                    state.options = previous;
                    return false;
                }
            }
            if (state.options.nnue_scale_percent != previous.nnue_scale_percent) {
                state.worker.setNnueScalePercent(state.options.nnue_scale_percent);
            }
            if (comptime build_options.tuning) {
                if (state.options.basinParamsChanged(previous)) {
                    state.worker.setBasinParams(state.options.basin_params);
                } else if (state.options.nnue_scale_percent == previous.nnue_scale_percent and state.options.hash_mb == previous.hash_mb and !state.options.evalFileChanged(previous) and state.options.contempt_cp == previous.contempt_cp and !state.options.syzygyPathChanged(previous)) {
                    state.worker.resetEngine();
                }
            } else if (state.options.nnue_scale_percent == previous.nnue_scale_percent and state.options.hash_mb == previous.hash_mb and !state.options.evalFileChanged(previous) and state.options.contempt_cp == previous.contempt_cp and !state.options.syzygyPathChanged(previous)) {
                state.worker.resetEngine();
            }
        } else {
            try state.worker.output.print("info string unknown option: {s}\n", .{setOptionNameForNotice(line)});
        }
        return false;
    }

    if (std.mem.eql(u8, command, "ucinewgame")) {
        state.worker.resetEngine();
        const parsed = try parsePositionCommand("position startpos");
        state.current_position = parsed.position;
        state.history = parsed.history;
        return false;
    }

    if (std.mem.eql(u8, command, "position")) {
        state.worker.stopAndWait();
        const parsed = try parsePositionCommand(line);
        state.current_position = parsed.position;
        state.history = parsed.history;
        return false;
    }

    if (std.mem.eql(u8, command, "go")) {
        try handleGo(state, line);
        return false;
    }

    if (std.mem.eql(u8, command, "stop")) {
        state.worker.stopAndWait();
        return false;
    }

    if (std.mem.eql(u8, command, "quit")) {
        state.worker.stopAndWait();
        return true;
    }

    return false;
}

/// Say WHICH net is playing, so every engine log is its own evidence of what ran
/// (the companion to fatalEvalFile: the wrong-subject failure class dies at the
/// instrument, not just at a harness preflight). `info string` lines are inert to
/// GUIs and to the `^info depth` parsing convention, and this never runs during a
/// search, so node counts and bestmoves are untouched.
fn announceEvalFile(state: *UciState) void {
    const path = state.options.evalFilePath();
    if (state.options.eval_file_len == 0) {
        state.worker.output.writeAll("info string EvalFile: builtin\n") catch {};
        return;
    }
    // Paths run to 512 bytes, past OutputSink.print's line buffer, so format here.
    var buffer: [768]u8 = undefined;
    var digest: [32]u8 = undefined;
    const text = if (fileSha256(path, &digest))
        std.fmt.bufPrint(&buffer, "info string EvalFile loaded: {s} sha256:{s}\n", .{ path, &std.fmt.bytesToHex(digest[0..8], .lower) }) catch return
    else
        std.fmt.bufPrint(&buffer, "info string EvalFile loaded: {s} sha256:unavailable\n", .{path}) catch return;
    state.worker.output.writeAll(text) catch {};
}

/// SHA-256 of `path` into `out`, false if the file could not be read whole.
/// Only ever called on the explicit-EvalFile path, so the shipping (builtin)
/// startup pays nothing for it.
fn fileSha256(path: []const u8, out: *[32]u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = file.read(&buffer) catch return false;
        if (read == 0) break;
        hasher.update(buffer[0..read]);
    }
    hasher.final(out);
    return true;
}

/// The value text of a `setoption name EvalFile value <...>` line, or null when
/// the line sets some other option. Only the failure paths need it: there the
/// options struct does not hold the path the caller asked for.
fn evalFileSetOptionValue(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, tokens.next() orelse return null, "setoption")) return null;
    if (!std.mem.eql(u8, tokens.next() orelse return null, "name")) return null;
    if (!std.mem.eql(u8, tokens.next() orelse return null, "EvalFile")) return null;
    if (!std.mem.eql(u8, tokens.next() orelse return null, "value")) return null;
    return std.mem.trim(u8, tokens.rest(), " \t\r\n");
}

/// An EvalFile the caller ASKED FOR and the engine could not load is fatal, never
/// papered over with the builtin net. Falling back silently makes the engine lie
/// about its own subject: a net-vs-net screen then runs as incumbent-vs-net with
/// no symptom at all (2026-08-14 — only score arithmetic exposed it). Missing,
/// unreadable, wrong magic, truncated, unsupported shape: all the same verdict.
/// Startup with no EvalFile set still loads the builtin net exactly as before.
fn fatalEvalFile(state: *UciState, path: []const u8, reason: []const u8) noreturn {
    // Paths run to 512 bytes, past OutputSink.print's line buffer, so format here.
    var buffer: [768]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "info string ERROR: EvalFile '{s}' could not be loaded: {s}\n", .{ path, reason }) catch
        "info string ERROR: EvalFile could not be loaded\n";
    state.worker.output.writeAll(text) catch {};
    std.process.exit(1);
}

fn setOptionNameForNotice(line: []const u8) []const u8 {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    _ = tokens.next() orelse return "<unknown>";
    _ = tokens.next() orelse return "<unknown>";

    const name_start = tokens.next() orelse return "<unknown>";
    const start = @intFromPtr(name_start.ptr) - @intFromPtr(line.ptr);
    if (std.mem.indexOfPos(u8, line, start, " value ")) |value_start| {
        return std.mem.trim(u8, line[start..value_start], " ");
    }
    return std.mem.trim(u8, line[start..], " ");
}

fn handleGo(state: *UciState, line: []const u8) !void {
    state.worker.stopAndWait();
    const command = try parseGoCommand(line, &state.current_position);
    state.worker.startSearch(.{
        .position = state.current_position,
        .history = state.history,
        .limits = command.limits,
        .root_moves = command.root_moves,
        .move_overhead_ms = state.options.move_overhead_ms,
    });
}

const GoCommand = struct {
    limits: search_time.GoLimits = .{},
    root_moves: ?move_mod.MoveList = null,
};

fn parseGoCommand(line: []const u8, pos: *const position.Position) UciError!GoCommand {
    var command = GoCommand{};
    var requested_moves = move_mod.MoveList.init();
    var parsing_searchmoves = false;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    _ = tokens.next() orelse return error.InvalidCommand;

    while (tokens.next()) |token| {
        if (parsing_searchmoves) {
            if (!isGoKeyword(token)) {
                if (findLegalMoveByUci(pos, token)) |mv| {
                    if (!moveListContains(&requested_moves, mv)) requested_moves.add(mv);
                }
                continue;
            }
            parsing_searchmoves = false;
        }

        if (std.mem.eql(u8, token, "searchmoves")) {
            requested_moves = move_mod.MoveList.init();
            parsing_searchmoves = true;
            continue;
        }
        if (std.mem.eql(u8, token, "depth")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.depth = std.fmt.parseInt(u16, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "movetime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.movetime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "nodes")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.node_limit = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "wtime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.wtime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "btime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.btime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "winc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.winc_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "binc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.binc_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "movestogo")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.movestogo = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "infinite")) {
            command.limits.infinite = true;
            continue;
        }
    }

    // If `searchmoves` supplied no parseable legal root move, deliberately
    // install no filter and search normally rather than returning `0000`.
    if (requested_moves.count != 0) command.root_moves = requested_moves;
    if (!command.limits.hasExplicitLimit()) command.limits.depth = 1;
    return command;
}

fn isGoKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{
        "searchmoves", "wtime", "btime", "winc",     "binc",     "movestogo",
        "depth",       "nodes", "mate",  "movetime", "infinite", "ponder",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn moveListContains(moves: *const move_mod.MoveList, wanted: move_mod.Move) bool {
    for (moves.slice()) |mv| {
        if (mv == wanted) return true;
    }
    return false;
}

pub fn parsePositionCommand(line: []const u8) UciError!PositionCommandResult {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    _ = tokens.next() orelse return error.InvalidPosition;

    const mode = tokens.next() orelse return error.InvalidPosition;
    var pos: position.Position = undefined;

    if (std.mem.eql(u8, mode, "startpos")) {
        pos = fen.startpos() catch return error.InvalidPosition;
    } else if (std.mem.eql(u8, mode, "fen")) {
        var fen_fields: [6][]const u8 = undefined;
        var fen_count: usize = 0;
        while (fen_count < fen_fields.len) {
            const token = tokens.next() orelse break;
            if (std.mem.eql(u8, token, "moves")) break;
            fen_fields[fen_count] = token;
            fen_count += 1;
        }
        if (fen_count != 6) return error.InvalidPosition;

        var fen_buffer: [128]u8 = undefined;
        var fen_len: usize = 0;
        for (fen_fields[0..fen_count], 0..) |field, index| {
            if (index != 0) {
                fen_buffer[fen_len] = ' ';
                fen_len += 1;
            }
            if (fen_len + field.len > fen_buffer.len) return error.InvalidPosition;
            @memcpy(fen_buffer[fen_len..][0..field.len], field);
            fen_len += field.len;
        }
        pos = fen.parse(fen_buffer[0..fen_len]) catch return error.InvalidPosition;
    } else {
        return error.InvalidPosition;
    }

    var history = repetition.History{};
    history.push(pos.zobrist_key);

    if (std.mem.indexOf(u8, line, " moves ")) |_| {
        var move_tokens = std.mem.tokenizeScalar(u8, line, ' ');
        _ = move_tokens.next();
        _ = move_tokens.next();
        if (!std.mem.eql(u8, mode, "startpos")) {
            var fen_fields_to_skip: usize = 6;
            while (fen_fields_to_skip > 0) : (fen_fields_to_skip -= 1) _ = move_tokens.next();
        }
        while (move_tokens.next()) |token| {
            if (std.mem.eql(u8, token, "moves")) break;
        }
        while (move_tokens.next()) |move_text| {
            const mv = findLegalMoveByUci(&pos, move_text) orelse return error.InvalidMove;
            var state = make_unmake.StateInfo{};
            _ = make_unmake.makeMove(&pos, mv, &state);
            history.push(pos.zobrist_key);
        }
    }

    return .{
        .position = pos,
        .history = history,
    };
}

fn findLegalMoveByUci(pos: *const position.Position, move_text: []const u8) ?move_mod.Move {
    var moves = move_mod.MoveList.init();
    legal.generate(pos, &moves);
    for (moves.slice()) |mv| {
        if (moveMatchesUci(mv, move_text)) return mv;
    }
    return null;
}

fn moveMatchesUci(mv: move_mod.Move, move_text: []const u8) bool {
    var buffer: [5]u8 = undefined;
    const uci = mv.toUci(&buffer);
    if (std.mem.eql(u8, uci, move_text)) return true;
    return uci.len == 5 and move_text.len == 5 and
        std.mem.eql(u8, uci[0..4], move_text[0..4]) and
        uci[4] == std.ascii.toLower(move_text[4]);
}

const TestOutput = struct {
    mutex: std.Thread.Mutex = .{},
    buffer: [8192]u8 = [_]u8{0} ** 8192,
    len: usize = 0,

    fn sink(self: *TestOutput) worker_mod.OutputSink {
        return .{ .ctx = self, .write_fn = write };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestOutput = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len + bytes.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn contents(self: *const TestOutput) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn bestMoveText(out: []const u8) ?[]const u8 {
    const marker = "bestmove ";
    const marker_index = std.mem.lastIndexOf(u8, out, marker) orelse return null;
    const move_start = marker_index + marker.len;
    const move_end = std.mem.indexOfScalarPos(u8, out, move_start, '\n') orelse out.len;
    return out[move_start..move_end];
}

test "handleCommand recognizes quit" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(try handleCommand(&state, "quit"));
}

test "handleCommand writes uci handshake" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "uci"));
    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "id name zigqueen ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, build_options.version) != null);
    const built_in_names = [_][]const u8{
        "Hash",
        "Threads",
        "Move Overhead",
        "SyzygyPath",
        "EvalFile",
        "NNUE Scale Percent",
        "Contempt",
    };
    for (built_in_names) |name| try expectAdvertisedOption(out, name, true);

    try std.testing.expectEqual(@as(usize, 43), tunables.specs.len);
    for (tunables.specs) |spec| try expectAdvertisedOption(out, spec.uci_name, build_options.tuning);
    try std.testing.expectEqual(@as(usize, 48), basin.specs.len);
    for (basin.specs) |spec| try expectAdvertisedOption(out, spec.uci_name, build_options.tuning);

    const expected_count: usize = if (build_options.tuning) 98 else 7;
    try std.testing.expectEqual(expected_count, std.mem.count(u8, out, "option name "));
    try std.testing.expect(std.mem.indexOf(u8, out, "uciok") != null);
}

fn expectAdvertisedOption(out: []const u8, name: []const u8, expected: bool) !void {
    var buffer: [96]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buffer, "option name {s} type ", .{name});
    try std.testing.expectEqual(expected, std.mem.indexOf(u8, out, needle) != null);
}

test "setoption hash reconfigures engine-owned table" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name Hash value 2"));
    try std.testing.expectEqual(@as(u32, 2), state.options.hash_mb);
    try std.testing.expectEqual(@as(u32, 2), state.worker.hashSizeMb());
}

test "position startpos with moves is applied legally" {
    const parsed = try parsePositionCommand("position startpos moves e2e4 c7c5 g1f3");
    const piece = @import("../core/piece.zig").Piece;

    try std.testing.expectEqual(piece.white_pawn, parsed.position.pieceAt(.e4));
    try std.testing.expectEqual(piece.black_pawn, parsed.position.pieceAt(.c5));
    try std.testing.expectEqual(piece.white_knight, parsed.position.pieceAt(.f3));
    try std.testing.expectEqual(parsed.position.zobrist_key, parsed.history.current());
}

test "go depth returns a legal move instead of 0000 in start position" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go depth 1"));
    state.worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
}

test "go searchmoves restricts start position to the listed legal moves" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go depth 3 searchmoves e2e4 d2d4"));
    state.worker.waitIdle();

    const bestmove = bestMoveText(output.contents()).?;
    try std.testing.expect(std.mem.eql(u8, bestmove, "e2e4") or std.mem.eql(u8, bestmove, "d2d4"));
}

test "go searchmoves ignores garbage and illegal moves" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go depth 3 searchmoves zz99 e2e5 e2e4"));
    state.worker.waitIdle();

    try std.testing.expectEqualStrings("e2e4", bestMoveText(output.contents()).?);
}

test "go searchmoves empty legal set searches normally" {
    var unrestricted_output = TestOutput{};
    var unrestricted_state: UciState = undefined;
    try unrestricted_state.init(unrestricted_output.sink());
    defer unrestricted_state.deinit();

    try std.testing.expect(!try handleCommand(&unrestricted_state, "go depth 3"));
    unrestricted_state.worker.waitIdle();

    var empty_output = TestOutput{};
    var empty_state: UciState = undefined;
    try empty_state.init(empty_output.sink());
    defer empty_state.deinit();

    try std.testing.expect(!try handleCommand(&empty_state, "go depth 3 searchmoves zz99 e2e5"));
    empty_state.worker.waitIdle();

    try std.testing.expectEqualStrings(bestMoveText(unrestricted_output.contents()).?, bestMoveText(empty_output.contents()).?);
}

test "go searchmoves accepts a legal promotion suffix" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "position fen 7k/P7/8/8/8/8/8/7K w - - 0 1"));
    try std.testing.expect(!try handleCommand(&state, "go depth 3 searchmoves a7a8q"));
    state.worker.waitIdle();

    try std.testing.expectEqualStrings("a7a8q", bestMoveText(output.contents()).?);
}

test "go searchmoves accepts an uppercase promotion suffix" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "position fen 7k/P7/8/8/8/8/8/7K w - - 0 1"));
    try std.testing.expect(!try handleCommand(&state, "go depth 3 searchmoves a7a8Q"));
    state.worker.waitIdle();

    try std.testing.expectEqualStrings("a7a8q", bestMoveText(output.contents()).?);
}

test "go searchmoves can force a legal non-book root move" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go depth 2 searchmoves g1h3"));
    state.worker.waitIdle();

    try std.testing.expectEqualStrings("g1h3", bestMoveText(output.contents()).?);
}

test "go infinite is interrupted by stop" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go infinite"));
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!try handleCommand(&state, "stop"));

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
}

test "go returns 0000 only when no legal move exists" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "position fen 7k/5Q2/7K/8/8/8/8/8 b - - 0 1"));
    try std.testing.expect(!try handleCommand(&state, "go depth 1"));
    state.worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") != null);
}

test "go movetime returns a legal move and reports nodes with full pv" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go movetime 10"));
    state.worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nodes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " nps ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " hashfull ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " pv ") != null);
}

test "setoption move overhead is accepted" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name Move Overhead value 12"));
    try std.testing.expectEqual(@as(u32, 12), state.options.move_overhead_ms);
}

test "RazorBase setoption follows the build flavour" {
    tunables.reset();
    defer tunables.reset();

    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name RazorBase value 200"));
    if (build_options.tuning) {
        try std.testing.expectEqual(@as(i32, 200), tunables.active.razor_base);
        try std.testing.expect(std.mem.indexOf(u8, output.contents(), "unknown option") == null);
    } else {
        try std.testing.expectEqual(@as(i32, 5), tunables.active.razor_base);
        try std.testing.expectEqualStrings("info string unknown option: RazorBase\n", output.contents());
    }
}

test "basin setoption is tuning-only and LMR rebuilds only for shape" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name BasinRfpLinear value 91"));
    if (build_options.tuning) {
        try std.testing.expectEqual(@as(i32, 91), state.worker.engine.basin_config.params.rfp_linear);
        const rebuilds = state.worker.engine.basin_config.lmr_rebuild_count;
        try std.testing.expect(!try handleCommand(&state, "setoption name BasinLmrQuietBase value 812"));
        try std.testing.expectEqual(rebuilds + 1, state.worker.engine.basin_config.lmr_rebuild_count);
    } else {
        try std.testing.expectEqualStrings("info string unknown option: BasinRfpLinear\n", output.contents());
    }
}

test "parse go command keeps node and time-control fields" {
    const pos = try fen.startpos();
    const command = try parseGoCommand("go nodes 128 wtime 5000 btime 4000 winc 50 binc 25 movestogo 20", &pos);
    const limits = command.limits;
    try std.testing.expectEqual(@as(?u64, 128), limits.node_limit);
    try std.testing.expectEqual(@as(?u64, 5000), limits.wtime_ms);
    try std.testing.expectEqual(@as(?u64, 4000), limits.btime_ms);
    try std.testing.expectEqual(@as(u64, 50), limits.winc_ms);
    try std.testing.expectEqual(@as(u64, 25), limits.binc_ms);
    try std.testing.expectEqual(@as(?u32, 20), limits.movestogo);
}

test "searchmoves stops at following go parameter and deduplicates in input order" {
    const pos = try fen.startpos();
    const command = try parseGoCommand("go searchmoves e2e4 d2d4 e2e4 movetime 100", &pos);

    try std.testing.expectEqual(@as(?u64, 100), command.limits.movetime_ms);
    const root_moves = command.root_moves.?;
    try std.testing.expectEqual(@as(usize, 2), root_moves.count);
    var first_buffer: [5]u8 = undefined;
    var second_buffer: [5]u8 = undefined;
    try std.testing.expectEqualStrings("e2e4", root_moves.slice()[0].toUci(&first_buffer));
    try std.testing.expectEqualStrings("d2d4", root_moves.slice()[1].toUci(&second_buffer));
}

test "a second searchmoves replaces the earlier move set" {
    const pos = try fen.startpos();
    const command = try parseGoCommand("go searchmoves e2e4 searchmoves d2d4 depth 3", &pos);

    const root_moves = command.root_moves.?;
    try std.testing.expectEqual(@as(usize, 1), root_moves.count);
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqualStrings("d2d4", root_moves.slice()[0].toUci(&buffer));
}
