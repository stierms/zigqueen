//! One machine-wide copy of a loaded net's weights (perf lever 2, 2026-10-15).
//!
//! `nnue768.loadFromBytes` builds every weight array privately: it reads the
//! file and runs the load-time layout transforms (l1 permutations, blocked
//! and fused l1 copies, transposed l2). `share` then
//! moves ALL of those arrays (every slice field of `Net`; they are read-only
//! from here on) into one shared read-only blob (util/shared_blob.zig) and
//! frees the private copies. Scalars and small fixed arrays (bucket tables,
//! l1 permutations and residual offsets, the AVX-VNNI flag) stay in the
//! process's own `Net`; each process computed them from the same bytes.
//!
//! Exactness: the blob key is a 64-bit XxHash3 of a descriptor (layout version,
//! target arch, CPU model and feature set, per-field name/offset/size) and of
//! every transformed byte. The key only names the blob: a blob is used only
//! after a byte-for-byte comparison of every array against this process's own
//! freshly built copy, so a key collision, a different net or EvalFile, another
//! ISA path or any incompatible build simply fails to attach and keeps (or
//! publishes) its own copy. Once the comparison passes, the search reads
//! exactly the bytes it would have read privately.
//!
//! Packing: fields in declaration order, each at a 64-byte boundary (every
//! weight array asks for at most align(64)); empty slices take no space.

const std = @import("std");
const builtin = @import("builtin");
const nnue768 = @import("nnue768.zig");
const shared_blob = @import("../util/shared_blob.zig");

const Net = nnue768.Net;

/// Bump when the packing rule or the set of shared fields changes meaning.
pub const LAYOUT_VERSION: u32 = 1;
const FIELD_ALIGN: usize = 64;

/// Names of every slice field of `Net`: all of them are weights.
pub const slice_fields: []const []const u8 = blk: {
    var names: []const []const u8 = &.{};
    for (@typeInfo(Net).@"struct".fields) |f| {
        const info = @typeInfo(f.type);
        if (info == .pointer and info.pointer.size == .slice) names = names ++ .{f.name};
    }
    break :blk names;
};

comptime {
    for (slice_fields) |name| {
        const P = @typeInfo(@FieldType(Net, name)).pointer;
        // Only plain data may live in a shared mapping.
        if (P.is_const or P.sentinel_ptr != null) @compileError("unexpected Net slice field " ++ name);
        if (P.alignment > FIELD_ALIGN) @compileError("Net field over-aligned for the blob: " ++ name);
        switch (@typeInfo(P.child)) {
            .int, .float => {},
            else => @compileError("Net slice field with non-scalar elements: " ++ name),
        }
    }
}

pub const Mode = enum { private, created, attached };

pub const Status = struct {
    mode: Mode = .private,
    /// Why the weights are private: "disabled", or an error name.
    reason: []const u8 = "disabled",
    /// Bytes of shared weights (excludes the header page and tail slack).
    payload_bytes: usize = 0,
    /// Whole mapping, for the huge-page share.
    map_bytes: usize = 0,
    pages: shared_blob.PageReport = .{},
    key: u64 = 0,

    pub fn isShared(self: Status) bool {
        return self.mode != .private;
    }

    /// One-line description for `info string NNUE weights: ...`.
    pub fn describe(self: Status, buf: []u8) []const u8 {
        if (self.mode == .private) {
            return std.fmt.bufPrint(buf, "private ({s})", .{self.reason}) catch "private";
        }
        const mb = @as(f64, @floatFromInt(self.payload_bytes)) / (1024.0 * 1024.0);
        const origin = if (self.mode == .created) "created" else "attached";
        var pages_buf: [48]u8 = undefined;
        const pages: []const u8 = if (!self.pages.known)
            "page size unknown"
        else if (builtin.os.tag == .windows)
            (if (self.pages.large_view) "large pages" else "4 KB pages")
        else if (self.pages.huge_bytes >= self.map_bytes and self.map_bytes != 0)
            "2 MB pages"
        else if (self.pages.huge_bytes == 0)
            "4 KB pages"
        else
            std.fmt.bufPrint(&pages_buf, "2 MB pages {d}%", .{self.pages.huge_bytes * 100 / @max(self.map_bytes, 1)}) catch "partial 2 MB pages";
        return std.fmt.bufPrint(buf, "shared ({s}, {d:.1} MB, {s}, key {x:0>16})", .{ origin, mb, pages, self.key }) catch "shared";
    }
};

