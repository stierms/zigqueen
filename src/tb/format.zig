//! Syzygy file names, header parsing and load-time validation
//! (docs/SYZYGY_FORMAT.md §3-§4, §4.6). Parsing runs off the search path, when
//! a snapshot is built; the result is immutable and lives in the snapshot arena.
const std = @import("std");
const types = @import("types.zig");
const index = @import("index.zig");

const Material = types.Material;
const MaterialKey = types.MaterialKey;
const Metric = types.Metric;
const Descriptor = index.Descriptor;

pub const wdl_magic: u32 = 0x5D23E871;
pub const dtz_magic: u32 = 0xA50C66D7;

/// `Truncated`: the header continues past the bytes supplied; the caller reads
/// more of the file and parses again.
pub const ParseError = error{ CorruptTable, Truncated, OutOfMemory };

/// Largest symbol count a subtable may declare (§4.6).
pub const max_symbols = 4095;
/// Largest block: 2^10 bytes (§4.6). Bounds the positioned-read buffer.
pub const max_block_bits = 10;
/// Bytes a decoder may read past a block (§6.4).
pub const block_slack = 8;

// ---------------------------------------------------------------------------
// File names (§3.2)

const letters = "KQRBNP";

fn pieceTypeOfLetter(ch: u8) ?usize {
    // Our PieceType numbering: pawn 0, knight 1, bishop 2, rook 3, queen 4.
    return switch (ch) {
        'Q' => 4,
        'R' => 3,
        'B' => 2,
        'N' => 1,
        'P' => 0,
        else => null,
    };
}

pub const FileName = struct {
    /// First side is white in the name orientation.
    material: Material,
    metric: Metric,
};

/// Parse `<name>.rtbw` / `<name>.rtbz`. Null for anything that is not a
/// canonical regular-chess table name (§3.2).
pub fn parseFileName(name: []const u8) ?FileName {
    if (name.len <= 5) return null;
    const ext = name[name.len - 5 ..];
    const metric: Metric = if (std.mem.eql(u8, ext, ".rtbw")) .wdl else if (std.mem.eql(u8, ext, ".rtbz")) .dtz else return null;
    const stem = name[0 .. name.len - 5];
    const v = std.mem.indexOfScalar(u8, stem, 'v') orelse return null;
    if (std.mem.indexOfScalarPos(u8, stem, v + 1, 'v') != null) return null;
    const sides = [2][]const u8{ stem[0..v], stem[v + 1 ..] };
    var m = Material{};
    for (sides, 0..) |side, c| {
        if (side.len == 0 or side[0] != 'K') return null;
        var last: usize = 0;
        for (side[1..]) |ch| {
            const order = std.mem.indexOfScalar(u8, letters, ch) orelse return null;
            if (order == 0 or order < last) return null;
            last = order;
            m.counts[c][pieceTypeOfLetter(ch).?] += 1;
        }
    }
    if (m.pieces() < 3 or m.pieces() > index.max_pieces) return null;
    // Canonical orientation: more pieces first; else the stronger list first.
    const a = sides[0][1..];
    const b = sides[1][1..];
    if (a.len < b.len) return null;
    if (a.len == b.len) {
        for (a, b) |x, y| {
            const ix = std.mem.indexOfScalar(u8, letters, x).?;
            const iy = std.mem.indexOfScalar(u8, letters, y).?;
            if (ix < iy) break;
            if (ix > iy) return null;
        }
    }
    return .{ .material = m, .metric = metric };
}

// ---------------------------------------------------------------------------
// Parsed tables

pub const Compressed = struct {
    block_bits: u8,
    index_bits: u8,
    real_blocks: u32,
    /// real_blocks + padding entries of the block-length table.
    length_entries: u32,
    min_len: u8,
    max_len: u8,
    num_syms: u16,
    /// first[L]: symbol number of the first code of length L (§4.3).
    first: [33]u16,
    /// Left-justified canonical bases B[L] (§6.2).
    base: [33]u64,
    /// 3 bytes per symbol (§6.1), in the snapshot arena.
    symbols: []const u8,
    /// Expansion length minus one per symbol.
    sym_len: []const u8,
    sparse_off: u64,
    sparse_count: u64,
    lengths_off: u64,
    data_off: u64,
};

pub const Pairs = union(enum) {
    /// Single-valued subtable; the raw header byte 1 (§4.3).
    single: u8,
    compressed: Compressed,
};

pub const DtzFlag = struct {
    pub const stored_side: u8 = 0x01;
    pub const mapped: u8 = 0x02;
    pub const win_plies: u8 = 0x04;
    pub const loss_plies: u8 = 0x08;
    pub const wide: u8 = 0x10;
    pub const single: u8 = 0x80;
};

