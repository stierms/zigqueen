//! Runtime inference for a bullet-trained pure NNUE with the standard Chess768
//! feature set: `(768 -> HIDDEN) x2 -> 1`, square-clipped-ReLU (screlu).
//!
//! This is a from-scratch (full-refresh) evaluator: it recomputes both
//! perspective accumulators from the board each call. The math mirrors bullet's
//! documented quantised inference (numpy-validated) so a net trained by
//! `examples/zq768*.rs` evaluates identically here.
//!
//! HIDDEN is a runtime property read from the file header, so a single binary
//! loads 256-, 512- or any-width nets up to MAX_HIDDEN. Weights are stored as
//! flat slices ([feature*hidden + h] row-major) allocated per net.
//!
//! Model file formats (little-endian), produced by a converter from bullet's
//! `quantised.bin`:
//!   `ZQB1` (single output bucket):
//!     magic "ZQB1"; u32 inputs(=768); u32 hidden; i32 scale; i32 qa; i32 qb;
//!     i16 feature_weights[inputs*hidden] (row-major [feature][hidden]);
//!     i16 feature_bias[hidden]; i16 output_weights[2*hidden]; i16 output_bias.
//!   `ZQB2` (N material-count output buckets, bullet `MaterialCount<N>`):
//!     magic "ZQB2"; u32 inputs(=768); u32 hidden; u32 buckets; i32 scale; i32 qa; i32 qb;
//!     i16 feature_weights[inputs*hidden]; i16 feature_bias[hidden];
//!     i16 output_weights[buckets*2*hidden] (bucket-major, contiguous per bucket);
//!     i16 output_biases[buckets].
//!   The output bucket is `(piece_count - 2) / ceil(32/buckets)` (matches bullet).
//!   ZQB1 is the buckets=1 special case (bucket always 0).
//!   `ZQB3` (king-bucketed, horizontally-mirrored HalfKA, bullet `ChessBucketsMirrored`):
//!     magic "ZQB3"; u32 inputs(=768*king_buckets); u32 hidden; u32 buckets(material);
//!     u32 king_buckets; u32 mirror(0/1); i32 scale; i32 qa; i32 qb; u8 table[64];
//!     i16 feature_weights[inputs*hidden]; i16 feature_bias[hidden];
//!     i16 output_weights[buckets*2*hidden]; i16 output_biases[buckets].
//!   `table[king_square]` -> king bucket (expanded 64-entry, matches bullet's mirror
//!   expansion). Per perspective P with own-king raw square ksq:
//!     flip = mirror && (ksq&7)>3 ? 7 : 0 ;  bucket = table[ksq]
//!     feat = 768*bucket + ((own?0:384) + 64*piece_type + (relsq ^ flip))
//!   where relsq = sq (white perspective) or sq^56 (black). ZQB1/ZQB2 are the
//!   king_buckets=1, mirror=0, all-zero-table special case (feat reduces to Chess768).
//!   `ZQB4` (multi-layer "layerstack", bullet `4_multi_layer.rs`): narrow accumulator
//!   feeds crelu+pairwise_mul -> l1 -> screlu -> l2 -> screlu -> l3 -> scalar.
//!     magic "ZQB4"; u32 inputs(=768*king_buckets); u32 hidden; u32 buckets(=1);
//!     u32 king_buckets; u32 mirror(0/1); u32 l2_size; u32 l3_size; i32 scale; i32 qa;
//!     i32 qb; u8 table[64]; i16 l0w[inputs*hidden]; i16 l0b[hidden];
//!     i8 l1w[l2_size*hidden]; f32 l1b[l2_size]; f32 l2w[l3_size*l2_size];
//!     f32 l2b[l3_size]; f32 l3w[l3_size]; f32 l3b. l0w input-major, l1/l2/l3
//!     output-major [out][in]. Forward: crelu(x)=clamp(x,0,1); pairwise out[i]=
//!     in[i]*in[i+h/2]; screlu(x)=clamp(x,0,1)^2; eval(cp)=l3_out*scale.

const std = @import("std");
const builtin = @import("builtin");
const position = @import("../core/position.zig");
const bitboard = @import("../core/bitboard.zig");
const types = @import("../core/types.zig");
const piece = @import("../core/piece.zig");
const square = @import("../core/square.zig");
const move_mod = @import("../core/move.zig");
const make_unmake = @import("../movegen/make_unmake.zig");
const threats_mod = @import("threats.zig");
const fullthreats_mod = @import("fullthreats.zig");
const attacks = @import("../movegen/attacks.zig");
const hugealloc = @import("../util/hugealloc.zig");

/// Allocate a 64-byte-aligned weight block, 2MB-huge-page backed when the OS
/// grants it (multi-MB blocks like feature_weights/threat_w8 are random-access
/// per active feature row -- the same dTLB story as the TT). Records HOW the
/// block was allocated into `method` so `freeWeights` can mirror it.
fn allocWeights(
    comptime T: type,
    allocator: std.mem.Allocator,
    n: usize,
    method: *hugealloc.Method,
) std.mem.Allocator.Error![]align(64) T {
    const backed = try hugealloc.allocAligned(T, .@"64", allocator, n);
    method.* = backed.method;
    return backed.items;
}

fn freeWeights(comptime T: type, allocator: std.mem.Allocator, items: []align(64) T, method: hugealloc.Method) void {
    hugealloc.freeAligned(T, .@"64", allocator, .{ .items = items, .method = method });
}

pub const MAGIC = "ZQB1"; // single output bucket
pub const MAGIC2 = "ZQB2"; // N material-count output buckets
pub const MAGIC3 = "ZQB3"; // king-bucketed, mirrored HalfKA
pub const MAGIC4 = "ZQB4"; // multi-layer layerstack (narrow accumulator + l1/l2/l3)
pub const MAGIC5 = "ZQB5"; // HalfKA + lean threats + seeded PSQT material head
pub const MAGIC6 = "ZQB6"; // ZQB5 with the threat weight block stored i8 (halves threat row bytes)
pub const MAGIC7 = "ZQB7"; // ZQB6 with the PSQT head bucketed alongside the output buckets
pub const MAGIC8 = "ZQB8"; // threats stack (ZQB6 FT + PSQT head) + SFNNv5 layerstack readout
/// ZQB9: byte-identical body layout to ZQB8, but the threat block is the v6 FULL-threats
/// space (docs/V6_THREATS_SPEC.md r2): threat_inputs MUST be exactly 60,144
/// (fullthreats.NUM_FULLTHREAT_FEATURES) — any other value is rejected. Loads with
/// `full_threats = true`; evaluation full-refreshes via `evaluateFull9` (the search-side
/// incremental path is docs/V6_INCREMENTAL_DESIGN.md, not wired yet).
pub const MAGIC9 = "ZQB9";
/// Chess768 per-king-bucket input block (2 colors * 6 piece types * 64 squares).
/// HalfKA nets have `768 * king_buckets` total inputs; `768` is the bucket stride.
pub const INPUTS: usize = 768;
/// Largest hidden width supported; bounds the per-ply incremental accumulators
/// carried in the search stack and the finny-refresh entries. The deployed net is
/// 2048-wide (v3.0.0 capacity step, up from 1024 in v1.5.0/v2.x). The wider
/// accumulator scales the per-ply applyMove copy + the output-layer dot, so it
/// costs nps — but eval scales up with TC and search is deep enough to absorb it
/// (the 512->1024 step won +27 despite a similar hit). Heap-allocated SearchContext,
/// so the larger accumulator/finny arrays don't threaten the stack.
pub const MAX_HIDDEN: usize = 2048;
/// Largest output-bucket count supported.
pub const MAX_BUCKETS: usize = 16;
/// Largest king-bucket count supported (input side, HalfKA). Bounds the feature
/// table and the widest feature-weight matrix.
pub const MAX_KING_BUCKETS: usize = 16;
/// Widest feature-input dimension = 768 * MAX_KING_BUCKETS.
pub const MAX_INPUTS: usize = INPUTS * MAX_KING_BUCKETS;
/// Lean threat feature count (ZQB5-8): attacker(10) x target_sq(64) x attacked_rel(12) = 7680.
pub const MAX_THREAT_INPUTS: usize = threats_mod.NUM_THREAT_FEATURES;
/// Full threat feature count (ZQB9 only): the frozen v6 space, exactly 60,144. The lean
/// constant stays the bound for ZQB5-8 buffers (Accumulator.tw/tb, finny tbits); ZQB9's
/// full-refresh path uses its own fullthreats.PerspBits scratch instead.
pub const MAX_FULL_THREAT_INPUTS: usize = fullthreats_mod.NUM_FULLTHREAT_FEATURES;
/// Portable SIMD width for the hot accumulator/output loops. `@Vector` lowers to
/// the target's best vector ISA (AVX-512/AVX2/SSE/NEON) with a scalar fallback, so
/// this stays portable; integer SIMD is bit-exact, so eval output is unchanged.
const VEC: usize = std.simd.suggestVectorLength(i32) orelse 8;
/// SIMD width for the i16 accumulator add/sub loop (twice the i32 width).
const VEC16: usize = std.simd.suggestVectorLength(i16) orelse 16;

/// Largest inner-layer widths supported (ZQB4 layerstack l2/l3). Our first net is
/// 16/32; keep generous headroom for re-tunes without a format change.
pub const MAX_L2: usize = 64;
pub const MAX_L3: usize = 64;

const header1_bytes = MAGIC.len + @sizeOf(u32) * 2 + @sizeOf(i32) * 3; // ZQB1
const header2_bytes = MAGIC2.len + @sizeOf(u32) * 3 + @sizeOf(i32) * 3; // ZQB2 (+u32 buckets)
// ZQB3: inputs,hidden,buckets,king_buckets,mirror (5 u32) + scale,qa,qb (3 i32) + u8[64] table.
const header3_bytes = MAGIC3.len + @sizeOf(u32) * 5 + @sizeOf(i32) * 3 + 64;
// ZQB4: inputs,hidden,buckets,king_buckets,mirror,l2_size,l3_size (7 u32) + scale,qa,qb (3 i32) + u8[64].
const header4_bytes = MAGIC4.len + @sizeOf(u32) * 7 + @sizeOf(i32) * 3 + 64;
// ZQB5: inputs,hidden,buckets,king_buckets,mirror,threat_inputs (6 u32) + scale,qa,qb (3 i32) + u8[64].
const header5_bytes = MAGIC5.len + @sizeOf(u32) * 6 + @sizeOf(i32) * 3 + 64;
const header6_bytes = header5_bytes; // ZQB6: identical header fields, i8 threat block in the body
const header7_bytes = header5_bytes; // ZQB7: identical header fields, bucketed PSQT in the body
// ZQB8: inputs,hidden,buckets,king_buckets,mirror,l2,l3,threat_inputs (8 u32) + scale,qa,qb + table.
const header8_bytes = MAGIC8.len + @sizeOf(u32) * 8 + @sizeOf(i32) * 3 + 64;
const header9_bytes = header8_bytes; // ZQB9: identical header fields, full-threat block in the body

pub const LoadError = error{ InvalidMagic, UnsupportedShape, TruncatedFile } || std.mem.Allocator.Error;

pub const Net = struct {
    scale: i32,
    qa: i32,
    qb: i32,
    hidden: usize,
    buckets: usize, // output material buckets (1 for ZQB1)
    king_buckets: usize = 1, // input king buckets (1 = Chess768, no king-relativity)
    mirror: bool = false, // horizontal (file) mirroring of features by king file
    table: [64]u8 = [_]u8{0} ** 64, // king square -> king bucket (all-zero for Chess768)
    feature_weights: []align(64) i16, // (768*king_buckets)*hidden, row-major [feature*hidden + h]
    feature_bias: []i16, // hidden
    output_weights: []align(64) i16, // buckets*2*hidden, bucket-major (bucket b at [b*2h ..][0..2h])
    output_biases: []i16, // buckets

    // Threats (ZQB5): lean threat features share the accumulator (feature rows live at
    // [inputs + threat_idx], added like HalfKA rows). The PSQT material head is a linear
    // scalar summed over the stm features and added to the readout. Unused for ZQB1/2/3/4.
    threats: bool = false,
    threat_inputs: usize = 0,
    // ZQB9: the threat block is the v6 FULL-threats space (60,144 features,
    // fullthreats.zig) instead of the lean 7,680 set. Only the full-refresh
    // `evaluateFull9` path serves it in Block A; the incremental machinery
    // (Accumulator.tw/tb, directThreatDelta, finny tbits) is lean-only until the
    // Block B accumulator lands (docs/V6_INCREMENTAL_DESIGN.md).
    full_threats: bool = false,
    // PSQT material head, quantized to Q20 fixed-point at load (file stores raw f32):
    // integer adds are exact/associative (no f32->f64 convert per toggle, no FP dep
    // chain) and sub-cp vs the f64 math (quantization ~1e-6 * scale). Scalars sum in
    // i64 (|w| <= ~16 -> 2^24 per feature; ~100 active features pushes past i32).
    // Layout [feat * psqt_buckets + b]: a feature's per-bucket weights are contiguous
    // (one cache line for 8 buckets), so the incremental maintenance of all bucket
    // scalars per change/toggle is a short streaming loop. psqt_buckets == 1 for
    // ZQB5/ZQB6 (single shared head); == output buckets for ZQB7 (SF-style: the
    // anchor is bucketed WITH the readout so per-phase material lives in the head,
    // not in threat-entangled readout corrections — the w1024+b8 collapse lesson).
    psqtw: []i32 = &.{}, // (inputs + threat_inputs) * psqt_buckets, Q20
    psqtb: []i64 = &.{}, // psqt_buckets entries, Q20
    psqt_buckets: usize = 1,
    // ZQB6: threat rows stored i8 (separate from the i16 HalfKA feature_weights, which
    // then hold ONLY the HalfKA rows). Empty for ZQB5 (threat rows live in
    // feature_weights at [inputs + idx], i16). len != 0 selects the i8 kernels.
    threat_w8: []align(64) i8 = &.{}, // threat_inputs*hidden, row-major

    // Multi-layer (ZQB4) layerstack. The narrow accumulator (feature_weights/bias)
    // feeds crelu+pairwise_mul -> l1 -> screlu -> l2 -> screlu -> l3 -> scalar. The
    // layer weights are dequantised to f32 at load (l1 from i8/qb; l2/l3 already f32),
    // output-major [out][in]. Empty/unused for ZQB1/2/3 (output_weights path instead).
    multilayer: bool = false,
    l2_size: usize = 0, // l1 output width (== l2 input)
    l3_size: usize = 0, // l2 output width (== l3 input)
    l1_weights: []align(64) i8 = &.{}, // [l2_size*hidden], output-major; raw i8 (scale qb) for a vpdpbusd dot
    l1_bias: []f32 = &.{}, // [l2_size]
    l2_weights: []f32 = &.{}, // [l3_size*l2_size], output-major
    // ZQB8: transposed copy built at load ([k*l3n + k3]) so l2 vectorizes over OUTPUTS
    // (broadcast-FMA; no per-row horizontal reduces / scalar screlu chains).
    l2_weights_t: []align(64) f32 = &.{},
    l2_bias: []f32 = &.{}, // [l3_size]
    l3_weights: []f32 = &.{}, // [l3_size]
    l3_bias: []f32 = &.{}, // [buckets]

    /// How each align(64) weight block was allocated (2MB huge pages vs heap).
    /// Frees MUST mirror the method; every Net constructor must set this
    /// (allocator.create applies no field defaults).
    weight_methods: WeightMethods = .{},

    pub const WeightMethods = struct {
        feature_weights: hugealloc.Method = .heap,
        output_weights: hugealloc.Method = .heap,
        threat_w8: hugealloc.Method = .heap,
        l1_weights: hugealloc.Method = .heap,
        l2_weights_t: hugealloc.Method = .heap,
    };

    /// Free the weight slices and the net itself (allocated by loadFromBytes).
    pub fn destroy(self: *Net, allocator: std.mem.Allocator) void {
        freeWeights(i16, allocator, self.feature_weights, self.weight_methods.feature_weights);
        allocator.free(self.feature_bias);
        freeWeights(i16, allocator, self.output_weights, self.weight_methods.output_weights);
        allocator.free(self.output_biases);
        if (self.threats) {
            allocator.free(self.psqtw);
            allocator.free(self.psqtb);
        }
        freeWeights(i8, allocator, self.threat_w8, self.weight_methods.threat_w8);
        if (self.multilayer) {
            freeWeights(i8, allocator, self.l1_weights, self.weight_methods.l1_weights);
            freeWeights(f32, allocator, self.l2_weights_t, self.weight_methods.l2_weights_t);
            allocator.free(self.l1_bias);
            allocator.free(self.l2_weights);
            allocator.free(self.l2_bias);
            allocator.free(self.l3_weights);
            allocator.free(self.l3_bias);
        }
        allocator.destroy(self);
    }

    /// Output bucket index from total piece count, matching bullet's
    /// `MaterialCount<N>`: divisor = ceil(32/N), bucket = (pieces - 2) / divisor.
    pub fn bucketIndex(self: *const Net, piece_count: usize) usize {
        if (self.buckets <= 1) return 0;
        const divisor = (32 + self.buckets - 1) / self.buckets; // ceil(32/buckets)
        const b = (piece_count -| 2) / divisor;
        return @min(b, self.buckets - 1);
    }
};

pub fn isBulletFile(header: []const u8) bool {
    if (header.len < MAGIC.len) return false;
    const m = header[0..MAGIC.len];
    return std.mem.eql(u8, m, MAGIC) or std.mem.eql(u8, m, MAGIC2) or std.mem.eql(u8, m, MAGIC3) or std.mem.eql(u8, m, MAGIC4) or std.mem.eql(u8, m, MAGIC5) or std.mem.eql(u8, m, MAGIC6) or std.mem.eql(u8, m, MAGIC7) or std.mem.eql(u8, m, MAGIC8) or std.mem.eql(u8, m, MAGIC9);
}

/// Largest legal file (MAX_INPUTS wide HalfKA, MAX_HIDDEN), plus slack for the
/// 64-byte pad bullet appends to its checkpoint.
fn maxFileBytes() usize {
    // Widest lean-threat net (ZQB1-8): HalfKA(MAX_INPUTS) + threats(MAX_THREAT_INPUTS)
    // feature rows + the PSQT f32 block.
    const widest_feat = MAX_INPUTS + MAX_THREAT_INPUTS;
    const widest_i16 = widest_feat * MAX_HIDDEN + MAX_HIDDEN + MAX_BUCKETS * 2 * MAX_HIDDEN + MAX_BUCKETS;
    const psqt_bytes = (widest_feat + 1) * MAX_BUCKETS * @sizeOf(f32); // ZQB7: per-bucket PSQT columns
    const lean = header5_bytes + widest_i16 * @sizeOf(i16) + psqt_bytes + 4096;
    // Widest ZQB9: HalfKA i16 rows + bucketed layerstacks + the 60,144-row i8 threat
    // block + the single-head PSQT over HalfKA+full-threat features.
    const full_feat = MAX_INPUTS + MAX_FULL_THREAT_INPUTS;
    const layer_bytes = MAX_BUCKETS * (MAX_L2 * MAX_HIDDEN) +
        MAX_BUCKETS * (MAX_L2 + MAX_L3 * MAX_L2 + MAX_L3 + MAX_L3 + 1) * @sizeOf(f32);
    const full = header9_bytes + (MAX_INPUTS * MAX_HIDDEN + MAX_HIDDEN) * @sizeOf(i16) + layer_bytes +
        MAX_FULL_THREAT_INPUTS * MAX_HIDDEN + (full_feat + 1) * @sizeOf(f32) + 4096;
    return @max(lean, full);
}

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !*Net {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, maxFileBytes());
    defer allocator.free(bytes);
    return loadFromBytes(allocator, bytes);
}

/// PTQ noise simulator (probe instrument, env-gated): snap the i16 HalfKA rows
/// to the i8-storage grid (value = i8 * 2, i.e. QA~127 granularity) in place at
/// load. Simulates EXACTLY the rounding noise of an i8 feature transformer with
/// none of the format/kernel work — a fixed-nodes A/B against the unsnapped net
/// then measures the pure eval cost of i8 storage. ZQ_FT_I8_SIM=1 enables.
fn maybeSimFtI8(net: *Net) void {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, "ZQ_FT_I8_SIM") catch return;
    defer std.heap.page_allocator.free(v);
    if (v.len == 0 or v[0] != '1') return;
    var clipped: usize = 0;
    for (net.feature_weights) |*w| {
        const half = @divTrunc(@as(i32, w.*) + (if (w.* >= 0) @as(i32, 1) else @as(i32, -1)), 2); // round half away
        const q = std.math.clamp(half, -127, 127);
        if (half != q) clipped += 1;
        w.* = @intCast(q * 2);
    }
    std.debug.print("ZQ_FT_I8_SIM: snapped {d} halfka weights to i8 grid ({d} clipped)\n", .{ net.feature_weights.len, clipped });
}

pub fn loadFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !*Net {
    const net = try loadFromBytesInner(allocator, bytes);
    maybeSimFtI8(net);
    return net;
}

