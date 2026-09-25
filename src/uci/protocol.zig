const std = @import("std");
const runtime = @import("../util/search_runtime.zig");
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
const search_stack = @import("../search/stack.zig");
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
    worker: worker_mod.Pool,

    fn init(self: *UciState, output: worker_mod.OutputSink) !void {
        const start_position = fen.startpos() catch unreachable;
        var history = repetition.History{};
        history.push(start_position.zobrist_key);
        const options = options_mod.Options{};

        self.* = .{
            .current_position = start_position,
            .history = history,
            .options = options,
            .worker = try worker_mod.Pool.initWithOptions(output, options.hash_mb, options.evalOptions()),
        };
        errdefer self.worker.deinit();
        try self.worker.start();
    }

    fn deinit(self: *UciState) void {
        self.worker.deinit();
    }
};

const StdoutOutput = struct {
    mutex: runtime.Mutex = .{},
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

    // Command input is cold-path storage. A complete game can exceed 4 KiB;
    // grow here, without adding any allocation to search or repetition tracking.
    const allocator = std.heap.page_allocator;
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);
    const stdin = std.fs.File.stdin();
    while (try readCommandLine(stdin, &line_buffer, allocator)) |line| {
        if (try handleCommand(&state, line)) break;
    }
}

fn readCommandLine(input: anytype, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !?[]const u8 {
    buffer.clearRetainingCapacity();
    var byte_buffer: [1]u8 = undefined;
    while (try input.read(&byte_buffer) != 0) {
        if (byte_buffer[0] == '\n') return std.mem.trimRight(u8, buffer.items, "\r");
        try buffer.append(allocator, byte_buffer[0]);
    }
    if (buffer.items.len == 0) return null;
    return std.mem.trimRight(u8, buffer.items, "\r");
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
            if (state.options.threads != previous.threads) {
                state.worker.setThreads(state.options.threads) catch {
                    state.options = previous;
                    return false;
                };
            }
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
            try writeUnknownOptionNotice(state.worker.output, setOptionNameForNotice(line));
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

fn writeUnknownOptionNotice(output: worker_mod.OutputSink, name: []const u8) !void {
    const prefix = "info string unknown option: ";
    var buffer: [256]u8 = undefined;
    const max_name = buffer.len - prefix.len - 1;
    const text = if (name.len <= max_name)
        try std.fmt.bufPrint(&buffer, prefix ++ "{s}\n", .{name})
    else
        try std.fmt.bufPrint(&buffer, prefix ++ "{s}...\n", .{name[0 .. max_name - 3]});
    try output.writeAll(text);
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
    try state.worker.startSearch(.{
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
            appendGameHistory(&history, pos.zobrist_key, pos.halfmove_clock);
        }
    }

    return .{
        .position = pos,
        .history = history,
    };
}

// Keep ordinary histories unchanged, but never consume the tail needed by a
// full search/PV. Only game ingestion compacts: search push/pop stays untouched.
// At a nonterminal root halfmove_clock < 100, so its entire reversible window
// survives. At >= 100 the engine immediately adjudicates a rule-50 draw; retaining
// the latest 100 ancestors also suffices after any later pawn move or capture.
fn appendGameHistory(history: *repetition.History, key: u64, halfmove_clock: u16) void {
    const max_game_history = repetition.MAX_HISTORY - search_stack.MAX_PLY;
    comptime std.debug.assert(max_game_history > 100);
    if (history.count >= max_game_history) {
        const keep = @min(history.count, @min(@as(usize, halfmove_clock), 100));
        std.mem.copyForwards(u64, history.keys[0..keep], history.keys[history.count - keep .. history.count]);
        history.count = keep;
    }
    history.push(key);
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
    mutex: runtime.Mutex = .{},
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
    runtime.Thread.sleep(5 * std.time.ns_per_ms);
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
        try std.testing.expectEqual(@as(i32, 91), state.worker.coordinator.engine.basin_config.params.rfp_linear);
        const rebuilds = state.worker.coordinator.engine.basin_config.lmr_rebuild_count;
        try std.testing.expect(!try handleCommand(&state, "setoption name BasinLmrQuietBase value 812"));
        try std.testing.expectEqual(rebuilds + 1, state.worker.coordinator.engine.basin_config.lmr_rebuild_count);
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

test "unknown option echo cannot terminate command handling on long raw names" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    // The option parser normalizes internal spaces into a short unknown name,
    // while the diagnostic echoes the raw name. A single overlong token is
    // rejected earlier, so it would not reproduce the old print-buffer failure.
    const command = "setoption name No" ++ (" " ** 1000) ++ "Such value 1";
    try std.testing.expect(!try handleCommand(&state, command));
    try std.testing.expect(!try handleCommand(&state, "isready"));
    const out = output.contents();
    try std.testing.expect(std.mem.startsWith(u8, out, "info string unknown option: No"));
    try std.testing.expect(std.mem.endsWith(u8, out, "...\nreadyok\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try std.testing.expectEqual(@as(usize, 256 + "readyok\n".len), out.len);
}

const ConcurrentLineProducer = struct {
    output: worker_mod.OutputSink,
    start: *runtime.ResetEvent,
    ready: runtime.ResetEvent = .{},
    failure: ?anyerror = null,
    search: bool,

    fn run(self: *@This()) void {
        self.ready.set();
        self.start.timedWait(5 * std.time.ns_per_s) catch |err| {
            self.failure = err;
            return;
        };
        self.emitLines() catch |err| {
            self.failure = err;
        };
    }

    fn emitLines(self: *@This()) !void {
        const info = @import("info.zig");
        const mv = move_mod.Move.init(.a7, .a8, .promo_queen);
        for (0..128) |_| {
            if (self.search) {
                try info.writeIterationLine(self.output, .{
                    .depth = 8,
                    .seldepth = 9,
                    .score = -42,
                    .nodes = 123,
                    .time_ms = 1000,
                    .hashfull = 12,
                    .best_move = mv,
                    .pv = &.{mv},
                });
                try info.writeCurrMoveLine(self.output, .{ .depth = 8, .move = mv, .move_number = 1, .time_ms = 3000 });
                try info.writeBestMoveLine(self.output, mv);
            } else {
                try self.output.writeAll("readyok\n");
            }
        }
    }
};

test "two producers preserve complete UCI lines through the production output mutex" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile("uci-lines", .{ .read = true });
    defer file.close();
    // Exercise the real stdout sink and its mutex, substituting only the fd.
    var output = StdoutOutput{ .file = file };
    var start = runtime.ResetEvent{};
    var search = ConcurrentLineProducer{ .output = output.sink(), .start = &start, .search = true };
    var protocol = ConcurrentLineProducer{ .output = output.sink(), .start = &start, .search = false };
    const search_thread = try runtime.Thread.spawn(.{}, ConcurrentLineProducer.run, .{&search});
    var search_joined = false;
    defer {
        if (!search_joined) {
            start.set();
            search_thread.join();
        }
    }
    const protocol_thread = try runtime.Thread.spawn(.{}, ConcurrentLineProducer.run, .{&protocol});
    var protocol_joined = false;
    defer {
        if (!protocol_joined) {
            start.set();
            protocol_thread.join();
        }
    }
    try search.ready.timedWait(5 * std.time.ns_per_s);
    try protocol.ready.timedWait(5 * std.time.ns_per_s);
    start.set();
    search_thread.join();
    search_joined = true;
    protocol_thread.join();
    protocol_joined = true;
    if (search.failure) |err| return err;
    if (protocol.failure) |err| return err;
    try file.seekTo(0);
    const bytes = try file.readToEndAlloc(std.testing.allocator, 128 * 256);
    defer std.testing.allocator.free(bytes);
    const expected = [_][]const u8{
        "info depth 8 seldepth 9 score cp -42 nodes 123 time 1000 nps 123 hashfull 12 pv a7a8q",
        "info depth 8 currmove a7a8q currmovenumber 1 time 3000",
        "bestmove a7a8q",
        "readyok",
    };
    var counts = [_]usize{0} ** expected.len;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var found = false;
        for (expected, 0..) |wanted, i| {
            if (std.mem.eql(u8, line, wanted)) {
                counts[i] += 1;
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    for (counts) |count| try std.testing.expectEqual(@as(usize, 128), count);
    try std.testing.expectEqual(@as(usize, 512), std.mem.count(u8, bytes, "\n"));
}

test "command reader grows beyond 4096 bytes and preserves line boundaries" {
    const text = "x" ** 5000 ++ "\r\n\nlast";
    var input = std.io.fixedBufferStream(text);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(text[0..5000], (try readCommandLine(&input, &buffer, std.testing.allocator)).?);
    try std.testing.expectEqualStrings("", (try readCommandLine(&input, &buffer, std.testing.allocator)).?);
    try std.testing.expectEqualStrings("last", (try readCommandLine(&input, &buffer, std.testing.allocator)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try readCommandLine(&input, &buffer, std.testing.allocator));
}

test "long position replay reserves search history and preserves the final position" {
    const line = "position startpos moves " ++ "g1f3 g8f6 f3g1 f6g8 " ** 400 ++ "e2e4";
    const parsed = try parsePositionCommand(line);
    const expected = try parsePositionCommand("position startpos moves e2e4");
    try std.testing.expectEqual(expected.position.zobrist_key, parsed.position.zobrist_key);
    try std.testing.expectEqual(@as(u16, 0), parsed.position.halfmove_clock);
    try std.testing.expectEqual(@as(u16, 801), parsed.position.fullmove_number);
    try std.testing.expect(!parsed.history.isRepetition(parsed.position.halfmove_clock));
    try std.testing.expect(parsed.history.count <= repetition.MAX_HISTORY - search_stack.MAX_PLY);
    var history = parsed.history;
    const root_count = history.count;
    for (0..search_stack.MAX_PLY) |i| history.push(@intCast(i));
    for (0..search_stack.MAX_PLY) |_| history.pop();
    try std.testing.expectEqual(root_count, history.count);
    try std.testing.expectEqual(parsed.position.zobrist_key, history.current());
}

test "game history compaction preserves every nonterminal repetition query" {
    // All possible nonterminal halfmove windows, including a zeroing move.
    for (0..100) |clock| {
        var original = repetition.History{};
        const limit = repetition.MAX_HISTORY - search_stack.MAX_PLY;
        for (0..limit) |i| original.push(@intCast(i % 12));
        var compacted = original;
        const key = @as(u64, @intCast(limit % 12));
        original.push(key);
        appendGameHistory(&compacted, key, @intCast(clock));
        try std.testing.expectEqual(clock + 1, compacted.count);
        try std.testing.expectEqual(original.currentPriorOccurrenceCount(@intCast(clock)), compacted.currentPriorOccurrenceCount(@intCast(clock)));
        try std.testing.expectEqual(original.currentPreviousCycleChildKey(@intCast(clock)), compacted.currentPreviousCycleChildKey(@intCast(clock)));
        try std.testing.expectEqual(original.isClaimableCurrentRepetition(@intCast(clock)), compacted.isClaimableCurrentRepetition(@intCast(clock)));
        // A reversible child extends the window by one, with unchanged parity.
        try std.testing.expectEqual(original.isRepetitionForKey((key + 1) % 12, @intCast(clock + 1)), compacted.isRepetitionForKey((key + 1) % 12, @intCast(clock + 1)));
    }
}