pub const Subtable = struct {
    desc: Descriptor,
    pairs: Pairs,
    /// Header flag byte (§4.3); only meaningful for DTZ.
    flags: u8 = 0,
    /// DTZ value maps 0: win, 1: loss, 2: cursed win, 3: blessed loss (§4.4).
    maps: [4][]const u16 = .{ &.{}, &.{}, &.{}, &.{} },
};

pub const PieceTable = struct {
    sides: [2]Subtable,
};

pub const PawnTable = struct {
    /// [leading-pawn file a..d][stored side].
    files: [4][2]Subtable,
    /// Colour of the leading pawns in the file frame.
    lead_colour: u1,
};

pub const Body = union(enum) {
    piece: PieceTable,
    pawn: PawnTable,
};

pub const Table = struct {
    metric: Metric,
    pieces: u8,
    symmetric: bool,
    /// Stored sides per subtable: 2 for a non-symmetric WDL file, else 1.
    sides: u8,
    /// Material of the frame's white (header-authoritative, §3.4).
    frame_key: MaterialKey,
    file_size: u64,
    /// Bytes of header parsed (magic through maps).
    header_len: u64,
    body: Body,

    pub fn subtable(self: *const Table, t: u2, s: u1) *const Subtable {
        const side: usize = if (self.sides == 2) s else 0;
        return switch (self.body) {
            .piece => |*p| &p.sides[side],
            .pawn => |*p| &p.files[t][side],
        };
    }
};

// ---------------------------------------------------------------------------
// Parsing

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    file_size: u64,

    fn need(self: *const Cursor, n: usize) ParseError!void {
        if (self.pos + n <= self.bytes.len) return;
        return if (self.pos + n > self.file_size) error.CorruptTable else error.Truncated;
    }
    fn byte(self: *Cursor) ParseError!u8 {
        try self.need(1);
        self.pos += 1;
        return self.bytes[self.pos - 1];
    }
    fn u16le(self: *Cursor) ParseError!u16 {
        try self.need(2);
        self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos - 2 ..][0..2], .little);
    }
    fn u32le(self: *Cursor) ParseError!u32 {
        try self.need(4);
        self.pos += 4;
        return std.mem.readInt(u32, self.bytes[self.pos - 4 ..][0..4], .little);
    }
    fn take(self: *Cursor, n: usize) ParseError![]const u8 {
        try self.need(n);
        self.pos += n;
        return self.bytes[self.pos - n .. self.pos];
    }
    fn alignTo(self: *Cursor, a: usize) void {
        self.pos = std.mem.alignForward(usize, self.pos, a);
    }
};

fn validCode(c: u8) bool {
    return (c >= 1 and c <= 6) or (c >= 9 and c <= 14);
}

fn countOf(codes: []const u8, c: u8) usize {
    var n: usize = 0;
    for (codes) |x| n += @intFromBool(x == c);
    return n;
}

fn runLength(codes: []const u8, start: usize) u8 {
    var i = start;
    while (i < codes.len and codes[i] == codes[start]) i += 1;
    return @intCast(i - start);
}

fn checkedMul(a: u64, b: u64) ParseError!u64 {
    return std.math.mul(u64, a, b) catch error.CorruptTable;
}

