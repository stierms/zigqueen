const std = @import("std");
const build_options = @import("build_options");
const eval_backend = @import("../eval/backend.zig");
const basin = @import("../search/basin.zig");
const tunables = @import("../search/tunables.zig");

const max_string_option_len = 512;

pub const Options = struct {
    hash_mb: u32 = 256,
    threads: u8 = 1,
    move_overhead_ms: u32 = 20,
    // Out-of-the-box default: the embedded bullet pure NNUE at its calibrated
    // scale (queen ~= HCE centipawns). Engine plays correctly with zero setoption.
    nnue_scale_percent: u16 = eval_backend.builtin_nnue_scale_percent,
    // Draw contempt in engine cp: in-tree draws score -contempt for the root
    // side. 0 (default) = classical draws, bit-identical to pre-contempt play.
    contempt_cp: i16 = 0,
    // One machine-wide read-only copy of the net weights for every zigqueen
    // process of this user that loads the same net (eval/net_share.zig).
    // Search output is identical either way. OFF by default (operator decision
    // 2026-10-15): our SPRTs and gauntlets run without it, since sharing only
    // between copies of the NEW version would inflate a new-vs-old test. Turn
    // it on where many copies of the same engine run on purpose (parallel
    // lichess bots, self-play datagen); among foreign engines it gains nothing.
    shared_weights: bool = false,
    eval_file_storage: [max_string_option_len]u8 = [_]u8{0} ** max_string_option_len,
    eval_file_len: usize = 0,
    syzygy_path_storage: [max_string_option_len]u8 = [_]u8{0} ** max_string_option_len,
    syzygy_path_len: usize = 0,
    basin_params: if (build_options.tuning) basin.Params else void = if (build_options.tuning) .{} else {},

    pub fn writeUciOptions(self: *const Options, sink: anytype) !void {
        var hash_buffer: [96]u8 = undefined;
        const hash_line = try std.fmt.bufPrint(&hash_buffer, "option name Hash type spin default {d} min 1 max 65536\n", .{self.hash_mb});
        try sink.writeAll(hash_line);

        var threads_buffer: [96]u8 = undefined;
        const threads_line = try std.fmt.bufPrint(&threads_buffer, "option name Threads type spin default {d} min 1 max 32\n", .{self.threads});
        try sink.writeAll(threads_line);

        var overhead_buffer: [128]u8 = undefined;
        const overhead_line = try std.fmt.bufPrint(&overhead_buffer, "option name Move Overhead type spin default {d} min 0 max 1000\n", .{self.move_overhead_ms});
        try sink.writeAll(overhead_line);

        var nnue_scale_buffer: [128]u8 = undefined;
        const nnue_scale_line = try std.fmt.bufPrint(&nnue_scale_buffer, "option name NNUE Scale Percent type spin default {d} min 0 max 400\n", .{self.nnue_scale_percent});
        try sink.writeAll(nnue_scale_line);

        var syzygy_buffer: [640]u8 = undefined;
        const syzygy_line = try std.fmt.bufPrint(&syzygy_buffer, "option name SyzygyPath type string default {s}\n", .{if (self.syzygy_path_len == 0) "<empty>" else self.syzygyPath()});
        try sink.writeAll(syzygy_line);

        var contempt_buffer: [128]u8 = undefined;
        const contempt_line = try std.fmt.bufPrint(&contempt_buffer, "option name Contempt type spin default {d} min -200 max 200\n", .{self.contempt_cp});
        try sink.writeAll(contempt_line);

        var eval_file_buffer: [640]u8 = undefined;
        const eval_file_line = try std.fmt.bufPrint(&eval_file_buffer, "option name EvalFile type string default {s}\n", .{self.evalFilePath()});
        try sink.writeAll(eval_file_line);

        try sink.writeAll(if (self.shared_weights)
            "option name NNUE Shared Weights type check default true\n"
        else
            "option name NNUE Shared Weights type check default false\n");

        // Runtime-tunable search params are a development-only UCI surface.
        // Their defaults remain the shipped search values in both flavours.
        if (comptime build_options.tuning) {
            inline for (tunables.specs) |spec| {
                var buffer: [160]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "option name {s} type spin default {d} min {d} max {d}\n", .{ spec.uci_name, spec.default, spec.min, spec.max });
                try sink.writeAll(line);
            }
            inline for (basin.specs) |spec| {
                var buffer: [192]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "option name {s} type spin default {d} min {d} max {d}\n", .{ spec.uci_name, spec.default, spec.min, spec.max });
                try sink.writeAll(line);
            }
        }
    }

    pub fn applySetOptionLine(self: *Options, line: []const u8) ApplyOptionError!ApplyOptionResult {
        const option_line = try parseSetOptionLine(line);
        const name = option_line.name();
        const value = option_line.value;

        if (std.ascii.eqlIgnoreCase(name, "Hash")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (parsed < 1 or parsed > 65536) return error.InvalidValue;
            self.hash_mb = parsed;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "Threads")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
            if (parsed < 1 or parsed > @import("../search/parallel_pool.zig").MAX_THREADS) return error.InvalidValue;
            self.threads = parsed;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "Move Overhead")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (parsed > 1000) return error.InvalidValue;
            self.move_overhead_ms = parsed;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "NNUE Scale Percent")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            if (parsed > 400) return error.InvalidValue;
            self.nnue_scale_percent = parsed;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "Contempt")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(i16, value, 10) catch return error.InvalidValue;
            if (parsed < -200 or parsed > 200) return error.InvalidValue;
            self.contempt_cp = parsed;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "SyzygyPath")) {
            if (value.len > max_string_option_len) return error.InvalidValue;
            @memcpy(self.syzygy_path_storage[0..value.len], value);
            self.syzygy_path_len = value.len;
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "EvalFile")) {
            try self.setEvalFilePath(value);
            return .applied;
        }

        if (std.ascii.eqlIgnoreCase(name, "NNUE Shared Weights")) {
            if (std.ascii.eqlIgnoreCase(value, "true")) {
                self.shared_weights = true;
            } else if (std.ascii.eqlIgnoreCase(value, "false")) {
                self.shared_weights = false;
            } else return error.InvalidValue;
            return .applied;
        }

        // Runtime-tunable search params (SPSA scaffold) -> global tunables.active.
        // The whole dispatch path is absent from the default release flavour.
        if (comptime build_options.tuning) {
            if (value.len != 0) {
                if (std.fmt.parseInt(i32, value, 10)) |parsed| {
                    if (basin.setParam(&self.basin_params, name, parsed)) return .applied;
                    if (tunables.set(name, parsed)) return .applied;
                } else |_| {}
            }
        }

        return .ignored;
    }

    pub fn syzygyPath(self: *const Options) []const u8 {
        return self.syzygy_path_storage[0..self.syzygy_path_len];
    }

    pub fn syzygyPathChanged(self: *const Options, previous: Options) bool {
        return !std.mem.eql(u8, self.syzygyPath(), previous.syzygyPath());
    }

    pub fn evalFilePath(self: *const Options) []const u8 {
        if (self.eval_file_len == 0) return eval_backend.builtin_eval_file;
        return self.eval_file_storage[0..self.eval_file_len];
    }

    pub fn evalFileChanged(self: *const Options, previous: Options) bool {
        return !std.mem.eql(u8, self.evalFilePath(), previous.evalFilePath());
    }

    pub fn evalOptions(self: *const Options) eval_backend.Options {
        return .{
            .nnue_scale_percent = self.nnue_scale_percent,
            .eval_file_path = self.evalFilePath(),
            .share_weights = self.shared_weights,
        };
    }

    pub fn basinParamsChanged(self: *const Options, previous: Options) bool {
        if (comptime build_options.tuning) return !std.meta.eql(self.basin_params, previous.basin_params);
        return false;
    }

    fn setEvalFilePath(self: *Options, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, eval_backend.builtin_eval_file)) {
            self.eval_file_len = 0;
            return;
        }
        if (trimmed.len > self.eval_file_storage.len) return error.InvalidValue;
        @memcpy(self.eval_file_storage[0..trimmed.len], trimmed);
        self.eval_file_len = trimmed.len;
    }
};