fn loadFromBytesInner(allocator: std.mem.Allocator, bytes: []const u8) !*Net {
    if (bytes.len < MAGIC.len) return error.TruncatedFile;
    if (!isBulletFile(bytes)) return error.InvalidMagic;
    const is_v9 = std.mem.eql(u8, bytes[0..MAGIC9.len], MAGIC9);
    const is_v8 = std.mem.eql(u8, bytes[0..MAGIC8.len], MAGIC8);
    const is_v7 = std.mem.eql(u8, bytes[0..MAGIC7.len], MAGIC7);
    const is_v6 = std.mem.eql(u8, bytes[0..MAGIC6.len], MAGIC6);
    const is_v5 = std.mem.eql(u8, bytes[0..MAGIC5.len], MAGIC5);
    const is_v4 = std.mem.eql(u8, bytes[0..MAGIC4.len], MAGIC4);
    const is_v3 = std.mem.eql(u8, bytes[0..MAGIC3.len], MAGIC3);
    const is_v2 = std.mem.eql(u8, bytes[0..MAGIC2.len], MAGIC2);
    const kinged = is_v3 or is_v4 or is_v5 or is_v6 or is_v7 or is_v8 or is_v9; // king-bucketed HalfKA (king_buckets/mirror/table present)
    const header = if (is_v9) header9_bytes else if (is_v8) header8_bytes else if (is_v7) header7_bytes else if (is_v6) header6_bytes else if (is_v5) header5_bytes else if (is_v4) header4_bytes else if (is_v3) header3_bytes else if (is_v2) header2_bytes else header1_bytes;
    if (bytes.len < header) return error.TruncatedFile;

    var idx: usize = MAGIC.len;
    const inputs = readU32(bytes, &idx);
    const hidden = readU32(bytes, &idx);
    const buckets: usize = if (is_v2 or is_v3 or is_v4 or is_v5 or is_v6 or is_v7 or is_v8 or is_v9) readU32(bytes, &idx) else 1;
    const king_buckets: usize = if (kinged) readU32(bytes, &idx) else 1;
    const mirror_u: u32 = if (kinged) readU32(bytes, &idx) else 0;
    const l2_size: usize = if (is_v4 or is_v8 or is_v9) readU32(bytes, &idx) else 0;
    const l3_size: usize = if (is_v4 or is_v8 or is_v9) readU32(bytes, &idx) else 0;
    const threat_inputs: usize = if (is_v5 or is_v6 or is_v7 or is_v8 or is_v9) readU32(bytes, &idx) else 0;
    if (king_buckets == 0 or king_buckets > MAX_KING_BUCKETS) return error.UnsupportedShape;
    if (inputs != INPUTS * king_buckets) return error.UnsupportedShape;
    if (hidden == 0 or hidden > MAX_HIDDEN) return error.UnsupportedShape;
    if (buckets == 0 or buckets > MAX_BUCKETS) return error.UnsupportedShape;
    if (mirror_u > 1) return error.UnsupportedShape;
    if ((is_v5 or is_v6 or is_v7 or is_v8) and (threat_inputs == 0 or threat_inputs > MAX_THREAT_INPUTS)) return error.UnsupportedShape;
    // ZQB9: the threat block is the FROZEN 60,144-feature full space — nothing else loads.
    if (is_v9 and threat_inputs != MAX_FULL_THREAT_INPUTS) return error.UnsupportedShape;
    if (is_v4 or is_v8 or is_v9) {
        if (l2_size == 0 or l2_size > MAX_L2) return error.UnsupportedShape;
        if (l3_size == 0 or l3_size > MAX_L3) return error.UnsupportedShape;
        if (hidden % 2 != 0) return error.UnsupportedShape; // pairwise_mul halves the accumulator
    }
    // ZQB8 allows buckets>=1: B material-bucketed layerstacks (bucket-major tensors).
    const h: usize = hidden;

    const scale = readI32(bytes, &idx);
    const qa = readI32(bytes, &idx);
    const qb = readI32(bytes, &idx);
    if (qa <= 0 or qb <= 0 or scale == 0) return error.UnsupportedShape;

    var table: [64]u8 = [_]u8{0} ** 64;
    if (kinged) {
        @memcpy(table[0..64], bytes[idx .. idx + 64]);
        idx += 64;
        // The expanded table must declare exactly `king_buckets` distinct buckets.
        var mx: u8 = 0;
        for (table) |t| mx = @max(mx, t);
        if (@as(usize, mx) + 1 != king_buckets) return error.UnsupportedShape;
    }

    const net = try allocator.create(Net);
    errdefer allocator.destroy(net);
    net.scale = scale;
    net.qa = qa;
    net.qb = qb;
    net.hidden = h;
    net.buckets = buckets;
    net.king_buckets = king_buckets;
    net.mirror = mirror_u != 0;
    net.table = table;
    net.multilayer = is_v4 or is_v8 or is_v9;
    net.l2_size = l2_size;
    net.l3_size = l3_size;
    net.threats = is_v5 or is_v6 or is_v7 or is_v8 or is_v9;
    net.full_threats = is_v9;
    net.threat_inputs = threat_inputs;
    net.psqtw = &.{};
    net.psqtb = &.{};
    net.psqt_buckets = 1;
    net.threat_w8 = &.{};
    net.l1_weights = &.{};
    net.l2_weights_t = &.{};
    net.l1_bias = &.{};
    net.l2_weights = &.{};
    net.l2_bias = &.{};
    net.l3_weights = &.{};
    net.l3_bias = &.{};
    net.weight_methods = .{};

    const feat_rows = inputs + threat_inputs; // == inputs for non-threat nets (threat_inputs = 0)
    // v6+ keeps threat rows in the separate i8 block, so feature_weights holds HalfKA only.
    const fw_rows = if (is_v6 or is_v7 or is_v8 or is_v9) inputs else feat_rows;
    net.feature_weights = try allocWeights(i16, allocator, fw_rows * h, &net.weight_methods.feature_weights);
    errdefer freeWeights(i16, allocator, net.feature_weights, net.weight_methods.feature_weights);
    net.feature_bias = try allocator.alloc(i16, h);
    errdefer allocator.free(net.feature_bias);

    if (is_v4) {
        // [l0w i16][l0b i16] then per-bucket: [l1w i8][l1b f32][l2w f32][l2b f32][l3w f32][l3b f32]
        const body = (inputs * h + h) * @sizeOf(i16) + (buckets * l2_size * h) * @sizeOf(i8) +
            (buckets * (l2_size + l3_size * l2_size + l3_size + l3_size + 1)) * @sizeOf(f32);
        if (bytes.len < header + body) return error.TruncatedFile;

        net.output_weights = try allocWeights(i16, allocator, 0, &net.weight_methods.output_weights);
        errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
        net.output_biases = try allocator.alloc(i16, 0);
        errdefer allocator.free(net.output_biases);

        for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);

        net.l1_weights = try allocWeights(i8, allocator, buckets * l2_size * h, &net.weight_methods.l1_weights);
        errdefer freeWeights(i8, allocator, net.l1_weights, net.weight_methods.l1_weights);
        net.l1_bias = try allocator.alloc(f32, buckets * l2_size);
        errdefer allocator.free(net.l1_bias);
        net.l2_weights = try allocator.alloc(f32, buckets * l3_size * l2_size);
        errdefer allocator.free(net.l2_weights);
        net.l2_bias = try allocator.alloc(f32, buckets * l3_size);
        errdefer allocator.free(net.l2_bias);
        net.l3_weights = try allocator.alloc(f32, buckets * l3_size);
        errdefer allocator.free(net.l3_weights);
        net.l3_bias = try allocator.alloc(f32, buckets);
        errdefer allocator.free(net.l3_bias);

        // bullet save order is bucket-major: each bucket's l1w,l1b,l2w,l2b,l3w,l3b
        // contiguous? NO -- bullet writes each weight tensor whole (all buckets), so
        // the blob is [l1w all][l1b all][l2w all][l2b all][l3w all][l3b all], each
        // tensor bucket-major internally. Read each tensor in full.
        for (net.l1_weights) |*w| w.* = readI8(bytes, &idx); // raw i8 (scale qb)
        for (net.l1_bias) |*w| w.* = readF32(bytes, &idx);
        for (net.l2_weights) |*w| w.* = readF32(bytes, &idx);
        for (net.l2_bias) |*w| w.* = readF32(bytes, &idx);
        for (net.l3_weights) |*w| w.* = readF32(bytes, &idx);
        for (net.l3_bias) |*w| w.* = readF32(bytes, &idx);
        return net;
    }

    if (is_v8 or is_v9) {
        // [l0w inputs*h i16][l0b h i16][l1w l2*h i8][l1b l2 f32][l2w l3*l2 f32][l2b l3 f32]
        // [l3w l3 f32][l3b 1 f32][threat_w8 threat_inputs*h i8][psqtw feat_rows f32][psqtb 1 f32]
        // — ZQB6's FT/threats/PSQT with the readout replaced by the ZQB4-style layerstack.
        // ZQB9 is byte-identical, just with the 60,144-row full-threat block (checked above).
        const i16_count = inputs * h + h;
        const layer_bytes = buckets * (l2_size * h) + buckets * (l2_size + l3_size * l2_size + l3_size + l3_size + 1) * @sizeOf(f32);
        const f32_count = feat_rows + 1;
        if (bytes.len < header + i16_count * @sizeOf(i16) + layer_bytes + threat_inputs * h + f32_count * @sizeOf(f32)) return error.TruncatedFile;
        net.output_weights = try allocWeights(i16, allocator, 0, &net.weight_methods.output_weights);
        errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
        net.output_biases = try allocator.alloc(i16, 0);
        errdefer allocator.free(net.output_biases);
        net.l1_weights = try allocWeights(i8, allocator, buckets * l2_size * h, &net.weight_methods.l1_weights);
        errdefer freeWeights(i8, allocator, net.l1_weights, net.weight_methods.l1_weights);
        net.l1_bias = try allocator.alloc(f32, buckets * l2_size);
        errdefer allocator.free(net.l1_bias);
        net.l2_weights = try allocator.alloc(f32, buckets * l3_size * l2_size);
        errdefer allocator.free(net.l2_weights);
        net.l2_bias = try allocator.alloc(f32, buckets * l3_size);
        errdefer allocator.free(net.l2_bias);
        net.l3_weights = try allocator.alloc(f32, buckets * l3_size);
        errdefer allocator.free(net.l3_weights);
        net.l3_bias = try allocator.alloc(f32, buckets);
        errdefer allocator.free(net.l3_bias);
        net.threat_w8 = try allocWeights(i8, allocator, threat_inputs * h, &net.weight_methods.threat_w8);
        errdefer freeWeights(i8, allocator, net.threat_w8, net.weight_methods.threat_w8);
        net.psqtw = try allocator.alloc(i32, feat_rows + MAX_BUCKETS);
        errdefer allocator.free(net.psqtw);
        @memset(net.psqtw[feat_rows..], 0); // fixed-width vector-load pad
        net.psqtb = try allocator.alloc(i64, 1);
        errdefer allocator.free(net.psqtb);
        for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);
        for (net.l1_weights) |*w| w.* = readI8(bytes, &idx);
        for (net.l1_bias) |*w| w.* = readF32(bytes, &idx);
        for (net.l2_weights) |*w| w.* = readF32(bytes, &idx);
        for (net.l2_bias) |*w| w.* = readF32(bytes, &idx);
        for (net.l3_weights) |*w| w.* = readF32(bytes, &idx);
        for (net.l3_bias) |*w| w.* = readF32(bytes, &idx);
        for (net.threat_w8) |*w| w.* = readI8(bytes, &idx);
        for (net.psqtw[0..feat_rows]) |*w| w.* = quantPsqt(readF32(bytes, &idx));
        for (net.psqtb) |*b| b.* = quantPsqt(readF32(bytes, &idx));
        // Transposed l2 per bucket: l2_weights_t[b][k*l3n + k3] = l2_weights[b][k3*l2n + k].
        net.l2_weights_t = try allocWeights(f32, allocator, buckets * l3_size * l2_size, &net.weight_methods.l2_weights_t);
        errdefer freeWeights(f32, allocator, net.l2_weights_t, net.weight_methods.l2_weights_t);
        for (0..buckets) |b| {
            const src = net.l2_weights[b * l3_size * l2_size ..];
            const dst = net.l2_weights_t[b * l3_size * l2_size ..];
            for (0..l2_size) |k| {
                for (0..l3_size) |k3| dst[k * l3_size + k3] = src[k3 * l2_size + k];
            }
        }
        return net;
    }

    if (is_v7) {
        // [l0w inputs*h i16][l0b h i16][l1w B*2h i16][l1b B i16][threat_w8 threat_inputs*h i8]
        // [psqtw feat_rows*B f32, feature-major (feat*B + b)][psqtb B f32] — ZQB6 with the
        // PSQT head bucketed alongside the readout (per-bucket seeded anchor).
        net.psqt_buckets = buckets;
        const pb = buckets;
        const i16_count = inputs * h + h + buckets * 2 * h + buckets;
        const f32_count = feat_rows * pb + pb;
        if (bytes.len < header + i16_count * @sizeOf(i16) + threat_inputs * h + f32_count * @sizeOf(f32)) return error.TruncatedFile;
        net.output_weights = try allocWeights(i16, allocator, buckets * 2 * h, &net.weight_methods.output_weights);
        errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
        net.output_biases = try allocator.alloc(i16, buckets);
        errdefer allocator.free(net.output_biases);
        net.threat_w8 = try allocWeights(i8, allocator, threat_inputs * h, &net.weight_methods.threat_w8);
        errdefer freeWeights(i8, allocator, net.threat_w8, net.weight_methods.threat_w8);
        net.psqtw = try allocator.alloc(i32, feat_rows * pb + MAX_BUCKETS);
        errdefer allocator.free(net.psqtw);
        @memset(net.psqtw[feat_rows * pb ..], 0); // fixed-width vector-load pad
        net.psqtb = try allocator.alloc(i64, pb);
        errdefer allocator.free(net.psqtb);
        for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);
        for (net.output_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.output_biases) |*w| w.* = readI16(bytes, &idx);
        for (net.threat_w8) |*w| w.* = readI8(bytes, &idx);
        for (net.psqtw[0 .. feat_rows * pb]) |*w| w.* = quantPsqt(readF32(bytes, &idx));
        for (net.psqtb) |*b| b.* = quantPsqt(readF32(bytes, &idx));
        if (!evalI32Safe(h, qa, net.output_weights)) return error.UnsupportedShape;
        return net;
    }

    if (is_v6) {
        // [l0w inputs*h i16][l0b h i16][l1w 2h i16][l1b 1 i16][threat_w8 threat_inputs*h i8]
        // [psqtw feat_rows f32][psqtb 1 f32] — ZQB5 with the threat rows split out as i8.
        const i16_count = inputs * h + h + buckets * 2 * h + buckets;
        const f32_count = feat_rows + 1;
        if (bytes.len < header + i16_count * @sizeOf(i16) + threat_inputs * h + f32_count * @sizeOf(f32)) return error.TruncatedFile;
        net.output_weights = try allocWeights(i16, allocator, buckets * 2 * h, &net.weight_methods.output_weights);
        errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
        net.output_biases = try allocator.alloc(i16, buckets);
        errdefer allocator.free(net.output_biases);
        net.threat_w8 = try allocWeights(i8, allocator, threat_inputs * h, &net.weight_methods.threat_w8);
        errdefer freeWeights(i8, allocator, net.threat_w8, net.weight_methods.threat_w8);
        net.psqtw = try allocator.alloc(i32, feat_rows * net.psqt_buckets + MAX_BUCKETS);
        errdefer allocator.free(net.psqtw);
        @memset(net.psqtw[feat_rows * net.psqt_buckets ..], 0); // fixed-width vector-load pad
        net.psqtb = try allocator.alloc(i64, net.psqt_buckets);
        errdefer allocator.free(net.psqtb);
        for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);
        for (net.output_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.output_biases) |*w| w.* = readI16(bytes, &idx);
        for (net.threat_w8) |*w| w.* = readI8(bytes, &idx);
        for (net.psqtw[0 .. feat_rows * net.psqt_buckets]) |*w| w.* = quantPsqt(readF32(bytes, &idx));
        for (net.psqtb) |*b| b.* = quantPsqt(readF32(bytes, &idx));
        if (!evalI32Safe(h, qa, net.output_weights)) return error.UnsupportedShape;
        return net;
    }

    if (is_v5) {
        // [l0w feat_rows*h i16][l0b h i16][l1w 2h i16][l1b 1 i16][psqtw feat_rows f32][psqtb 1 f32]
        const i16_count = feat_rows * h + h + buckets * 2 * h + buckets;
        const f32_count = feat_rows + 1; // psqtw[feat_rows] + psqtb
        if (bytes.len < header + i16_count * @sizeOf(i16) + f32_count * @sizeOf(f32)) return error.TruncatedFile;
        net.output_weights = try allocWeights(i16, allocator, buckets * 2 * h, &net.weight_methods.output_weights);
        errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
        net.output_biases = try allocator.alloc(i16, buckets);
        errdefer allocator.free(net.output_biases);
        net.psqtw = try allocator.alloc(i32, feat_rows * net.psqt_buckets + MAX_BUCKETS);
        errdefer allocator.free(net.psqtw);
        @memset(net.psqtw[feat_rows * net.psqt_buckets ..], 0); // fixed-width vector-load pad
        net.psqtb = try allocator.alloc(i64, net.psqt_buckets);
        errdefer allocator.free(net.psqtb);
        for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);
        for (net.output_weights) |*w| w.* = readI16(bytes, &idx);
        for (net.output_biases) |*w| w.* = readI16(bytes, &idx);
        for (net.psqtw[0 .. feat_rows * net.psqt_buckets]) |*w| w.* = quantPsqt(readF32(bytes, &idx));
        for (net.psqtb) |*b| b.* = quantPsqt(readF32(bytes, &idx));
        if (!evalI32Safe(h, qa, net.output_weights)) return error.UnsupportedShape;
        return net;
    }

    const weights_i16 = inputs * h + h + buckets * 2 * h + buckets;
    if (bytes.len < header + weights_i16 * @sizeOf(i16)) return error.TruncatedFile;
    net.output_weights = try allocWeights(i16, allocator, buckets * 2 * h, &net.weight_methods.output_weights);
    errdefer freeWeights(i16, allocator, net.output_weights, net.weight_methods.output_weights);
    net.output_biases = try allocator.alloc(i16, buckets);
    errdefer allocator.free(net.output_biases);

    for (net.feature_weights) |*w| w.* = readI16(bytes, &idx);
    for (net.feature_bias) |*w| w.* = readI16(bytes, &idx);
    for (net.output_weights) |*w| w.* = readI16(bytes, &idx);
    for (net.output_biases) |*w| w.* = readI16(bytes, &idx);
    // `screluDotPair` accumulates per-lane products in i32; reject any net whose output
    // weights are large enough that the sum could overflow (would need |ow| > ~258).
    if (!evalI32Safe(h, qa, net.output_weights)) return error.UnsupportedShape;
    return net;
}

/// The engine's default net, embedded so the binary works out-of-the-box with no
/// external EvalFile (bullet-trained pure NNUE on Stockfish T80 self-play data).
pub const default_net_bytes = @embedFile("default_net.zqb");

pub fn loadDefault(allocator: std.mem.Allocator) !*Net {
    return loadFromBytes(allocator, default_net_bytes);
}

inline fn screlu(x: i32, qa: i32) i64 {
    const y: i64 = std.math.clamp(x, 0, qa);
    return y * y;
}

/// Per-perspective king bucket + horizontal-mirror flip, derived from that
/// perspective's own king square. For Chess768 (king_buckets=1, no mirror) this
/// is always {bucket:0, flip:0}, so the feature index reduces to plain Chess768.
const PerspCtx = struct { bucket: usize, flip: u6 };

/// Add/remove one piece's feature row in a raw i16 accumulator for `persp`'s
/// bucket/flip. The shared core of `editP` (per-ply acc) and `finnyRefresh` (cache
/// acc). i16 SIMD via VEC16; bit-exact integer math.
/// HalfKA feature index in `persp`'s bucket/flip frame: the shared index core of
/// editAcc / featureRow AND the PSQT lookup. INPUTS*bucket + (own?0:384) + 64*pt + (relsq^flip).
inline fn halfkaIndex(comptime persp: types.Color, ctx: PerspCtx, color: types.Color, pt: piece.PieceType, sidx: u6) usize {
    const ptn: usize = @intFromEnum(pt);
    const base: usize = if (color == persp) 0 else 384;
    const relsq: u6 = if (persp == .white) sidx else sidx ^ 56;
    return INPUTS * ctx.bucket + base + 64 * ptn + @as(usize, relsq ^ ctx.flip);
}

inline fn editAcc(acc: *[MAX_HIDDEN]i16, net: *const Net, comptime persp: types.Color, ctx: PerspCtx, color: types.Color, pt: piece.PieceType, sidx: u6, comptime add: bool) void {
    const h = net.hidden;
    const feat = halfkaIndex(persp, ctx, color, pt, sidx);
    const w = net.feature_weights[feat * h ..][0..h];
    var i: usize = 0;
    while (i + VEC16 <= h) : (i += VEC16) {
        const wv: @Vector(VEC16, i16) = w[i..][0..VEC16].*;
        var av: @Vector(VEC16, i16) = acc[i..][0..VEC16].*;
        // Deliberately NON-wrapping (vs the fused kernels' +%/-%): this is the
        // canonical-order reference path, so a Debug-build overflow trap here means
        // the NET violates the i16-safe assumption — a signal, not a bug. The fused
        // kernels reorder partial sums and must wrap to avoid spurious traps.
        av = if (add) av + wv else av - wv;
        acc[i..][0..VEC16].* = av;
    }
    while (i < h) : (i += 1) {
        if (add) acc[i] += w[i] else acc[i] -= w[i];
    }
}

/// Weight row for one feature in `persp`'s bucket/flip frame — the index core of
/// `editAcc`, factored out so the fused per-move update can gather row pointers up
/// front and apply every delta in a single accumulator pass.
inline fn featureRow(net: *const Net, comptime persp: types.Color, ctx: PerspCtx, color: types.Color, pt: piece.PieceType, sidx: u6) []const i16 {
    const h = net.hidden;
    const feat = halfkaIndex(persp, ctx, color, pt, sidx);
    return net.feature_weights[feat * h ..][0..h];
}

/// One piece feature change for a move. The SAME (color,pt,sq,add) list drives both
/// perspectives; each maps it to its own weight row via `featureRow`.
pub const Change = struct { color: types.Color, pt: piece.PieceType, sq: u6, add: bool };

/// Most piece feature changes one move can produce (castle: 2 king + 2 rook).
pub const MAX_MOVE_CHANGES: usize = 4;

/// Decode a move's piece feature changes ONCE from the move flag + make/unmake
/// state — the single source of truth for "which squares/pieces changed" shared
/// by the HalfKA per-ply update (applyMoveColor) and the v6 full-threat delta
/// (FullThreatState.advanceMove, via squareChangesFrom). Up to 4 (castle).
///
/// perf-r5: writes the list THROUGH `out` and returns the count, instead of
/// returning a by-value `{[4]Change, n}` struct. The old shape forced the
/// caller to copy the array out of the returned aggregate (`const changes =
/// g.changes`), and that 16-byte copy read back the four 4-byte element stores
/// the decode had just issued — a store-to-load-forwarding stall on every
/// materialized move, in BOTH consumers. Writing in place leaves only
/// element-width stores feeding element-width loads, which forward cleanly.
inline fn gatherChangesInto(comptime mc: types.Color, mv: move_mod.Move, state: *const make_unmake.StateInfo, out: *[MAX_MOVE_CHANGES]Change) usize {
    const mpt = state.moved_piece.pieceType();
    const from = mv.from.index();
    const to = mv.to.index();
    var g = struct { changes: *[MAX_MOVE_CHANGES]Change, n: usize }{ .changes = out, .n = 0 };
    switch (mv.flag) {
        .quiet, .double_push => {
            g.changes[0] = .{ .color = mc, .pt = mpt, .sq = from, .add = false };
            g.changes[1] = .{ .color = mc, .pt = mpt, .sq = to, .add = true };
            g.n = 2;
        },
        .capture => {
            const cap = state.captured_piece;
            g.changes[0] = .{ .color = cap.color().?, .pt = cap.pieceType(), .sq = to, .add = false };
            g.changes[1] = .{ .color = mc, .pt = mpt, .sq = from, .add = false };
            g.changes[2] = .{ .color = mc, .pt = mpt, .sq = to, .add = true };
            g.n = 3;
        },
        .en_passant => {
            const cap = state.captured_piece;
            const cap_sq = enPassantCapturedSquare(mc, mv.to).index();
            g.changes[0] = .{ .color = cap.color().?, .pt = cap.pieceType(), .sq = cap_sq, .add = false };
            g.changes[1] = .{ .color = mc, .pt = mpt, .sq = from, .add = false };
            g.changes[2] = .{ .color = mc, .pt = mpt, .sq = to, .add = true };
            g.n = 3;
        },
        .castle => {
            const rook = castleRookSquares(mc, mv.to);
            g.changes[0] = .{ .color = mc, .pt = .king, .sq = from, .add = false };
            g.changes[1] = .{ .color = mc, .pt = .king, .sq = to, .add = true };
            g.changes[2] = .{ .color = mc, .pt = .rook, .sq = rook.from, .add = false };
            g.changes[3] = .{ .color = mc, .pt = .rook, .sq = rook.to, .add = true };
            g.n = 4;
        },
        .promo_knight, .promo_bishop, .promo_rook, .promo_queen => {
            g.changes[0] = .{ .color = mc, .pt = .pawn, .sq = from, .add = false };
            g.changes[1] = .{ .color = mc, .pt = mv.promotionPieceType().?, .sq = to, .add = true };
            g.n = 2;
        },
        .promo_knight_capture, .promo_bishop_capture, .promo_rook_capture, .promo_queen_capture => {
            const cap = state.captured_piece;
            g.changes[0] = .{ .color = cap.color().?, .pt = cap.pieceType(), .sq = to, .add = false };
            g.changes[1] = .{ .color = mc, .pt = .pawn, .sq = from, .add = false };
            g.changes[2] = .{ .color = mc, .pt = mv.promotionPieceType().?, .sq = to, .add = true };
            g.n = 3;
        },
    }
    return g.n;
}

/// Runtime-mover-colour wrapper over the comptime-specialised decode: the single
/// decode a materialization performs, whose result feeds BOTH the HalfKA
/// accumulator update and the v6 full-threat delta (they used to decode the same
/// move twice, once each).
pub inline fn decodeMoveChanges(mv: move_mod.Move, state: *const make_unmake.StateInfo, out: *[MAX_MOVE_CHANGES]Change) usize {
    return switch (state.moved_piece.color().?) {
        .white => gatherChangesInto(.white, mv, state, out),
        .black => gatherChangesInto(.black, mv, state, out),
    };
}

/// Merge a move's (color,pt,sq,add) feature-change list into per-square
/// old/new occupant records — the input applyMoveDelta (fullthreats.zig) wants.
/// Same decode as the HalfKA path (gatherChanges), never a mailbox re-diff.
fn squareChangesFrom(changes: []const Change, out: *[4]fullthreats_mod.SquareChange) usize {
    var n: usize = 0;
    for (changes) |c| {
        const p = piece.Piece.make(c.color, c.pt);
        var slot: usize = n;
        for (0..n) |i| {
            if (out[i].sq == c.sq) slot = i;
        }
        if (slot == n) {
            out[n] = .{ .sq = c.sq, .old = .none, .new = .none };
            n += 1;
        }
        if (c.add) out[slot].new = p else out[slot].old = p;
    }
    return n;
}

/// COMPTIME-unrolled fused accumulator update: child = par + Σ add_rows[0..na] −
/// Σ sub_rows[0..ns] in ONE pass. na/ns are comptime so the inner delta loops fully
/// unroll (no per-chunk branch overhead — the whole point vs a runtime-bounded loop).
/// Wrapping i16 ops; the final accumulator is i16-safe so this equals the checked
/// sequential sum, bit-for-bit.
inline fn fusedRows(child: *[MAX_HIDDEN]i16, par: *const [MAX_HIDDEN]i16, h: usize, comptime na: usize, add_rows: [4][]const i16, comptime ns: usize, sub_rows: [4][]const i16) void {
    var i: usize = 0;
    while (i + VEC16 <= h) : (i += VEC16) {
        var av: @Vector(VEC16, i16) = par[i..][0..VEC16].*;
        inline for (0..na) |k| {
            const wv: @Vector(VEC16, i16) = add_rows[k][i..][0..VEC16].*;
            av = av +% wv;
        }
        inline for (0..ns) |k| {
            const wv: @Vector(VEC16, i16) = sub_rows[k][i..][0..VEC16].*;
            av = av -% wv;
        }
        child[i..][0..VEC16].* = av;
    }
    while (i < h) : (i += 1) {
        var v: i16 = par[i];
        inline for (0..na) |k| v +%= add_rows[k][i];
        inline for (0..ns) |k| v -%= sub_rows[k][i];
        child[i] = v;
    }
}

/// Super-chunk width for the dual fused update: how many VEC16 accumulator
/// vectors stay live across the row loop. At h=1024/VEC16=32 an 8-wide chunk is
/// exactly 4 super-chunks per half. Two halves x U vectors must fit the register
/// file (2*4 = 8 zmm of 32 on AVX-512, leaving room for the row operands).
const FUSED_U: usize = 8;

/// BOTH perspectives' fused updates in ONE loop: white and black are entirely
/// independent accumulator chains over the same index range, so interleaving them
/// pays the loop overhead once instead of twice and gives the scheduler 2*FUSED_U
/// independent dependency chains (the single-perspective loop ran one add chain
/// per 32-lane chunk and was overhead/latency-bound, not bandwidth-bound). Same
/// per-perspective add order, same wrapping integer ops -> bit-exact with two
/// back-to-back `fusedRows` calls.
inline fn fusedRowsDual(
    wchild: *[MAX_HIDDEN]i16,
    wpar: *const [MAX_HIDDEN]i16,
    bchild: *[MAX_HIDDEN]i16,
    bpar: *const [MAX_HIDDEN]i16,
    h: usize,
    comptime na: usize,
    w_add: [4][]const i16,
    b_add: [4][]const i16,
    comptime ns: usize,
    w_sub: [4][]const i16,
    b_sub: [4][]const i16,
) void {
    const U = FUSED_U;
    var i: usize = 0;
    while (i + U * VEC16 <= h) : (i += U * VEC16) {
        var wv: [U]@Vector(VEC16, i16) = undefined;
        var bv: [U]@Vector(VEC16, i16) = undefined;
        inline for (0..U) |u| {
            wv[u] = wpar[i + u * VEC16 ..][0..VEC16].*;
            bv[u] = bpar[i + u * VEC16 ..][0..VEC16].*;
        }
        inline for (0..na) |k| {
            inline for (0..U) |u| {
                wv[u] +%= @as(@Vector(VEC16, i16), w_add[k][i + u * VEC16 ..][0..VEC16].*);
                bv[u] +%= @as(@Vector(VEC16, i16), b_add[k][i + u * VEC16 ..][0..VEC16].*);
            }
        }
        inline for (0..ns) |k| {
            inline for (0..U) |u| {
                wv[u] -%= @as(@Vector(VEC16, i16), w_sub[k][i + u * VEC16 ..][0..VEC16].*);
                bv[u] -%= @as(@Vector(VEC16, i16), b_sub[k][i + u * VEC16 ..][0..VEC16].*);
            }
        }
        inline for (0..U) |u| {
            wchild[i + u * VEC16 ..][0..VEC16].* = wv[u];
            bchild[i + u * VEC16 ..][0..VEC16].* = bv[u];
        }
    }
    // Tails (h not a whole number of super-chunks): plain per-chunk then scalar.
    while (i + VEC16 <= h) : (i += VEC16) {
        var a: @Vector(VEC16, i16) = wpar[i..][0..VEC16].*;
        var b: @Vector(VEC16, i16) = bpar[i..][0..VEC16].*;
        inline for (0..na) |k| {
            a +%= @as(@Vector(VEC16, i16), w_add[k][i..][0..VEC16].*);
            b +%= @as(@Vector(VEC16, i16), b_add[k][i..][0..VEC16].*);
        }
        inline for (0..ns) |k| {
            a -%= @as(@Vector(VEC16, i16), w_sub[k][i..][0..VEC16].*);
            b -%= @as(@Vector(VEC16, i16), b_sub[k][i..][0..VEC16].*);
        }
        wchild[i..][0..VEC16].* = a;
        bchild[i..][0..VEC16].* = b;
    }
    while (i < h) : (i += 1) {
        var a: i16 = wpar[i];
        var b: i16 = bpar[i];
        inline for (0..na) |k| {
            a +%= w_add[k][i];
            b +%= b_add[k][i];
        }
        inline for (0..ns) |k| {
            a -%= w_sub[k][i];
            b -%= b_sub[k][i];
        }
        wchild[i] = a;
        bchild[i] = b;
    }
}