fn buildDescriptor(raw: []const u8, side: u1, order_byte: u8, order2_byte: ?u8, t: u2, pawnful: bool, both_pawns: bool) ParseError!Descriptor {
    var d = Descriptor{};
    const n: u8 = @intCast(raw.len);
    d.n = n;
    for (raw, 0..) |b, i| {
        const c = if (side == 0) b & 0xF else b >> 4;
        if (!validCode(c)) return error.CorruptTable;
        d.codes[i] = c;
    }
    const codes = d.codes[0..n];
    // Equal codes are consecutive.
    for (codes, 0..) |c, i| {
        if (i > 0 and codes[i - 1] != c and std.mem.indexOfScalar(u8, codes[0..i], c) != null) return error.CorruptTable;
    }
    if (countOf(codes, 6) != 1 or countOf(codes, 14) != 1) return error.CorruptTable;
    if (pawnful) {
        if (codes[0] & 7 != 1) return error.CorruptTable;
        const k = runLength(codes, 0);
        if (k > index.max_lead) return error.CorruptTable;
        d.lead = .pawn;
        d.lead_len = k;
        const other = codes[0] ^ 8;
        if (both_pawns) {
            if (k >= n or codes[k] != other) return error.CorruptTable;
            d.second_len = runLength(codes, k);
        } else if (countOf(codes, other) != 0) return error.CorruptTable;
    } else {
        var unique: usize = 0;
        for (codes) |c| unique += @intFromBool(countOf(codes, c) == 1);
        d.lead = if (unique == 2) .kk else .three;
        d.lead_len = if (unique == 2) 2 else 3;
        if (d.lead_len > n) return error.CorruptTable;
        for (codes[0..d.lead_len]) |c| {
            if (countOf(codes, c) != 1) return error.CorruptTable;
            if (d.lead == .kk and c & 7 != 6) return error.CorruptTable;
        }
        if (countOf(codes, 1) + countOf(codes, 9) != 0) return error.CorruptTable;
    }
    // Groups in descriptor order and their sizes.
    var sizes: [index.max_pieces]u64 = undefined;
    d.group_start[0] = 0;
    d.group_len[0] = d.lead_len;
    sizes[0] = switch (d.lead) {
        .kk => index.kk_size,
        .three => index.three_size,
        .pawn => index.lead_size[d.lead_len][t],
    };
    var g: u8 = 1;
    var pos: u8 = d.lead_len;
    if (d.second_len != 0) {
        d.group_start[1] = pos;
        d.group_len[1] = d.second_len;
        sizes[1] = index.binomial[d.second_len][48 - d.lead_len];
        pos += d.second_len;
        g = 2;
    }
    while (pos < n) {
        const len = runLength(codes, pos);
        d.group_start[g] = pos;
        d.group_len[g] = len;
        sizes[g] = index.binomial[len][64 - pos];
        pos += len;
        g += 1;
    }
    d.group_count = g;
    // Digit order (§5.8).
    const o = if (side == 0) order_byte & 0xF else order_byte >> 4;
    const o2: u8 = if (order2_byte) |b| (if (side == 0) b & 0xF else b >> 4) else 0xF;
    if (o >= g) return error.CorruptTable;
    if (d.second_len != 0) {
        if (o2 >= g or o2 == o) return error.CorruptTable;
    } else if (o2 != 0xF) return error.CorruptTable;
    const first_other: u8 = if (d.second_len != 0) 2 else 1;
    var next_other = first_other;
    var f: u64 = 1;
    for (0..g) |p| {
        const group: u8 = if (p == o) 0 else if (d.second_len != 0 and p == o2) 1 else blk: {
            if (next_other >= g) return error.CorruptTable;
            next_other += 1;
            break :blk next_other - 1;
        };
        d.factor[group] = f;
        f = try checkedMul(f, sizes[group]);
    }
    if (next_other != g) return error.CorruptTable;
    d.size = f;
    return d;
}

fn materialOfCodes(codes: []const u8) Material {
    var m = Material{};
    for (codes) |c| {
        const kind = c & 7;
        if (kind == 6) continue;
        m.counts[c >> 3][kind - 1] += 1;
    }
    return m;
}

fn parsePairs(cur: *Cursor, metric: Metric, size: u64, arena: std.mem.Allocator, flags_out: *u8) ParseError!Pairs {
    const flags = try cur.byte();
    flags_out.* = flags;
    if (metric == .dtz and flags & 0x60 != 0) return error.CorruptTable;
    if (flags & DtzFlag.single != 0) {
        const v = try cur.byte();
        if (metric == .wdl and v > 4) return error.CorruptTable;
        if (metric == .dtz and flags & DtzFlag.mapped != 0) return error.CorruptTable;
        return .{ .single = v };
    }
    var c: Compressed = undefined;
    c.block_bits = try cur.byte();
    c.index_bits = try cur.byte();
    const pad = try cur.byte();
    c.real_blocks = try cur.u32le();
    c.max_len = try cur.byte();
    c.min_len = try cur.byte();
    if (c.block_bits < 1 or c.block_bits > max_block_bits) return error.CorruptTable;
    if (c.index_bits < 1 or c.index_bits > 40) return error.CorruptTable;
    if (c.min_len < 1 or c.min_len > c.max_len or c.max_len > 32) return error.CorruptTable;
    c.length_entries = std.math.add(u32, c.real_blocks, pad) catch return error.CorruptTable;
    c.first = .{0} ** 33;
    c.base = .{0} ** 33;
    var len: usize = c.min_len;
    while (len <= c.max_len) : (len += 1) c.first[len] = try cur.u16le();
    c.num_syms = try cur.u16le();
    if (c.num_syms == 0 or c.num_syms > max_symbols) return error.CorruptTable;
    const raw_syms = try cur.take(3 * @as(usize, c.num_syms));
    if (c.num_syms & 1 != 0) _ = try cur.take(1);
    // Canonical bases (§6.2), then left-justify.
    var base: [33]u64 = .{0} ** 33;
    len = c.max_len;
    while (len > c.min_len) {
        len -= 1;
        if (c.first[len] < c.first[len + 1]) return error.CorruptTable;
        base[len] = (base[len + 1] + c.first[len] - c.first[len + 1]) / 2;
        if (2 * base[len] < base[len + 1]) return error.CorruptTable;
    }
    len = c.min_len;
    while (len <= c.max_len) : (len += 1) {
        if (base[len] >> @intCast(len) != 0) return error.CorruptTable;
        c.base[len] = if (len == 0) 0 else base[len] << @intCast(64 - len);
    }
    c.symbols = try arena.dupe(u8, raw_syms);
    c.sym_len = try symbolLengths(arena, c.symbols, c.num_syms);
    c.sparse_count = std.math.divCeil(u64, size, @as(u64, 1) << @intCast(c.index_bits)) catch unreachable;
    if (c.sparse_count > std.math.maxInt(u32)) return error.CorruptTable;
    return .{ .compressed = c };
}

