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
const syzygy = @import("../search/syzygy.zig");

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
    /// Root side of the last search started with a nonzero Contempt.
    contempt_root_side: ?@import("../core/types.zig").Color = null,
    /// False after a `position` command was rejected, until one is accepted.
    /// The board the GUI means is then unknown, so `go` must not answer with
    /// a move for the older one.
    position_accepted: bool = true,

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
        if (try handleCommandRecovering(&state, line)) break;
    }
}

/// A command the engine cannot parse is reported and dropped; the last accepted
/// position and every option stay as they were and the next command is read.
/// Output failures still end the session.
fn handleCommandRecovering(state: *UciState, line: []const u8) !bool {
    return handleCommand(state, line) catch |err| switch (err) {
        error.InvalidCommand, error.InvalidPosition, error.InvalidMove => {
            try writeRejectedCommandNotice(state.worker.output, @errorName(err), line);
            return false;
        },
        else => return err,
    };
}

fn writeGoFallbackNotice(output: worker_mod.OutputSink, reason: []const u8, line: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const shown = line[0..@min(line.len, 160)];
    const text = try std.fmt.bufPrint(&buffer, "info string error: {s}, searching depth 1 instead: {s}{s}\n", .{ reason, shown, if (shown.len < line.len) "..." else "" });
    try output.writeAll(text);
}

fn writeRejectedCommandNotice(output: worker_mod.OutputSink, reason: []const u8, line: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const shown = line[0..@min(line.len, 160)];
    const text = try std.fmt.bufPrint(&buffer, "info string error: {s}, command ignored: {s}{s}\n", .{ reason, shown, if (shown.len < line.len) "..." else "" });
    try output.writeAll(text);
}