const field_count = slice_fields.len;

const Plan = struct {
    offsets: [field_count]usize = undefined,
    bytes: [field_count]usize = undefined,
    payload_len: usize = 0,
};

fn fieldBytes(net: *const Net, comptime name: []const u8) []const u8 {
    return std.mem.sliceAsBytes(@field(net, name));
}

fn makePlan(net: *const Net) Plan {
    var plan = Plan{};
    var cursor: usize = 0;
    inline for (slice_fields, 0..) |name, i| {
        const len = fieldBytes(net, name).len;
        cursor = std.mem.alignForward(usize, cursor, FIELD_ALIGN);
        plan.offsets[i] = cursor;
        plan.bytes[i] = len;
        cursor += len;
    }
    plan.payload_len = cursor;
    return plan;
}

/// Content key: layout descriptor + target identity + every shared byte.
pub fn contentKey(net: *const Net) u64 {
    const plan = makePlan(net);
    return keyFor(net, &plan);
}

fn keyFor(net: *const Net, plan: *const Plan) u64 {
    var h = std.hash.XxHash3.init(0x7a71_5eed_0000_0000 | @as(u64, LAYOUT_VERSION));
    const Desc = extern struct {
        layout: u32,
        blob_format: u32,
        ptr_bytes: u32,
        little_endian: u32,
        field_count: u32,
        _pad: u32 = 0,
        payload_len: u64,
    };
    const desc = Desc{
        .layout = LAYOUT_VERSION,
        .blob_format = shared_blob.FORMAT_VERSION,
        .ptr_bytes = @sizeOf(usize),
        .little_endian = @intFromBool(builtin.cpu.arch.endian() == .little),
        .field_count = field_count,
        .payload_len = plan.payload_len,
    };
    h.update(std.mem.asBytes(&desc));
    h.update(@tagName(builtin.cpu.arch));
    h.update(builtin.cpu.model.name);
    h.update(std.mem.asBytes(&builtin.cpu.features.ints));
    inline for (slice_fields, 0..) |name, i| {
        const Elem = std.meta.Elem(@FieldType(Net, name));
        const meta = [3]u64{ plan.offsets[i], plan.bytes[i], @sizeOf(Elem) };
        h.update(name);
        h.update(std.mem.asBytes(&meta));
    }
    inline for (slice_fields) |name| h.update(fieldBytes(net, name));
    return h.final();
}

const Ctx = struct {
    net: *const Net,
    plan: *const Plan,

    fn fill(ctx_ptr: *const anyopaque, dst: []u8) void {
        const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
        inline for (slice_fields, 0..) |name, i| {
            const src = fieldBytes(ctx.net, name);
            @memcpy(dst[ctx.plan.offsets[i]..][0..src.len], src);
        }
    }

    /// Byte-for-byte: every array the search will read through the blob must
    /// equal the private copy built from the file by this very process.
    fn verify(ctx_ptr: *const anyopaque, src: []const u8) bool {
        const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
        if (src.len != ctx.plan.payload_len) return false;
        inline for (slice_fields, 0..) |name, i| {
            const mine = fieldBytes(ctx.net, name);
            if (!std.mem.eql(u8, src[ctx.plan.offsets[i]..][0..mine.len], mine)) return false;
        }
        return true;
    }
};