pub inline fn symbolChildren(symbols: []const u8, s: usize) [2]u16 {
    const w = symbols[3 * s ..][0..3];
    return .{ w[0] | (@as(u16, w[1] & 0x0F) << 8), (w[1] >> 4) | (@as(u16, w[2]) << 4) };
}

/// Expansion length of every symbol (§6.1), computed with an explicit stack;
/// rejects out-of-range children, cycles and lengths over 256.
fn symbolLengths(arena: std.mem.Allocator, symbols: []const u8, num_syms: u16) ParseError![]const u8 {
    var state = [_]u8{0} ** (max_symbols + 1);
    var lens = [_]u16{0} ** (max_symbols + 1);
    var stack: [max_symbols + 1]u16 = undefined;
    for (0..num_syms) |root| {
        if (state[root] == 2) continue;
        var sp: usize = 1;
        stack[0] = @intCast(root);
        state[root] = 1;
        while (sp > 0) {
            const x = stack[sp - 1];
            const kids = symbolChildren(symbols, x);
            if (kids[1] == 0xFFF) {
                lens[x] = 1;
            } else {
                const l, const r = kids;
                if (l >= num_syms or r >= num_syms) return error.CorruptTable;
                var pending: ?u16 = null;
                if (state[l] != 2) pending = l else if (state[r] != 2) pending = r;
                if (pending) |child| {
                    if (state[child] == 1) return error.CorruptTable;
                    state[child] = 1;
                    stack[sp] = child;
                    sp += 1;
                    continue;
                }
                lens[x] = lens[l] + lens[r];
                if (lens[x] > 256) return error.CorruptTable;
            }
            state[x] = 2;
            sp -= 1;
        }
    }
    const out = try arena.alloc(u8, num_syms);
    for (out, 0..) |*o, i| o.* = @intCast(lens[i] - 1);
    return out;
}

fn parseMaps(cur: *Cursor, arena: std.mem.Allocator, sub: *Subtable) ParseError!void {
    const wide = sub.flags & DtzFlag.wide != 0;
    if (wide) cur.alignTo(2);
    for (&sub.maps) |*map| {
        const count: usize = if (wide) try cur.u16le() else try cur.byte();
        const out = try arena.alloc(u16, count);
        for (out) |*v| v.* = if (wide) try cur.u16le() else try cur.byte();
        map.* = out;
    }
}