/// Finny (accumulator-refresh) table: a cached accumulator + the board snapshot that
/// produced it, per (perspective, king-bucket slot). On a king move that changes the
/// bucket/flip, `finnyRefresh` rebuilds the mover perspective by applying only the
/// piece DIFF vs the snapshot -- far cheaper than a from-scratch refresh when the same
/// bucket recurs in the search. Always exact (cached = bias + snapshot pieces; diff to
/// current -> bias + current pieces = full refresh). One per thread (engine is 1-thread).
const FINNY_SLOTS = MAX_KING_BUCKETS * 2; // bucket*2 + (flip != 0)

const FinnyEntry = struct {
    acc: [MAX_HIDDEN]i16 align(64) = undefined,
    bbs: [2][6]bitboard.Bitboard = .{ .{0} ** 6, .{0} ** 6 },
    // Threats nets: the threat rows are cached IN `acc` and diffed like the piece bbs
    // (`tbits` = which threat features the cached acc contains, `psqt_t` their PSQT sum),
    // so a king bucket/flip crossing costs only the changed rows, not a full ~40-row
    // re-add. Untouched for non-threat nets.
    tbits: threats_mod.PerspBits = [_]u64{0} ** threats_mod.WORDS,
    psqt_t: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    // HalfKA-PSQT sum over the SNAPSHOT pieces in this (bucket, flip) frame,
    // maintained by the same piece diff that rebuilds `acc`. A bucket/flip cross
    // used to re-derive the mover perspective's HalfKA PSQT with sumHalfkaPsqt —
    // a full 32-piece scan of random psqtw lookups — even though the diff loop
    // right above already knew exactly which pieces changed.
    psqt_h: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    valid: bool = false,
};

pub const FinnyTable = struct {
    sides: [2][FINNY_SLOTS]FinnyEntry = .{[_]FinnyEntry{.{}} ** FINNY_SLOTS} ** 2,

    /// Invalidate all slots (call at search start / on net change). Cheap: only
    /// flips the `valid` flags; entries re-seed (bias + empty board) on first use.
    pub fn reset(self: *FinnyTable) void {
        for (&self.sides) |*side| {
            for (side) |*e| e.valid = false;
        }
    }
};

/// White- and black-perspective hidden accumulators, maintained incrementally
/// across make/unmake so eval only runs the output layer. One per search ply.
/// Stored as i16 (the standard NNUE accumulator width): bullet quantises the net
/// for an i16 accumulator (QA=255), so the maintained sums fit (~+/-3000 in
/// practice, vs the i16 +/-32767 range). i16 halves the per-node copy/edit memory
/// bandwidth and doubles SIMD lanes vs the old i32. Debug builds panic on overflow,
/// so the TreeVerifier + bullet-reference tests catch any net that violates the
/// i16-safe assumption.
pub const Accumulator = struct {
    // align(64): the halves are swept with 64-byte vector ops every applyMove/eval;
    // without an explicit alignment the containing StackEntry only guarantees
    // natural (8-byte) alignment, so every zmm load/store could straddle two
    // cache lines. Alignment is semantics-free -> bit-exact.
    white: [MAX_HIDDEN]i16 align(64) = undefined,
    black: [MAX_HIDDEN]i16 align(64) = undefined,
    // ZQB5 threats: threat feature rows are added INTO white/black (shared accumulator);
    // tw/tb track which threat features are active per COLOUR (white-/black-perspective) so
    // applyMove can apply only the bitset delta vs the parent. Zero/unused for non-threat nets.
    tw: threats_mod.PerspBits = [_]u64{0} ** threats_mod.WORDS,
    tb: threats_mod.PerspBits = [_]u64{0} ** threats_mod.WORDS,
    // Per-colour threat-PSQT material sums (Σ psqtw over active threat features), maintained
    // alongside tw/tb so eval needn't re-sum them. (HalfKA PSQT is still summed per eval.)
    psqt_tw: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    psqt_tb: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    // Per-colour HalfKA-PSQT material sums (Σ psqtw over active HalfKA features), maintained
    // via the move change-list so eval needn't iterate the pieces.
    psqt_hw: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    psqt_hb: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS,
    // ZQB9 full threats (docs/V6_INCREMENTAL_DESIGN.md): SEPARATE per-colour threat
    // accumulator halves — Σ threat rows over the active full-threat features, NO
    // bias, HalfKA rows never mixed in (white/black stay HalfKA-only for ZQB9).
    // Kept apart from white/black because the full-threat state does not depend on
    // king BUCKETS at all: bucket-only king crossings rebuild the HalfKA half via
    // finny while these halves ride along untouched; only the horizontal mirror
    // flip forces a threat rebuild (via FullThreatState's 2-slot flip cache).
    // Eval sums HalfKA half + threat half lane-wise (evaluateFull9Incremental).
    // The matching per-colour threat-PSQT scalars reuse psqt_tw/psqt_tb above.
    // Unused (undefined) for every other net format.
    ftw: [MAX_HIDDEN]i16 align(64) = undefined,
    ftb: [MAX_HIDDEN]i16 align(64) = undefined,

    /// King bucket + mirror flip for `persp`, keyed on that side's king square in
    /// the perspective's OWN frame (own king at the bottom): white as-is, black
    /// rank-flipped (`^56`). bullet's loader reorients the board to be stm-relative
    /// (swap_bytes + color swap when black is to move), so `our_ksq/opp_ksq` index
    /// the bucket table by the side-relative king square; the black perspective's
    /// piece squares are likewise `^56`, so the king must be too (frame-consistent).
    /// Reads `pos.kingSquare(persp)` (the post-move square in applyMove). `^56`
    /// preserves the file, so the mirror flip is identical either way.
    /// Bucket+flip for `persp` given that side's RAW king square (own-frame: white
    /// as-is, black `^56`). Used to detect whether a king move actually changes the
    /// mover perspective's indexing (and thus needs a full refresh).
    inline fn kingCtx(net: *const Net, comptime persp: types.Color, kabs: u6) PerspCtx {
        const ksq: u6 = if (persp == .white) kabs else kabs ^ 56;
        return .{
            .bucket = net.table[ksq],
            .flip = if (net.mirror and (ksq & 7) > 3) 7 else 0,
        };
    }

    fn perspCtx(net: *const Net, comptime persp: types.Color, pos: *const position.Position) PerspCtx {
        return kingCtx(net, persp, pos.kingSquare(persp).?.index());
    }

    /// Add/remove ONE piece's feature row for a SINGLE perspective, applying that
    /// perspective's king-bucket offset + mirror flip. Bit-exact HalfKA index;
    /// reduces to plain Chess768 when `ctx = {bucket:0, flip:0}`.
    inline fn editP(
        self: *Accumulator,
        net: *const Net,
        comptime persp: types.Color,
        ctx: PerspCtx,
        color: types.Color,
        pt: piece.PieceType,
        sidx: u6,
        comptime add: bool,
    ) void {
        editAcc(if (persp == .white) &self.white else &self.black, net, persp, ctx, color, pt, sidx, add);
    }

    /// Fused per-ply update for ONE incremental perspective: child = parent + Σadds −
    /// Σsubs in a SINGLE accumulator pass (read parent, apply every delta in-register,
    /// store child once). Replaces copyFrom + one full `editAcc` pass per delta — the
    /// identical integer adds/subs, in the same per-perspective order, so bit-exact —
    /// but ~2-3x less accumulator store traffic at 2048 width (the width-tax hot path).
    /// Wrapping ops (+%/-%): the final accumulator is i16-safe so this equals the
    /// checked sequential result, and reordered partial sums never spuriously trap.
    inline fn applyPersp(self: *Accumulator, net: *const Net, comptime persp: types.Color, ctx: PerspCtx, parent: *const Accumulator, changes: []const Change) void {
        const h = net.hidden;
        const child = if (persp == .white) &self.white else &self.black;
        const par = if (persp == .white) &parent.white else &parent.black;
        var add_rows: [4][]const i16 = undefined;
        var sub_rows: [4][]const i16 = undefined;
        var na: usize = 0;
        var ns: usize = 0;
        for (changes) |c| {
            const w = featureRow(net, persp, ctx, c.color, c.pt, c.sq);
            if (c.add) {
                add_rows[na] = w;
                na += 1;
            } else {
                sub_rows[ns] = w;
                ns += 1;
            }
        }
        // Dispatch the small (#add,#sub) combo ONCE to a comptime-unrolled fused loop
        // (combos: (1,1) quiet/promo, (1,2) capture/ep/promo-capture, (2,2) castle).
        switch (na) {
            inline 1, 2 => |cna| switch (ns) {
                inline 1, 2 => |cns| fusedRows(child, par, h, cna, add_rows, cns, sub_rows),
                else => unreachable,
            },
            else => unreachable,
        }
    }

    /// The COMMON per-ply update (no king bucket/flip cross): both perspectives'
    /// fused passes in one interleaved loop. Gathers each change's white AND black
    /// weight rows in a single index pass — the old shape computed every row index
    /// three times (once for the prefetch loop, once per applyPersp) — prefetches
    /// them, then runs `fusedRowsDual`. Bit-exact with the two sequential
    /// `applyPersp` calls it replaces.
    inline fn applyPerspDual(self: *Accumulator, net: *const Net, wctx: PerspCtx, bctx: PerspCtx, parent: *const Accumulator, changes: []const Change) void {
        const h = net.hidden;
        var w_add: [4][]const i16 = undefined;
        var w_sub: [4][]const i16 = undefined;
        var b_add: [4][]const i16 = undefined;
        var b_sub: [4][]const i16 = undefined;
        var na: usize = 0;
        var ns: usize = 0;
        for (changes) |c| {
            const wr = featureRow(net, .white, wctx, c.color, c.pt, c.sq);
            const br = featureRow(net, .black, bctx, c.color, c.pt, c.sq);
            // Each row is a random multi-KB read into the 50MB net: issue both
            // prefetches during the gather so the misses overlap each other and the
            // loop prologue. (Hint only: exact-output.)
            @prefetch(wr.ptr, .{ .rw = .read, .locality = 3, .cache = .data });
            @prefetch(br.ptr, .{ .rw = .read, .locality = 3, .cache = .data });
            if (c.add) {
                w_add[na] = wr;
                b_add[na] = br;
                na += 1;
            } else {
                w_sub[ns] = wr;
                b_sub[ns] = br;
                ns += 1;
            }
        }
        switch (na) {
            inline 1, 2 => |cna| switch (ns) {
                inline 1, 2 => |cns| fusedRowsDual(&self.white, &parent.white, &self.black, &parent.black, h, cna, w_add, b_add, cns, w_sub, b_sub),
                else => unreachable,
            },
            else => unreachable,
        }
    }

    /// Full recompute of ONE perspective from the board.
    fn refreshPersp(self: *Accumulator, net: *const Net, pos: *const position.Position, comptime persp: types.Color) void {
        const h = net.hidden;
        const acc = if (persp == .white) &self.white else &self.black;
        for (0..h) |i| acc[i] = net.feature_bias[i];
        const ctx = perspCtx(net, persp, pos);
        var occ = pos.occupancy();
        while (bitboard.popLsb(&occ)) |sq| {
            const p = pos.pieceAt(sq);
            const color = p.color() orelse continue;
            self.editP(net, persp, ctx, color, p.pieceType(), sq.index(), true);
        }
    }

    /// Rebuild ONE perspective via the finny cache: apply only the piece diff vs the
    /// cached snapshot for this (persp, bucket, flip) slot, then copy into `self`.
    /// Bit-exact-equal to `refreshPersp`; used on king moves that change bucket/flip.
    fn finnyRefresh(self: *Accumulator, net: *const Net, pos: *const position.Position, comptime persp: types.Color, ctx: PerspCtx, finny: *FinnyTable) void {
        const h = net.hidden;
        const slot = ctx.bucket * 2 + @as(usize, @intFromBool(ctx.flip != 0));
        const entry = &finny.sides[@intFromEnum(persp)][slot];
        if (!entry.valid) {
            for (0..h) |i| entry.acc[i] = net.feature_bias[i];
            entry.bbs = .{ .{0} ** 6, .{0} ** 6 };
            entry.tbits = [_]u64{0} ** threats_mod.WORDS;
            entry.psqt_t = [_]i64{0} ** MAX_BUCKETS;
            entry.psqt_h = [_]i64{0} ** MAX_BUCKETS;
            entry.valid = true;
        }
        // Collect the piece-diff rows into a pending batch instead of one full
        // editAcc RMW sweep of entry.acc PER row (each read+wrote the whole 2h-byte
        // half): the final dual flush below applies them all in ONE pass that also
        // writes the child half — replacing k sweeps + copyHalf with a single
        // sweep + row loads. Adds/subs commute (wrapping) and the final sum is
        // i16-safe, so this is bit-exact vs the sequential edits (same argument
        // as flushInto; refreshPersp keeps the canonical-order editAcc path).
        // Bounds: adds <= 32 and subs <= 32 (piece counts) == pending MAX; a
        // (cold, never-expected) overflow flush stays in place on entry.acc.
        var pending: PendingThreatRowsT(i16) = undefined;
        pending.initEmpty();
        inline for (.{ types.Color.white, types.Color.black }) |c| {
            inline for (0..6) |ptn| {
                const pt: piece.PieceType = @enumFromInt(ptn);
                const cur = pos.pieceBitboard(c, pt);
                const old = entry.bbs[@intFromEnum(c)][ptn];
                var removed = old & ~cur;
                while (bitboard.popLsb(&removed)) |sq| {
                    pending.pushSub(&entry.acc, h, featureRow(net, persp, ctx, c, pt, sq.index()));
                    // Only threats nets (ZQB5+) carry a PSQT head at all — older
                    // formats have an EMPTY psqtw, so the lookup must not run.
                    if (net.threats) addPsqtVecRaw(&entry.psqt_h, net, halfkaIndex(persp, ctx, c, pt, sq.index()), false);
                }
                var added = cur & ~old;
                while (bitboard.popLsb(&added)) |sq| {
                    pending.pushAdd(&entry.acc, h, featureRow(net, persp, ctx, c, pt, sq.index()));
                    if (net.threats) addPsqtVecRaw(&entry.psqt_h, net, halfkaIndex(persp, ctx, c, pt, sq.index()), true);
                }
                entry.bbs[@intFromEnum(c)][ptn] = cur;
            }
        }
        // LEAN threats: diff the cached threat rows against this perspective's CURRENT bitset
        // (the caller enumerates into self.tw/tb before finnyRefresh) — same idea as the
        // piece diff above. Runs BEFORE the pending piece rows flush; both are commuting
        // adds into entry.acc, so the reordering vs the old edit-then-delta sequence is
        // value-identical. ZQB9 full-threat nets skip this: their threat rows live in the
        // SEPARATE ftw/ftb halves (untouched by king-bucket crossings), the finny entry
        // stays HalfKA-only, and FinnyEntry.tbits (lean-sized) is never consulted.
        if (net.threats and !net.full_threats) {
            const cur_bits = if (persp == .white) &self.tw else &self.tb;
            if (net.threat_w8.len != 0)
                applyThreatBitsetDelta(i8, &entry.acc, net, &entry.tbits, cur_bits, &entry.psqt_t)
            else
                applyThreatBitsetDelta(i16, &entry.acc, net, &entry.tbits, cur_bits, &entry.psqt_t);
            copyPerspBits(&entry.tbits, cur_bits);
        }
        // One fused pass: entry.acc += pending rows, child half = the same result.
        const dst = if (persp == .white) &self.white else &self.black;
        pending.flushIntoDual(&entry.acc, dst, &entry.acc, h);
    }

    /// Full recompute of both perspectives from the board (used at the root and
    /// as the correctness reference).
    pub fn refresh(self: *Accumulator, net: *const Net, pos: *const position.Position) void {
        self.refreshPersp(net, pos, .white);
        self.refreshPersp(net, pos, .black);
        if (net.full_threats) {
            self.refreshFullThreats(net, pos);
        } else if (net.threats) {
            self.refreshThreats(net, pos);
        }
    }

    /// ZQB9: full recompute of the SEPARATE threat halves (ftw/ftb) + both PSQT
    /// scalar families from the board. The HalfKA halves (white/black) must
    /// already be refreshed (refreshPersp) and contain NO threat rows.
    fn refreshFullThreats(self: *Accumulator, net: *const Net, pos: *const position.Position) void {
        const h = net.hidden;
        var wbits: fullthreats_mod.PerspBits = undefined;
        var bbits: fullthreats_mod.PerspBits = undefined;
        fullthreats_mod.enumerateColors(pos, &wbits, &bbits);
        @memset(self.ftw[0..h], 0);
        @memset(self.ftb[0..h], 0);
        self.psqt_tw = [_]i64{0} ** MAX_BUCKETS;
        self.psqt_tb = [_]i64{0} ** MAX_BUCKETS;
        addThreatBitsetRows(i8, &self.ftw, net, &wbits, &self.psqt_tw);
        addThreatBitsetRows(i8, &self.ftb, net, &bbits, &self.psqt_tb);
        sumHalfkaPsqt(net, .white, pos, &self.psqt_hw);
        sumHalfkaPsqt(net, .black, pos, &self.psqt_hb);
    }

    /// Full threat-feature recompute: enumerate per colour, add every threat row into the
    /// (HalfKA-filled) accumulators, and store the active-feature bitsets. ZQB5 only.
    fn refreshThreats(self: *Accumulator, net: *const Net, pos: *const position.Position) void {
        threats_mod.enumerateColors(pos, &self.tw, &self.tb);
        self.psqt_tw = [_]i64{0} ** MAX_BUCKETS;
        self.psqt_tb = [_]i64{0} ** MAX_BUCKETS;
        if (net.threat_w8.len != 0) {
            addThreatBitsetRows(i8, &self.white, net, &self.tw, &self.psqt_tw);
            addThreatBitsetRows(i8, &self.black, net, &self.tb, &self.psqt_tb);
        } else {
            addThreatBitsetRows(i16, &self.white, net, &self.tw, &self.psqt_tw);
            addThreatBitsetRows(i16, &self.black, net, &self.tb, &self.psqt_tb);
        }
        sumHalfkaPsqt(net, .white, pos, &self.psqt_hw);
        sumHalfkaPsqt(net, .black, pos, &self.psqt_hb);
    }

    /// Aligned accumulator-half copy: explicit VEC16-wide vector moves instead of a
    /// runtime-length @memcpy, which lowers to an out-of-line compiler_rt memcpy call
    /// (unaligned-store block loop + length dispatch — the 1.2-1.5% memcpy line in the
    /// opening/middle profiles, all attributable to finnyRefresh's entry->child copy).
    /// Both halves are align(64) and h is a multiple large enough that the scalar tail
    /// rarely runs; a pure copy either way, so bit-exact.
    inline fn copyHalf(dst: *[MAX_HIDDEN]i16, src: *const [MAX_HIDDEN]i16, h: usize) void {
        var i: usize = 0;
        while (i + VEC16 <= h) : (i += VEC16) {
            dst[i..][0..VEC16].* = @as(@Vector(VEC16, i16), src[i..][0..VEC16].*);
        }
        while (i < h) : (i += 1) dst[i] = src[i];
    }

    /// Fixed-size threat-bitset copy (WORDS u64 = 960B), fully unrolled into
    /// inline vector moves. The plain array assignment `dst.* = src.*` is large
    /// enough that LLVM lowers it to an out-of-line memcpy CALL — and the
    /// tw/tb parent->child carry runs on EVERY applyMove (the common
    /// incremental path), making it the top memcpy caller in the opening/middle
    /// profiles (1.5-1.8%). Pure copy — bit-exact.
    inline fn copyPerspBits(dst: *threats_mod.PerspBits, src: *const threats_mod.PerspBits) void {
        const VW = comptime (std.simd.suggestVectorLength(u64) orelse 4);
        comptime var i: usize = 0;
        inline while (i + VW <= threats_mod.WORDS) : (i += VW) {
            dst[i..][0..VW].* = @as(@Vector(VW, u64), src[i..][0..VW].*);
        }
        inline while (i < threats_mod.WORDS) : (i += 1) dst[i] = src[i];
    }

    /// Copy only the LIVE per-bucket psqt scalars (psqt_buckets of MAX_BUCKETS) —
    /// whole-array struct copies cost 4x128B per make at psqt_buckets == 1.
    inline fn copyPsqtVecs(self: *Accumulator, parent: *const Accumulator, pb: usize) void {
        @memcpy(self.psqt_tw[0..pb], parent.psqt_tw[0..pb]);
        @memcpy(self.psqt_tb[0..pb], parent.psqt_tb[0..pb]);
        @memcpy(self.psqt_hw[0..pb], parent.psqt_hw[0..pb]);
        @memcpy(self.psqt_hb[0..pb], parent.psqt_hb[0..pb]);
    }

    pub fn copyFrom(self: *Accumulator, parent: *const Accumulator, net: *const Net) void {
        const hidden = net.hidden;
        copyHalf(&self.white, &parent.white, hidden);
        copyHalf(&self.black, &parent.black, hidden);
        if (net.full_threats) {
            // ZQB9: the separate threat halves + all PSQT scalars carry over (a null
            // move — the only copyFrom user — changes no pieces). The lean bitsets
            // tw/tb are unmaintained for full-threat nets: nothing to copy.
            copyHalf(&self.ftw, &parent.ftw, hidden);
            copyHalf(&self.ftb, &parent.ftb, hidden);
            self.psqt_tw = parent.psqt_tw;
            self.psqt_tb = parent.psqt_tb;
            self.psqt_hw = parent.psqt_hw;
            self.psqt_hb = parent.psqt_hb;
            return;
        }
        // threat rows live in white/black (copied above); carry the active-feature bitsets too.
        // A null move (the only copyFrom user) doesn't change the board, so threats are unchanged.
        copyPerspBits(&self.tw, &parent.tw);
        copyPerspBits(&self.tb, &parent.tb);
        // null-move copy: copy the full psqt arrays; null moves are ~1% of makes.
        self.psqt_tw = parent.psqt_tw;
        self.psqt_tb = parent.psqt_tb;
        self.psqt_hw = parent.psqt_hw;
        self.psqt_hb = parent.psqt_hb;
    }

    /// child = parent then apply the feature changes of `mv` (decoded from the
    /// move flag + make/unmake `state`). Must reproduce `refresh(pos_after)`.
    /// `pos` is the POST-move board (king squares already updated): when the mover's
    /// king moves, HalfKA re-indexes every feature for that perspective (bucket/flip
    /// change), so that perspective is fully refreshed from `pos`.
    /// `changes` is the move's already-decoded piece feature list (decodeMoveChanges):
    /// the materialization walk decodes it ONCE and hands the same buffer to this and
    /// to FullThreatState.advanceMove, which used to decode the identical list again.
    pub fn applyMove(self: *Accumulator, parent: *const Accumulator, net: *const Net, mv: move_mod.Move, state: *const make_unmake.StateInfo, pos: *const position.Position, finny: *FinnyTable, changes: []const Change) void {
        const wctx = perspCtx(net, .white, pos);
        const bctx = perspCtx(net, .black, pos);
        if (state.moved_piece.color().? == .white) {
            self.applyMoveColor(.white, net, mv, state, pos, wctx, bctx, parent, finny, changes);
        } else {
            self.applyMoveColor(.black, net, mv, state, pos, wctx, bctx, parent, finny, changes);
        }
    }

    /// `applyMove` specialised on the mover color so the opponent perspective is
    /// comptime-known. Gathers the move's piece feature changes once, then applies
    /// them per perspective: a king move that changes the mover's bucket/flip fully
    /// refreshes the mover perspective (never also edited); every other perspective
    /// updates incrementally via the fused `applyPersp` (parent + Σdeltas, one pass).
    inline fn applyMoveColor(
        self: *Accumulator,
        comptime mc: types.Color,
        net: *const Net,
        mv: move_mod.Move,
        state: *const make_unmake.StateInfo,
        pos: *const position.Position,
        wctx: PerspCtx,
        bctx: PerspCtx,
        parent: *const Accumulator,
        finny: *FinnyTable,
        changes: []const Change,
    ) void {
        const mctx = if (mc == .white) wctx else bctx; // mover's POST-move ctx
        const mpt = state.moved_piece.pieceType();
        const from = mv.from.index();
        // A king move only needs a full mover-perspective refresh if it crosses a
        // bucket or mirror-half boundary; otherwise it is a cheap 2-edit like any
        // piece (bucket/flip unchanged -> the incremental edits reproduce the
        // refresh exactly). Most mid-board king moves stay within a (coarse) bucket.
        const pre_kctx = if (mpt == .king) kingCtx(net, mc, from) else mctx;
        const mover_refresh = (mpt == .king) and (pre_kctx.bucket != mctx.bucket or pre_kctx.flip != mctx.flip);
        // Threat features are indexed under the perspective's MIRROR FLIP, so the parent
        // bitset is only reusable when the mover's flip is unchanged (bucket-only cross).
        const mover_flip_changed = (mpt == .king) and (pre_kctx.flip != mctx.flip);
        // The move's piece feature changes (identical for both perspectives; same
        // order as the old per-edit sequence), decoded once by the caller.
        const n = changes.len;
        if (mover_refresh) {
            // Opponent half FIRST (applyPersp overwrites it from the parent), so the
            // threat delta below can add the opponent's changed threat rows in place.
            const op = comptime mc.other();
            const octx = if (op == .white) wctx else bctx;
            self.applyPersp(net, op, octx, parent, changes[0..n]);
            if (net.threats and !net.full_threats) {
                const pb0 = net.psqt_buckets;
                if (pb0 == 1) {
                    self.psqt_tw[0] = parent.psqt_tw[0];
                    self.psqt_tb[0] = parent.psqt_tb[0];
                } else {
                    self.psqt_tw = parent.psqt_tw;
                    self.psqt_tb = parent.psqt_tb;
                }
                if (!mover_flip_changed) {
                    // BUCKET-ONLY cross (the common majority): threat indexing is
                    // flip-invariant here, so the child bitsets derive INCREMENTALLY —
                    // seed from the parent and run the same directThreatDelta as the
                    // common path. Replaces the full enumerateColors AND the opponent
                    // applyThreatBitsetDelta scan; the mover-half row pushes + psqt
                    // commit are superseded by finnyRefresh / the finny psqt_t below
                    // (wasted-but-correct). Bit-exact: same changed features, int adds.
                    copyPerspBits(&self.tw, &parent.tw);
                    copyPerspBits(&self.tb, &parent.tb);
                    if (net.threat_w8.len != 0)
                        directThreatDelta(i8, self, net, pos, changes[0..n], wctx.flip, bctx.flip)
                    else
                        directThreatDelta(i16, self, net, pos, changes[0..n], wctx.flip, bctx.flip);
                } else {
                    // FLIP changed: the mover's parent bitset lives in the OLD mirror
                    // index space — a full re-enumeration is required (both colours;
                    // the opponent's diff below is still parent-based and flip-valid).
                    threats_mod.enumerateColors(pos, &self.tw, &self.tb);
                    const opp_half = if (op == .white) &self.white else &self.black;
                    const opp_old = if (op == .white) &parent.tw else &parent.tb;
                    const opp_new = if (op == .white) &self.tw else &self.tb;
                    const opp_psqt = if (op == .white) &self.psqt_tw else &self.psqt_tb;
                    if (net.threat_w8.len != 0) {
                        applyThreatBitsetDelta(i8, opp_half, net, opp_old, opp_new, opp_psqt);
                    } else {
                        applyThreatBitsetDelta(i16, opp_half, net, opp_old, opp_new, opp_psqt);
                    }
                }
            }
            self.finnyRefresh(net, pos, mc, mctx, finny);
        } else {
            self.applyPerspDual(net, wctx, bctx, parent, changes[0..n]);
        }

        // ZQB5-8 LEAN threat delta (after HalfKA). ZQB9 full-threat nets skip all of
        // this: their threat state lives in the SEPARATE ftw/ftb halves + the shared
        // FullThreatState bitsets, maintained by the search backend's materialization
        // walk (ensureMaterialized -> FullThreatState.advanceMove) — never here.
        //  - mover perspective, if HalfKA was finny-REBUILT (threats lost): add the FULL threats;
        //  - otherwise (HalfKA was applyPersp'd, so parent threats are still present): apply only
        //    the parent->child bitset delta (add newly-set rows, sub newly-cleared rows).
        // The opponent perspective is always incremental (its HalfKA was applyPersp'd).
        if (net.threats and !net.full_threats) {
            const pb = net.psqt_buckets;
            if (mover_refresh) {
                // Threat rows + bitsets + opponent psqt were fully handled BEFORE
                // finnyRefresh (see above). Only the mover's threat-PSQT remains: take
                // the finny entry's cached sum (the dTD commit for the mover side was
                // parent-based and is superseded by the re-indexed entry).
                const slot = mctx.bucket * 2 + @as(usize, @intFromBool(mctx.flip != 0));
                const mover_psqt = if (mc == .white) &self.psqt_tw else &self.psqt_tb;
                mover_psqt.* = finny.sides[@intFromEnum(mc)][slot].psqt_t; // fixed-size, inlined
            } else {
                // COMMON: direct delta from the parent bitsets (no re-enumeration).
                // pb==1: two scalar moves. pb>1: FIXED-size whole-array copies (inline
                // vector moves) — runtime-length @memcpy of [0..pb] compiles to a library
                // call per array (+0.9pp memcpy in the pb=4 profile).
                if (pb == 1) {
                    self.psqt_tw[0] = parent.psqt_tw[0]; // delta perspectives carry the parent's threat-PSQT
                    self.psqt_tb[0] = parent.psqt_tb[0];
                } else {
                    self.psqt_tw = parent.psqt_tw;
                    self.psqt_tb = parent.psqt_tb;
                }
                copyPerspBits(&self.tw, &parent.tw);
                copyPerspBits(&self.tb, &parent.tb);
                if (net.threat_w8.len != 0)
                    directThreatDelta(i8, self, net, pos, changes[0..n], wctx.flip, bctx.flip)
                else
                    directThreatDelta(i16, self, net, pos, changes[0..n], wctx.flip, bctx.flip);
            }
        }

        // PSQT material head over the HalfKA features — maintained for BOTH threat
        // families (lean ZQB5-8 and full ZQB9; the threat-side PSQT is handled above
        // for lean nets and by FullThreatState for ZQB9).
        if (net.threats) {
            const pb = net.psqt_buckets;
            // HalfKA-PSQT delta from the move's piece change-list; the finny-rebuilt mover
            // perspective re-indexed every feature, so recompute it from the pieces instead.
            if (pb == 1) {
                self.psqt_hw[0] = parent.psqt_hw[0];
                self.psqt_hb[0] = parent.psqt_hb[0];
            } else {
                self.psqt_hw = parent.psqt_hw;
                self.psqt_hb = parent.psqt_hb;
            }
            // pb-aware zeroing: pb==1 nets (all shipped) only ever touch [0] via the
            // addPsqtVecRaw fast path -- zeroing all MAX_BUCKETS lanes was ~256B of
            // dead stores per make (memset showed in the profile).
            var hw_delta: [MAX_BUCKETS]i64 = undefined;
            var hb_delta: [MAX_BUCKETS]i64 = undefined;
            if (pb == 1) {
                hw_delta[0] = 0;
                hb_delta[0] = 0;
            } else {
                @memset(&hw_delta, 0);
                @memset(&hb_delta, 0);
            }
            for (changes[0..n]) |c| {
                const wi = halfkaIndex(.white, wctx, c.color, c.pt, c.sq);
                const bi = halfkaIndex(.black, bctx, c.color, c.pt, c.sq);
                if (c.add) {
                    addPsqtVecRaw(&hw_delta, net, wi, true);
                    addPsqtVecRaw(&hb_delta, net, bi, true);
                } else {
                    addPsqtVecRaw(&hw_delta, net, wi, false);
                    addPsqtVecRaw(&hb_delta, net, bi, false);
                }
            }
            for (0..net.psqt_buckets) |b| {
                self.psqt_hw[b] += hw_delta[b];
                self.psqt_hb[b] += hb_delta[b];
            }
            if (mover_refresh) {
                // The finny entry's HalfKA-PSQT sum is over exactly this frame's
                // current pieces (diff-maintained alongside `acc`), so it equals
                // what sumHalfkaPsqt would recompute — same weights, i64 adds in a
                // different order, hence bit-identical — without the 32-piece scan.
                // Supersedes the parent-based delta committed just above (the mover
                // perspective re-indexed every feature).
                const mslot = mctx.bucket * 2 + @as(usize, @intFromBool(mctx.flip != 0));
                const mover_h = if (mc == .white) &self.psqt_hw else &self.psqt_hb;
                mover_h.* = finny.sides[@intFromEnum(mc)][mslot].psqt_h;
            }
        }
    }
};