fn readCommandLine(input: anytype, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !?[]const u8 {
    buffer.clearRetainingCapacity();
    var byte_buffer: [1]u8 = undefined;
    while (try input.read(&byte_buffer) != 0) {
        if (byte_buffer[0] == '\n') return std.mem.trimRight(u8, buffer.items, "\r");
        // UCI allows arbitrary whitespace between tokens; every tokenizer here
        // splits on spaces, so fold tabs into spaces once at the reader.
        try buffer.append(allocator, if (byte_buffer[0] == '\t') ' ' else byte_buffer[0]);
    }
    if (buffer.items.len == 0) return null;
    return std.mem.trimRight(u8, buffer.items, "\r");
}

/// Every command of the UCI specification, including the ones this engine
/// accepts and ignores (debug, register, ponderhit).
const uci_commands = [_][]const u8{ "uci", "debug", "isready", "setoption", "register", "ucinewgame", "position", "go", "stop", "ponderhit", "quit" };

/// The line from its first UCI command on, or null when it has none. UCI:
/// "if the engine or the GUI receives an unknown command or token it should
/// just ignore it and try to parse the rest of the string", so `joho isready`
/// is `isready` (audit D, U-UNKNOWN-TOKEN). Only leading tokens are skipped:
/// a recognized command owns the rest of its line, arguments included.
fn commandSuffix(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    while (tokens.next()) |token| {
        for (uci_commands) |command| {
            if (std.mem.eql(u8, token, command)) return line[@intFromPtr(token.ptr) - @intFromPtr(line.ptr) ..];
        }
    }
    return null;
}

fn handleCommand(state: *UciState, raw_line: []const u8) !bool {
    // Each handler re-reads its own line, so it gets the line from the command on.
    const line = commandSuffix(raw_line) orelse return false;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const command = tokens.next() orelse return false;

    if (std.mem.eql(u8, command, "uci")) {
        try state.worker.output.print("id name zigqueen {s}\n", .{build_options.version});
        try state.worker.output.writeAll("id author Matthias Stier\n");
        try state.options.writeUciOptions(state.worker.output);
        try state.worker.output.writeAll("uciok\n");
        announceEvalFile(state);
        announceWeights(state);
        return false;
    }

    if (std.mem.eql(u8, command, "isready")) {
        // Tablebase snapshots are freed on this thread only (see syzygy.zig).
        syzygy.collect();
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
                state.worker.setThreads(state.options.threads) catch |err| {
                    const requested = state.options.threads;
                    state.options = previous;
                    try writeOptionRollbackNotice(state.worker.output, "Threads", requested, previous.threads, @errorName(err));
                    return false;
                };
            }
            if (state.options.hash_mb != previous.hash_mb) {
                state.worker.resizeHash(state.options.hash_mb) catch |err| {
                    const requested = state.options.hash_mb;
                    state.options = previous;
                    try writeOptionRollbackNotice(state.worker.output, "Hash", requested, previous.hash_mb, @errorName(err));
                    return false;
                };
            }
            if (state.options.evalFileChanged(previous)) {
                state.worker.loadNnueFile(state.options.evalFilePath()) catch |err| {
                    fatalEvalFile(state, state.options.evalFilePath(), @errorName(err));
                };
                announceEvalFile(state);
                announceWeights(state);
            }
            if (state.options.shared_weights != previous.shared_weights) {
                state.worker.setSharedWeights(state.options.shared_weights) catch |err| {
                    state.options.shared_weights = previous.shared_weights;
                    try state.worker.output.print("info string NNUE Shared Weights unchanged: {s}\n", .{@errorName(err)});
                };
                announceWeights(state);
            }
            if (state.options.contempt_cp != previous.contempt_cp) {
                state.worker.setContempt(state.options.contempt_cp);
            }
            if (state.options.syzygyPathChanged(previous)) {
                if (!state.worker.setSyzygyPath(state.options.syzygyPath())) {
                    // The failed load already released the previous tables.
                    // Reload them so the path the option still shows is the
                    // one being probed; if that fails too, show none.
                    state.options = previous;
                    if (previous.syzygy_path_len != 0 and !state.worker.setSyzygyPath(previous.syzygyPath())) {
                        state.options.syzygy_path_len = 0;
                    }
                    try state.worker.output.writeAll(if (state.options.syzygy_path_len != 0)
                        "info string SyzygyPath could not be loaded; previous tablebases kept\n"
                    else
                        "info string SyzygyPath could not be loaded; tablebases disabled\n");
                    return false;
                }
                // Tables found, and which files are mapped or on positioned reads.
                if (syzygy.report()) |r| try r.write(state.worker.output);
            }
            // An explicit NNUE Scale Percent always wins, even when it equals the shown
            // value: a pawn-pair (ZQBA) net loaded later keeps its own default scale
            // only while the scale was never set explicitly (B3 review finding 4).
            // Named by the option layer's canonical name, so any token spacing
            // counts (audit D, U-SCALE-WS).
            const scale_named = if (options_mod.parseSetOptionLine(line)) |parsed| parsed.names("NNUE Scale Percent") else |_| false;
            if (state.options.nnue_scale_percent != previous.nnue_scale_percent or scale_named) {
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
        syzygy.collect();
        const parsed = try parsePositionCommand("position startpos");
        state.current_position = parsed.position;
        state.history = parsed.history;
        state.position_accepted = true;
        state.contempt_root_side = null;
        return false;
    }

    if (std.mem.eql(u8, command, "position")) {
        state.worker.stopAndWait();
        const parsed = parsePositionCommand(line) catch |err| {
            state.position_accepted = false;
            return err;
        };
        state.current_position = parsed.position;
        state.history = parsed.history;
        state.position_accepted = true;
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
        syzygy.collect();
        return true;
    }

    return false;
}

/// Say how the net's weights are held: one machine-wide shared copy (created
/// by this process or attached to another's) or a private copy, and why.
/// Like announceEvalFile, never during a search.
fn announceWeights(state: *UciState) void {
    var desc_buf: [160]u8 = undefined;
    const text = state.worker.weightsStatus().describe(&desc_buf);
    state.worker.output.print("info string NNUE weights: {s}\n", .{text}) catch {};
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
    if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return null, "EvalFile")) return null;
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