pub const ApplyOptionResult = enum {
    applied,
    ignored,
};

/// A `setoption name <id> [value <x>]` line split into the option name, its
/// tokens joined by single spaces, and the value text. This is the one place
/// an option name is canonicalized: `applySetOptionLine` dispatches on it, and
/// the protocol asks it which option a line named (audit D, U-SCALE-WS: a raw
/// substring test missed `NNUE  Scale  Percent` with doubled spaces).
pub const SetOptionLine = struct {
    name_buffer: [64]u8 = undefined,
    name_len: usize = 0,
    value: []const u8 = "",

    pub fn name(self: *const SetOptionLine) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// Whether the line names `option`, matched as `applySetOptionLine` matches it.
    pub fn names(self: *const SetOptionLine, option: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name(), option);
    }
};

pub fn parseSetOptionLine(line: []const u8) ApplyOptionError!SetOptionLine {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidCommand, "setoption")) {
        return error.InvalidCommand;
    }
    if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidCommand, "name")) {
        return error.InvalidCommand;
    }

    var parsed = SetOptionLine{};
    var saw_value = false;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "value")) {
            saw_value = true;
            break;
        }
        if (parsed.name_len != 0) {
            if (parsed.name_len >= parsed.name_buffer.len) return error.InvalidOption;
            parsed.name_buffer[parsed.name_len] = ' ';
            parsed.name_len += 1;
        }
        if (parsed.name_len + token.len > parsed.name_buffer.len) return error.InvalidOption;
        @memcpy(parsed.name_buffer[parsed.name_len..][0..token.len], token);
        parsed.name_len += token.len;
    }

    if (parsed.name_len == 0) return error.InvalidOption;

    // The value is everything after the `value` token, byte for byte apart
    // from surrounding whitespace: a path may contain repeated spaces.
    const raw_value = if (saw_value) std.mem.trim(u8, tokens.rest(), " \t\r\n") else "";
    // `<empty>` is how UCI spells the empty string, as in our own
    // `option name SyzygyPath type string default <empty>`.
    parsed.value = if (std.mem.eql(u8, raw_value, "<empty>")) "" else raw_value;
    return parsed;
}