fn enPassantCapturedSquare(side: types.Color, destination: square.Square) square.Square {
    return switch (side) {
        .white => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) - 1)),
        .black => square.Square.fromCoords(destination.file(), @intCast(@as(u8, destination.rank()) + 1)),
    };
}

fn castleRookSquares(side: types.Color, king_destination: square.Square) struct { from: u6, to: u6 } {
    return switch (side) {
        .white => switch (king_destination) {
            .g1 => .{ .from = square.Square.h1.index(), .to = square.Square.f1.index() },
            .c1 => .{ .from = square.Square.a1.index(), .to = square.Square.d1.index() },
            else => unreachable,
        },
        .black => switch (king_destination) {
            .g8 => .{ .from = square.Square.h8.index(), .to = square.Square.f8.index() },
            .c8 => .{ .from = square.Square.a8.index(), .to = square.Square.d8.index() },
            else => unreachable,
        },
    };
}

/// Vectorized `sum_i screlu(xs[i]) * ws[i]` (one accumulator half). Bit-exact with
/// the scalar `screlu(x)*ow`: clamp[0,qa] then square fits i32 (qa<=255 -> <=65025),
/// and screlu^2 * |ow| stays within i32 for trained nets (ow ~ qb-scaled); products
/// widen to i64 before the reduction, so the integer sum is order-independent/exact.
/// `sum_i screlu(us[i])*ow[i] + sum_i screlu(them[i])*ow[h+i]` over both accumulator
/// halves in ONE fused pass (interleaved for ILP via two independent accumulators).
/// Per-lane sums accumulate in i32 and widen to i64 ONCE at the end: the loader
/// guarantees (h/VEC)*qa^2*max|ow| < 2^31 (see `evalI32Safe`), so no i32 overflow ->
/// bit-exact with per-product i64 accumulation, but without the per-chunk i64 widen+add.
inline fn screluDotPair(us: []const i16, them: []const i16, ow: []const i16, qa: i32) i64 {
    const V = VEC;
    const h = us.len;
    const qa_v: @Vector(V, i32) = @splat(qa);
    const zero_v: @Vector(V, i32) = @splat(@as(i32, 0));
    var au0: @Vector(V, i32) = @splat(@as(i32, 0));
    var au1: @Vector(V, i32) = @splat(@as(i32, 0));
    var at0: @Vector(V, i32) = @splat(@as(i32, 0));
    var at1: @Vector(V, i32) = @splat(@as(i32, 0));
    var i: usize = 0;
    // 2x-unrolled: 4 independent accumulator chains hide the vpmulld (square/multiply)
    // latency (the eval bottleneck). au0/au1 sum disjoint chunk sets; au0+au1 == the
    // single-accumulator sum (integer add associative) and stays < 2^31 (evalI32Safe),
    // so still bit-exact with the original.
    while (i + 2 * V <= h) : (i += 2 * V) {
        const uc0 = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), us[i..][0..V].*)), zero_v), qa_v);
        au0 += (uc0 * uc0) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[i..][0..V].*));
        const uc1 = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), us[i + V ..][0..V].*)), zero_v), qa_v);
        au1 += (uc1 * uc1) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[i + V ..][0..V].*));
        const tc0 = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), them[i..][0..V].*)), zero_v), qa_v);
        at0 += (tc0 * tc0) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[h + i ..][0..V].*));
        const tc1 = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), them[i + V ..][0..V].*)), zero_v), qa_v);
        at1 += (tc1 * tc1) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[h + i + V ..][0..V].*));
    }
    while (i + V <= h) : (i += V) {
        const ucl = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), us[i..][0..V].*)), zero_v), qa_v);
        au0 += (ucl * ucl) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[i..][0..V].*));
        const tcl = @min(@max(@as(@Vector(V, i32), @as(@Vector(V, i16), them[i..][0..V].*)), zero_v), qa_v);
        at0 += (tcl * tcl) * @as(@Vector(V, i32), @as(@Vector(V, i16), ow[h + i ..][0..V].*));
    }
    var total: i64 = @reduce(.Add, @as(@Vector(V, i64), au0 + au1)) + @reduce(.Add, @as(@Vector(V, i64), at0 + at1));
    while (i < h) : (i += 1) {
        const u: i64 = std.math.clamp(@as(i32, us[i]), 0, qa);
        total += u * u * @as(i64, ow[i]);
        const t: i64 = std.math.clamp(@as(i32, them[i]), 0, qa);
        total += t * t * @as(i64, ow[h + i]);
    }
    return total;
}

/// True if i32 per-lane accumulation in `screluDotPair` cannot overflow for this net:
/// each of the (h/VEC) chunks adds one product <= qa^2*max|ow| per lane. The loader
/// rejects nets that fail this (would need |ow| > ~258 at h=2048 — untrainable at qb).
fn evalI32Safe(hidden: usize, qa: i32, output_weights: []const i16) bool {
    var max_ow: i64 = 0;
    for (output_weights) |w| max_ow = @max(max_ow, @as(i64, @intCast(@abs(@as(i32, w)))));
    const chunks: i64 = @intCast(hidden / VEC);
    return chunks * @as(i64, qa) * @as(i64, qa) * max_ow < (1 << 31);
}

/// Output layer only, from a maintained accumulator (the hot search path).
/// `piece_count` (total occupancy popcount) selects the output bucket.
pub fn evaluateAcc(net: *const Net, acc: *const Accumulator, stm: types.Color, piece_count: usize, scale_percent: u16) i32 {
    if (net.multilayer) return evaluateAccMulti(net, acc, stm, piece_count, scale_percent);
    const h = net.hidden;
    const bucket = net.bucketIndex(piece_count);
    const ow = net.output_weights[bucket * 2 * h ..][0 .. 2 * h];
    const us = if (stm == .white) &acc.white else &acc.black;
    const them = if (stm == .white) &acc.black else &acc.white;
    var out: i64 = screluDotPair(us[0..h], them[0..h], ow, net.qa);
    out = @divTrunc(out, net.qa);
    out += net.output_biases[bucket];
    out *= net.scale;
    out = @divTrunc(out, @as(i64, net.qa) * @as(i64, net.qb));
    if (scale_percent != 100) out = @divTrunc(out * @as(i64, scale_percent), 100);
    return @intCast(out);
}

/// Full-refresh evaluate (refresh + output). The reference for tests and the
/// root; the search uses incremental accumulators via `evaluateAcc`.
pub fn evaluate(net: *const Net, pos: *const position.Position, scale_percent: u16) i32 {
    if (net.full_threats) return evaluateFull9(net, pos, scale_percent);
    if (net.threats) return evaluateThreats(net, pos, scale_percent);
    var acc: Accumulator = undefined;
    acc.refresh(net, pos);
    return evaluateAcc(net, &acc, pos.side_to_move, @popCount(pos.occupancy()), scale_percent);
}

/// Add the threat feature rows of ONE perspective's active-feature bitset into that
/// perspective's accumulator half, and (for the stm half) sum the PSQT material
/// weights of those threat features. Threat feature `idx` lives at feature row
/// `halfka_inputs + idx` (threats share the HalfKA accumulator). `bits` is a
/// word-slice so the same code serves the lean set (threats_mod.PerspBits, ZQB5-8)
/// and the full set (fullthreats_mod.PerspBits, ZQB9).
fn addThreatRows(comptime T: type, half: *[MAX_HIDDEN]i16, net: *const Net, bits: []const u64, psqt: *[MAX_BUCKETS]i64, comptime collect_psqt: bool) void {
    const h = net.hidden;
    const base = net.king_buckets * INPUTS; // HalfKA feature count == where the threat block starts
    for (bits, 0..) |word0, w| {
        var word = word0;
        while (word != 0) {
            const bit: usize = @ctz(word);
            word &= word - 1;
            const tidx = w * 64 + bit;
            const row = threatRowT(T, net, tidx);
            var i: usize = 0;
            while (i + VEC16 <= h) : (i += VEC16) {
                const rv: @Vector(VEC16, T) = row[i..][0..VEC16].*;
                const wv: @Vector(VEC16, i16) = if (T == i16) rv else @as(@Vector(VEC16, i16), rv);
                var av: @Vector(VEC16, i16) = half[i..][0..VEC16].*;
                // Deliberately NON-wrapping (canonical-order reference path): a Debug
                // overflow trap means the net is not i16-safe — see editAcc.
                av = av + wv;
                half[i..][0..VEC16].* = av;
            }
            while (i < h) : (i += 1) half[i] += @as(i16, row[i]);
            if (collect_psqt) addPsqtVecRaw(psqt, net, base + tidx, true);
        }
    }
}

/// Full-refresh evaluate for a ZQB5 (HalfKA + lean threats + PSQT) net — the M1
/// non-incremental reference. Rebuilds both accumulators from scratch (HalfKA rows +
/// deduped threat rows), sums the linear PSQT material head over the stm features, and
/// adds it to the readout: eval = readout + round(psqt * scale), all before scale_percent.
fn evaluateThreats(net: *const Net, pos: *const position.Position, scale_percent: u16) i32 {
    const h = net.hidden;
    const stm = pos.side_to_move;
    var acc: Accumulator = undefined;
    var psqt_vec: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS;
    // HalfKA rows (both perspectives) + stm PSQT over HalfKA features.
    inline for (.{ types.Color.white, types.Color.black }) |persp| {
        const a = if (persp == .white) &acc.white else &acc.black;
        for (0..h) |i| a[i] = net.feature_bias[i];
        const ctx = Accumulator.perspCtx(net, persp, pos);
        var occ = pos.occupancy();
        while (bitboard.popLsb(&occ)) |sq| {
            const p = pos.pieceAt(sq);
            const color = p.color() orelse continue;
            const sidx = sq.index();
            editAcc(a, net, persp, ctx, color, p.pieceType(), sidx, true);
            if (persp == stm) addPsqtVecRaw(&psqt_vec, net, halfkaIndex(persp, ctx, color, p.pieceType(), sidx), true);
        }
    }
    // Threat rows (both perspectives) + stm PSQT over threat features.
    var tf: threats_mod.ThreatFeatures = .{};
    threats_mod.enumerate(pos, &tf);
    const stm_half = if (stm == .white) &acc.white else &acc.black;
    const ntm_half = if (stm == .white) &acc.black else &acc.white;
    var unused: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS;
    if (net.threat_w8.len != 0) {
        addThreatRows(i8, stm_half, net, &tf.stm, &psqt_vec, true);
        addThreatRows(i8, ntm_half, net, &tf.ntm, &unused, false);
    } else {
        addThreatRows(i16, stm_half, net, &tf.stm, &psqt_vec, true);
        addThreatRows(i16, ntm_half, net, &tf.ntm, &unused, false);
    }
    const pc: usize = @popCount(pos.occupancy());
    const pbkt = if (net.psqt_buckets > 1) net.bucketIndex(pc) else 0;
    const psqt = net.psqtb[pbkt] + psqt_vec[pbkt];
    // ZQB8 dispatches to the layerstack finisher (same maintained inputs, deeper readout).
    if (net.multilayer) return finishThreatsEvalMulti(net, &acc, stm, pc, psqt, scale_percent);
    return finishThreatsEval(net, &acc, stm, pc, psqt, scale_percent);
}

/// Full-refresh evaluate for a ZQB9 (HalfKA + FULL threats + PSQT + SFNNv5 layerstack)
/// net — the v6 non-incremental reference, mirroring `evaluateThreats`. Rebuilds both
/// perspective accumulators from scratch: HalfKA rows (the refreshPersp math, no
/// lean-threat rows) plus one i8 row (widened to i16) per active full-threat feature
/// from `fullthreats.enumerateColors`, and the Q20 PSQT head summed over the stm
/// perspective's HalfKA + threat features (threat PSQT indices offset by the HalfKA
/// input count, same convention as the lean path). Readout = the shared layerstack
/// finisher. The search-side incremental path is Block B (docs/V6_INCREMENTAL_DESIGN.md);
/// until it lands, ZQB9 nets evaluate through this full refresh only.
fn evaluateFull9(net: *const Net, pos: *const position.Position, scale_percent: u16) i32 {
    const h = net.hidden;
    const stm = pos.side_to_move;
    var acc: Accumulator = undefined;
    var psqt_vec: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS;
    // HalfKA rows (both perspectives) + stm PSQT over HalfKA features.
    inline for (.{ types.Color.white, types.Color.black }) |persp| {
        const a = if (persp == .white) &acc.white else &acc.black;
        for (0..h) |i| a[i] = net.feature_bias[i];
        const ctx = Accumulator.perspCtx(net, persp, pos);
        var occ = pos.occupancy();
        while (bitboard.popLsb(&occ)) |sq| {
            const p = pos.pieceAt(sq);
            const color = p.color() orelse continue;
            const sidx = sq.index();
            editAcc(a, net, persp, ctx, color, p.pieceType(), sidx, true);
            if (persp == stm) addPsqtVecRaw(&psqt_vec, net, halfkaIndex(persp, ctx, color, p.pieceType(), sidx), true);
        }
    }
    // Full-threat rows (both COLOUR perspectives — the accumulator halves are
    // colour-anchored) + stm PSQT over the stm perspective's threat features.
    var wbits: fullthreats_mod.PerspBits = undefined;
    var bbits: fullthreats_mod.PerspBits = undefined;
    fullthreats_mod.enumerateColors(pos, &wbits, &bbits);
    var unused: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS;
    if (stm == .white) {
        addThreatRows(i8, &acc.white, net, &wbits, &psqt_vec, true);
        addThreatRows(i8, &acc.black, net, &bbits, &unused, false);
    } else {
        addThreatRows(i8, &acc.black, net, &bbits, &psqt_vec, true);
        addThreatRows(i8, &acc.white, net, &wbits, &unused, false);
    }
    const pc: usize = @popCount(pos.occupancy());
    const pbkt = if (net.psqt_buckets > 1) net.bucketIndex(pc) else 0;
    const psqt = net.psqtb[pbkt] + psqt_vec[pbkt];
    // ZQB9 is always a layerstack net (same body as ZQB8).
    return finishThreatsEvalMulti(net, &acc, stm, pc, psqt, scale_percent);
}

/// Shared output tail: readout (integer path, identical to evaluateAcc) + the PSQT
/// material head (round(psqt*scale)), then scale_percent. Used by both threats paths.
fn finishThreatsEval(net: *const Net, acc: *const Accumulator, stm: types.Color, piece_count: usize, psqt: i64, scale_percent: u16) i32 {
    const h = net.hidden;
    const bucket = net.bucketIndex(piece_count);
    const ow = net.output_weights[bucket * 2 * h ..][0 .. 2 * h];
    const us = if (stm == .white) &acc.white else &acc.black;
    const them = if (stm == .white) &acc.black else &acc.white;
    var out: i64 = screluDotPair(us[0..h], them[0..h], ow, net.qa);
    out = @divTrunc(out, net.qa);
    out += net.output_biases[bucket];
    out *= net.scale;
    out = @divTrunc(out, @as(i64, net.qa) * @as(i64, net.qb));
    // round(psqt * scale / 2^Q), half away from zero — the Q20 integer image of the
    // old f64 @round(psqt * scale).
    const num: i64 = psqt * net.scale;
    const half_q: i64 = @as(i64, 1) << (PSQT_Q - 1);
    out += if (num >= 0) (num + half_q) >> PSQT_Q else -((-num + half_q) >> PSQT_Q);
    if (scale_percent != 100) out = @divTrunc(out * @as(i64, scale_percent), 100);
    return @intCast(out);
}

/// Add (sign=+1) or subtract one feature's per-bucket PSQT weights into the maintained
/// per-bucket scalars. The weights for a feature are CONTIGUOUS (layout [feat*pb + b]).
inline fn addPsqtVecRaw(dst: *[MAX_BUCKETS]i64, net: *const Net, feat: usize, comptime add: bool) void {
    const pb = net.psqt_buckets;
    if (pb == 1) {
        // Fast path for single-head nets (ZQB5/6): the old scalar add, one branch.
        const w: i64 = net.psqtw[feat];
        if (add) dst[0] += w else dst[0] -= w;
        return;
    }
    // Fixed-width vector path for bucketed heads: ONE MAX_BUCKETS-wide load + widen +
    // add regardless of pb (the psqtw allocation is padded by MAX_BUCKETS so the load
    // never overreads; lanes >= pb accumulate garbage that no commit ever reads —
    // every consumer copies/commits [0..pb] only). Replaces the scalar loop that
    // dominated the measured ~7% pb=4 tax.
    const wv: @Vector(MAX_BUCKETS, i32) = net.psqtw[feat * pb ..][0..MAX_BUCKETS].*;
    const wide: @Vector(MAX_BUCKETS, i64) = wv;
    var acc: @Vector(MAX_BUCKETS, i64) = dst.*;
    acc = if (add) acc + wide else acc - wide;
    dst.* = acc;
}

/// Sum the PSQT material weights over `persp`'s active HalfKA features (scalar lookups,
/// no accumulator row-adds) — the HalfKA part of the PSQT head (threats add their own).
fn sumHalfkaPsqt(net: *const Net, comptime persp: types.Color, pos: *const position.Position, out: *[MAX_BUCKETS]i64) void {
    out.* = [_]i64{0} ** MAX_BUCKETS;
    const ctx = Accumulator.perspCtx(net, persp, pos);
    var occ = pos.occupancy();
    while (bitboard.popLsb(&occ)) |sq| {
        const p = pos.pieceAt(sq);
        const color = p.color() orelse continue;
        addPsqtVecRaw(out, net, halfkaIndex(persp, ctx, color, p.pieceType(), sq.index()), true);
    }
}

// ---- ZQB5 incremental threat maintenance (the search/deploy path) ----

/// One threat feature row, typed by the net's threat weight storage: i16 rows live in
/// `feature_weights` after the HalfKA block (ZQB5); i8 rows in the separate `threat_w8`
/// (ZQB6 — half the row bytes, widened to i16 at apply). `feat` is the THREAT-relative
/// index (leanIndex). The PSQT weight for it is `psqtw[king_buckets*INPUTS + feat]` —
/// psqtw spans HalfKA+threat features in both formats.
inline fn threatRowT(comptime T: type, net: *const Net, feat: usize) []const T {
    const h = net.hidden;
    return if (T == i8)
        net.threat_w8[feat * h ..][0..h]
    else
        net.feature_weights[(net.king_buckets * INPUTS + feat) * h ..][0..h];
}