/// A Hash or Threads change the engine could not prepare is rolled back whole
/// (the worker's configuration change is transactional). Say so: silently the
/// GUI would keep showing a value that is not in effect (audit D, U-HASH-FAIL).
fn writeOptionRollbackNotice(output: worker_mod.OutputSink, name: []const u8, requested: u32, kept: u32, reason: []const u8) !void {
    try output.print("info string {s} {d} could not be applied ({s}); keeping {d}\n", .{ name, requested, reason, kept });
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
    if (!state.position_accepted) {
        try state.worker.output.writeAll("info string error: the last position command was rejected; no search started\nbestmove 0000\n");
        return;
    }
    // UCI: every go needs a bestmove. A go line that still fails to parse is
    // reported and answered by a one-ply search instead of being dropped.
    const command = parseGoCommand(line, &state.current_position) catch |err| fallback: {
        try writeGoFallbackNotice(state.worker.output, @errorName(err), line);
        break :fallback GoCommand{ .limits = .{ .depth = 1 } };
    };
    // Contempt makes a draw worth -c to the root side and +c to its opponent,
    // and the tables store those scores as found. Entries written for one
    // root side are wrong for the other, so a change of root side starts from
    // empty tables. Games never change it; analysis of both sides does.
    if (state.options.contempt_cp != 0) {
        const side = state.current_position.side_to_move;
        if (state.contempt_root_side) |previous| {
            if (previous != side) state.worker.resetEngine();
        }
        state.contempt_root_side = side;
    }
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
            command.limits.movetime_ms = try parseClockMs(value);
            continue;
        }
        if (std.mem.eql(u8, token, "nodes")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.node_limit = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "wtime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.wtime_ms = try parseClockMs(value);
            continue;
        }
        if (std.mem.eql(u8, token, "btime")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.btime_ms = try parseClockMs(value);
            continue;
        }
        if (std.mem.eql(u8, token, "winc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.winc_ms = try parseClockMs(value);
            continue;
        }
        if (std.mem.eql(u8, token, "binc")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.binc_ms = try parseClockMs(value);
            continue;
        }
        if (std.mem.eql(u8, token, "movestogo")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.movestogo = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, token, "mate")) {
            const value = tokens.next() orelse return error.InvalidCommand;
            command.limits.mate_in_moves = std.fmt.parseInt(u16, value, 10) catch return error.InvalidCommand;
            if (command.limits.mate_in_moves == 0) return error.InvalidCommand;
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

/// UCI clock fields are milliseconds "left on the clock". A GUI that tolerates
/// a small overstep reports it as a negative number: that is 0 ms left, not a
/// malformed command (CCRL game 93, 2026-10-15: `btime -1000` made 6.4.0
/// ignore the whole go and lose on time with minutes left).
fn parseClockMs(value: []const u8) UciError!u64 {
    const ms = std.fmt.parseInt(i64, value, 10) catch return error.InvalidCommand;
    return if (ms < 0) 0 else @intCast(ms);
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
        // Leniency for GUIs and hand-typed FENs (audit C, C-FEN-SHORT): the move
        // counters may be missing (4 or 5 fields; they default to `0 1`), a
        // halfmove `-` reads as 0 and a fullmove 0 as 1. fen.parse stays strict.
        var fen_fields = [6][]const u8{ "", "", "", "", "0", "1" };
        var fen_count: usize = 0;
        while (fen_count < fen_fields.len) {
            const token = tokens.next() orelse break;
            if (std.mem.eql(u8, token, "moves")) break;
            fen_fields[fen_count] = token;
            fen_count += 1;
        }
        if (fen_count < 4) return error.InvalidPosition;
        if (std.mem.eql(u8, fen_fields[4], "-")) fen_fields[4] = "0";
        if (std.mem.eql(u8, fen_fields[5], "0")) fen_fields[5] = "1";

        var fen_buffer: [128]u8 = undefined;
        var fen_len: usize = 0;
        for (fen_fields, 0..) |field, index| {
            // Capacity for the separator AND the field before either is written:
            // a first field that fills the buffer exactly must not let the
            // separator land one byte past it (audit D, U-FEN-OVF).
            const separator: usize = @intFromBool(index != 0);
            if (fen_len + separator + field.len > fen_buffer.len) return error.InvalidPosition;
            if (separator != 0) {
                fen_buffer[fen_len] = ' ';
                fen_len += 1;
            }
            @memcpy(fen_buffer[fen_len..][0..field.len], field);
            fen_len += field.len;
        }
        pos = fen.parse(fen_buffer[0..fen_len]) catch return error.InvalidPosition;
        if (pos.hasBackRankPawn()) return error.InvalidPosition;
    } else {
        return error.InvalidPosition;
    }

    var history = repetition.History{};
    history.push(pos.zobrist_key);

    // The move list follows the first `moves` token. No FEN field is ever
    // `moves`, so this needs no count of FEN fields to skip; a fixed skip of
    // six would swallow `moves e2e4` after a short FEN (judge C's hazard).
    var move_tokens = std.mem.tokenizeScalar(u8, line, ' ');
    while (move_tokens.next()) |token| {
        if (std.mem.eql(u8, token, "moves")) break;
    }
    while (move_tokens.next()) |move_text| {
        const mv = findLegalMoveByUci(&pos, move_text) orelse return error.InvalidMove;
        var state = make_unmake.StateInfo{};
        _ = make_unmake.makeMove(&pos, mv, &state);
        appendGameHistory(&history, pos.zobrist_key, pos.halfmove_clock);
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
        "NNUE Shared Weights",
    };
    for (built_in_names) |name| try expectAdvertisedOption(out, name, true);

    try std.testing.expectEqual(@as(usize, 39), tunables.specs.len);
    for (tunables.specs) |spec| try expectAdvertisedOption(out, spec.uci_name, build_options.tuning);
    try std.testing.expectEqual(@as(usize, 63), basin.specs.len);
    for (basin.specs) |spec| try expectAdvertisedOption(out, spec.uci_name, build_options.tuning);

    const expected_count: usize = if (build_options.tuning) 8 + 39 + 63 else 8;
    try std.testing.expectEqual(expected_count, std.mem.count(u8, out, "option name "));
    try std.testing.expect(std.mem.indexOf(u8, out, "uciok") != null);
}