/// Move `net`'s weights into the machine-wide blob for its content, or leave
/// them private. Never fails: the returned status says which happened (and
/// why not). On success the net's slices point into a read-only mapping and
/// `Net.destroy` releases the blob instead of freeing them.
pub fn share(net: *Net, allocator: std.mem.Allocator, config: shared_blob.Config) Status {
    std.debug.assert(net.shared_blob == null);
    const plan = makePlan(net);
    if (plan.payload_len == 0) return .{ .reason = "no weights" };
    const key = keyFor(net, &plan);
    const handle = allocator.create(shared_blob.Blob) catch return .{ .reason = "OutOfMemory", .key = key };
    const ctx = Ctx{ .net = net, .plan = &plan };
    handle.* = shared_blob.acquire(config, key, plan.payload_len, .{ .ctx = &ctx, .fill = Ctx.fill, .verify = Ctx.verify }) catch |err| {
        allocator.destroy(handle);
        return .{ .reason = @errorName(err), .key = key, .payload_bytes = plan.payload_len };
    };
    // Verified equal: drop the private arrays and point every field at its
    // view. The mapping is PROT_READ; Net's slice types stay mutable only by
    // declaration (nothing writes weights after load).
    net.freeWeightSlices(allocator);
    const payload: []u8 = @constCast(handle.payload);
    inline for (slice_fields, 0..) |name, i| {
        const Elem = std.meta.Elem(@FieldType(Net, name));
        if (plan.bytes[i] == 0) {
            @field(net, name) = &.{};
        } else {
            const bytes: []align(FIELD_ALIGN) u8 = @alignCast(payload[plan.offsets[i]..][0..plan.bytes[i]]);
            @field(net, name) = std.mem.bytesAsSlice(Elem, bytes);
        }
    }
    inline for (@typeInfo(Net.WeightMethods).@"struct".fields) |f| @field(net.weight_methods, f.name) = .shared;
    net.shared_blob = handle;
    return .{
        .mode = if (handle.origin == .created) .created else .attached,
        .reason = "",
        .payload_bytes = plan.payload_len,
        .map_bytes = handle.map_len,
        .pages = handle.pages,
        .key = key,
    };
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

fn testConfig(buf: []u8, tag: []const u8) shared_blob.Config {
    return .{ .namespace = shared_blob.test_support.namespace(buf, tag) };
}

fn removeRegistry(config: shared_blob.Config) void {
    shared_blob.test_support.removeRegistry(config.namespace);
}

test "net_share: every Net slice field is a shared weight array" {
    // Adding a slice field to Net shares it automatically; this pins the list
    // so the addition is a conscious one (it must be read-only after load).
    const expected = [_][]const u8{
        "feature_weights", "feature_bias",    "output_weights", "output_biases",
        "psqtw",           "psqtb",           "threat_w8",      "pawn_w8",
        "l1_weights",      "l1_byte_weights", "l1_blocked",     "l1_fused",
        "l1_res_w",        "l1_bias",         "l2_weights",     "l2_weights_t",
        "l2_bias",         "l3_weights",      "l3_bias",
    };
    try testing.expectEqual(expected.len, slice_fields.len);
    for (expected, slice_fields) |e, f| try testing.expectEqualStrings(e, f);
}

test "net_share: shared default net evaluates exactly like a private one" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const fen = @import("../core/fen.zig");
    const allocator = testing.allocator;
    var cfg_buf: [64]u8 = undefined;
    const cfg = testConfig(&cfg_buf, "eval");
    defer removeRegistry(cfg);

    const private = try nnue768.loadDefault(allocator);
    defer private.destroy(allocator);
    const a = try nnue768.loadDefault(allocator);
    defer a.destroy(allocator);
    const b = try nnue768.loadDefault(allocator);
    defer b.destroy(allocator);
    const key = contentKey(private);
    const sa = share(a, allocator, cfg);
    const sb = share(b, allocator, cfg);
    try testing.expectEqual(Mode.created, sa.mode);
    try testing.expectEqual(Mode.attached, sb.mode);
    try testing.expectEqual(key, sa.key);
    try testing.expectEqual(key, sb.key);
    try testing.expect(a.shared_blob != null and b.shared_blob != null);
    try testing.expect(private.shared_blob == null);
    try testing.expectEqual(hugealloc_shared, a.weight_methods.threat_w8);
    inline for (slice_fields) |name| {
        try testing.expectEqualSlices(u8, fieldBytes(private, name), fieldBytes(a, name));
        try testing.expectEqualSlices(u8, fieldBytes(private, name), fieldBytes(b, name));
    }
    if (builtin.os.tag == .linux) {
        // Same physical object: identical (dev, inode) behind both mappings.
        var st_a: std.os.linux.Stat = undefined;
        var st_b: std.os.linux.Stat = undefined;
        try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(std.os.linux.fstat(a.shared_blob.?.os.memfd, &st_a)));
        try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.E.init(std.os.linux.fstat(b.shared_blob.?.os.memfd, &st_b)));
        try testing.expectEqual(st_a.ino, st_b.ino);
    }
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 8",
        "8/5k2/3p4/1p1Pp2p/pP2Pp1P/P4P1K/8/8 b - - 99 50",
        "4k3/PPPPPPPP/8/8/8/8/pppppppp/4K3 w - - 0 1",
    };
    for (fens) |f| {
        const pos = try fen.parse(f);
        const want = nnue768.evaluate(private, &pos, 44);
        try testing.expectEqual(want, nnue768.evaluate(a, &pos, 44));
        try testing.expectEqual(want, nnue768.evaluate(b, &pos, 44));
    }
}