/// Deferred threat row-adds for ONE perspective half: toggles collect row slices here
/// and `flush` applies them all in a single fused accumulator pass (1 read + 1 write of
/// the half instead of one RMW per row — the row-add bucket is memory-traffic-bound).
/// Wrapping ops: integer add/sub commute mod 2^16 and the final accumulator is i16-safe,
/// so the fused result is bit-exact with the sequential per-row applies it replaces.
/// Generic over the row weight type (i16 for ZQB5, i8 for ZQB6 — widened per chunk).
fn PendingThreatRowsT(comptime T: type) type {
    return struct {
        const Self = @This();
        const MAX = 32;
        adds: [MAX][]const T = undefined,
        subs: [MAX][]const T = undefined,
        na: usize = 0,
        ns: usize = 0,

        /// Empty-init WITHOUT `.{}`: only the counts are meaningful state (the
        /// adds/subs slice arrays are always written before read), but a `.{}`
        /// init zero-fills the whole 1040-byte struct — measured as two memset
        /// calls (~2KB of dead stack stores) per applyDeltaToChild, i.e. per
        /// materialized move. Callers declare the struct `undefined` and call
        /// this instead.
        inline fn initEmpty(self: *Self) void {
            self.na = 0;
            self.ns = 0;
        }

        inline fn widen(v: @Vector(VEC16, T)) @Vector(VEC16, i16) {
            return if (T == i16) v else @as(@Vector(VEC16, i16), v);
        }

        inline fn pushAdd(self: *Self, half: *[MAX_HIDDEN]i16, h: usize, row: []const T) void {
            // Overflow flush is COLD (32 pending rows mid-delta): keep it an out-of-line
            // call so the big fused-pass body never inlines into the push sites.
            if (self.na == MAX) @call(.never_inline, flush, .{ self, half, h });
            self.adds[self.na] = row;
            self.na += 1;
        }

        inline fn pushSub(self: *Self, half: *[MAX_HIDDEN]i16, h: usize, row: []const T) void {
            if (self.ns == MAX) @call(.never_inline, flush, .{ self, half, h });
            self.subs[self.ns] = row;
            self.ns += 1;
        }

        fn flush(self: *Self, half: *[MAX_HIDDEN]i16, h: usize) void {
            if (self.na == 0 and self.ns == 0) return;
            self.flushInto(half, half, h);
        }

        /// dst = src + pending adds - pending subs in ONE fused pass (dst may alias
        /// src — that is exactly `flush`). With dst != src this fuses a parent->child
        /// half COPY into the flush: read src + row adds + write dst, replacing the
        /// copyHalf-then-flush 2-pass scheme (which read+wrote dst twice). The loads
        /// read the same values the copy would have staged and the add order is
        /// unchanged -> bit-exact. Unlike flush, no early return: with zero pending
        /// rows this must still perform the copy. Resets the pending counts.
        fn flushInto(self: *Self, dst: *[MAX_HIDDEN]i16, src: *const [MAX_HIDDEN]i16, h: usize) void {
            var i: usize = 0;
            // 8-wide chunk unroll: 8 accumulator vectors stay live across the row loop,
            // so each row iteration does 8 loads+adds per loop-overhead set (vs 1 in the
            // naive nesting — the overhead tripled the op count) and the row pointer is
            // loaded once per row per super-chunk. h=768 at VEC16=32 -> 3 super-chunks.
            const U = 8;
            while (i + U * VEC16 <= h) : (i += U * VEC16) {
                var acc: [U]@Vector(VEC16, i16) = undefined;
                inline for (0..U) |u| acc[u] = src[i + u * VEC16 ..][0..VEC16].*;
                for (self.adds[0..self.na]) |row| {
                    inline for (0..U) |u| acc[u] +%= widen(row[i + u * VEC16 ..][0..VEC16].*);
                }
                for (self.subs[0..self.ns]) |row| {
                    inline for (0..U) |u| acc[u] -%= widen(row[i + u * VEC16 ..][0..VEC16].*);
                }
                inline for (0..U) |u| dst[i + u * VEC16 ..][0..VEC16].* = acc[u];
            }
            while (i + VEC16 <= h) : (i += VEC16) {
                var av: @Vector(VEC16, i16) = src[i..][0..VEC16].*;
                for (self.adds[0..self.na]) |row| av +%= widen(row[i..][0..VEC16].*);
                for (self.subs[0..self.ns]) |row| av -%= widen(row[i..][0..VEC16].*);
                dst[i..][0..VEC16].* = av;
            }
            while (i < h) : (i += 1) {
                var v = src[i];
                for (self.adds[0..self.na]) |row| v +%= @as(i16, row[i]);
                for (self.subs[0..self.ns]) |row| v -%= @as(i16, row[i]);
                dst[i] = v;
            }
            self.na = 0;
            self.ns = 0;
        }

        /// Push variants for the copy-fused pattern (applyDeltaToChild): rows collect
        /// against a SOURCE half (`src.*`, initially the parent) that differs from
        /// `dst` (the child) until the first flush. The overflow flush is COLD (>MAX
        /// pending one direction mid-delta; never observed — mean churn ~14): it
        /// materializes dst = src + pending early and redirects src to dst, after
        /// which further flushes are dst-in-place exactly like flush.
        inline fn pushAddFrom(self: *Self, dst: *[MAX_HIDDEN]i16, src: **const [MAX_HIDDEN]i16, h: usize, row: []const T) void {
            if (self.na == MAX) {
                @call(.never_inline, flushInto, .{ self, dst, src.*, h });
                src.* = dst;
            }
            self.adds[self.na] = row;
            self.na += 1;
        }

        inline fn pushSubFrom(self: *Self, dst: *[MAX_HIDDEN]i16, src: **const [MAX_HIDDEN]i16, h: usize, row: []const T) void {
            if (self.ns == MAX) {
                @call(.never_inline, flushInto, .{ self, dst, src.*, h });
                src.* = dst;
            }
            self.subs[self.ns] = row;
            self.ns += 1;
        }

        /// flushInto with TWO destinations: dst_a and dst_b both receive
        /// src + adds - subs from the same single fused pass (dst_a may alias
        /// src — chunks are read before either store). Fuses a cache-entry
        /// update (dst_a, in place) with the entry->consumer copy (dst_b),
        /// replacing flush-then-copyHalf's extra full read+write of the half.
        /// Same adds, dst_b = a copy of the final dst_a values -> bit-exact.
        /// No early return (the copy must always run). Resets pending counts.
        fn flushIntoDual(self: *Self, dst_a: *[MAX_HIDDEN]i16, dst_b: *[MAX_HIDDEN]i16, src: *const [MAX_HIDDEN]i16, h: usize) void {
            var i: usize = 0;
            const U = 8;
            while (i + U * VEC16 <= h) : (i += U * VEC16) {
                var acc: [U]@Vector(VEC16, i16) = undefined;
                inline for (0..U) |u| acc[u] = src[i + u * VEC16 ..][0..VEC16].*;
                for (self.adds[0..self.na]) |row| {
                    inline for (0..U) |u| acc[u] +%= widen(row[i + u * VEC16 ..][0..VEC16].*);
                }
                for (self.subs[0..self.ns]) |row| {
                    inline for (0..U) |u| acc[u] -%= widen(row[i + u * VEC16 ..][0..VEC16].*);
                }
                inline for (0..U) |u| dst_a[i + u * VEC16 ..][0..VEC16].* = acc[u];
                inline for (0..U) |u| dst_b[i + u * VEC16 ..][0..VEC16].* = acc[u];
            }
            while (i + VEC16 <= h) : (i += VEC16) {
                var av: @Vector(VEC16, i16) = src[i..][0..VEC16].*;
                for (self.adds[0..self.na]) |row| av +%= widen(row[i..][0..VEC16].*);
                for (self.subs[0..self.ns]) |row| av -%= widen(row[i..][0..VEC16].*);
                dst_a[i..][0..VEC16].* = av;
                dst_b[i..][0..VEC16].* = av;
            }
            while (i < h) : (i += 1) {
                var v = src[i];
                for (self.adds[0..self.na]) |row| v +%= @as(i16, row[i]);
                for (self.subs[0..self.ns]) |row| v -%= @as(i16, row[i]);
                dst_a[i] = v;
                dst_b[i] = v;
            }
            self.na = 0;
            self.ns = 0;
        }
    };
}

/// Add every set threat feature's row into `half` (full threats — refresh / finny rebuild),
/// accumulating the threat-PSQT material into `psqt`. Rows are applied in fused batches.
/// `bits` is a word slice so the same code serves the lean bitsets (ZQB5-8) and the
/// full-threat bitsets (ZQB9) — the feature index is the bit position either way.
fn addThreatBitsetRows(comptime T: type, half: *[MAX_HIDDEN]i16, net: *const Net, bits: []const u64, psqt: *[MAX_BUCKETS]i64) void {
    const h = net.hidden;
    const base = net.king_buckets * INPUTS; // threat block starts at the HalfKA feature count
    var pending: PendingThreatRowsT(T) = undefined;
    pending.initEmpty();
    for (bits, 0..) |word0, w| {
        var word = word0;
        while (word != 0) {
            const bit: usize = @ctz(word);
            word &= word - 1;
            const tidx = w * 64 + bit;
            pending.pushAdd(half, h, threatRowT(T, net, tidx));
            addPsqtVecRaw(psqt, net, base + tidx, true);
        }
    }
    pending.flush(half, h);
}

/// Apply the parent->child threat bitset delta to `half` (add newly-set rows, sub newly-cleared
/// rows) and the matching threat-PSQT delta to `psqt`. XOR finds the changed features; rows
/// are applied in one fused batch. `old_bits`/`new_bits` are word slices (same length) so the
/// same code serves the lean bitsets (ZQB5-8 finny) and the full-threat bitsets (ZQB9 barrier
/// rebuilds + the flip cache).
fn applyThreatBitsetDelta(comptime T: type, half: *[MAX_HIDDEN]i16, net: *const Net, old_bits: []const u64, new_bits: []const u64, psqt: *[MAX_BUCKETS]i64) void {
    applyThreatBitsetDeltaInto(T, half, half, null, net, old_bits, new_bits, psqt);
}

/// applyThreatBitsetDelta with the surrounding half COPIES fused into its single
/// row pass (perf-r4, the barrier-path twin of applyDeltaToChild's flushInto):
///   - `src` != `dst`: the caller's `copyHalf(dst, src)` + in-place diff becomes
///     one read-src / add-rows / write-dst pass (rebuildPersp's flip-unchanged
///     perspective, which copied the parent half and then re-read+rewrote it).
///   - `also` != null: a SECOND destination receives the same final values from
///     the same pass (rebuildPersp's flip cache: the slot is updated in place and
///     copied to the child half — flushIntoDual replaces that extra read+write).
/// Row order and the integer add order are unchanged, so every result is
/// bit-identical to the copy-then-diff form it replaces.
fn applyThreatBitsetDeltaInto(
    comptime T: type,
    dst: *[MAX_HIDDEN]i16,
    src0: *const [MAX_HIDDEN]i16,
    also: ?*[MAX_HIDDEN]i16,
    net: *const Net,
    old_bits: []const u64,
    new_bits: []const u64,
    psqt: *[MAX_BUCKETS]i64,
) void {
    const h = net.hidden;
    const base = net.king_buckets * INPUTS;
    const half = dst;
    var src: *const [MAX_HIDDEN]i16 = src0;
    const in_place = @intFromPtr(src0) == @intFromPtr(dst);
    var pending: PendingThreatRowsT(T) = undefined;
    pending.initEmpty();
    // accumulate the PSQT delta locally; commit once (same rationale as directThreatDelta)
    var psqt_local: [MAX_BUCKETS]i64 = [_]i64{0} ** MAX_BUCKETS;
    // The XOR scan is SKIP-SCANNED in SIMD chunks (perf-r4). The full-threat
    // bitsets are 940 words but only a handful of them ever differ (a plain
    // move's pre/post diff is ~14 bits; even a flip-cache diff touches well
    // under a tenth of the words), so the scalar word-at-a-time loop spent
    // ~55% of this function's time on `o ^ nw == 0` words. A chunk whose XOR
    // is entirely zero is skipped with one vector compare. Word order, bit
    // order and therefore the pending row ORDER are unchanged -> bit-exact
    // (not merely order-insensitive).
    const VW = std.simd.suggestVectorLength(u64) orelse 2;
    var w: usize = 0;
    while (w < old_bits.len) {
        // Skip whole all-equal chunks with one vector compare each.
        while (w + VW <= old_bits.len) {
            const ov: @Vector(VW, u64) = old_bits[w..][0..VW].*;
            const nv: @Vector(VW, u64) = new_bits[w..][0..VW].*;
            if (@reduce(.Or, ov ^ nv) != 0) break;
            w += VW;
        }
        if (w >= old_bits.len) break;
        // One chunk (or the sub-chunk tail) word by word — the only copy of the body.
        const end = @min(w + VW, old_bits.len);
        while (w < end) : (w += 1) {
            const o = old_bits[w];
            const nw = new_bits[w];
            const changed = o ^ nw;
            if (changed == 0) continue;
            var added = changed & nw;
            while (added != 0) {
                const bit: usize = @ctz(added);
                added &= added - 1;
                const tidx = w * 64 + bit;
                pending.pushAddFrom(half, &src, h, threatRowT(T, net, tidx));
                addPsqtVecRaw(&psqt_local, net, base + tidx, true);
            }
            var removed = changed & o;
            while (removed != 0) {
                const bit: usize = @ctz(removed);
                removed &= removed - 1;
                const tidx = w * 64 + bit;
                pending.pushSubFrom(half, &src, h, threatRowT(T, net, tidx));
                addPsqtVecRaw(&psqt_local, net, base + tidx, false);
            }
        }
    }
    if (also) |dst_b| {
        // Both destinations must always be written (dst_b is a copy target).
        pending.flushIntoDual(half, dst_b, src, h);
    } else if (in_place and pending.na == 0 and pending.ns == 0) {
        // Pure in-place with nothing pending: the old `flush` early-out — no copy owed.
    } else {
        pending.flushInto(half, src, h);
    }
    for (0..net.psqt_buckets) |b| psqt[b] += psqt_local[b];
}

// ---- Direct threat delta (no per-move re-enumeration) ----

/// Forward attack bitboard of a threat-source piece type (king is not a source).
fn threatAttackBB(pt: piece.PieceType, color: types.Color, sq: square.Square, occ: bitboard.Bitboard) bitboard.Bitboard {
    return switch (pt) {
        .pawn => attacks.pawnAttacksFrom(color, sq),
        .knight => attacks.knightAttacksFrom(sq),
        .bishop => attacks.bishopAttacksDirect(sq, occ),
        .rook => attacks.rookAttacksDirect(sq, occ),
        .queen => attacks.queenAttacksDirect(sq, occ),
        else => 0,
    };
}

/// leanIndex(ak, t, r) = ak*AK_STRIDE + (t*NUM_ATTACKED_REL + r): a (target, rel) GROUP's
/// 10 features (one per attacker key) share ONE in-word bit position and sit at word
/// stride AK_WORDS in the perspective bitset — the group is register-maskable.
const AK_STRIDE: usize = 64 * threats_mod.NUM_ATTACKED_REL; // 768
const AK_WORDS: usize = AK_STRIDE / 64; // 12
comptime {
    std.debug.assert(threats_mod.leanIndex(1, 0, 0) == AK_STRIDE);
    std.debug.assert(threats_mod.NUM_ATTACKER_KEYS * AK_WORDS <= threats_mod.WORDS);
}

/// Gather one (target, rel) group's stored bits — features ak*AK_STRIDE + fbase for
/// ak in [0, 10) — into a 10-bit register mask (bit ak). The 10 loads are independent
/// (same shift count, fixed word stride): pure ILP, zero branches.
inline fn gatherThreatGroup(bits: *const threats_mod.PerspBits, fbase: usize) u32 {
    const w = fbase >> 6;
    const b: u6 = @intCast(fbase & 63);
    var m: u32 = 0;
    inline for (0..threats_mod.NUM_ATTACKER_KEYS) |ak| {
        var bit: u64 = (bits[ak * AK_WORDS + w] >> b) & 1;
        // Zero-cost SLP barrier: without it LLVM fuses the 10 extracts into a
        // vpgatherqq zmm + ~20 uops of vector address setup — slower than 10
        // independent scalar L1 loads whose word offsets fold into displacements.
        asm volatile (""
            : [bit] "+r" (bit),
        );
        m |= @as(u32, @intCast(bit)) << ak;
    }
    return m;
}

/// Toggle one threat feature KNOWN to change (bit `ak` of the group at `fbase`): flip the
/// bitset bit, queue the row add/sub, update the PSQT sum. The did-it-change test already
/// happened in register mask space — no per-feature memory probe or branch here.
inline fn toggleThreatFeature(comptime T: type, comptime add: bool, bits: *threats_mod.PerspBits, half: *[MAX_HIDDEN]i16, psqt: *[MAX_BUCKETS]i64, pending: *PendingThreatRowsT(T), net: *const Net, ak: usize, fbase: usize) void {
    const feat = ak * AK_STRIDE + fbase;
    const word = ak * AK_WORDS + (fbase >> 6);
    const mask = @as(u64, 1) << @as(u6, @intCast(fbase & 63));
    const h = net.hidden;
    if (add) {
        bits[word] |= mask;
        pending.pushAdd(half, h, threatRowT(T, net, feat));
    } else {
        bits[word] &= ~mask;
        pending.pushSub(half, h, threatRowT(T, net, feat));
    }
    addPsqtVecRaw(psqt, net, net.king_buckets * INPUTS + feat, add);
}

/// Recompute every threat feature targeting square `t` (both perspectives) and toggle vs the
/// parent-initialised child bitsets. Handles the target's rel change (occupant changed).
/// Attacker presence at `t` comes from the per-(colour,pt) UNION attack boards computed once
/// per MOVE by directThreatDelta, extracted here as per-colour 5-bit masks. Each (target,
/// rel) group is diffed WHOLE: gather the 10 stored bits into a register mask, XOR against
/// the wanted mask, and toggle only the set bits of the difference (@ctz loops) — replaces
/// the 20-per-perspective branchy per-feature bitset probes of the pre-restructure form.
/// Bit-exact: the same feature set toggles in the same directions; row adds/subs are
/// wrapping i16 (commute) and the PSQT sums are i64 adds (commute).
fn updateThreatTarget(comptime T: type, self: *Accumulator, net: *const Net, pos: *const position.Position, t: u6, cu: *const [2][5]bitboard.Bitboard, changes: []const Change, wflip: u6, bflip: u6, wpend: *PendingThreatRowsT(T), bpend: *PendingThreatRowsT(T), wpsqt: *[MAX_BUCKETS]i64, bpsqt: *[MAX_BUCKETS]i64) void {
    const child_piece = pos.mailbox[t];
    var parent_piece = child_piece;
    for (changes) |c| {
        if (!c.add and c.sq == t) parent_piece = piece.Piece.make(c.color, c.pt);
    }
    // Per-colour 5-bit attacker-presence masks at t (bit pi = "any (colour,pt) attacks t"),
    // extracted branchlessly from the union boards.
    var amask: [2]u32 = .{ 0, 0 };
    inline for (0..2) |ci| {
        inline for (0..5) |pi| {
            amask[ci] |= @as(u32, @intCast((cu[ci][pi] >> t) & 1)) << pi;
        }
    }
    inline for ([_]types.Color{ .white, .black }) |persp| {
        const flip = if (persp == .white) wflip else bflip;
        const oriented_t: u6 = (if (persp == .white) t else t ^ 56) ^ flip;
        const bits = if (persp == .white) &self.tw else &self.tb;
        const half = if (persp == .white) &self.white else &self.black;
        const psqt = if (persp == .white) wpsqt else bpsqt;
        const pending = if (persp == .white) wpend else bpend;
        const crel: ?usize = if (child_piece.color()) |cc|
            ((if (cc == persp) @as(usize, 0) else @as(usize, 6)) + @intFromEnum(child_piece.pieceType()))
        else
            null;
        const prel: ?usize = if (parent_piece.color()) |pc|
            ((if (pc == persp) @as(usize, 0) else @as(usize, 6)) + @intFromEnum(parent_piece.pieceType()))
        else
            null;
        const gbase = @as(usize, oriented_t) * threats_mod.NUM_ATTACKED_REL;
        // occupant's rel changed -> the old-rel group goes fully inactive: every stored
        // bit IS a change; clear them all.
        if (prel) |pr| {
            if (crel == null or pr != crel.?) {
                const fbase = gbase + pr;
                var stored = gatherThreatGroup(bits, fbase);
                while (stored != 0) {
                    const ak: usize = @ctz(stored);
                    stored &= stored - 1;
                    toggleThreatFeature(T, false, bits, half, psqt, pending, net, ak, fbase);
                }
            }
        }
        // child-rel group -> board truth. akey = (attacker colour == persp ? 0 : 5) + pt,
        // so the wanted mask is the own-colour amask in bits 0-4, the other in bits 5-9.
        // One XOR decides both loops; the common all-unchanged case falls straight through.
        if (crel) |cr| {
            const wanted: u32 = if (persp == .white) amask[0] | (amask[1] << 5) else amask[1] | (amask[0] << 5);
            const fbase = gbase + cr;
            const stored = gatherThreatGroup(bits, fbase);
            const changed = stored ^ wanted;
            var adds = changed & wanted;
            while (adds != 0) {
                const ak: usize = @ctz(adds);
                adds &= adds - 1;
                toggleThreatFeature(T, true, bits, half, psqt, pending, net, ak, fbase);
            }
            var subs = changed & stored;
            while (subs != 0) {
                const ak: usize = @ctz(subs);
                subs &= subs - 1;
                toggleThreatFeature(T, false, bits, half, psqt, pending, net, ak, fbase);
            }
        }
    }
}

/// Incremental threat update without re-enumerating the board: collect the squares whose threat
/// features a move can change — the moved/captured pieces' squares + attack sets, plus every
/// slider's attack symmetric-difference (discovered/blocked rays) — then recompute each. The
/// bitsets start as a copy of the parent's; this toggles only the deltas (+rows +PSQT).
fn directThreatDelta(comptime T: type, self: *Accumulator, net: *const Net, pos: *const position.Position, changes: []const Change, wflip: u6, bflip: u6) void {
    const child_occ = pos.occupancy();
    var flip_bb: bitboard.Bitboard = 0;
    for (changes) |c| flip_bb ^= (@as(bitboard.Bitboard, 1) << c.sq);
    const parent_occ = child_occ ^ flip_bb;
    var affected: bitboard.Bitboard = 0;
    for (changes) |c| {
        affected |= (@as(bitboard.Bitboard, 1) << c.sq);
        const occ = if (c.add) child_occ else parent_occ;
        affected |= threatAttackBB(c.pt, c.color, square.Square.fromIndex(c.sq), occ);
    }
    // Per-(colour,pt) UNION attack boards under the child board: bit t == "any such
    // piece attacks t" — replaces all of updateThreatTarget's per-target magic/table
    // attacker queries with one bit-extract each. Pawns are two shift ops; the slider
    // pass doubles as the attack-XOR scan (discovered/blocked rays into `affected`),
    // where the empty-board ray pre-filter still gates the parent-occupancy lookup.
    var cu: [2][5]bitboard.Bitboard = .{ .{0} ** 5, .{0} ** 5 };
    inline for ([_]types.Color{ .white, .black }) |col| {
        const ci = @intFromEnum(col);
        cu[ci][0] = attacks.pawnAttacksDirect(col, pos.pieceBitboard(col, .pawn));
        var kn = pos.pieceBitboard(col, .knight);
        while (bitboard.popLsb(&kn)) |s| cu[ci][1] |= attacks.knightAttacksDirect(s);
    }
    inline for ([_]piece.PieceType{ .bishop, .rook, .queen }) |pt| {
        inline for ([_]types.Color{ .white, .black }) |col| {
            const ci = @intFromEnum(col);
            const pi = @intFromEnum(pt);
            var sb = pos.pieceBitboard(col, pt);
            while (bitboard.popLsb(&sb)) |s| {
                const a_child = threatAttackBB(pt, col, s, child_occ);
                cu[ci][pi] |= a_child;
                const rays = switch (pt) {
                    .bishop => attacks.BISHOP_RAYS[s.index()],
                    .rook => attacks.ROOK_RAYS[s.index()],
                    .queen => attacks.BISHOP_RAYS[s.index()] | attacks.ROOK_RAYS[s.index()],
                    else => unreachable,
                };
                if ((rays & flip_bb) == 0) continue;
                affected |= a_child ^ threatAttackBB(pt, col, s, parent_occ);
            }
        }
    }
    affected &= (parent_occ | child_occ); // only occupied squares can be targets
    var wpend: PendingThreatRowsT(T) = undefined;
    var bpend: PendingThreatRowsT(T) = undefined;
    wpend.initEmpty();
    bpend.initEmpty();
    // PSQT deltas accumulate in stack locals across the whole delta (register-resident
    // after SROA) and commit ONCE per perspective — per-toggle RMW of the accumulator
    // arrays was the dominant pb>1 cost.
    // pb-aware zeroing (see applyMoveColor): only lane 0 lives for pb==1 nets.
    var wpsqt: [MAX_BUCKETS]i64 = undefined;
    var bpsqt: [MAX_BUCKETS]i64 = undefined;
    if (net.psqt_buckets == 1) {
        wpsqt[0] = 0;
        bpsqt[0] = 0;
    } else {
        @memset(&wpsqt, 0);
        @memset(&bpsqt, 0);
    }
    while (bitboard.popLsb(&affected)) |t| {
        updateThreatTarget(T, self, net, pos, t.index(), &cu, changes, wflip, bflip, &wpend, &bpend, &wpsqt, &bpsqt);
    }
    wpend.flush(&self.white, net.hidden);
    bpend.flush(&self.black, net.hidden);
    const pb = net.psqt_buckets;
    for (0..pb) |b| {
        self.psqt_tw[b] += wpsqt[b];
        self.psqt_tb[b] += bpsqt[b];
    }
}