test "uci handshake reports how the NNUE weights are held; the option reloads them" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    // Off by default: the handshake says so.
    try std.testing.expect(!try handleCommand(&state, "uci"));
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "option name NNUE Shared Weights type check default false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "info string NNUE weights: private (disabled)\n") != null);
    try std.testing.expectEqual(@import("../eval/net_share.zig").Mode.private, state.worker.weightsStatus().mode);

    // On: the same net is reloaded into the shared blob, where the platform
    // allows it (otherwise private with the reason, never "disabled").
    try std.testing.expect(!try handleCommand(&state, "setoption name NNUE Shared Weights value true"));
    try std.testing.expect(state.options.shared_weights);
    const shared = state.worker.weightsStatus();
    try std.testing.expect(shared.isShared() or !std.mem.eql(u8, shared.reason, "disabled"));
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) try std.testing.expect(shared.isShared());
    // Same net, same scale: only where the weights live changed.
    try std.testing.expectEqualStrings(eval_backend_builtin, state.worker.network_owner.evalFilePath());

    // Off again: private.
    try std.testing.expect(!try handleCommand(&state, "setoption name NNUE Shared Weights value false"));
    try std.testing.expectEqual(@import("../eval/net_share.zig").Mode.private, state.worker.weightsStatus().mode);

    // A search still works after the reloads.
    try std.testing.expect(!try handleCommand(&state, "position startpos"));
    try std.testing.expect(!try handleCommand(&state, "go depth 2"));
    state.worker.waitIdle();
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "bestmove 0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "bestmove ") != null);
}

const eval_backend_builtin = @import("../eval/backend.zig").builtin_eval_file;

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

test "a failed Hash or Threads change is reported and rolled back" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();
    const engine = &state.worker.coordinator.engine;

    // Hash: the new table's allocation fails (a 2 MB table goes through the
    // TT's own allocator, as in engine.zig's real-allocator failure test).
    const tt_allocator = engine.tt.allocator;
    var failing_tt = std.testing.FailingAllocator.init(tt_allocator, .{ .fail_index = 0 });
    engine.tt.allocator = failing_tt.allocator();
    const hash_result = handleCommand(&state, "setoption name Hash value 2");
    engine.tt.allocator = tt_allocator;
    try std.testing.expect(!try hash_result);
    try std.testing.expect(failing_tt.has_induced_failure);
    try std.testing.expectEqual(@as(u32, 256), state.options.hash_mb);
    try std.testing.expectEqual(@as(u32, 256), state.worker.hashSizeMb());

    // Threads: the new configuration's first allocation fails.
    const engine_allocator = engine.allocator;
    var failing_engine = std.testing.FailingAllocator.init(engine_allocator, .{ .fail_index = 0 });
    engine.allocator = failing_engine.allocator();
    const threads_result = handleCommand(&state, "setoption name Threads value 2");
    engine.allocator = engine_allocator;
    try std.testing.expect(!try threads_result);
    try std.testing.expect(failing_engine.has_induced_failure);
    try std.testing.expectEqual(@as(u8, 1), state.options.threads);
    try std.testing.expectEqual(@as(u8, 1), state.worker.threads());

    try std.testing.expectEqualStrings(
        "info string Hash 2 could not be applied (OutOfMemory); keeping 256\n" ++
            "info string Threads 2 could not be applied (OutOfMemory); keeping 1\n",
        output.contents(),
    );
    // The engine still searches with the kept configuration.
    try std.testing.expect(!try handleCommand(&state, "go depth 2"));
    state.worker.waitIdle();
    try std.testing.expect(!std.mem.eql(u8, bestMoveText(output.contents()).?, "0000"));
}

test "a failed Hash or Threads change is rolled back even when its notice cannot be written" {
    // Judges D (H / J7): restore the options first, then report. The session
    // ends on an output error anyway; the options must not keep the value.
    const Broken = struct {
        fn write(_: *anyopaque, _: []const u8) anyerror!void {
            return error.BrokenPipe;
        }
    };
    var unused: u8 = 0;
    var state: UciState = undefined;
    try state.init(.{ .ctx = &unused, .write_fn = Broken.write });
    defer state.deinit();
    const engine = &state.worker.coordinator.engine;

    const tt_allocator = engine.tt.allocator;
    var failing_tt = std.testing.FailingAllocator.init(tt_allocator, .{ .fail_index = 0 });
    engine.tt.allocator = failing_tt.allocator();
    const hash_result = handleCommand(&state, "setoption name Hash value 2");
    engine.tt.allocator = tt_allocator;
    try std.testing.expectError(error.BrokenPipe, hash_result);
    try std.testing.expectEqual(@as(u32, 256), state.options.hash_mb);

    const engine_allocator = engine.allocator;
    var failing_engine = std.testing.FailingAllocator.init(engine_allocator, .{ .fail_index = 0 });
    engine.allocator = failing_engine.allocator();
    const threads_result = handleCommand(&state, "setoption name Threads value 2");
    engine.allocator = engine_allocator;
    try std.testing.expectError(error.BrokenPipe, threads_result);
    try std.testing.expectEqual(@as(u8, 1), state.options.threads);
}

