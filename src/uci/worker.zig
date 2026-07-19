const std = @import("std");
const engine_mod = @import("../search/engine.zig");
const position = @import("../core/position.zig");
const repetition = @import("../search/repetition.zig");
const search_time = @import("../search/time.zig");
const search_info = @import("../search/search_info.zig");
const tt = @import("../search/tt.zig");
const info = @import("info.zig");

pub const OutputSink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn writeAll(self: OutputSink, bytes: []const u8) anyerror!void {
        return self.write_fn(self.ctx, bytes);
    }

    pub fn print(self: OutputSink, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buffer: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(text);
    }

    pub fn writeByte(self: OutputSink, byte: u8) anyerror!void {
        var buffer = [1]u8{byte};
        try self.writeAll(&buffer);
    }
};

pub const SearchRequest = struct {
    position: position.Position,
    history: repetition.History,
    limits: search_time.GoLimits,
    move_overhead_ms: u32 = @intCast(search_time.DEFAULT_MOVE_OVERHEAD_MS),
};

pub const Worker = struct {
    mutex: std.Thread.Mutex = .{},
    command_ready: std.Thread.Condition = .{},
    became_idle: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    output: OutputSink,
    engine: engine_mod.Engine,
    pending_request: ?SearchRequest = null,
    searching: bool = false,
    shutdown: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set true once the search has streamed at least one exact iteration line,
    /// so the post-search code knows not to print a duplicate final line.
    info_streamed: bool = false,

    pub fn init(output: OutputSink, hash_mb: u32) !Worker {
        return initWithOptions(output, hash_mb, .{});
    }

    pub fn initWithOptions(output: OutputSink, hash_mb: u32, eval_options: engine_mod.EvalOptions) !Worker {
        return .{
            .output = output,
            .engine = try engine_mod.Engine.initWithOptions(std.heap.page_allocator, hash_mb, eval_options),
        };
    }

    pub fn start(self: *Worker) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn deinit(self: *Worker) void {
        self.mutex.lock();
        self.shutdown = true;
        self.stop_requested.store(true, .release);
        self.pending_request = null;
        self.command_ready.broadcast();
        self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.engine.deinit();
    }

    pub fn resetEngine(self: *Worker) void {
        self.stopAndWait();
        self.engine.reset();
    }

    pub fn setNnueScalePercent(self: *Worker, nnue_scale_percent: u16) void {
        self.stopAndWait();
        self.engine.setNnueScalePercent(nnue_scale_percent);
    }

    pub fn setContempt(self: *Worker, contempt_cp: i32) void {
        self.stopAndWait();
        self.engine.setContempt(contempt_cp);
    }

    pub fn setSyzygyPath(self: *Worker, path: []const u8) bool {
        self.stopAndWait();
        return self.engine.setSyzygyPath(path);
    }

    pub fn loadNnueFile(self: *Worker, path: []const u8) !void {
        self.stopAndWait();
        try self.engine.loadNnueFile(path);
    }

    pub fn resizeHash(self: *Worker, hash_mb: u32) !void {
        self.stopAndWait();
        try self.engine.resizeHash(hash_mb);
    }

    pub fn hashSizeMb(self: *const Worker) u32 {
        return self.engine.hashSizeMb();
    }

    pub fn startSearch(self: *Worker, request: SearchRequest) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.thread != null);
        std.debug.assert(!self.searching);

        self.stop_requested.store(false, .release);
        self.pending_request = request;
        self.searching = true;
        self.command_ready.signal();
    }

    pub fn stop(self: *Worker) void {
        self.stop_requested.store(true, .release);
    }

    pub fn stopAndWait(self: *Worker) void {
        self.stop();
        self.waitIdle();
    }

    pub fn waitIdle(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.searching) {
            self.became_idle.wait(&self.mutex);
        }
    }

    fn threadMain(self: *Worker) void {
        self.mutex.lock();
        while (true) {
            while (self.pending_request == null and !self.shutdown) {
                self.command_ready.wait(&self.mutex);
            }

            if (self.shutdown and self.pending_request == null) {
                self.searching = false;
                self.became_idle.broadcast();
                self.mutex.unlock();
                return;
            }

            const request = self.pending_request.?;
            self.pending_request = null;
            self.mutex.unlock();

            self.runSearch(request);

            self.mutex.lock();
            self.searching = false;
            self.became_idle.broadcast();
        }
    }

    fn runSearch(self: *Worker, request: SearchRequest) void {
        var timer = std.time.Timer.start() catch null;
        const controller_limits = request.limits.toControllerLimits(request.position.side_to_move, request.move_overhead_ms);

        // Install the per-iteration info sink for this search; the engine streams
        // `info depth ...` lines through it as each depth (or aspiration fail) lands.
        self.info_streamed = false;
        self.engine.info_emitter = .{ .ctx = self, .emit_fn = emitInfo };

        const result = self.engine.search(&request.position, &request.history, controller_limits, &self.stop_requested);
        const elapsed_ns: u64 = if (timer) |*search_timer| search_timer.read() else 0;
        const elapsed_ms: u64 = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
        const reported_depth = if (result.depth != 0) result.depth else request.limits.depth orelse 1;

        if (result.best_move != null) {
            // The last streamed exact line already IS the final line; only emit one
            // here for the paths that never stream (book move, immediate draw, a
            // depth-1 stop before any iteration completed).
            if (!self.info_streamed) self.writeInfoLine(&result, reported_depth, elapsed_ms) catch {};
            self.writeBestMove(result.best_move.?) catch {};
        } else {
            self.output.print("info depth 0 score cp 0 nodes {d} time {d}\n", .{ result.nodes, elapsed_ms }) catch {};
            self.output.writeAll("bestmove 0000\n") catch {};
        }
    }

    fn emitInfo(ctx: *anyopaque, msg: search_info.InfoMessage) void {
        const self: *Worker = @ptrCast(@alignCast(ctx));
        switch (msg) {
            .iteration => |it| {
                if (it.bound == .exact) self.info_streamed = true;
                info.writeIterationLine(self.output, it) catch {};
            },
            .currmove => |cm| info.writeCurrMoveLine(self.output, cm) catch {},
        }
    }

    fn writeInfoLine(self: *Worker, result: *const engine_mod.SearchResult, depth: u16, elapsed_ms: u64) !void {
        try info.writeFinalLine(self.output, result, depth, elapsed_ms, self.engine.hashfullPermille());
    }

    fn writeBestMove(self: *Worker, mv: @import("../core/move.zig").Move) !void {
        try self.output.writeAll("bestmove ");
        try mv.writeUci(self.output);
        try self.output.writeAll("\n");
    }
};

