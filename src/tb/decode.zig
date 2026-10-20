//! Block location and symbol decoding (docs/SYZYGY_FORMAT.md §6). Works over
//! any storage backend through `io.view`; every buffer is a fixed-size local,
//! so the probe path allocates nothing.
const std = @import("std");
const format = @import("format.zig");
const ProbeError = @import("types.zig").ProbeError;

/// Block-length entries fetched per positioned read during the §6.3 walk.
const length_window = 64;

const LengthWindow = struct {
    lo: u64 = 0,
    count: u64 = 0,
    bytes: []const u8 = &.{},
    buf: [2 * length_window]u8 = undefined,

    /// Stored length of block `b` (values in the block minus one).
    fn get(self: *LengthWindow, io: anytype, file: u32, c: *const format.Compressed, b: u64) ProbeError!u64 {
        if (b >= c.length_entries) return error.CorruptTable;
        if (b < self.lo or b >= self.lo + self.count) {
            const lo = b -| length_window / 2;
            const hi = @min(lo + length_window, c.length_entries);
            self.bytes = try io.view(file, c.lengths_off + 2 * lo, @intCast(2 * (hi - lo)), &self.buf);
            self.lo = lo;
            self.count = hi - lo;
        }
        const at: usize = @intCast(2 * (b - self.lo));
        return std.mem.readInt(u16, self.bytes[at..][0..2], .little);
    }
};

/// Stored 12-bit value at `index` of a compressed subtable (§6.3-§6.4).
pub fn valueAt(io: anytype, file: u32, c: *const format.Compressed, index: u64) ProbeError!u16 {
    const k = index >> @intCast(c.index_bits);
    if (k >= c.sparse_count) return error.CorruptTable;
    var sparse_buf: [6]u8 = undefined;
    const entry = try io.view(file, c.sparse_off + 6 * k, 6, &sparse_buf);
    var block: u64 = std.mem.readInt(u32, entry[0..4], .little);
    const offset: i64 = std.mem.readInt(u16, entry[4..6], .little);
    const span_mask = (@as(u64, 1) << @intCast(c.index_bits)) - 1;
    const half: i64 = @as(i64, 1) << @intCast(c.index_bits - 1);
    var r: i64 = offset + @as(i64, @intCast(index & span_mask)) - half;
    var lengths = LengthWindow{};
    while (r < 0) {
        if (block == 0) return error.CorruptTable;
        block -= 1;
        r += @as(i64, @intCast(try lengths.get(io, file, c, block))) + 1;
    }
    while (true) {
        const len: i64 = @intCast(try lengths.get(io, file, c, block));
        if (r <= len) break;
        r -= len + 1;
        block += 1;
    }
    if (block >= c.real_blocks) return error.CorruptTable;
    var block_buf: [(1 << format.max_block_bits) + format.block_slack]u8 = undefined;
    const block_size = @as(usize, 1) << @intCast(c.block_bits);
    const data = try io.view(file, c.data_off + (block << @intCast(c.block_bits)), block_size + format.block_slack, &block_buf);
    return decodeInBlock(c, data, @intCast(r));
}

/// Value number `r` of a block whose bytes (plus 8 bytes of slack) are `data`.
pub fn decodeInBlock(c: *const format.Compressed, data: []const u8, r_in: u32) ProbeError!u16 {
    var r = r_in;
    var code: u64 = std.mem.readInt(u64, data[0..8], .big);
    var ptr: usize = 8;
    var pending: u32 = 0;
    var sym: usize = undefined;
    while (true) {
        var len: usize = c.min_len;
        while (code < c.base[len]) len += 1;
        sym = c.first[len] + @as(usize, @intCast((code - c.base[len]) >> @intCast(64 - len)));
        if (sym >= c.num_syms) return error.CorruptTable;
        const values = @as(u32, c.sym_len[sym]) + 1;
        if (r < values) break;
        r -= values;
        code <<= @intCast(len);
        pending += @intCast(len);
        if (pending >= 32) {
            if (ptr + 4 > data.len) return error.CorruptTable;
            pending -= 32;
            code |= @as(u64, std.mem.readInt(u32, data[ptr..][0..4], .big)) << @intCast(pending);
            ptr += 4;
        }
    }
    while (true) {
        const kids = format.symbolChildren(c.symbols, sym);
        if (kids[1] == 0xFFF) return kids[0];
        const left_values = @as(u32, c.sym_len[kids[0]]) + 1;
        if (r < left_values) {
            sym = kids[0];
        } else {
            r -= left_values;
            sym = kids[1];
        }
    }
}

test "decoder walks a hand-built canonical code" {
    // Leaves 0 -> 7 and 1 -> 9, pair symbol 2 = (0, 1) -> 7, 9. Code lengths:
    // symbol 2 has length 1 ("1"), symbols 0 and 1 length 2 ("00", "01").
    // Canonical: first[2] = 0, first[1] = 2; base[1] = (0 + 2 - 0) / 2 = 1.
    const symbols = [_]u8{
        7, 0xF0, 0xFF, // leaf 7
        9, 0xF0, 0xFF, // leaf 9
        0, 0x10, 0x00, // pair (0, 1)
    };
    const sym_len = [_]u8{ 0, 0, 1 };
    var c: format.Compressed = undefined;
    c.min_len = 1;
    c.max_len = 2;
    c.num_syms = 3;
    c.first = .{0} ** 33;
    c.base = .{0} ** 33;
    c.first[1] = 2;
    c.first[2] = 0;
    c.base[1] = @as(u64, 1) << 63;
    c.symbols = &symbols;
    c.sym_len = &sym_len;
    // Bits 1 | 01 | 00 -> values 7 9 | 9 | 7.
    var data = [_]u8{0} ** 16;
    data[0] = 0b1010_0000;
    try std.testing.expectEqual(@as(u16, 7), try decodeInBlock(&c, &data, 0));
    try std.testing.expectEqual(@as(u16, 9), try decodeInBlock(&c, &data, 1));
    try std.testing.expectEqual(@as(u16, 9), try decodeInBlock(&c, &data, 2));
    try std.testing.expectEqual(@as(u16, 7), try decodeInBlock(&c, &data, 3));
}