test "unknown leading tokens are skipped and the command behind them runs once" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    // Audit D (U-UNKNOWN-TOKEN): `joho isready` produced no readyok.
    try std.testing.expect(!try handleCommand(&state, "joho isready"));
    try std.testing.expectEqualStrings("readyok\n", output.contents());
    try std.testing.expect(!try handleCommand(&state, "xyzzy  plugh position startpos moves e2e4"));
    try std.testing.expectEqual(@import("../core/types.zig").Color.black, state.current_position.side_to_move);
    try std.testing.expect(!try handleCommand(&state, "foo go depth 1"));
    state.worker.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.contents(), "bestmove "));
    const before = output.len;

    // No command at all, and the commands accepted and ignored, do nothing; a
    // command owns its arguments, so `isready` after `debug` is not dispatched.
    for ([_][]const u8{ "xyzzy", "  ", "debug on", "register later", "ponderhit", "joho debug isready" }) |line| {
        try std.testing.expect(!try handleCommand(&state, line));
    }
    try std.testing.expectEqual(before, output.len);
    // A command word inside a recognized command's arguments is not run.
    try std.testing.expect(!try handleCommand(&state, "setoption name go value 1"));
    try std.testing.expectEqualStrings("info string unknown option: go\n", output.contents()[before..]);
    try std.testing.expect(try handleCommand(&state, "bye quit"));
}

test "position startpos with moves is applied legally" {
    const parsed = try parsePositionCommand("position startpos moves e2e4 c7c5 g1f3");
    const piece = @import("../core/piece.zig").Piece;

    try std.testing.expectEqual(piece.white_pawn, parsed.position.pieceAt(.e4));
    try std.testing.expectEqual(piece.black_pawn, parsed.position.pieceAt(.c5));
    try std.testing.expectEqual(piece.white_knight, parsed.position.pieceAt(.f3));
    try std.testing.expectEqual(parsed.position.zobrist_key, parsed.history.current());
}

test "position fen rejects an oversized first field without writing past the FEN buffer" {
    // Audit D (U-FEN-OVF): a 128-byte first field filled the 128-byte buffer and
    // the separator before the side-to-move field was written at index 128.
    // Safe builds panicked there; every length is now rejected cleanly.
    for ([_]usize{ 126, 127, 128, 129 }) |len| {
        var line_buffer: [192]u8 = undefined;
        const prefix = "position fen ";
        const suffix = " w - - 0 1";
        @memcpy(line_buffer[0..prefix.len], prefix);
        @memset(line_buffer[prefix.len..][0..len], '8');
        @memcpy(line_buffer[prefix.len + len ..][0..suffix.len], suffix);
        const line = line_buffer[0 .. prefix.len + len + suffix.len];
        try std.testing.expectError(error.InvalidPosition, parsePositionCommand(line));
    }
    // An ordinary FEN still parses.
    _ = try parsePositionCommand("position fen r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 1");
}

test "position fen with a pawn on rank 1 or 8 is rejected" {
    // Audit B (E-BACKRANK-PAWN): both FENs panicked a safe build in the
    // full-threat indexing; a pawn that attacks nothing did not.
    for ([_][]const u8{
        "position fen r3k3/8/8/8/8/8/1n6/P3K2R w - - 0 1",
        "position fen 1p2k3/2N5/8/8/8/8/8/4K3 w - - 0 1",
        "position fen r3k3/8/8/8/8/8/8/P3K2R w - - 0 1",
        "position fen 4k2P/8/8/8/8/8/8/4K3 b - - 0 1",
    }) |line| try std.testing.expectError(error.InvalidPosition, parsePositionCommand(line));
    // Pawns on ranks 2 and 7 and promotions stay fine.
    _ = try parsePositionCommand("position fen 4k3/P6p/8/8/8/8/p6P/4K3 w - - 0 1");
    _ = try parsePositionCommand("position fen 4k3/P7/8/8/8/8/8/4K3 w - - 0 1 moves a7a8q");

    // Rejected like any invalid position: reported, and go does not search the old board.
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();
    try std.testing.expect(!try handleCommandRecovering(&state, "position fen r3k3/8/8/8/8/8/1n6/P3K2R w - - 0 1"));
    try std.testing.expect(!try handleCommandRecovering(&state, "go depth 4"));
    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "info string error: InvalidPosition, command ignored: position fen r3k3/8/8/8/8/8/1n6/P3K2R") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "bestmove 0000\n"));
}