/// Parse and validate a whole header (§4, §4.6). `bytes` is a prefix of the
/// file; `error.Truncated` asks for a longer prefix. `name` is the material in
/// the file name's orientation.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8, file_size: u64, metric: Metric, name: Material) ParseError!Table {
    if (file_size % 64 != 16) return error.CorruptTable;
    var cur = Cursor{ .bytes = bytes, .file_size = file_size };
    const magic = try cur.u32le();
    if (magic != (if (metric == .wdl) wdl_magic else dtz_magic)) return error.CorruptTable;
    const flag = try cur.byte();
    const n = flag >> 4;
    const symmetric = flag & 1 == 0;
    const pawnful = flag & 2 != 0;
    if (flag & 0x0C != 0) return error.CorruptTable;
    if (n != name.pieces() or pawnful != name.hasPawns() or symmetric != name.symmetric()) return error.CorruptTable;
    if (n < 3 or n > index.max_pieces) return error.CorruptTable;
    const num_t: usize = if (pawnful) 4 else 1;
    const sides: u8 = if (metric == .wdl and !symmetric) 2 else 1;
    const both_pawns = name.bothHavePawns();

    var subs: [4][2]Subtable = undefined;
    for (0..num_t) |t| {
        const order = try cur.byte();
        const order2: ?u8 = if (both_pawns) try cur.byte() else null;
        const raw = try cur.take(n);
        for (0..sides) |s| {
            subs[t][s] = .{ .desc = try buildDescriptor(raw, @intCast(s), order, order2, @intCast(t), pawnful, both_pawns), .pairs = .{ .single = 0 } };
        }
    }
    cur.alignTo(2);

    // Frame material: every descriptor lists the same multiset (§4.6), which
    // must be the name's material or its mirror (§3.4, §10 item 7).
    const frame = materialOfCodes(subs[0][0].desc.codes[0..n]);
    const frame_key = frame.key();
    for (0..num_t) |t| for (0..sides) |s| {
        const d = &subs[t][s].desc;
        if (materialOfCodes(d.codes[0..n]).key() != frame_key) return error.CorruptTable;
        if (pawnful and d.codes[0] != subs[0][0].desc.codes[0]) return error.CorruptTable;
    };
    if (frame_key != name.key() and frame_key != types.mirrorKey(name.key())) return error.CorruptTable;

    for (0..num_t) |t| for (0..sides) |s| {
        const sub = &subs[t][s];
        sub.pairs = try parsePairs(&cur, metric, sub.desc.size, arena, &sub.flags);
    };
    if (metric == .dtz) {
        for (0..num_t) |t| {
            if (subs[t][0].flags & DtzFlag.mapped != 0) try parseMaps(&cur, arena, &subs[t][0]);
        }
        cur.alignTo(2);
    }
    const header_len: u64 = cur.pos;

    // Section offsets (§4.5).
    var off: u64 = header_len;
    for (0..num_t) |t| for (0..sides) |s| switch (subs[t][s].pairs) {
        .single => {},
        .compressed => |*c| {
            c.sparse_off = off;
            off += 6 * c.sparse_count;
        },
    };
    for (0..num_t) |t| for (0..sides) |s| switch (subs[t][s].pairs) {
        .single => {},
        .compressed => |*c| {
            c.lengths_off = off;
            off += 2 * @as(u64, c.length_entries);
        },
    };
    for (0..num_t) |t| for (0..sides) |s| switch (subs[t][s].pairs) {
        .single => {},
        .compressed => |*c| {
            off = std.mem.alignForward(u64, off, 64);
            c.data_off = off;
            off += @as(u64, c.real_blocks) << @intCast(c.block_bits);
        },
    };
    off = std.mem.alignForward(u64, off, 64);
    if (off + 16 != file_size) return error.CorruptTable;

    const body: Body = if (pawnful) blk: {
        var p: PawnTable = .{ .files = undefined, .lead_colour = @intCast(subs[0][0].desc.codes[0] >> 3) };
        for (0..4) |t| {
            p.files[t][0] = subs[t][0];
            p.files[t][1] = if (sides == 2) subs[t][1] else subs[t][0];
        }
        break :blk .{ .pawn = p };
    } else .{ .piece = .{ .sides = .{ subs[0][0], if (sides == 2) subs[0][1] else subs[0][0] } } };
    return .{
        .metric = metric,
        .pieces = n,
        .symmetric = symmetric,
        .sides = sides,
        .frame_key = frame_key,
        .file_size = file_size,
        .header_len = header_len,
        .body = body,
    };
}

test "file names parse canonically" {
    const krpvkr = parseFileName("KRPvKR.rtbw").?;
    try std.testing.expectEqual(Metric.wdl, krpvkr.metric);
    try std.testing.expectEqual(@as(u8, 1), krpvkr.material.counts[0][3]);
    try std.testing.expectEqual(@as(u8, 1), krpvkr.material.counts[0][0]);
    try std.testing.expectEqual(@as(u8, 1), krpvkr.material.counts[1][3]);
    try std.testing.expectEqual(@as(u8, 5), krpvkr.material.pieces());
    try std.testing.expect(parseFileName("KRvKRP.rtbw") == null); // fewer pieces first
    try std.testing.expect(parseFileName("KNvKB.rtbz") == null); // weaker first
    try std.testing.expect(parseFileName("KBvKN.rtbz") != null);
    try std.testing.expect(parseFileName("KPRvK.rtbw") == null); // letter order
    try std.testing.expect(parseFileName("KQvKQ.rtbz").?.material.symmetric());
    try std.testing.expect(parseFileName("KQvKQ.rtbm") == null);
    try std.testing.expect(parseFileName("KvK.rtbw") == null);
    try std.testing.expect(parseFileName("KQvK.rtbw") != null);
    try std.testing.expect(parseFileName(".rtbw") == null);
}
