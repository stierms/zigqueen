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
const search_time = @import("../search/time.zig");
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
        try state.worker.output.writeAll("id author stierms\n");
        try state.options.writeUciOptions(state.worker.output);
        try state.worker.output.writeAll("uciok\n");
        return false;
    }

    if (std.mem.eql(u8, command, "isready")) {
        try state.worker.output.writeAll("readyok\n");
        return false;
    }

    if (std.mem.eql(u8, command, "setoption")) {
        state.worker.stopAndWait();
        const previous = state.options;
        const apply_result = state.options.applySetOptionLine(line) catch return false;
        if (apply_result == .applied) {
            if (state.options.hash_mb != previous.hash_mb) {
                state.worker.resizeHash(state.options.hash_mb) catch {
                    state.options = previous;
                    return false;
                };
            }
            if (state.options.evalFileChanged(previous)) {
                state.worker.loadNnueFile(state.options.evalFilePath()) catch {
                    state.options = previous;
                    return false;
                };
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
            } else if (state.options.hash_mb == previous.hash_mb and !state.options.evalFileChanged(previous) and state.options.contempt_cp == previous.contempt_cp and !state.options.syzygyPathChanged(previous)) {
                state.worker.resetEngine();
            }
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

fn handleGo(state: *UciState, line: []const u8) !void {
    state.worker.stopAndWait();
    const limits = try parseGoCommand(line);
    state.worker.startSearch(.{
        .position = state.current_position,
        .history = state.history,
        .limits = limits,
        .move_overhead_ms = state.options.move_overhead_ms,
    });
}

fn parseGoCommand(line: []const u8) UciError!search_time.GoLimits {
    var limits = search_time.GoLimits{};
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    _ = tokens.next() orelse return error.InvalidCommand;

    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "depth")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.depth = std.fmt.parseInt(u16, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "movetime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.movetime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "nodes")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.node_limit = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "wtime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.wtime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "btime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.btime_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "winc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.winc_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "binc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.binc_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "movestogo")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            limits.movestogo = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "infinite")) {
            limits.infinite = true;
            continue;
        }
    }

    if (!limits.hasExplicitLimit()) limits.depth = 1;
    return limits;
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
    return std.mem.eql(u8, mv.toUci(&buffer), move_text);
}

const TestOutput = worker_mod.TestOutput;

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
    try std.testing.expect(std.mem.indexOf(u8, out, "option name Hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "option name NNUE Scale Percent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "option name EvalFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "uciok") != null);
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

test "parse go command keeps node and time-control fields" {
    const limits = try parseGoCommand("go nodes 128 wtime 5000 btime 4000 winc 50 binc 25 movestogo 20");
    try std.testing.expectEqual(@as(?u64, 128), limits.node_limit);
    try std.testing.expectEqual(@as(?u64, 5000), limits.wtime_ms);
    try std.testing.expectEqual(@as(?u64, 4000), limits.btime_ms);
    try std.testing.expectEqual(@as(u64, 50), limits.winc_ms);
    try std.testing.expectEqual(@as(u64, 25), limits.binc_ms);
    try std.testing.expectEqual(@as(?u32, 20), limits.movestogo);
}