/// In-memory OutputSink for unit tests (shared with protocol.zig's tests).
pub const TestOutput = struct {
    mutex: std.Thread.Mutex = .{},
    buffer: [8192]u8 = [_]u8{0} ** 8192,
    len: usize = 0,

    pub fn sink(self: *TestOutput) OutputSink {
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

    pub fn contents(self: *const TestOutput) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "worker emits bestmove after stop on infinite search" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .infinite = true },
    });

    std.Thread.sleep(5 * std.time.ns_per_ms);
    worker.stopAndWait();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove 0000") == null);
}

test "worker prints a pv line starting with the reported bestmove" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 2 },
    });
    worker.waitIdle();

    const out = output.contents();
    const bestmove_index = std.mem.indexOf(u8, out, "bestmove ").? + "bestmove ".len;
    // We now stream a pv line per iteration; the final iteration's pv (the last
    // one) is the one that must agree with the reported bestmove.
    const pv_index = std.mem.lastIndexOf(u8, out, " pv ").? + " pv ".len;

    try std.testing.expect(std.mem.eql(u8, out[bestmove_index .. bestmove_index + 4], out[pv_index .. pv_index + 4]));
}

test "worker hash can be resized via engine ownership" {
    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), 1);
    defer worker.deinit();

    const before = worker.hashSizeMb();
    try worker.resizeHash(2);
    try std.testing.expect(worker.hashSizeMb() >= before);
}

test "worker info line includes nps and hashfull" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .movetime_ms = 10 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, " seldepth ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " nps ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " hashfull ") != null);
}

test "worker formats mate scores in uci info lines" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.init(output.sink(), tt.DEFAULT_HASH_MB);
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.parse("6k1/5Q2/6K1/8/8/8/8/8 w - - 0 1");
    history.push(pos.zobrist_key);

    worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 1 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "score mate 1") != null);
}

test "worker can search with nnue backend enabled" {
    const fen = @import("../core/fen.zig");

    var output = TestOutput{};
    var worker = try Worker.initWithOptions(output.sink(), tt.DEFAULT_HASH_MB, .{});
    try worker.start();
    defer worker.deinit();

    var history = repetition.History{};
    const pos = try fen.startpos();
    history.push(pos.zobrist_key);

    worker.startSearch(.{
        .position = pos,
        .history = history,
        .limits = .{ .depth = 2 },
    });
    worker.waitIdle();

    const out = output.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bestmove ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nodes 0") == null);
}