/// Threats eval from the search's incrementally-maintained accumulator (`acc` already holds
/// HalfKA + threats + the per-colour threat-PSQT). Just the readout + the PSQT head (HalfKA
/// part summed from the pieces, threat part read from the maintained scalar) — no per-node
/// copy or row-adds. The search/deploy path.
pub fn evaluateThreatsIncremental(net: *const Net, acc: *const Accumulator, pos: *const position.Position, scale_percent: u16) i32 {
    const stm = pos.side_to_move;
    // All PSQT bucket scalars are maintained incrementally (HalfKA via the change-list,
    // threats via the bitset delta) — eval picks the position's bucket: two array reads.
    const pc: usize = if (net.buckets > 1 or net.psqt_buckets > 1) @popCount(pos.occupancy()) else 0;
    const pbkt = if (net.psqt_buckets > 1) net.bucketIndex(pc) else 0;
    var psqt: i64 = net.psqtb[pbkt];
    psqt += if (stm == .white) acc.psqt_hw[pbkt] else acc.psqt_hb[pbkt];
    psqt += if (stm == .white) acc.psqt_tw[pbkt] else acc.psqt_tb[pbkt];
    // ZQB8: same maintained accumulator + PSQT, layerstack readout instead of the dot.
    if (net.multilayer) return finishThreatsEvalMulti(net, acc, stm, pc, psqt, scale_percent);
    return finishThreatsEval(net, acc, stm, pc, psqt, scale_percent);
}

/// ZQB9 full-threats eval from the search's incrementally-maintained accumulator:
/// the HalfKA halves (white/black) and the SEPARATE threat halves (ftw/ftb) are
/// combined lane-wise INSIDE the activation pass (fillPairwiseU8Split — no
/// hidden-wide stm/ntm temporaries), then fed to the shared layerstack readout;
/// the PSQT head is read from the maintained per-colour scalars (HalfKA
/// psqt_hw/hb + threat psqt_tw/tb) exactly like evaluateThreatsIncremental. Must
/// equal `evaluateFull9` (the refresh reference) bit-for-bit — the Debug
/// cross-check in backend.evaluate and the ZQB9 tree tests assert it (the
/// in-register wrapping half-sum is the refresh path's sequential row adds'
/// exact value: the combined accumulator is i16-safe for any legal net).
pub fn evaluateFull9Incremental(net: *const Net, acc: *const Accumulator, pos: *const position.Position, scale_percent: u16) i32 {
    const h = net.hidden;
    const half = h / 2;
    const stm = pos.side_to_move;
    const pc: usize = @popCount(pos.occupancy());
    const pbkt = if (net.psqt_buckets > 1) net.bucketIndex(pc) else 0;
    var psqt: i64 = net.psqtb[pbkt];
    psqt += if (stm == .white) acc.psqt_hw[pbkt] else acc.psqt_hb[pbkt];
    psqt += if (stm == .white) acc.psqt_tw[pbkt] else acc.psqt_tb[pbkt];
    var p_u8: [MAX_HIDDEN]u8 align(64) = undefined;
    if (stm == .white) {
        fillPairwiseU8Split(p_u8[0..half], acc.white[0..h], acc.ftw[0..h], net.qa);
        fillPairwiseU8Split(p_u8[half..h], acc.black[0..h], acc.ftb[0..h], net.qa);
    } else {
        fillPairwiseU8Split(p_u8[0..half], acc.black[0..h], acc.ftb[0..h], net.qa);
        fillPairwiseU8Split(p_u8[half..h], acc.white[0..h], acc.ftw[0..h], net.qa);
    }
    // ZQB9 is always a layerstack net (same body as ZQB8).
    return finishMultiActivated(net, &p_u8, pc, psqt, scale_percent);
}

// ---------------------------------------------------------------------------
// v6 FULL-THREATS incremental state (docs/V6_INCREMENTAL_DESIGN.md, Block B).
//
// The 60,144-bit active-feature sets are 7.5KB per perspective — far too big to
// copy per ply. ONE shared pair lives here (in the search context, alongside
// the finny table), always describing the state at some ply of the search's
// materialized path, plus a PATH STACK of per-ply undo records. The per-ply
// Accumulator carries only the cheap derived VALUES (ftw/ftb threat halves +
// psqt_tw/tb scalars), written child-from-parent at materialization time.
//
// Path identity needs no explicit keys: the backend's materialization walk is
// fused with the HalfKA lazy walk, so the shared bitsets' path always matches
// the search stack's contiguous CLEAN prefix (entries are re-marked dirty by
// every make). ensureMaterialized unwinds the bitsets to the walk's start ply
// (`top`, always a clean ancestor on the live line) and re-advances them move
// by move alongside the accumulator updates.
//
// Barriers (mirror-flip crossings ~1.4% of moves, and the delta-overflow
// fallback) re-enumerate both bitsets from the board; the record stores NO
// bitset snapshot (deviation from the design note's 7.5KB-snapshot barrier:
// records stay ~1KB flat, and exact restoration is available anyway) — instead,
// UNWINDING through a barrier resets the bitsets by full re-enumeration at the
// unwind-target board, which ensureMaterialized can always reconstruct because
// the target is on the live line. Records at shallower plies remain valid
// descriptions of this line's moves after such a reset (the re-enumerated
// bitsets are bit-identical to the delta-maintained ones — the invariant).
//
// The accumulator threat halves rebuild across a flip crossing via a 2-slot
// flip cache per perspective (slot = mirror flip on/off): each slot holds a
// threat half + the bitset it sums + its PSQT scalars, diff-applied against
// the freshly enumerated truth exactly like finnyRefresh — the flip-space
// analog of the finny table (full-threat state depends on the FLIP only,
// never on king buckets).
// ---------------------------------------------------------------------------

/// Path-stack capacity; must cover the search stack's MAX_PLY (asserted at
/// comptime in eval/backend.zig — the two constants cannot import each other).
pub const FT_MAX_PLY: usize = 128;

const FtRecord = struct {
    const Kind = enum(u8) {
        /// Plain applyMoveDelta undo log (n == 0 for null moves) — exactly undoable.
        delta,
        /// Flip refresh or delta overflow: bitsets were re-enumerated; not
        /// undoable in place (unwind resets at the target board instead).
        barrier,
    };
    kind: Kind,
    delta: fullthreats_mod.Delta,
};

/// One flip-cache slot: `acc` = Σ threat rows over `bits`, `psqt` their PSQT sums.
const FtFlipSlot = struct {
    acc: [MAX_HIDDEN]i16 align(64),
    bits: fullthreats_mod.PerspBits,
    psqt: [MAX_BUCKETS]i64,
};

pub const FullThreatState = struct {
    /// Shared active-feature bitsets (white/black COLOUR perspective) at `depth`.
    wbits: fullthreats_mod.PerspBits = undefined,
    bbits: fullthreats_mod.PerspBits = undefined,
    /// Mirror flips the bitsets are indexed under (own-king d/e-file rule).
    wflip: u6 = 0,
    bflip: u6 = 0,
    /// Ply of the materialized path the bitsets currently describe;
    /// records[1..depth] are that path's per-ply undo records.
    depth: usize = 0,
    records: [FT_MAX_PLY]FtRecord = undefined,
    /// 2-slot flip cache per perspective: [persp][flip != 0].
    cache: [2][2]FtFlipSlot = undefined,
    cache_valid: [2][2]bool = .{ .{ false, false }, .{ false, false } },
    /// Pre-move bitset scratch for barrier advances (kept off the stack).
    scratch_w: fullthreats_mod.PerspBits = undefined,
    scratch_b: fullthreats_mod.PerspBits = undefined,

    /// Root reset (prepareRoot): full enumeration at the root board, empty path,
    /// cold flip cache. The root Accumulator refresh is separate (refresh()).
    pub fn prepare(self: *FullThreatState, pos: *const position.Position) void {
        self.resetAt(pos, 0);
        self.cache_valid = .{ .{ false, false }, .{ false, false } };
    }

    /// Re-anchor the shared bitsets at `pos` as path depth `d` (used by prepare
    /// and by the unwind-through-barrier fallback). Flip cache stays warm: its
    /// slots are self-consistent (acc == Σ rows(bits)) independent of the path.
    pub fn resetAt(self: *FullThreatState, pos: *const position.Position, d: usize) void {
        fullthreats_mod.enumerateColors(pos, &self.wbits, &self.bbits);
        const flips = fullthreats_mod.kingFlips(pos);
        self.wflip = flips.w;
        self.bflip = flips.b;
        self.depth = d;
    }

    /// True if unwinding to `target` would cross a barrier record (then the
    /// caller must resetAt(target board) instead of unwindTo).
    pub fn unwindNeedsReset(self: *const FullThreatState, target: usize) bool {
        var j = self.depth;
        while (j > target) : (j -= 1) {
            if (self.records[j].kind == .barrier) return true;
        }
        return false;
    }

    /// Pop plain-delta records down to `target` (XOR toggles are self-inverse).
    /// Caller guarantees no barrier in the span (unwindNeedsReset == false).
    pub fn unwindTo(self: *FullThreatState, target: usize) void {
        while (self.depth > target) : (self.depth -= 1) {
            const r = &self.records[self.depth];
            std.debug.assert(r.kind == .delta);
            fullthreats_mod.undoDelta(&self.wbits, &self.bbits, &r.delta);
        }
    }

    /// A null move changes no pieces: push an empty (trivially undoable) record.
    /// The child's threat halves/scalars are carried by Accumulator.copyFrom.
    pub fn advanceNull(self: *FullThreatState) void {
        std.debug.assert(self.depth + 1 < FT_MAX_PLY);
        self.depth += 1;
        // Field stores, not a record-literal assign: `.delta = .{}` zero-fills
        // the 1KB undo array (idx is undefined-until-logged by contract).
        const rec = &self.records[self.depth];
        rec.kind = .delta;
        rec.delta.n = 0;
        rec.delta.groups = 0;
    }

    /// Advance the shared bitsets across one materialized move (board = POST-move
    /// position) and write the child's threat halves + PSQT scalars from the
    /// parent's. Fast path: applyMoveDelta + per-toggle row adds/subs. Barrier
    /// path (either flip changed, or the undo log overflowed): re-enumerate both
    /// bitsets and rebuild each perspective's half — flip-unchanged perspectives
    /// diff parent-vs-truth, flip-changed perspectives go through the flip cache.
    /// `changes` is the SAME decoded piece feature list the HalfKA path consumed
    /// (never a mailbox re-diff, and — since perf-r5 — never a second decode).
    pub fn advanceMove(
        self: *FullThreatState,
        net: *const Net,
        child: *Accumulator,
        parent: *const Accumulator,
        changes: []const Change,
        board: *const position.Position,
    ) void {
        std.debug.assert(self.depth + 1 < FT_MAX_PLY);
        var sqbuf: [4]fullthreats_mod.SquareChange = undefined;
        const nsq = squareChangesFrom(changes, &sqbuf);

        const new_flips = fullthreats_mod.kingFlips(board);
        const rec = &self.records[self.depth + 1];
        const wflip_changed = new_flips.w != self.wflip;
        const bflip_changed = new_flips.b != self.bflip;
        var barrier = wflip_changed or bflip_changed;
        if (!barrier) {
            // Field stores, not `rec.delta = .{}`: the literal assign memsets
            // the whole 1KB Delta (idx is undefined-until-logged by contract)
            // on EVERY materialized move.
            rec.delta.n = 0;
            rec.delta.groups = 0;
            if (fullthreats_mod.applyMoveDelta(board, sqbuf[0..nsq], &self.wbits, &self.bbits, &rec.delta)) {
                rec.kind = .delta;
                self.applyDeltaToChild(net, child, parent, &rec.delta);
            } else {
                // Undo-log overflow (>256 toggles; never observed — mean churn is
                // ~14): roll the partial toggles back and take the barrier path.
                fullthreats_mod.undoDelta(&self.wbits, &self.bbits, &rec.delta);
                barrier = true;
            }
        }
        if (barrier) {
            rec.kind = .barrier;
            // Only a flip-UNCHANGED perspective diffs against its pre-move bitset
            // (rebuildPersp's flip_changed branch goes through the flip cache and
            // never reads scratch) — so a flip-changed perspective's 7.5KB
            // snapshot copy was dead work on every barrier, and the usual barrier
            // flips exactly one side.
            if (!wflip_changed) self.scratch_w = self.wbits;
            if (!bflip_changed) self.scratch_b = self.bbits;
            fullthreats_mod.enumerateColors(board, &self.wbits, &self.bbits);
            self.wflip = new_flips.w;
            self.bflip = new_flips.b;
            self.rebuildPersp(net, .white, child, parent, wflip_changed);
            self.rebuildPersp(net, .black, child, parent, bflip_changed);
        }
        self.depth += 1;
    }

    /// Fast path: child threat halves = parent halves plus the delta's toggled
    /// rows (direction = the toggled bit's POST state in the shared bitset),
    /// child threat-PSQT = parent scalars plus the matching weight deltas.
    /// Each half is written in ONE fused pass (read parent, add rows, write
    /// child — flushInto), not copyHalf-then-flush.
    fn applyDeltaToChild(self: *const FullThreatState, net: *const Net, child: *Accumulator, parent: *const Accumulator, delta: *const fullthreats_mod.Delta) void {
        const h = net.hidden;
        const pb = net.psqt_buckets;
        if (pb == 1) {
            child.psqt_tw[0] = parent.psqt_tw[0];
            child.psqt_tb[0] = parent.psqt_tb[0];
        } else {
            child.psqt_tw = parent.psqt_tw;
            child.psqt_tb = parent.psqt_tb;
        }
        var wpend: PendingThreatRowsT(i8) = undefined;
        var bpend: PendingThreatRowsT(i8) = undefined;
        wpend.initEmpty();
        bpend.initEmpty();
        // Flush sources: the PARENT halves until a (cold) overflow flush
        // materializes a child half early — see pushAddFrom/pushSubFrom.
        var wsrc: *const [MAX_HIDDEN]i16 = &parent.ftw;
        var bsrc: *const [MAX_HIDDEN]i16 = &parent.ftb;
        // PSQT deltas in locals, committed once (see directThreatDelta).
        var wpsqt: [MAX_BUCKETS]i64 = undefined;
        var bpsqt: [MAX_BUCKETS]i64 = undefined;
        if (pb == 1) {
            wpsqt[0] = 0;
            bpsqt[0] = 0;
        } else {
            @memset(&wpsqt, 0);
            @memset(&bpsqt, 0);
        }
        const base = net.king_buckets * INPUTS;
        for (delta.idx[0..delta.n]) |e| {
            const idx: usize = e & 0x7FFF_FFFF;
            const black = (e & 0x8000_0000) != 0;
            const bits = if (black) &self.bbits else &self.wbits;
            const added = (bits[idx >> 6] >> @as(u6, @intCast(idx & 63))) & 1 == 1;
            const row = threatRowT(i8, net, idx);
            if (black) {
                if (added) {
                    bpend.pushAddFrom(&child.ftb, &bsrc, h, row);
                    addPsqtVecRaw(&bpsqt, net, base + idx, true);
                } else {
                    bpend.pushSubFrom(&child.ftb, &bsrc, h, row);
                    addPsqtVecRaw(&bpsqt, net, base + idx, false);
                }
            } else {
                if (added) {
                    wpend.pushAddFrom(&child.ftw, &wsrc, h, row);
                    addPsqtVecRaw(&wpsqt, net, base + idx, true);
                } else {
                    wpend.pushSubFrom(&child.ftw, &wsrc, h, row);
                    addPsqtVecRaw(&wpsqt, net, base + idx, false);
                }
            }
        }
        // Unconditional (unlike flush): with zero pending rows this is the copy.
        wpend.flushInto(&child.ftw, wsrc, h);
        bpend.flushInto(&child.ftb, bsrc, h);
        for (0..pb) |b| {
            child.psqt_tw[b] += wpsqt[b];
            child.psqt_tb[b] += bpsqt[b];
        }
    }

    /// Barrier path, one perspective. scratch_w/b hold the PRE-move bitsets,
    /// wbits/bbits the freshly enumerated POST-move truth.
    /// - flip unchanged: same index space, so child half = parent half + the
    ///   (pre XOR post) row delta — the applyThreatBitsetDelta diff.
    /// - flip changed: the parent half is indexed under the OLD mirror — rebuild
    ///   from the flip-cache slot for the NEW flip instead (seeded empty on first
    ///   use), diff-applied like finnyRefresh, then copied to the child.
    fn rebuildPersp(self: *FullThreatState, net: *const Net, comptime persp: types.Color, child: *Accumulator, parent: *const Accumulator, flip_changed: bool) void {
        const h = net.hidden;
        const new_bits = if (persp == .white) &self.wbits else &self.bbits;
        const old_bits = if (persp == .white) &self.scratch_w else &self.scratch_b;
        const child_half = if (persp == .white) &child.ftw else &child.ftb;
        const child_psqt = if (persp == .white) &child.psqt_tw else &child.psqt_tb;
        const parent_half = if (persp == .white) &parent.ftw else &parent.ftb;
        const parent_psqt = if (persp == .white) &parent.psqt_tw else &parent.psqt_tb;
        if (!flip_changed) {
            child_psqt.* = parent_psqt.*;
            // parent -> child copy fused into the diff's single row pass.
            applyThreatBitsetDeltaInto(i8, child_half, parent_half, null, net, old_bits, new_bits, child_psqt);
            return;
        }
        const flip = if (persp == .white) self.wflip else self.bflip; // POST-move flip
        const si = @as(usize, @intFromBool(flip != 0));
        const pi = @intFromEnum(persp);
        const slot = &self.cache[pi][si];
        if (!self.cache_valid[pi][si]) {
            @memset(slot.acc[0..h], 0);
            slot.bits = [_]u64{0} ** fullthreats_mod.WORDS;
            slot.psqt = [_]i64{0} ** MAX_BUCKETS;
            self.cache_valid[pi][si] = true;
        }
        // Slot update (in place) and slot -> child copy from ONE fused pass.
        applyThreatBitsetDeltaInto(i8, &slot.acc, &slot.acc, child_half, net, &slot.bits, new_bits, &slot.psqt);
        slot.bits = new_bits.*;
        child_psqt.* = slot.psqt;
    }
};

/// ZQB8 finisher: crelu+pairwise activation over the maintained threats accumulator,
/// then the f32 layerstack forward (the ZQB4-validated l1/l2/l3 algebra — see
/// evaluateAccMulti) plus the Q20 PSQT head combined exactly like finishThreatsEval.
/// Only the readout differs from ZQB6; all incremental maintenance is shared.
fn finishThreatsEvalMulti(net: *const Net, acc: *const Accumulator, stm: types.Color, piece_count: usize, psqt: i64, scale_percent: u16) i32 {
    const us = if (stm == .white) &acc.white else &acc.black;
    const them = if (stm == .white) &acc.black else &acc.white;
    return finishMultiHalves(net, us, them, piece_count, psqt, scale_percent);
}

/// The layerstack readout body over EXPLICIT stm/ntm accumulator halves — factored
/// out of finishThreatsEvalMulti so the ZQB9 incremental path (which sums its
/// separate HalfKA + threat halves into temporaries first) shares it bit-for-bit.
fn finishMultiHalves(net: *const Net, us: *const [MAX_HIDDEN]i16, them: *const [MAX_HIDDEN]i16, piece_count: usize, psqt: i64, scale_percent: u16) i32 {
    const h = net.hidden;
    const half = h / 2;
    // crelu + pairwise_mul -> u8 products; concat(stm half, ntm half) = h wide.
    var p_u8: [MAX_HIDDEN]u8 align(64) = undefined;
    fillPairwiseU8(p_u8[0..half], us[0..h], net.qa);
    fillPairwiseU8(p_u8[half..h], them[0..h], net.qa);
    return finishMultiActivated(net, &p_u8, piece_count, psqt, scale_percent);
}

/// The layerstack forward from the ACTIVATED u8 products (l1 -> screlu -> l2 ->
/// screlu -> l3, plus the PSQT combine) — factored out of finishMultiHalves so
/// the ZQB9 incremental path (fillPairwiseU8Split, no combined-half temps)
/// shares the body bit-for-bit.
fn finishMultiActivated(net: *const Net, p_u8: *const [MAX_HIDDEN]u8, piece_count: usize, psqt: i64, scale_percent: u16) i32 {
    const h = net.hidden;
    const l2n = net.l2_size;
    const l3n = net.l3_size;
    const qaf: f32 = @floatFromInt(net.qa);
    // Material-bucketed stacks (bucket 0 for single-stack nets): bucket-major slices.
    const bucket = net.bucketIndex(piece_count);
    const l1w = net.l1_weights[bucket * l2n * h ..];
    const l1b = net.l1_bias[bucket * l2n ..];
    const l2wt = net.l2_weights_t[bucket * l3n * l2n ..];
    const l2b = net.l2_bias[bucket * l3n ..];
    const l3w = net.l3_weights[bucket * l3n ..][0..l3n];
    const l3b = net.l3_bias[bucket];

    // l1 (i8 x u8 dot; dequant folds the pairwise >>8) -> screlu -> l2 -> screlu -> l3.
    // Rows consumed 4 at a time so each activation load feeds 4 vpdpbusd chains.
    const l1_dequant: f32 = 256.0 / (@as(f32, @floatFromInt(net.qb)) * qaf * qaf);
    var hl2: [MAX_L2]f32 align(64) = undefined;
    var k: usize = 0;
    while (k + 4 <= l2n) : (k += 4) {
        var dots: [4]i32 = undefined;
        dotI8U8x4(l1w[k * h ..][0..h], l1w[(k + 1) * h ..][0..h], l1w[(k + 2) * h ..][0..h], l1w[(k + 3) * h ..][0..h], p_u8[0..h], &dots);
        inline for (0..4) |j| {
            hl2[k + j] = screluF(@as(f32, @floatFromInt(dots[j])) * l1_dequant + l1b[k + j]);
        }
    }
    while (k < l2n) : (k += 1) {
        const dot = dotI8U8(l1w[k * h ..][0..h], p_u8[0..h]);
        hl2[k] = screluF(@as(f32, @floatFromInt(dot)) * l1_dequant + l1b[k]);
    }
    // l2 vectorized over OUTPUTS: acc[k3] = l2b[k3] + sum_k hl2[k]*l2wT[k][k3]
    // (broadcast-FMA per k; no horizontal reduces), then one vectorized screlu.
    var acc3: [MAX_L3]f32 align(64) = undefined;
    @memcpy(acc3[0..l3n], l2b[0..l3n]);
    // Register-blocked when l3n fits in <=4 vectors (l3n=32 at VECF=16 -> 2 zmm):
    // the per-kk acc3 load/store round-trip through the stack put ~13% of the whole
    // finisher on ONE store instruction (store->load-forward chain: each kk reloads
    // what the previous kk just stored). Holding acc3 in registers across the kk
    // loop removes the round-trip. Per-element op order is IDENTICAL (kk-ascending
    // mul then add, no FMA contraction in either form) -> bit-exact.
    if (l3n % VECF == 0 and l3n <= 4 * VECF) {
        switch (l3n / VECF) {
            inline 1, 2, 3, 4 => |nb| l2ForwardBlocked(nb, acc3[0..l3n], hl2[0..l2n], l2wt, l3n),
            else => unreachable,
        }
    } else {
        for (0..l2n) |kk| {
            const hk: @Vector(VECF, f32) = @splat(hl2[kk]);
            var j: usize = 0;
            while (j + VECF <= l3n) : (j += VECF) {
                const wv: @Vector(VECF, f32) = l2wt[kk * l3n + j ..][0..VECF].*;
                const av: @Vector(VECF, f32) = acc3[j..][0..VECF].*;
                acc3[j..][0..VECF].* = av + hk * wv;
            }
            while (j < l3n) : (j += 1) acc3[j] += hl2[kk] * l2wt[kk * l3n + j];
        }
    }
    var hl3: [MAX_L3]f32 align(64) = undefined;
    {
        const zero: @Vector(VECF, f32) = @splat(0.0);
        const one: @Vector(VECF, f32) = @splat(1.0);
        var j: usize = 0;
        while (j + VECF <= l3n) : (j += VECF) {
            const av: @Vector(VECF, f32) = acc3[j..][0..VECF].*;
            const c = @min(@max(av, zero), one);
            hl3[j..][0..VECF].* = c * c;
        }
        while (j < l3n) : (j += 1) hl3[j] = screluF(acc3[j]);
    }
    const z3: f32 = l3b + dotF(l3w, hl3[0..l3n]);

    // Integer combine mirroring finishThreatsEval: round(z3*scale) + round(psqt*scale/2^Q).
    var out: i64 = @intFromFloat(@round(z3 * @as(f32, @floatFromInt(net.scale))));
    const num: i64 = psqt * net.scale;
    const half_q: i64 = @as(i64, 1) << (PSQT_Q - 1);
    out += if (num >= 0) (num + half_q) >> PSQT_Q else -((-num + half_q) >> PSQT_Q);
    if (scale_percent != 100) out = @divTrunc(out * @as(i64, scale_percent), 100);
    return @intCast(out);
}

/// SIMD width for the f32 layerstack matmuls.
const VECF: usize = std.simd.suggestVectorLength(f32) orelse 8;

/// l2 forward (acc3[j] += hl2[kk] * l2wT[kk][j]) with acc3 held in NB register
/// vectors across the whole kk loop. Same kk-major traversal and the same
/// separate mul/add per element as the memory-round-trip version -> bit-exact;
/// only the redundant per-kk stack stores/reloads are gone.
inline fn l2ForwardBlocked(comptime NB: usize, acc3: []f32, hl2: []const f32, l2wt: []const f32, l3n: usize) void {
    var av: [NB]@Vector(VECF, f32) = undefined;
    inline for (0..NB) |b| av[b] = acc3[b * VECF ..][0..VECF].*;
    for (hl2, 0..) |hkv, kk| {
        const hk: @Vector(VECF, f32) = @splat(hkv);
        const wrow = l2wt[kk * l3n ..];
        inline for (0..NB) |b| {
            const wv: @Vector(VECF, f32) = wrow[b * VECF ..][0..VECF].*;
            av[b] = av[b] + hk * wv;
        }
    }
    inline for (0..NB) |b| acc3[b * VECF ..][0..VECF].* = av[b];
}

inline fn screluF(x: f32) f32 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return c * c;
}