test "setoption names are canonicalized whatever the token spacing" {
    const parsed = try parseSetOptionLine("setoption  name  NNUE   Scale  Percent   value  44 ");
    try std.testing.expectEqualStrings("NNUE Scale Percent", parsed.name());
    try std.testing.expect(parsed.names("nnue scale percent"));
    try std.testing.expectEqualStrings("44", parsed.value);
    const bare = try parseSetOptionLine("setoption name Clear Hash");
    try std.testing.expect(bare.names("Clear Hash"));
    try std.testing.expectEqualStrings("", bare.value);
    try std.testing.expectError(error.InvalidOption, parseSetOptionLine("setoption name value 1"));
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption  name NNUE  Scale Percent value 75"));
    try std.testing.expectEqual(@as(u16, 75), options.nnue_scale_percent);
}

pub const ApplyOptionError = error{
    InvalidCommand,
    InvalidOption,
    InvalidValue,
};

test "setoption updates hash within bounds" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name Hash value 128"));
    try std.testing.expectEqual(@as(u32, 128), options.hash_mb);
}

test "setoption rejects unsupported thread counts" {
    var options = Options{};
    try std.testing.expectError(error.InvalidValue, options.applySetOptionLine("setoption name Threads value 33"));
    try std.testing.expectEqual(@as(u8, 1), options.threads);
}

test "unknown setoption names are ignored" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.ignored, try options.applySetOptionLine("setoption name Clear Hash"));
    try std.testing.expectEqual(@as(u32, 256), options.hash_mb);
}

