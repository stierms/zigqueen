const std = @import("std");
const build_options = @import("build_options");
const eval_backend = @import("../eval/backend.zig");
const tunables = @import("../search/tunables.zig");

const max_string_option_len = 512;

pub const Options = struct {
    hash_mb: u32 = 256,
    threads: u8 = 1,
    move_overhead_ms: u32 = 20,
    // Out-of-the-box default: the embedded bullet pure NNUE at its calibrated
    // scale (queen ~= HCE centipawns). Engine plays correctly with zero setoption.
    nnue_scale_percent: u16 = eval_backend.default_nnue_scale_percent,
    // Draw contempt in engine cp: in-tree draws score -contempt for the root
    // side. 0 (default) = classical draws, bit-identical to pre-contempt play.
    contempt_cp: i16 = 0,
    eval_file_storage: [max_string_option_len]u8 = [_]u8{0} ** max_string_option_len,
    eval_file_len: usize = 0,
    syzygy_path_storage: [max_string_option_len]u8 = [_]u8{0} ** max_string_option_len,
    syzygy_path_len: usize = 0,

    pub fn writeUciOptions(self: *const Options, sink: anytype) !void {
        var hash_buffer: [96]u8 = undefined;
        const hash_line = try std.fmt.bufPrint(&hash_buffer, "option name Hash type spin default {d} min 1 max 65536\n", .{self.hash_mb});
        try sink.writeAll(hash_line);

        var threads_buffer: [96]u8 = undefined;
        const threads_line = try std.fmt.bufPrint(&threads_buffer, "option name Threads type spin default {d} min 1 max 1\n", .{self.threads});
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

        // Runtime-tunable search params: only advertised in -Dtunables builds
        // (internal SPSA tuning). The release binary ships the compiled-in
        // defaults and does not expose them.
        if (build_options.tunables) {
            inline for (tunables.specs) |spec| {
                var buffer: [160]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "option name {s} type spin default {d} min {d} max {d}\n", .{ spec.uci_name, spec.default, spec.min, spec.max });
                try sink.writeAll(line);
            }
        }
    }

    pub fn applySetOptionLine(self: *Options, line: []const u8) ApplyOptionError!ApplyOptionResult {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidCommand, "setoption")) {
            return error.InvalidCommand;
        }
        if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidCommand, "name")) {
            return error.InvalidCommand;
        }

        var name_buffer: [64]u8 = undefined;
        var name_len: usize = 0;
        var saw_value = false;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "value")) {
                saw_value = true;
                break;
            }
            if (name_len != 0) {
                if (name_len >= name_buffer.len) return error.InvalidOption;
                name_buffer[name_len] = ' ';
                name_len += 1;
            }
            if (name_len + token.len > name_buffer.len) return error.InvalidOption;
            @memcpy(name_buffer[name_len..][0..token.len], token);
            name_len += token.len;
        }

        if (name_len == 0) return error.InvalidOption;
        const name = name_buffer[0..name_len];

        var value_buffer: [max_string_option_len]u8 = undefined;
        var value_len: usize = 0;
        if (saw_value) {
            while (tokens.next()) |token| {
                if (value_len != 0) {
                    if (value_len >= value_buffer.len) return error.InvalidValue;
                    value_buffer[value_len] = ' ';
                    value_len += 1;
                }
                if (value_len + token.len > value_buffer.len) return error.InvalidValue;
                @memcpy(value_buffer[value_len..][0..token.len], token);
                value_len += token.len;
            }
        }
        const value = value_buffer[0..value_len];

        if (std.mem.eql(u8, name, "Hash")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (parsed < 1 or parsed > 65536) return error.InvalidValue;
            self.hash_mb = parsed;
            return .applied;
        }

        if (std.mem.eql(u8, name, "Threads")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
            if (parsed != 1) return error.InvalidValue;
            self.threads = parsed;
            return .applied;
        }

        if (std.mem.eql(u8, name, "Move Overhead")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            if (parsed > 1000) return error.InvalidValue;
            self.move_overhead_ms = parsed;
            return .applied;
        }

        if (std.mem.eql(u8, name, "NNUE Scale Percent")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            if (parsed > 400) return error.InvalidValue;
            self.nnue_scale_percent = parsed;
            return .applied;
        }

        if (std.mem.eql(u8, name, "Contempt")) {
            if (value.len == 0) return error.InvalidValue;
            const parsed = std.fmt.parseInt(i16, value, 10) catch return error.InvalidValue;
            if (parsed < -200 or parsed > 200) return error.InvalidValue;
            self.contempt_cp = parsed;
            return .applied;
        }

        if (std.mem.eql(u8, name, "SyzygyPath")) {
            if (value.len > max_string_option_len) return error.InvalidValue;
            @memcpy(self.syzygy_path_storage[0..value.len], value);
            self.syzygy_path_len = value.len;
            return .applied;
        }

        if (std.mem.eql(u8, name, "EvalFile")) {
            try self.setEvalFilePath(value);
            return .applied;
        }

        // Runtime-tunable search params -> global tunables.active (only settable
        // in -Dtunables builds; clamps internally, so a boundary perturbation
        // never stalls an SPSA driver).
        if (build_options.tunables and value.len != 0) {
            if (std.fmt.parseInt(i32, value, 10)) |parsed| {
                if (tunables.set(name, parsed)) return .applied;
            } else |_| {}
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
        };
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
    try std.testing.expectError(error.InvalidValue, options.applySetOptionLine("setoption name Threads value 2"));
    try std.testing.expectEqual(@as(u8, 1), options.threads);
}

test "unknown setoption names are ignored" {
    var options = Options{};
    try std.testing.expectEqual(ApplyOptionResult.ignored, try options.applySetOptionLine("setoption name Clear Hash"));
    try std.testing.expectEqual(@as(u32, 256), options.hash_mb);
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