/// Vectorised f32 dot product (the layerstack matmul kernel).
/// FIXED 16-lane accumulation, deliberately NOT the target-derived VECF: f32
/// addition is not associative, so a width-derived lane count makes the sum
/// GROUPING (and thus rounding) an ISA property — the x86-64-v3 build's evals
/// diverged from native by an occasional ulp, breaking cross-build node
/// identity at depth (kiwipete d22: 7193085 vs 7193101 nodes, avx2-perf-r1;
/// every other kernel in this file is integer/elementwise and width-neutral).
/// 16 lanes == the native AVX-512 build's historical grouping, so native
/// signatures are unchanged and AVX2/NEON builds converge to them (a 16-wide
/// f32 vector lowers to 2 ymm / 4 NEON regs — same op count, fixed grouping).
inline fn dotF(w: []const f32, x: []const f32) f32 {
    const V = 16;
    const n = w.len;
    var acc: @Vector(V, f32) = @splat(0.0);
    var i: usize = 0;
    while (i + V <= n) : (i += V) {
        const wv: @Vector(V, f32) = w[i..][0..V].*;
        const xv: @Vector(V, f32) = x[i..][0..V].*;
        acc += wv * xv;
    }
    var s: f32 = @reduce(.Add, acc);
    while (i < n) : (i += 1) s += w[i] * x[i];
    return s;
}

/// crelu+pairwise_mul of one perspective's accumulator into u8 [0,255]:
/// out[i] = (clamp(acc[i],0,qa) * clamp(acc[i+half],0,qa)) >> 8, i in 0..half.
/// (bullet `pairwise_mul`: first half * second half of the crelu'd accumulator.)
/// The >>8 (=/256, vs the exact /qa^2 normalisation) is a uniform ~0.4% scale folded
/// into the l1 dequant constant; it keeps the activation in u8 so the l1 matmul is a
/// `vpdpbusd` (i8*u8->i32) dot — the whole point of bullet quantising l1 to i8.
inline fn fillPairwiseU8(out: []u8, acc: []const i16, qa: i32) void {
    // i16 lanes -> size by the i16 SIMD width (VEC16 = 32 on AVX-512), not VECF:
    // VECF (=16 f32 lanes) only filled a ymm here, running the clamp/mul at 256-bit.
    // Elementwise ops only, so the width is bit-exact-neutral.
    const V = VEC16;
    const half = out.len;
    const qa16: @Vector(V, i16) = @splat(@intCast(qa));
    const zero16: @Vector(V, i16) = @splat(0);
    var i: usize = 0;
    while (i + V <= half) : (i += V) {
        const lo: @Vector(V, i16) = acc[i..][0..V].*;
        const hi: @Vector(V, i16) = acc[i + half ..][0..V].*;
        const a = @min(@max(lo, zero16), qa16);
        const b = @min(@max(hi, zero16), qa16);
        // u16 low-multiply is EXACT here (a,b <= qa=255 -> a*b <= 65025 < 2^16), so
        // (a*b)>>8 in u16 == the old widen-to-i32 path bit-for-bit, without pmulld.
        const au: @Vector(V, u16) = @bitCast(a);
        const bu: @Vector(V, u16) = @bitCast(b);
        const pu: @Vector(V, u16) = (au *% bu) >> @splat(8);
        const ov: @Vector(V, u8) = @intCast(pu);
        out[i..][0..V].* = ov;
    }
    while (i < half) : (i += 1) {
        const a: i32 = std.math.clamp(@as(i32, acc[i]), 0, qa);
        const b: i32 = std.math.clamp(@as(i32, acc[i + half]), 0, qa);
        out[i] = @intCast((a * b) >> 8);
    }
}

/// Split-input fillPairwiseU8 for the ZQB9 incremental eval: the perspective's
/// accumulator lives as SEPARATE HalfKA (`ha`) and threat (`ta`) halves; each
/// lane's value is their wrapping i16 sum, formed IN-REGISTER inside the
/// activation pass instead of staging combined stm/ntm temporaries first
/// (which cost 2 extra hidden-wide passes per eval). The +% is the exact
/// lane-wise op the old sumHalvesInto staging performed, and the combined
/// accumulator is i16-safe for any legal net, so the clamp/mul sees identical
/// values -> bit-exact with the staged path.
inline fn fillPairwiseU8Split(out: []u8, ha: []const i16, ta: []const i16, qa: i32) void {
    const V = VEC16;
    const half = out.len;
    const qa16: @Vector(V, i16) = @splat(@intCast(qa));
    const zero16: @Vector(V, i16) = @splat(0);
    var i: usize = 0;
    while (i + V <= half) : (i += V) {
        const lo_h: @Vector(V, i16) = ha[i..][0..V].*;
        const lo_t: @Vector(V, i16) = ta[i..][0..V].*;
        const hi_h: @Vector(V, i16) = ha[i + half ..][0..V].*;
        const hi_t: @Vector(V, i16) = ta[i + half ..][0..V].*;
        const a = @min(@max(lo_h +% lo_t, zero16), qa16);
        const b = @min(@max(hi_h +% hi_t, zero16), qa16);
        // Same exact-u16 low-multiply argument as fillPairwiseU8.
        const au: @Vector(V, u16) = @bitCast(a);
        const bu: @Vector(V, u16) = @bitCast(b);
        const pu: @Vector(V, u16) = (au *% bu) >> @splat(8);
        const ov: @Vector(V, u8) = @intCast(pu);
        out[i..][0..V].* = ov;
    }
    while (i < half) : (i += 1) {
        const a: i32 = std.math.clamp(@as(i32, ha[i] +% ta[i]), 0, qa);
        const b: i32 = std.math.clamp(@as(i32, ha[i + half] +% ta[i + half]), 0, qa);
        out[i] = @intCast((a * b) >> 8);
    }
}

/// True at comptime when the build target has AVX-512 VNNI (this native Zen5 build
/// does; falls back to the scalar path elsewhere, keeping the engine portable).
const has_avx512vnni = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    break :blk std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vnni);
};

/// True at comptime when the build target has AVX2 (x86-64-v3 — the public
/// release/CCRL "avx2" artifact baseline). Selects the exact ymm vpmaddwd l1
/// kernel below when VNNI is absent.
const has_avx2 = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    break :blk std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
};

/// One exact AVX2 madd step for the l1 dot: multiply 16 widened-i16 (x,w) lane
/// pairs and horizontally add adjacent pairs into 8 i32 lanes (`vpmaddwd`).
/// Every product fits i16*i16 -> i32 exactly (x in [0,255], w in [-128,127]:
/// pair sum <= 2*255*127 = 64770), so the result is the exact integer pair sum.
/// Forced via inline asm: from portable code LLVM widens to i32 LANES instead
/// (vpmovsxbd + vpmaddwd on widened lanes = 8 effective MACs/instr and twice
/// the widening loads — measured ~2x slower on the v3 build, avx2-perf-r1).
inline fn madd16(w: @Vector(16, i16), x: @Vector(16, i16)) @Vector(8, i32) {
    return asm ("vpmaddwd %[w], %[x], %[p]"
        : [p] "=v" (-> @Vector(8, i32)),
        : [w] "v" (w),
          [x] "v" (x),
    );
}

/// i8 (weights) * u8 (activations) -> i32 dot — the l1 matmul kernel. On VNNI it
/// issues `vpdpbusd` (64 MACs/instr) over 64-wide chunks; the i8 weights (16KB for
/// 16x1024) stay L1-resident. LLVM will not auto-emit vpdpbusd from the scalar
/// idiom, so it is forced via inline asm. Scalar fallback handles the tail + non-VNNI.
/// 4-row variant of dotI8U8: one activation load feeds four vpdpbusd chains
/// (the finisher re-loads x per row otherwise; l1 rows are consumed in groups
/// of 4). Each row's accumulation chain is IDENTICAL to dotI8U8's -> bit-exact.
inline fn dotI8U8x4(w0: []const i8, w1: []const i8, w2: []const i8, w3: []const i8, x: []const u8, out: *[4]i32) void {
    const n = x.len;
    var i: usize = 0;
    if (comptime has_avx512vnni and builtin.zig_backend == .stage2_llvm) {
        var a0: @Vector(16, i32) = @splat(0);
        var a1: @Vector(16, i32) = @splat(0);
        var a2: @Vector(16, i32) = @splat(0);
        var a3: @Vector(16, i32) = @splat(0);
        while (i + 64 <= n) : (i += 64) {
            const xv: @Vector(64, u8) = x[i..][0..64].*;
            const w0v: @Vector(64, i8) = w0[i..][0..64].*;
            const w1v: @Vector(64, i8) = w1[i..][0..64].*;
            const w2v: @Vector(64, i8) = w2[i..][0..64].*;
            const w3v: @Vector(64, i8) = w3[i..][0..64].*;
            a0 = asm ("vpdpbusd %[w], %[x], %[acc]"
                : [acc] "=v" (-> @Vector(16, i32)),
                : [w] "v" (w0v),
                  [x] "v" (xv),
                  [accin] "0" (a0),
            );
            a1 = asm ("vpdpbusd %[w], %[x], %[acc]"
                : [acc] "=v" (-> @Vector(16, i32)),
                : [w] "v" (w1v),
                  [x] "v" (xv),
                  [accin] "0" (a1),
            );
            a2 = asm ("vpdpbusd %[w], %[x], %[acc]"
                : [acc] "=v" (-> @Vector(16, i32)),
                : [w] "v" (w2v),
                  [x] "v" (xv),
                  [accin] "0" (a2),
            );
            a3 = asm ("vpdpbusd %[w], %[x], %[acc]"
                : [acc] "=v" (-> @Vector(16, i32)),
                : [w] "v" (w3v),
                  [x] "v" (xv),
                  [accin] "0" (a3),
            );
        }
        out[0] = @reduce(.Add, a0);
        out[1] = @reduce(.Add, a1);
        out[2] = @reduce(.Add, a2);
        out[3] = @reduce(.Add, a3);
    } else if (comptime has_avx2 and builtin.zig_backend == .stage2_llvm) {
        // AVX2 (no vpdpbusd): widen x/w chunks to i16 lanes (vpmovzxbw/vpmovsxbw)
        // and vpmaddwd 16 pairs -> 8 i32 per instruction, one shared widened x per
        // 4 weight rows. Exact: every pair sum fits i32 (see madd16) and the i32
        // lane accumulators stay <= (n/16)*64770 < 2^23 for any legal net width,
        // so the reassociated sum == the scalar/VNNI sum bit-for-bit.
        var a0: @Vector(8, i32) = @splat(0);
        var a1: @Vector(8, i32) = @splat(0);
        var a2: @Vector(8, i32) = @splat(0);
        var a3: @Vector(8, i32) = @splat(0);
        while (i + 32 <= n) : (i += 32) {
            const x0: @Vector(16, i16) = @as(@Vector(16, u8), x[i..][0..16].*);
            const x1: @Vector(16, i16) = @as(@Vector(16, u8), x[i + 16 ..][0..16].*);
            a0 += madd16(@as(@Vector(16, i8), w0[i..][0..16].*), x0);
            a0 += madd16(@as(@Vector(16, i8), w0[i + 16 ..][0..16].*), x1);
            a1 += madd16(@as(@Vector(16, i8), w1[i..][0..16].*), x0);
            a1 += madd16(@as(@Vector(16, i8), w1[i + 16 ..][0..16].*), x1);
            a2 += madd16(@as(@Vector(16, i8), w2[i..][0..16].*), x0);
            a2 += madd16(@as(@Vector(16, i8), w2[i + 16 ..][0..16].*), x1);
            a3 += madd16(@as(@Vector(16, i8), w3[i..][0..16].*), x0);
            a3 += madd16(@as(@Vector(16, i8), w3[i + 16 ..][0..16].*), x1);
        }
        out[0] = @reduce(.Add, a0);
        out[1] = @reduce(.Add, a1);
        out[2] = @reduce(.Add, a2);
        out[3] = @reduce(.Add, a3);
    } else {
        out.* = .{ 0, 0, 0, 0 };
    }
    while (i < n) : (i += 1) {
        const xi: i32 = x[i];
        out[0] += @as(i32, w0[i]) * xi;
        out[1] += @as(i32, w1[i]) * xi;
        out[2] += @as(i32, w2[i]) * xi;
        out[3] += @as(i32, w3[i]) * xi;
    }
}

inline fn dotI8U8(w: []const i8, x: []const u8) i32 {
    const n = w.len;
    var i: usize = 0;
    var s: i32 = 0;
    // The vector asm constraint only compiles under the LLVM backend (Release);
    // the self-hosted backend (Debug/test) takes the scalar fallback — correctness
    // is identical, only speed differs, which is irrelevant for tests.
    if (comptime has_avx512vnni and builtin.zig_backend == .stage2_llvm) {
        var acc: @Vector(16, i32) = @splat(0);
        while (i + 64 <= n) : (i += 64) {
            const wv: @Vector(64, i8) = w[i..][0..64].*;
            const xv: @Vector(64, u8) = x[i..][0..64].*;
            // AT&T order: `vpdpbusd src2(i8), src1(u8), dst`; dst += src1(u8)·src2(i8).
            acc = asm ("vpdpbusd %[w], %[x], %[acc]"
                : [acc] "=v" (-> @Vector(16, i32)),
                : [w] "v" (wv),
                  [x] "v" (xv),
                  [accin] "0" (acc),
            );
        }
        s = @reduce(.Add, acc);
    } else if (comptime has_avx2 and builtin.zig_backend == .stage2_llvm) {
        // Single-row AVX2 twin of the dotI8U8x4 kernel (see there for exactness).
        var acc: @Vector(8, i32) = @splat(0);
        while (i + 32 <= n) : (i += 32) {
            const x0: @Vector(16, i16) = @as(@Vector(16, u8), x[i..][0..16].*);
            const x1: @Vector(16, i16) = @as(@Vector(16, u8), x[i + 16 ..][0..16].*);
            acc += madd16(@as(@Vector(16, i8), w[i..][0..16].*), x0);
            acc += madd16(@as(@Vector(16, i8), w[i + 16 ..][0..16].*), x1);
        }
        s = @reduce(.Add, acc);
    }
    while (i < n) : (i += 1) s += @as(i32, w[i]) * @as(i32, x[i]);
    return s;
}

/// ZQB4 multi-layer forward pass from a maintained accumulator. The narrow
/// accumulator (integer, scale qa) feeds crelu+pairwise_mul (stm half then ntm
/// half) -> l1 -> screlu -> l2 -> screlu -> l3 -> scalar. crelu+pairwise is exact
/// integer; the layerstack runs in f32 (l1 dequantised i8/qb at load, l2/l3 f32).
/// Matches bullet `examples/progression/4_multi_layer.rs`.
fn evaluateAccMulti(net: *const Net, acc: *const Accumulator, stm: types.Color, piece_count: usize, scale_percent: u16) i32 {
    const h = net.hidden;
    const half = h / 2;
    const l2n = net.l2_size;
    const l3n = net.l3_size;
    const qa: i32 = net.qa;
    const qaf: f32 = @floatFromInt(qa);
    const us = if (stm == .white) &acc.white else &acc.black;
    const them = if (stm == .white) &acc.black else &acc.white;

    // Per-phase output bucket: each layer's weights/biases are bucket-major; offset
    // into the bucket's slice (bucket 0 for a single-bucket net -> identical play).
    const bucket = net.bucketIndex(piece_count);
    const l1w = net.l1_weights[bucket * l2n * h ..];
    const l1b = net.l1_bias[bucket * l2n ..];
    const l2w = net.l2_weights[bucket * l3n * l2n ..];
    const l2b = net.l2_bias[bucket * l3n ..];
    const l3w = net.l3_weights[bucket * l3n ..][0..l3n];
    const l3b = net.l3_bias[bucket];

    // crelu + pairwise_mul -> p_u8[0..h] (u8); concat(stm half, ntm half).
    var p_u8: [MAX_HIDDEN]u8 align(64) = undefined;
    fillPairwiseU8(p_u8[0..half], us[0..h], qa);
    fillPairwiseU8(p_u8[half..h], them[0..h], qa);

    // l1: p_u8(h) -> z1(l2_size) via i8*u8 dot; dequant z1 = dot*256/(qb*qa^2) + l1b
    // (the 256 folds the pairwise >>8 — see fillPairwiseU8); screlu -> hl2.
    const l1_dequant: f32 = 256.0 / (@as(f32, @floatFromInt(net.qb)) * qaf * qaf);
    var hl2: [MAX_L2]f32 align(64) = undefined;
    for (0..l2n) |k| {
        const dot = dotI8U8(l1w[k * h ..][0..h], p_u8[0..h]);
        hl2[k] = screluF(@as(f32, @floatFromInt(dot)) * l1_dequant + l1b[k]);
    }

    // l2: hl2(l2_size) -> z2(l3_size); screlu -> hl3
    var hl3: [MAX_L3]f32 align(64) = undefined;
    for (0..l3n) |k| {
        hl3[k] = screluF(l2b[k] + dotF(l2w[k * l2n ..][0..l2n], hl2[0..l2n]));
    }

    // l3: hl3(l3_size) -> scalar eval
    const z3: f32 = l3b + dotF(l3w, hl3[0..l3n]);

    var out: f32 = z3 * @as(f32, @floatFromInt(net.scale)); // eval (cp) = z3 * scale
    if (scale_percent != 100) out = out * @as(f32, @floatFromInt(scale_percent)) / 100.0;
    return @intFromFloat(@round(out));
}

fn readU32(bytes: []const u8, idx: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[idx.*..][0..4], .little);
    idx.* += 4;
    return v;
}
fn readI32(bytes: []const u8, idx: *usize) i32 {
    const v = std.mem.readInt(i32, bytes[idx.*..][0..4], .little);
    idx.* += 4;
    return v;
}
fn readI16(bytes: []const u8, idx: *usize) i16 {
    const v = std.mem.readInt(i16, bytes[idx.*..][0..2], .little);
    idx.* += 2;
    return v;
}
fn readI8(bytes: []const u8, idx: *usize) i8 {
    const v: i8 = @bitCast(bytes[idx.*]);
    idx.* += 1;
    return v;
}
/// PSQT fixed-point precision (Q20) — see `Net.psqtw`.
const PSQT_Q: u6 = 20;

/// Quantize one raw f32 PSQT weight to Q20 at load time.
inline fn quantPsqt(x: f32) i32 {
    return @intFromFloat(@round(@as(f64, x) * @as(f64, @floatFromInt(@as(i64, 1) << PSQT_Q))));
}

fn readF32(bytes: []const u8, idx: *usize) f32 {
    const v: f32 = @bitCast(std.mem.readInt(u32, bytes[idx.*..][0..4], .little));
    idx.* += 4;
    return v;
}

test "nnue768 evaluates a material imbalance from the side to move" {
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const H: usize = 256;

    // Build a tiny synthetic net: validate the load round-trip + that evaluate
    // runs and is sign-correct on a constructed net.
    const net = try allocator.create(Net);
    defer net.destroy(allocator);
    net.scale = 400;
    net.qa = 255;
    net.qb = 64;
    net.hidden = H;
    net.buckets = 1;
    net.king_buckets = 1;
    net.mirror = false;
    net.table = [_]u8{0} ** 64;
    // `allocator.create` applies NO field defaults — every field `destroy` or
    // `evaluate` inspects must be set explicitly or it reads undefined memory
    // (threats/full_threats/multilayer/threat_w8).
    net.threats = false;
    net.full_threats = false;
    net.multilayer = false;
    net.threat_w8 = &.{};
    net.weight_methods = .{}; // plain heap allocs below
    net.feature_weights = try allocator.alignedAlloc(i16, .@"64", INPUTS * H);
    net.feature_bias = try allocator.alloc(i16, H);
    net.output_weights = try allocator.alignedAlloc(i16, .@"64", 2 * H);
    net.output_biases = try allocator.alloc(i16, 1);
    @memset(net.feature_weights, 0);
    @memset(net.feature_bias, 0);
    @memset(net.output_weights, 0);
    net.output_biases[0] = 0;

    // own queen (c=0, pt=4) on d1 (sq=3) from white's perspective: feat = 0 + 64*4 + 3 = 259.
    net.feature_weights[259 * H + 0] = 255; // pushes accumulator[0] to QA when that queen is present
    net.output_weights[0] = 64; // stm half, hidden 0

    const pos = try fen.parse("4k3/8/8/8/8/8/8/3QK3 w - - 0 1"); // white (stm) has a queen on d1
    const score = evaluate(net, &pos, 100);
    try std.testing.expect(score > 0);

    const pos_b = try fen.parse("4k3/8/8/8/8/8/8/3QK3 b - - 0 1");
    const score_b = evaluate(net, &pos_b, 100);
    try std.testing.expect(score_b <= 0);
}

test "nnue768 load rejects bad magic and wrong shape" {
    const allocator = std.testing.allocator;
    var buf = [_]u8{0} ** 64;
    try std.testing.expectError(error.InvalidMagic, loadFromBytes(allocator, &buf));
    @memcpy(buf[0..4], MAGIC);
    std.mem.writeInt(u32, buf[4..8], 999, .little); // wrong inputs
    std.mem.writeInt(u32, buf[8..12], 256, .little);
    try std.testing.expectError(error.UnsupportedShape, loadFromBytes(allocator, &buf));
    // hidden over MAX_HIDDEN is rejected too
    std.mem.writeInt(u32, buf[4..8], INPUTS, .little);
    std.mem.writeInt(u32, buf[8..12], MAX_HIDDEN + 1, .little);
    try std.testing.expectError(error.UnsupportedShape, loadFromBytes(allocator, &buf));
}