test "setoption matches option names without regard to case" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name hash value 64"));
    try std.testing.expectEqual(@as(u32, 64), options.hash_mb);
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name MOVE overhead value 7"));
    try std.testing.expectEqual(@as(u32, 7), options.move_overhead_ms);
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name syzygypath value /tb"));
    try std.testing.expectEqualStrings("/tb", options.syzygyPath());
}

test "setoption keeps string values byte for byte" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name EvalFile value   /nets/my  net  v2.zqb  "));
    try std.testing.expectEqualStrings("/nets/my  net  v2.zqb", options.evalFilePath());
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name SyzygyPath value /tb/a  b:/tb/c"));
    try std.testing.expectEqualStrings("/tb/a  b:/tb/c", options.syzygyPath());
    // Empty spellings clear the path: no value, a lone space, UCI's <empty>.
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name SyzygyPath value <empty>"));
    try std.testing.expectEqualStrings("", options.syzygyPath());
    _ = try options.applySetOptionLine("setoption name SyzygyPath value /tb");
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name SyzygyPath value  "));
    try std.testing.expectEqualStrings("", options.syzygyPath());
    try std.testing.expectError(error.InvalidValue, options.applySetOptionLine("setoption name Hash value 64 128"));
}

test "setoption updates move overhead" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name Move Overhead value 12"));
    try std.testing.expectEqual(@as(u32, 12), options.move_overhead_ms);
}

test "setoption updates NNUE Scale Percent" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name NNUE Scale Percent value 75"));
    try std.testing.expectEqual(@as(u16, 75), options.nnue_scale_percent);
    try std.testing.expectError(error.InvalidValue, options.applySetOptionLine("setoption name NNUE Scale Percent value 401"));
}

test "setoption updates EvalFile and builtin sentinel" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name EvalFile value /tmp/model.zqnnue"));
    try std.testing.expectEqualStrings("/tmp/model.zqnnue", options.evalFilePath());
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name EvalFile value <builtin>"));
    try std.testing.expectEqualStrings(eval_backend.builtin_eval_file, options.evalFilePath());
}

test "setoption toggles NNUE Shared Weights (default off)" {
    var options = Options{};
    try std.testing.expect(!options.shared_weights);
    try std.testing.expect(!options.evalOptions().share_weights);
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name nnue shared weights value TRUE"));
    try std.testing.expect(options.shared_weights);
    try std.testing.expect(options.evalOptions().share_weights);
    try std.testing.expectError(error.InvalidValue, options.applySetOptionLine("setoption name NNUE Shared Weights value 0"));
    try std.testing.expect(options.shared_weights);
    try std.testing.expectEqual(ApplyOptionResult.applied, try options.applySetOptionLine("setoption name NNUE Shared Weights value false"));
    try std.testing.expect(!options.shared_weights);
}

test "tuning setoption dispatch follows the build flavour" {
    tunables.reset();
    defer tunables.reset();

    var options = Options{};
    const result = try options.applySetOptionLine("setoption name RazorBase value 200");
    if (build_options.tuning) {
        try std.testing.expectEqual(ApplyOptionResult.applied, result);
        try std.testing.expectEqual(@as(i32, 200), tunables.active.razor_base);
    } else {
        try std.testing.expectEqual(ApplyOptionResult.ignored, result);
        try std.testing.expectEqual(TunablesDefaults.razor_base, tunables.active.razor_base);
    }
}

test "basin tuning setoption dispatch follows the build flavour" {
    var options = Options{};
    const result = try options.applySetOptionLine("setoption name BasinRfpLinear value 91");
    if (build_options.tuning) {
        try std.testing.expectEqual(ApplyOptionResult.applied, result);
        try std.testing.expectEqual(@as(i32, 91), options.basin_params.rfp_linear);
    } else {
        try std.testing.expectEqual(ApplyOptionResult.ignored, result);
    }
}

const TunablesDefaults = tunables.Tunables{};