test "position fen accepts missing move counters, halfmove - and fullmove 0" {
    // Audit C (C-FEN-SHORT): these were rejected and answered bestmove 0000.
    const reference = try parsePositionCommand("position startpos moves e2e4");
    const four = try parsePositionCommand("position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - moves e2e4");
    try std.testing.expect(four.position.eql(&reference.position));
    try std.testing.expectEqual(reference.position.zobrist_key, four.position.zobrist_key);
    try std.testing.expectEqual(@as(usize, 2), four.history.count);

    const five = try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - 7");
    try std.testing.expectEqual(@as(u16, 7), five.position.halfmove_clock);
    try std.testing.expectEqual(@as(u16, 1), five.position.fullmove_number);
    const five_moves = try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - 7 moves e1g1");
    try std.testing.expectEqual(@import("../core/piece.zig").Piece.white_king, five_moves.position.pieceAt(.g1));

    const zero = try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - 0 0");
    try std.testing.expectEqual(@as(u16, 1), zero.position.fullmove_number);
    const dash = try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R b K - - 1");
    try std.testing.expectEqual(@as(u16, 0), dash.position.halfmove_clock);
    try std.testing.expectEqual(@as(u16, 1), dash.position.fullmove_number);
    // Equal to the six-field spelling, key included.
    const six = try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - 0 1");
    try std.testing.expect(six.position.eql(&zero.position));
    try std.testing.expectEqual(six.position.zobrist_key, (try parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K -")).position.zobrist_key);

    // Still rejected: three fields, with or without moves, and malformed counters.
    try std.testing.expectError(error.InvalidPosition, parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K"));
    try std.testing.expectError(error.InvalidPosition, parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K moves e1g1"));
    try std.testing.expectError(error.InvalidPosition, parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - x 1"));
    try std.testing.expectError(error.InvalidPosition, parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - 0 -"));
    // A move list after a short FEN is applied, never skipped silently.
    try std.testing.expectError(error.InvalidMove, parsePositionCommand("position fen 4k3/8/8/8/8/8/8/4K2R w K - moves e2e4"));
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

    // Stalemate: no move, score 0.
    try std.testing.expectEqualStrings("0000", bestMoveText(output.contents()).?);
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "info depth 0 score cp 0 ") != null);

    // Checkmate: no move, and the score says so.
    try std.testing.expect(!try handleCommand(&state, "position fen 7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"));
    try std.testing.expect(!try handleCommand(&state, "go depth 1"));
    state.worker.waitIdle();
    try std.testing.expectEqualStrings("0000", bestMoveText(output.contents()).?);
    try std.testing.expect(std.mem.indexOf(u8, output.contents(), "info depth 0 score mate 0 ") != null);
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

test "contempt draw scores do not leak across a change of root side" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name Contempt value 20"));
    // White root: every reply reaches the fifty-move clock, a draw worth -20.
    try std.testing.expect(!try handleCommand(&state, "position fen 6k1/8/8/8/8/8/1R6/K7 w - - 99 2"));
    try std.testing.expect(!try handleCommand(&state, "go depth 1"));
    state.worker.waitIdle();
    // Black root one ply earlier: the same child is now the opponent's draw,
    // still -20 for the root. A reused entry would report +20.
    try std.testing.expect(!try handleCommand(&state, "position fen 7k/8/8/8/8/8/1R6/K7 b - - 98 1"));
    try std.testing.expect(!try handleCommand(&state, "go depth 2 searchmoves h8g8"));
    state.worker.waitIdle();

    const out = output.contents();
    const last_info = std.mem.lastIndexOf(u8, out, "info depth 2 ").?;
    try std.testing.expect(std.mem.indexOf(u8, out[last_info..], " score cp -20 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " score cp 20 ") == null);
}

test "setoption NNUE Scale Percent equal to the shown value is still explicit (a loaded net of another family keeps it)" {
    // B3 review finding 4: a `setoption ... value <shown default>` changed no option and was
    // ignored, so a net of another family loaded afterwards ran at its own default. The
    // embedded net is the E-final ZQBA (advertised 44, the ZQB9 scale too); the other
    // family here is a ZQB1 (66), whose own default differs from the shown value.
    const nnue768 = @import("../eval/nnue768.zig");
    const eval_backend = @import("../eval/backend.zig");
    const allocator = std.testing.allocator;
    const blob = try nnue768.buildZqb1TestBlob(allocator);
    defer allocator.free(blob);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.zqb1", .data = blob });
    const path = try tmp.dir.realpathAlloc(allocator, "t.zqb1");
    defer allocator.free(path);
    var line_buf: [512]u8 = undefined;
    const eval_line = try std.fmt.bufPrint(&line_buf, "setoption name EvalFile value {s}", .{path});

    // Any token spacing names the option (audit D, U-SCALE-WS: doubled spaces
    // used to lose the explicit pin, 44 became 66).
    inline for (.{ "setoption name NNUE Scale Percent value {d}", "setoption  name  NNUE  Scale   Percent  value {d}" }) |spelling| {
        var output = TestOutput{};
        var state: UciState = undefined;
        try state.init(output.sink());
        defer state.deinit();
        const shown = state.options.nnue_scale_percent;
        try std.testing.expectEqual(eval_backend.zqba_nnue_scale_percent, shown);
        try std.testing.expect(shown != eval_backend.default_nnue_scale_percent);
        var set_buf: [128]u8 = undefined;
        const scale_line = try std.fmt.bufPrint(&set_buf, spelling, .{shown});
        try std.testing.expect(!try handleCommand(&state, scale_line));
        try std.testing.expect(!try handleCommand(&state, eval_line));
        try std.testing.expectEqual(shown, state.worker.coordinator.engine.evaluator.nnue_scale_percent);
    }

    // Without the explicit setting the ZQB1 net adopts its own default.
    var fresh: UciState = undefined;
    var output2 = TestOutput{};
    try fresh.init(output2.sink());
    defer fresh.deinit();
    try std.testing.expect(!try handleCommand(&fresh, eval_line));
    try std.testing.expectEqual(eval_backend.default_nnue_scale_percent, fresh.worker.coordinator.engine.evaluator.nnue_scale_percent);
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

test "parse go command treats negative clock values as zero" {
    const pos = try fen.startpos();
    // CCRL game 93: the GUI reported the opponent's overstepped clock.
    const ccrl = try parseGoCommand("go wtime 54250 btime -1000 winc 2000 binc 2000", &pos);
    try std.testing.expectEqual(@as(?u64, 54250), ccrl.limits.wtime_ms);
    try std.testing.expectEqual(@as(?u64, 0), ccrl.limits.btime_ms);
    try std.testing.expectEqual(@as(u64, 2000), ccrl.limits.winc_ms);
    try std.testing.expectEqual(@as(u64, 2000), ccrl.limits.binc_ms);
    const own = try parseGoCommand("go wtime -25 btime 3000 winc -5 binc 0 movetime -1", &pos);
    try std.testing.expectEqual(@as(?u64, 0), own.limits.wtime_ms);
    try std.testing.expectEqual(@as(u64, 0), own.limits.winc_ms);
    try std.testing.expectEqual(@as(?u64, 0), own.limits.movetime_ms);
    try std.testing.expectError(error.InvalidCommand, parseGoCommand("go wtime 12abc", &pos));
}

test "go with the opponent's clock negative still answers with bestmove" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "position startpos moves e2e4"));
    try std.testing.expect(!try handleCommand(&state, "go wtime 54250 btime -1000 winc 2000 binc 2000"));
    state.worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "info string error") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
}

test "go with our own clock negative moves at once" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    var timer = try std.time.Timer.start();
    try std.testing.expect(!try handleCommand(&state, "go wtime -1000 btime 60000 winc 0 binc 0"));
    state.worker.waitIdle();
    // A 1 ms hard cap; generous bound for loaded test hosts.
    try std.testing.expect(timer.read() < 2 * std.time.ns_per_s);

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    // The clock waits for depth 1, so the move is a searched one (U-STOP-D1).
    // The final info line must count searched nodes: an unsearched result is
    // reported as `info depth 1 ... nodes 0` as well (judge D finding E).
    const final_info = std.mem.lastIndexOf(u8, out, "info depth ").?;
    const line_end = std.mem.indexOfScalarPos(u8, out, final_info, '\n').?;
    const nodes_start = std.mem.indexOf(u8, out[final_info..line_end], " nodes ").? + final_info + " nodes ".len;
    const nodes_end = std.mem.indexOfScalarPos(u8, out[0..line_end], nodes_start, ' ') orelse line_end;
    try std.testing.expect(try std.fmt.parseInt(u64, out[nodes_start..nodes_end], 10) > 0);
}

test "go that fails to parse is answered by a one-ply search" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "go mate 0"));
    state.worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "info string error: InvalidCommand, searching depth 1 instead: go mate 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
}