const hugealloc_shared = @import("../util/hugealloc.zig").Method.shared;

test "net_share: different nets get different keys and never share" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var cfg_buf: [64]u8 = undefined;
    const cfg = testConfig(&cfg_buf, "nets");
    defer removeRegistry(cfg);

    // A second net: the embedded one with one threat weight changed.
    const bytes = try allocator.dupe(u8, nnue768.default_net_bytes);
    defer allocator.free(bytes);
    const a = try nnue768.loadFromBytes(allocator, nnue768.default_net_bytes);
    defer a.destroy(allocator);
    const probe = try nnue768.loadFromBytes(allocator, nnue768.default_net_bytes);
    defer probe.destroy(allocator);
    // The HalfKA rows are stored untransformed right after the header: find
    // the first 64 bytes of them in the file and bump the first weight.
    const fw_off = std.mem.indexOf(u8, bytes, std.mem.sliceAsBytes(probe.feature_weights[0..32])) orelse return error.SkipZigTest;
    bytes[fw_off] +%= 1;
    const b = try nnue768.loadFromBytes(allocator, bytes);
    defer b.destroy(allocator);
    try testing.expect(contentKey(a) != contentKey(b));
    const sa = share(a, allocator, cfg);
    const sb = share(b, allocator, cfg);
    try testing.expectEqual(Mode.created, sa.mode);
    try testing.expectEqual(Mode.created, sb.mode);
    try testing.expect(sa.key != sb.key);
    try testing.expect(!std.mem.eql(i16, a.feature_weights[0..32], b.feature_weights[0..32]));
    try testing.expectEqualSlices(i16, probe.feature_weights[32..64], b.feature_weights[32..64]);
}

test "net_share: a failed acquire keeps the private weights intact" {
    const allocator = testing.allocator;
    const net = try nnue768.loadDefault(allocator);
    defer net.destroy(allocator);
    const before = net.threat_w8.ptr;
    // An invalid namespace fails before any OS call on every platform.
    const st = share(net, allocator, .{ .namespace = "bad/ns" });
    try testing.expectEqual(Mode.private, st.mode);
    try testing.expectEqualStrings("InvalidRequest", st.reason);
    try testing.expect(net.shared_blob == null);
    try testing.expectEqual(before, net.threat_w8.ptr);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("private (InvalidRequest)", st.describe(&buf));
}

test "net_share: status lines" {
    var buf: [160]u8 = undefined;
    const disabled = Status{};
    try testing.expectEqualStrings("private (disabled)", disabled.describe(&buf));
    const shared = Status{ .mode = .attached, .payload_bytes = 96 * 1024 * 1024, .map_bytes = 98 * 1024 * 1024, .pages = .{ .known = true, .huge_bytes = 98 * 1024 * 1024 }, .key = 0xab };
    const line = shared.describe(&buf);
    try testing.expect(std.mem.startsWith(u8, line, "shared (attached, 96.0 MB, "));
    try testing.expect(std.mem.endsWith(u8, line, "key 00000000000000ab)"));
}