test "nnue768 embedded default net loads and is materially aware" {
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const net = try loadDefault(allocator);
    defer net.destroy(allocator);
    const start = try fen.startpos();
    const up_queen = try fen.parse("rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
    // At the default scale (backend.default_nnue_scale_percent = 54) the eval is
    // ~HCE centipawns: startpos near 0, a queen up is decisively positive.
    try std.testing.expect(@abs(evaluate(net, &start, 54)) < 120);
    try std.testing.expect(evaluate(net, &up_queen, 54) > 300);
}

const TreeVerifier = struct {
    net: *const Net,
    finny: *FinnyTable,
    fn walk(self: TreeVerifier, pos: *position.Position, acc: *const Accumulator, depth: u8) !void {
        const legal = @import("../movegen/legal.zig");
        // The maintained accumulator (incremental + finny king-refresh, plus the
        // ZQB5 threat bitsets / PSQT scalars for threats nets) must evaluate
        // identically to a from-scratch full refresh.
        const refresh_eval = evaluate(self.net, pos, 100);
        const inc_eval = if (self.net.threats)
            evaluateThreatsIncremental(self.net, acc, pos, 100)
        else
            evaluateAcc(self.net, acc, pos.side_to_move, @popCount(pos.occupancy()), 100);
        try std.testing.expectEqual(refresh_eval, inc_eval);
        if (depth == 0) return;
        var moves = move_mod.MoveList.init();
        legal.generate(pos, &moves);
        for (moves.slice()) |mv| {
            var state: make_unmake.StateInfo = .{};
            _ = make_unmake.makeMove(pos, mv, &state);
            var child: Accumulator = undefined;
            var chg: [MAX_MOVE_CHANGES]Change = undefined;
            const nchg = decodeMoveChanges(mv, &state, &chg);
            child.applyMove(acc, self.net, mv, &state, pos, self.finny, chg[0..nchg]);
            try self.walk(pos, &child, depth - 1);
            make_unmake.unmakeMove(pos, mv, &state);
        }
    }
};

test "nnue768 ZQB7 bucketed-psqt incremental matches refresh over a game tree" {
    // Synthetic ZQB7 (HalfKA-8 mirror, h=32, 8 output buckets, i8 threats, PER-BUCKET
    // seeded-style PSQT) with deterministic pseudo-random weights: any indexing or
    // per-bucket-scalar maintenance bug breaks incremental == refresh. This is the
    // pre-train correctness gate for the bucketed-PSQT machinery (the SF-style fix
    // for the w1024+b8 head-stall collapse).
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const H: u32 = 32;
    const B: u32 = 8;
    const KB: u32 = 8;
    const THREAT: u32 = threats_mod.NUM_THREAT_FEATURES;
    const HALFKA: u32 = INPUTS * KB;
    const FEATS: u32 = HALFKA + THREAT;
    const layout = [_]u8{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7 };
    const table = expandMirrorTable(layout);

    const i16_count: usize = HALFKA * H + H + B * 2 * H + B;
    const blob_len: usize = header5_bytes + i16_count * 2 + THREAT * H + (FEATS * B + B) * 4;
    const blob = try allocator.alloc(u8, blob_len);
    defer allocator.free(blob);

    var off: usize = 0;
    @memcpy(blob[0..4], MAGIC7);
    off = 4;
    for ([_]u32{ HALFKA, H, B, KB, 1, THREAT }) |v| {
        std.mem.writeInt(u32, blob[off..][0..4], v, .little);
        off += 4;
    }
    for ([_]i32{ 400, 255, 64 }) |v| {
        std.mem.writeInt(i32, blob[off..][0..4], v, .little);
        off += 4;
    }
    @memcpy(blob[off..][0..64], &table);
    off += 64;

    var rng: u32 = 0x9e3779b9;
    const next = struct {
        fn f(r: *u32) u32 {
            r.* = r.* *% 1664525 +% 1013904223;
            return r.* >> 8;
        }
    }.f;
    // feature rows + bias + readout: small i16s (accumulator stays far inside i16)
    for (0..i16_count) |_| {
        const v: i16 = @intCast(@as(i32, @intCast(next(&rng) % 81)) - 40);
        std.mem.writeInt(i16, blob[off..][0..2], v, .little);
        off += 2;
    }
    // threat rows: i8
    for (0..THREAT * H) |_| {
        blob[off] = @bitCast(@as(i8, @intCast(@as(i32, @intCast(next(&rng) % 41)) - 20)));
        off += 1;
    }
    // psqtw (feature-major, B per feature) + psqtb: f32 in [-2, 2]
    for (0..FEATS * B + B) |_| {
        const v: f32 = (@as(f32, @floatFromInt(next(&rng) % 4001)) - 2000.0) / 1000.0;
        std.mem.writeInt(u32, blob[off..][0..4], @bitCast(v), .little);
        off += 4;
    }
    try std.testing.expectEqual(blob_len, off);

    const net = try loadFromBytes(allocator, blob);
    defer net.destroy(allocator);
    try std.testing.expect(net.threats);
    try std.testing.expectEqual(@as(usize, B), net.psqt_buckets);
    try std.testing.expectEqual(@as(usize, THREAT * H), net.threat_w8.len);

    const finny = try allocator.create(FinnyTable);
    defer allocator.destroy(finny);
    const cases = [_]struct { f: []const u8, d: u8 }{
        .{ .f = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .d = 2 },
        .{ .f = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .d = 2 }, // captures + castling (bucket crossings)
        .{ .f = "4k3/PPPPPPPP/8/8/8/8/pppppppp/4K3 w - - 0 1", .d = 2 }, // promotions
        .{ .f = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", .d = 2 }, // en passant
        .{ .f = "8/8/8/3k4/3K4/8/8/8 w - - 0 1", .d = 4 }, // king walk (finny + low-bucket psqt)
    };
    for (cases) |c| {
        var pos = try fen.parse(c.f);
        var root_acc: Accumulator = undefined;
        root_acc.refresh(net, &pos);
        finny.reset();
        try (TreeVerifier{ .net = net, .finny = finny }).walk(&pos, &root_acc, c.d);
    }
}

test "nnue768 ZQB8 layerstack incremental matches refresh over a game tree" {
    // Synthetic ZQB8 (HalfKA-8 mirror, h=32 EVEN for pairwise, i8 threats, single-head
    // PSQT, 8 MATERIAL-BUCKETED layerstacks l1 i8 16-wide -> l2 f32 8-wide -> l3) with
    // deterministic pseudo-random weights: exercises the ZQB8 loader, the bucket-sliced
    // crelu+pairwise finisher on both eval paths (incremental == refresh), and bucket
    // crossings (captures change piece count -> different stack).
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const H: u32 = 32;
    const L2S: u32 = 16;
    const L3S: u32 = 8;
    const B: u32 = 8; // material-bucketed stacks
    const KB: u32 = 8;
    const THREAT: u32 = threats_mod.NUM_THREAT_FEATURES;
    const HALFKA: u32 = INPUTS * KB;
    const FEATS: u32 = HALFKA + THREAT;
    const layout = [_]u8{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7 };
    const table = expandMirrorTable(layout);

    const i16_count: usize = HALFKA * H + H; // l0w + l0b only (readout is the layerstack)
    const layer_bytes: usize = B * (L2S * H) + B * (L2S + L3S * L2S + L3S + L3S + 1) * 4;
    const blob_len: usize = header8_bytes + i16_count * 2 + layer_bytes + THREAT * H + (FEATS + 1) * 4;
    const blob = try allocator.alloc(u8, blob_len);
    defer allocator.free(blob);

    var off: usize = 0;
    @memcpy(blob[0..4], MAGIC8);
    off = 4;
    for ([_]u32{ HALFKA, H, B, KB, 1, L2S, L3S, THREAT }) |v| {
        std.mem.writeInt(u32, blob[off..][0..4], v, .little);
        off += 4;
    }
    for ([_]i32{ 400, 255, 64 }) |v| {
        std.mem.writeInt(i32, blob[off..][0..4], v, .little);
        off += 4;
    }
    @memcpy(blob[off..][0..64], &table);
    off += 64;

    var rng: u32 = 0x2545f491;
    const next = struct {
        fn f(r: *u32) u32 {
            r.* = r.* *% 1664525 +% 1013904223;
            return r.* >> 8;
        }
    }.f;
    // l0w + l0b: small i16s (accumulator stays far inside i16)
    for (0..i16_count) |_| {
        const v: i16 = @intCast(@as(i32, @intCast(next(&rng) % 81)) - 40);
        std.mem.writeInt(i16, blob[off..][0..2], v, .little);
        off += 2;
    }
    // l1w: i8 (bucket-major)
    for (0..B * L2S * H) |_| {
        blob[off] = @bitCast(@as(i8, @intCast(@as(i32, @intCast(next(&rng) % 41)) - 20)));
        off += 1;
    }
    // l1b, l2w, l2b, l3w, l3b: f32 in [-1, 1] (each bucket-major)
    for (0..B * (L2S + L3S * L2S + L3S + L3S + 1)) |_| {
        const v: f32 = (@as(f32, @floatFromInt(next(&rng) % 2001)) - 1000.0) / 1000.0;
        std.mem.writeInt(u32, blob[off..][0..4], @bitCast(v), .little);
        off += 4;
    }
    // threat rows: i8
    for (0..THREAT * H) |_| {
        blob[off] = @bitCast(@as(i8, @intCast(@as(i32, @intCast(next(&rng) % 41)) - 20)));
        off += 1;
    }
    // psqtw + psqtb: f32 in [-2, 2]
    for (0..FEATS + 1) |_| {
        const v: f32 = (@as(f32, @floatFromInt(next(&rng) % 4001)) - 2000.0) / 1000.0;
        std.mem.writeInt(u32, blob[off..][0..4], @bitCast(v), .little);
        off += 4;
    }
    try std.testing.expectEqual(blob_len, off);

    const net = try loadFromBytes(allocator, blob);
    defer net.destroy(allocator);
    try std.testing.expect(net.threats);
    try std.testing.expect(net.multilayer);
    try std.testing.expectEqual(@as(usize, L2S), net.l2_size);
    try std.testing.expectEqual(@as(usize, L3S), net.l3_size);
    try std.testing.expectEqual(@as(usize, THREAT * H), net.threat_w8.len);

    const finny = try allocator.create(FinnyTable);
    defer allocator.destroy(finny);
    const cases = [_]struct { f: []const u8, d: u8 }{
        .{ .f = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .d = 2 },
        .{ .f = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .d = 2 }, // captures + castling
        .{ .f = "4k3/PPPPPPPP/8/8/8/8/pppppppp/4K3 w - - 0 1", .d = 2 }, // promotions
        .{ .f = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", .d = 2 }, // en passant
        .{ .f = "8/8/8/3k4/3K4/8/8/8 w - - 0 1", .d = 4 }, // king walk (finny crossings)
    };
    for (cases) |c| {
        var pos = try fen.parse(c.f);
        var root_acc: Accumulator = undefined;
        root_acc.refresh(net, &pos);
        finny.reset();
        try (TreeVerifier{ .net = net, .finny = finny }).walk(&pos, &root_acc, c.d);
    }
}

/// Colour-mirror a FEN: rank-flip the board, swap piece colours + castling case, flip
/// the side to move and the EP rank. The two perspectives then swap roles exactly
/// (own-frame ^56 anchoring), so evaluate(pos) == evaluate(colorMirror(pos)) must hold
/// bit-for-bit for ANY net in this module — the colour-symmetry gate for feature maps.
fn colorMirrorFen(f: []const u8, buf: []u8) []const u8 {
    const swapCase = struct {
        fn s(c: u8) u8 {
            if (c >= 'a' and c <= 'z') return c - 32;
            if (c >= 'A' and c <= 'Z') return c + 32;
            return c;
        }
    }.s;
    var it = std.mem.splitScalar(u8, f, ' ');
    const board = it.next().?;
    const stm = it.next().?;
    const castle = it.next().?;
    const ep = it.next().?;
    const rest = it.rest(); // halfmove/fullmove tail (eval-irrelevant, copied verbatim)
    var ranks: [8][]const u8 = undefined;
    var nr: usize = 0;
    var rit = std.mem.splitScalar(u8, board, '/');
    while (rit.next()) |r| : (nr += 1) ranks[nr] = r;
    var n: usize = 0;
    var i = nr;
    while (i > 0) {
        i -= 1;
        for (ranks[i]) |c| {
            buf[n] = swapCase(c);
            n += 1;
        }
        if (i != 0) {
            buf[n] = '/';
            n += 1;
        }
    }
    buf[n] = ' ';
    buf[n + 1] = if (stm[0] == 'w') 'b' else 'w';
    buf[n + 2] = ' ';
    n += 3;
    if (castle[0] == '-') {
        buf[n] = '-';
        n += 1;
    } else for ([_]u8{ 'K', 'Q', 'k', 'q' }) |want| { // canonical KQkq order after the case swap
        for (castle) |c| {
            if (swapCase(c) == want) {
                buf[n] = want;
                n += 1;
            }
        }
    }
    buf[n] = ' ';
    n += 1;
    if (ep[0] == '-') {
        buf[n] = '-';
        n += 1;
    } else {
        buf[n] = ep[0];
        buf[n + 1] = if (ep[1] == '3') '6' else '3';
        n += 2;
    }
    if (rest.len != 0) {
        buf[n] = ' ';
        n += 1;
        @memcpy(buf[n..][0..rest.len], rest);
        n += rest.len;
    }
    return buf[0..n];
}

/// Build the synthetic ZQB9 test net blob (HalfKA-8 mirror, h=32 EVEN for pairwise,
/// FULL 60,144-feature i8 threat block, single-head PSQT, 8 material-bucketed
/// layerstacks l1 i8 16-wide -> l2 f32 8-wide -> l3), deterministic pseudo-random
/// weights following the ZQB8 test pattern. Shared by the loader/refresh test here
/// and the Block B incremental tree tests in eval/backend.zig + search/engine.zig
/// (test support only — never a shipping code path). Caller frees the blob.
pub fn buildZqb9TestBlob(allocator: std.mem.Allocator) ![]u8 {
    const H: u32 = 32;
    const L2S: u32 = 16;
    const L3S: u32 = 8;
    const B: u32 = 8; // material-bucketed stacks
    const KB: u32 = 8;
    const THREAT: u32 = @intCast(MAX_FULL_THREAT_INPUTS); // 60144, the only legal value
    const HALFKA: u32 = INPUTS * KB;
    const FEATS: u32 = HALFKA + THREAT;
    const layout = [_]u8{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7 };
    const table = expandMirrorTable(layout);

    const i16_count: usize = HALFKA * H + H; // l0w + l0b only (readout is the layerstack)
    const layer_bytes: usize = B * (L2S * H) + B * (L2S + L3S * L2S + L3S + L3S + 1) * 4;
    const blob_len: usize = header9_bytes + i16_count * 2 + layer_bytes + THREAT * H + (FEATS + 1) * 4;
    const blob = try allocator.alloc(u8, blob_len);
    errdefer allocator.free(blob);

    var off: usize = 0;
    @memcpy(blob[0..4], MAGIC9);
    off = 4;
    for ([_]u32{ HALFKA, H, B, KB, 1, L2S, L3S, THREAT }) |v| {
        std.mem.writeInt(u32, blob[off..][0..4], v, .little);
        off += 4;
    }
    for ([_]i32{ 400, 255, 64 }) |v| {
        std.mem.writeInt(i32, blob[off..][0..4], v, .little);
        off += 4;
    }
    @memcpy(blob[off..][0..64], &table);
    off += 64;

    var rng: u32 = 0x00c0ffee;
    const next = struct {
        fn f(r: *u32) u32 {
            r.* = r.* *% 1664525 +% 1013904223;
            return r.* >> 8;
        }
    }.f;
    // l0w + l0b: small i16s (accumulator stays far inside i16 even with ~50 threat rows)
    for (0..i16_count) |_| {
        const v: i16 = @intCast(@as(i32, @intCast(next(&rng) % 81)) - 40);
        std.mem.writeInt(i16, blob[off..][0..2], v, .little);
        off += 2;
    }
    // l1w: i8 (bucket-major)
    for (0..B * L2S * H) |_| {
        blob[off] = @bitCast(@as(i8, @intCast(@as(i32, @intCast(next(&rng) % 41)) - 20)));
        off += 1;
    }
    // l1b, l2w, l2b, l3w, l3b: f32 in [-1, 1] (each bucket-major)
    for (0..B * (L2S + L3S * L2S + L3S + L3S + 1)) |_| {
        const v: f32 = (@as(f32, @floatFromInt(next(&rng) % 2001)) - 1000.0) / 1000.0;
        std.mem.writeInt(u32, blob[off..][0..4], @bitCast(v), .little);
        off += 4;
    }
    // threat rows: i8
    for (0..THREAT * H) |_| {
        blob[off] = @bitCast(@as(i8, @intCast(@as(i32, @intCast(next(&rng) % 41)) - 20)));
        off += 1;
    }
    // psqtw + psqtb: f32 in [-0.5, 0.5] — tighter than the ZQB8 test's [-2, 2] so the
    // stm PSQT sum (~80 HalfKA+threat features in dense positions) keeps |eval| well
    // inside the refresh test's 20000 sanity bound.
    for (0..FEATS + 1) |_| {
        const v: f32 = (@as(f32, @floatFromInt(next(&rng) % 1001)) - 500.0) / 1000.0;
        std.mem.writeInt(u32, blob[off..][0..4], @bitCast(v), .little);
        off += 4;
    }
    std.debug.assert(off == blob_len);
    return blob;
}

test "nnue768 ZQB9 full-threats refresh eval" {
    // Synthetic ZQB9 (buildZqb9TestBlob). Gates: the ZQB9 loader (full_threats flag +
    // exact-threat_inputs check), the evaluateFull9 full-refresh path (determinism +
    // sane bounds on both-colour and flipped-/mixed-king positions), and colour-mirror
    // symmetry of the whole HalfKA + full-threat + PSQT + layerstack mapping.
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const H: u32 = 32; // buildZqb9TestBlob's fixed shape
    const THREAT: u32 = @intCast(MAX_FULL_THREAT_INPUTS);
    const HALFKA: u32 = INPUTS * 8; // KB = 8
    const blob = try buildZqb9TestBlob(allocator);
    defer allocator.free(blob);
    const blob_len = blob.len;

    // (a) loads with full_threats=true and the ZQB8-shaped body split (HalfKA-only l0).
    const net = try loadFromBytes(allocator, blob);
    defer net.destroy(allocator);
    try std.testing.expect(net.full_threats);
    try std.testing.expect(net.threats);
    try std.testing.expect(net.multilayer);
    try std.testing.expectEqual(@as(usize, H), net.hidden);
    try std.testing.expectEqual(MAX_FULL_THREAT_INPUTS, net.threat_inputs);
    try std.testing.expectEqual(@as(usize, THREAT * H), net.threat_w8.len);
    try std.testing.expectEqual(@as(usize, HALFKA * H), net.feature_weights.len);

    // (b)+(c): deterministic, sanely bounded, colour-mirror symmetric.
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", // e-file kings: both perspectives flipped
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1", // both-colour: black to move
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", // kiwipete: dense threats
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", // castled kings, g-file
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", // MIXED flips: Ka5 (0) vs Kh4 (7)
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", // promotion tactics
    };
    var mbuf: [128]u8 = undefined;
    for (fens) |f| {
        const pos = try fen.parse(f);
        const e1 = evaluate(net, &pos, 100);
        const e2 = evaluate(net, &pos, 100);
        try std.testing.expectEqual(e1, e2);
        try std.testing.expect(@abs(e1) < 20000);
        const mpos = try fen.parse(colorMirrorFen(f, &mbuf));
        try std.testing.expectEqual(e1, evaluate(net, &mpos, 100));
    }

    // Truncated body fails to load.
    try std.testing.expectError(error.TruncatedFile, loadFromBytes(allocator, blob[0 .. blob_len - 64]));
    // A ZQB9 header carrying the LEAN threat count (7680) is rejected outright.
    var hdr: [header9_bytes]u8 = undefined;
    @memcpy(hdr[0..header9_bytes], blob[0..header9_bytes]);
    std.mem.writeInt(u32, hdr[32..36], @intCast(threats_mod.NUM_THREAT_FEATURES), .little);
    try std.testing.expectError(error.UnsupportedShape, loadFromBytes(allocator, &hdr));
}

test "nnue768 incremental accumulator matches full refresh over a game tree" {
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    const net = try loadDefault(allocator);
    defer net.destroy(allocator);
    // This walk drives the LEAN incremental path (`evaluateThreatsIncremental`),
    // which does not apply to a ZQB9 full-threats net: that family maintains a
    // separate threat accumulator owned by `FullThreatState` in the backend, and
    // its incremental-vs-refresh equality is covered by the backend ZQB9 tree
    // tests (game trees, lazy materialization, and real searches). Lean-threats
    // incremental stays covered here by the synthetic ZQB6/ZQB7 tests above.
    if (net.full_threats) return error.SkipZigTest;
    const finny = try allocator.create(FinnyTable);
    defer allocator.destroy(finny);
    const cases = [_]struct { f: []const u8, d: u8 }{
        .{ .f = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .d = 3 },
        .{ .f = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .d = 2 }, // captures + castling
        .{ .f = "4k3/PPPPPPPP/8/8/8/8/pppppppp/4K3 w - - 0 1", .d = 2 }, // promotions (incl. capture-promos)
        .{ .f = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", .d = 2 }, // en passant
    };
    for (cases) |c| {
        var pos = try fen.parse(c.f);
        var root_acc: Accumulator = undefined;
        root_acc.refresh(net, &pos);
        finny.reset();
        try (TreeVerifier{ .net = net, .finny = finny }).walk(&pos, &root_acc, c.d);
    }
}

/// Expand a 32-entry mirrored king-bucket layout (files a-d x 8 ranks) to the
/// full 64-entry table, matching bullet's `ChessBucketsMirrored` expansion.
fn expandMirrorTable(layout: [32]u8) [64]u8 {
    const mirror = [8]usize{ 0, 1, 2, 3, 3, 2, 1, 0 };
    var t: [64]u8 = undefined;
    for (0..64) |idx| t[idx] = layout[(idx / 8) * 4 + mirror[idx % 8]];
    return t;
}

/// Build a synthetic net with deterministic, mid-range weights so any feature-
/// indexing bug (wrong bucket/flip/perspective) perturbs the eval and breaks the
/// incremental==refresh invariant. Accumulator values stay inside (0, qa)
/// unsaturated, so screlu is sensitive to even a one-unit difference.
fn buildTestNet(allocator: std.mem.Allocator, hidden: usize, king_buckets: usize, mirror: bool, table: [64]u8) !*Net {
    const inputs = INPUTS * king_buckets;
    const net = try allocator.create(Net);
    errdefer allocator.destroy(net);
    net.scale = 400;
    net.qa = 255;
    net.qb = 64;
    net.hidden = hidden;
    net.buckets = 1;
    net.king_buckets = king_buckets;
    net.mirror = mirror;
    net.table = table;
    // `allocator.create` applies NO field defaults — every field `destroy` or
    // `evaluate` inspects must be set explicitly or it reads undefined memory
    // (threats/full_threats/multilayer/threat_w8).
    net.threats = false;
    net.full_threats = false;
    net.multilayer = false;
    net.threat_w8 = &.{};
    net.weight_methods = .{}; // plain heap allocs below
    net.feature_weights = try allocator.alignedAlloc(i16, .@"64", inputs * hidden);
    errdefer allocator.free(net.feature_weights);
    net.feature_bias = try allocator.alloc(i16, hidden);
    errdefer allocator.free(net.feature_bias);
    net.output_weights = try allocator.alignedAlloc(i16, .@"64", 2 * hidden);
    errdefer allocator.free(net.output_weights);
    net.output_biases = try allocator.alloc(i16, 1);
    for (net.feature_weights, 0..) |*w, i| w.* = @as(i16, @intCast(i % 5)) - 2;
    @memset(net.feature_bias, 100);
    @memset(net.output_weights, 1);
    net.output_biases[0] = 0;
    return net;
}

test "nnue768 HalfKA incremental accumulator matches full refresh (king buckets + mirror)" {
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    var layout: [32]u8 = undefined;
    for (0..32) |i| layout[i] = @intCast(i / 2); // 16 distinct buckets (0..15)
    const net = try buildTestNet(allocator, 16, 16, true, expandMirrorTable(layout));
    defer net.destroy(allocator);
    const finny = try allocator.create(FinnyTable);
    defer allocator.destroy(finny);
    const cases = [_]struct { f: []const u8, d: u8 }{
        .{ .f = "8/8/8/3k4/3K4/8/8/8 w - - 0 1", .d = 4 }, // king walk: repeated bucket/flip changes -> finny warm-diff
        .{ .f = "4k3/8/8/4r3/4K3/8/8/8 w - - 0 1", .d = 2 }, // king capture (Kxe5)
        .{ .f = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .d = 2 }, // castling + captures
        .{ .f = "4k3/PPPPPPPP/8/8/8/8/pppppppp/4K3 w - - 0 1", .d = 2 }, // promotions (incl. capture-promos)
        .{ .f = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", .d = 2 }, // en passant
    };
    for (cases) |c| {
        var pos = try fen.parse(c.f);
        var root_acc: Accumulator = undefined;
        root_acc.refresh(net, &pos);
        finny.reset();
        try (TreeVerifier{ .net = net, .finny = finny }).walk(&pos, &root_acc, c.d);
    }
}

test "nnue768 ZQB3 round-trips king-bucket fields and validates the table" {
    const allocator = std.testing.allocator;
    const king_buckets: usize = 2;
    const hidden: usize = 4;
    const inputs = INPUTS * king_buckets;
    const weights_i16 = inputs * hidden + hidden + 2 * hidden + 1;
    const buf = try allocator.alloc(u8, header3_bytes + weights_i16 * @sizeOf(i16));
    defer allocator.free(buf);
    @memset(buf, 0);
    @memcpy(buf[0..4], MAGIC3);
    std.mem.writeInt(u32, buf[4..][0..4], @intCast(inputs), .little);
    std.mem.writeInt(u32, buf[8..][0..4], @intCast(hidden), .little);
    std.mem.writeInt(u32, buf[12..][0..4], 1, .little); // material buckets
    std.mem.writeInt(u32, buf[16..][0..4], @intCast(king_buckets), .little);
    std.mem.writeInt(u32, buf[20..][0..4], 1, .little); // mirror
    std.mem.writeInt(i32, buf[24..][0..4], 400, .little);
    std.mem.writeInt(i32, buf[28..][0..4], 255, .little);
    std.mem.writeInt(i32, buf[32..][0..4], 64, .little);
    for (0..64) |i| buf[36 + i] = @intCast(i % 2); // table -> 2 distinct buckets

    const net = try loadFromBytes(allocator, buf);
    defer net.destroy(allocator);
    try std.testing.expectEqual(@as(usize, 2), net.king_buckets);
    try std.testing.expect(net.mirror);
    try std.testing.expectEqual(@as(usize, inputs * hidden), net.feature_weights.len);
    try std.testing.expectEqual(@as(u8, 1), net.table[63]);

    // A table whose (max bucket + 1) disagrees with king_buckets is rejected.
    @memset(buf[36 .. 36 + 64], 0); // only bucket 0 present, but king_buckets=2
    try std.testing.expectError(error.UnsupportedShape, loadFromBytes(allocator, buf));
}

/// bullet-faithful perspective accumulators, computed directly from `pos` using
/// bullet's stm/ntm split + own-frame king buckets (king & piece squares `^56` for
/// the black-anchored frame, matching bulletformat's stm-relative reorientation and
/// `our_ksq/opp_ksq`). Structured by side-to-move, INDEPENDENT of the engine's
/// color-anchored refresh, and compared element-wise on the exact i64 accumulator
/// (no output-layer quantization) — so a wrong king-bucket index (e.g. raw vs `^56`)
/// is detected, which the incremental==refresh TreeVerifier cannot do (it only
/// checks self-consistency). `us` = stm perspective, `them` = ntm.
fn referenceAccums(net: *const Net, pos: *const position.Position, us: []i64, them: []i64) void {
    const ownFrame = struct {
        fn f(c: types.Color, sq: u6) u6 {
            return if (c == .white) sq else sq ^ 56;
        }
    }.f;
    const h = net.hidden;
    const stm = pos.side_to_move;
    const ntm = stm.other();
    const ourk = ownFrame(stm, pos.kingSquare(stm).?.index());
    const oppk = ownFrame(ntm, pos.kingSquare(ntm).?.index());
    const stm_bucket: usize = net.table[ourk];
    const ntm_bucket: usize = net.table[oppk];
    const stm_flip: u6 = if (net.mirror and (ourk & 7) > 3) 7 else 0;
    const ntm_flip: u6 = if (net.mirror and (oppk & 7) > 3) 7 else 0;
    for (0..h) |i| {
        us[i] = net.feature_bias[i];
        them[i] = net.feature_bias[i];
    }
    var occ = pos.occupancy();
    while (bitboard.popLsb(&occ)) |sq| {
        const p = pos.pieceAt(sq);
        const c = p.color() orelse continue;
        const ptn: usize = @intFromEnum(p.pieceType());
        const orsq = ownFrame(stm, sq.index()); // piece square in stm's frame
        const c_is_stm = (c == stm);
        const us_local: usize = (if (c_is_stm) @as(usize, 0) else 384) + 64 * ptn + @as(usize, orsq ^ stm_flip);
        const them_local: usize = (if (c_is_stm) @as(usize, 384) else 0) + 64 * ptn + @as(usize, (orsq ^ 56) ^ ntm_flip);
        const uf = net.feature_weights[(768 * stm_bucket + us_local) * h ..][0..h];
        const tf = net.feature_weights[(768 * ntm_bucket + them_local) * h ..][0..h];
        for (0..h) |i| {
            us[i] += uf[i];
            them[i] += tf[i];
        }
    }
}

test "nnue768 HalfKA feature mapping matches the bullet reference (king-relative buckets)" {
    const fen = @import("../core/fen.zig");
    const allocator = std.testing.allocator;
    var layout: [32]u8 = undefined;
    for (0..32) |i| layout[i] = @intCast(i / 2); // 16 distinct buckets (0..15), NOT rank-symmetric
    const net = try buildTestNet(allocator, 16, 16, true, expandMirrorTable(layout));
    defer net.destroy(allocator);
    const fens = [_][]const u8{
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", // black king e8: table[60]=15 vs table[60^56]=1
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1", // black to move -> black is "us"
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 b kq - 0 1",
        "8/8/8/3k4/4K3/8/8/8 w - - 0 1",
        "8/2k5/8/8/8/8/5K2/8 b - - 0 1",
        "4k3/8/8/8/8/8/8/4K2R w K - 0 1", // white king on the king side -> mirror flip
    };
    var us_ref: [16]i64 = undefined;
    var them_ref: [16]i64 = undefined;
    for (fens) |f| {
        const pos = try fen.parse(f);
        var acc: Accumulator = undefined;
        acc.refresh(net, &pos);
        referenceAccums(net, &pos, us_ref[0..16], them_ref[0..16]);
        const us = if (pos.side_to_move == .white) &acc.white else &acc.black;
        const them = if (pos.side_to_move == .white) &acc.black else &acc.white;
        for (0..16) |i| {
            try std.testing.expectEqual(us_ref[i], @as(i64, us[i]));
            try std.testing.expectEqual(them_ref[i], @as(i64, them[i]));
        }
    }
}