test "parse go command reads a mate request as an explicit limit" {
    const pos = try fen.startpos();
    const command = try parseGoCommand("go mate 3", &pos);
    try std.testing.expectEqual(@as(u16, 3), command.limits.mate_in_moves);
    // Not the one-ply default that a go without any limit gets.
    try std.testing.expectEqual(@as(?u16, null), command.limits.depth);
    try std.testing.expectError(error.InvalidCommand, parseGoCommand("go mate", &pos));
    try std.testing.expectError(error.InvalidCommand, parseGoCommand("go mate 0", &pos));
}

test "go mate searches until the requested mate is proven" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "position fen k7/8/1P6/K7/p1P5/1p4Q1/8/8 w - - 2 40"));
    try std.testing.expect(!try handleCommand(&state, "go mate 2"));
    state.worker.waitIdle();
    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "score mate 2") != null);
    // Two keys mate in 2 here: a5a6 (then b7#) and g3c7 (then Qc8# or Qa7#); the
    // net's move ordering decides which one is proven first.
    const best = bestMoveText(out).?;
    try std.testing.expect(std.mem.eql(u8, best, "a5a6") or std.mem.eql(u8, best, "g3c7"));
}

test "unparseable commands are reported and the session continues" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommandRecovering(&state, "position startpos moves e2e4"));
    const accepted = state.current_position.zobrist_key;

    // UCI: every go needs a bestmove, so a go that fails to parse is answered
    // by a one-ply search of the accepted position instead of being dropped.
    try std.testing.expect(!try handleCommandRecovering(&state, "go depth nope"));
    state.worker.waitIdle();
    try std.testing.expect(!std.mem.eql(u8, bestMoveText(output.contents()).?, "0000"));
    try std.testing.expect(!try handleCommandRecovering(&state, "position startpos moves e2e5"));
    try std.testing.expect(!try handleCommandRecovering(&state, "position fen 4k3/8/8/4P3/8/8/8/4K3 w - d6 0 1"));
    try std.testing.expect(!try handleCommandRecovering(&state, "position"));
    // The stored position is untouched by the rejected commands...
    try std.testing.expectEqual(accepted, state.current_position.zobrist_key);
    // ...but it is not the board the GUI means, so go does not search it.
    try std.testing.expect(!try handleCommandRecovering(&state, "go depth 1"));
    try std.testing.expect(!try handleCommandRecovering(&state, "isready"));
    {
        const out = output.contents();
        try std.testing.expect(std.mem.indexOf(u8, out, "info string error: InvalidCommand, searching depth 1 instead: go depth nope\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "info string error: InvalidMove, command ignored: position startpos moves e2e5\n") != null);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "info string error: InvalidPosition"));
        try std.testing.expect(std.mem.endsWith(u8, out, "no search started\nbestmove 0000\nreadyok\n"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "bestmove"));
    }

    // An accepted position restores normal service.
    try std.testing.expect(!try handleCommandRecovering(&state, "position startpos moves e2e4 e7e5"));
    try std.testing.expect(!try handleCommandRecovering(&state, "go depth 1"));
    state.worker.waitIdle();
    try std.testing.expect(!std.mem.eql(u8, bestMoveText(output.contents()).?, "0000"));
    try std.testing.expect(try handleCommandRecovering(&state, "quit"));
}

test "a failed SyzygyPath change reports that tablebases are off" {
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();

    try std.testing.expect(!try handleCommand(&state, "setoption name SyzygyPath value /nonexistent-zigqueen-tablebases"));
    try std.testing.expectEqualStrings("", state.options.syzygyPath());
    try std.testing.expectEqualStrings("info string SyzygyPath could not be loaded; tablebases disabled\n", output.contents());
    // Clearing the path is not a failure and stays silent.
    try std.testing.expect(!try handleCommand(&state, "setoption name SyzygyPath value <empty>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.contents(), "\n"));
}

test "a SyzygyPath change reports the tables and how they are stored" {
    const path = std.process.getEnvVarOwned(std.testing.allocator, "ZQ_TB_PATH") catch return error.SkipZigTest;
    defer std.testing.allocator.free(path);
    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();
    var line: [600]u8 = undefined;
    try std.testing.expect(!try handleCommand(&state, try std.fmt.bufPrint(&line, "setoption name SyzygyPath value {s}", .{path})));
    defer _ = handleCommand(&state, "setoption name SyzygyPath value <empty>") catch {};
    const out = output.contents();
    try std.testing.expect(std.mem.startsWith(u8, out, "info string Syzygy tables: "));
    try std.testing.expect(std.mem.indexOf(u8, out, " 0 rejected; storage " ++ build_options.tb_storage ++ ": ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " 0 mapping failures\n") != null);
    if (!std.mem.eql(u8, build_options.tb_storage, "pread")) {
        try std.testing.expect(std.mem.indexOf(u8, out, " 0 on positioned reads,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ": 0 files mapped") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
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

test "command reader folds tabs into spaces" {
    const text = "position\tstartpos \t moves\te2e4\r\nisready\t\n";
    var input = std.io.fixedBufferStream(text);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);

    const position_line = (try readCommandLine(&input, &buffer, std.testing.allocator)).?;
    const parsed = try parsePositionCommand(position_line);
    const expected = try parsePositionCommand("position startpos moves e2e4");
    try std.testing.expectEqual(expected.position.zobrist_key, parsed.position.zobrist_key);

    var output = TestOutput{};
    var state: UciState = undefined;
    try state.init(output.sink());
    defer state.deinit();
    try std.testing.expect(!try handleCommand(&state, (try readCommandLine(&input, &buffer, std.testing.allocator)).?));
    try std.testing.expectEqualStrings("readyok\n", output.contents());
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
