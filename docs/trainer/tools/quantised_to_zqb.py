#!/usr/bin/env python3
"""Convert a bullet `quantised.bin` to zigqueen's ZQB net format (src/eval/nnue768.zig).

bullet quantised.bin layout (no header, padded up to a 64-byte boundary), in
save-format order:
    [l0w: IN*H i16][l0b: H i16][l1w: B*2*H i16][l1b: B i16]
where IN = 768 (Chess768) or 768*king_buckets (king-bucketed HalfKA), B = output
material buckets. For B>1 the bullet save format transposes l1w to bucket-major
(each bucket's 2*H weights contiguous), matching zigqueen's output_weights[b*2H..].
For a factorised HalfKA net the factoriser is already merged into l0w at save time.

Output formats (little-endian):
    ZQB1 (B==1, Chess768):      b"ZQB1" + u32 inputs(768) + u32 hidden
                                + i32 scale + i32 qa + i32 qb + weights
    ZQB2 (B>1, Chess768):       b"ZQB2" + u32 inputs(768) + u32 hidden + u32 buckets
                                + i32 scale + i32 qa + i32 qb + weights
    ZQB3 (king-bucketed HalfKA): b"ZQB3" + u32 inputs(768*king_buckets) + u32 hidden
                                + u32 buckets(material) + u32 king_buckets + u32 mirror
                                + i32 scale + i32 qa + i32 qb + u8 table[64] + weights
The 64-entry table maps king square -> king bucket, matching bullet's
ChessBucketsMirrored expansion; zigqueen indexes it by the side-relative king
square (white raw, black ^56).
"""
import argparse
import struct
import sys

BASE_INPUTS = 768
# bullet's ChessBucketsMirrored file-fold map: square file -> folded file index.
MIRROR = [0, 1, 2, 3, 3, 2, 1, 0]


def expand_table(layout: list[int], mirror: bool) -> list[int]:
    """Expand a king-bucket layout to the full 64-entry square->bucket table,
    matching bullet's ChessBuckets / ChessBucketsMirrored::new()."""
    if mirror:
        if len(layout) != 32:
            sys.exit(f"--mirror layout must have 32 entries (files a-d x 8 ranks), got {len(layout)}")
        return [layout[(idx // 8) * 4 + MIRROR[idx % 8]] for idx in range(64)]
    if len(layout) != 64:
        sys.exit(f"non-mirrored layout must have 64 entries, got {len(layout)}")
    return list(layout)


def convert_multilayer(quantised: bytes, hidden: int, l2: int, l3: int, buckets: int,
                       scale: int, qa: int, qb: int, king_buckets: int, mirror: bool,
                       table: list[int]) -> bytes:
    """ZQB4 layerstack net. bullet quantised.bin layout (save_format order):
        [l0w IN*H i16][l0b H i16][l1w l2*H i8][l1b l2 f32]
        [l2w l3*l2 f32][l2b l3 f32][l3w l3 f32][l3b 1 f32]
    l0w is input-major (no transpose); l1/l2/l3 are output-major (.transpose()),
    which is exactly the engine's read layout -> the weight blob is copied as-is."""
    inputs = BASE_INPUTS * king_buckets
    blob = (inputs * hidden + hidden) * 2 + (buckets * l2 * hidden) * 1 + (buckets * (l2 + l3 * l2 + l3 + l3 + 1)) * 4
    if len(quantised) < blob:
        sys.exit(f"quantised.bin too small: {len(quantised)} < {blob} "
                 f"(hidden={hidden} l2={l2} l3={l3} king_buckets={king_buckets}?)")
    if len(table) != 64:
        sys.exit("internal: expanded table must be 64 entries")
    if max(table) + 1 != king_buckets:
        sys.exit(f"layout declares {max(table) + 1} buckets but king_buckets={king_buckets}")
    header = (b"ZQB4"
              + struct.pack("<IIIIIII", inputs, hidden, buckets, king_buckets, int(mirror), l2, l3)
              + struct.pack("<iii", scale, qa, qb)
              + bytes(table))
    return header + quantised[:blob]


def convert(quantised: bytes, hidden: int, buckets: int, scale: int, qa: int, qb: int,
            king_buckets: int, mirror: bool, table: list[int]) -> bytes:
    inputs = BASE_INPUTS * king_buckets
    n_i16 = inputs * hidden + hidden + buckets * 2 * hidden + buckets
    nbytes = n_i16 * 2
    if len(quantised) < nbytes:
        sys.exit(f"quantised.bin too small: {len(quantised)} < {nbytes} "
                 f"(hidden={hidden} buckets={buckets} king_buckets={king_buckets}?)")
    weights = quantised[:nbytes]
    if king_buckets > 1:
        if len(table) != 64:
            sys.exit("internal: expanded table must be 64 entries")
        if max(table) + 1 != king_buckets:
            sys.exit(f"layout declares {max(table) + 1} buckets but king_buckets={king_buckets}")
        header = (b"ZQB3"
                  + struct.pack("<IIIIIiii", inputs, hidden, buckets, king_buckets, int(mirror), scale, qa, qb)
                  + bytes(table))
    elif buckets == 1:
        header = b"ZQB1" + struct.pack("<IIiii", inputs, hidden, scale, qa, qb)
    else:
        header = b"ZQB2" + struct.pack("<IIIiii", inputs, hidden, buckets, scale, qa, qb)
    return header + weights


def convert_threats(quantised: bytes, hidden: int, buckets: int, scale: int, qa: int, qb: int,
                    king_buckets: int, mirror: bool, table: list[int], threat_inputs: int) -> bytes:
    """ZQB5: king-bucketed HalfKA + lean threat features + seeded PSQT material head.
    bullet quantised.bin (save_format order):
        [l0w (HALFKA+THREAT)*H i16][l0b H i16][l1w 2*H i16][l1b 1 i16]
        [psqtw (HALFKA+THREAT) f32][psqtb 1 f32]
    l0w is feature-major: HalfKA rows [0,HALFKA) then threat rows [HALFKA,HALFKA+THREAT),
    copied as-is (the threat enumeration indexes the threat block at HALFKA+idx). psqtw/psqtb
    are raw f32 (the material head, summed over active stm features and added to the readout)."""
    if buckets != 1:
        sys.exit("ZQB5 (threats) currently supports a single output bucket only")
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    i16_count = total * hidden + hidden + buckets * 2 * hidden + buckets
    f32_count = total + 1  # psqtw[total] + psqtb[1]
    need = i16_count * 2 + f32_count * 4
    if len(quantised) < need:
        sys.exit(f"quantised.bin too small: {len(quantised)} < {need} "
                 f"(hidden={hidden} king_buckets={king_buckets} threat_inputs={threat_inputs}?)")
    if len(table) != 64:
        sys.exit("internal: expanded table must be 64 entries")
    if max(table) + 1 != king_buckets:
        sys.exit(f"layout declares {max(table) + 1} buckets but king_buckets={king_buckets}")
    header = (b"ZQB5"
              + struct.pack("<IIIIIIiii", halfka, hidden, buckets, king_buckets, int(mirror), threat_inputs, scale, qa, qb)
              + bytes(table))
    return header + quantised[:need]


def convert_threats_i8(quantised: bytes, hidden: int, buckets: int, scale: int, qa: int, qb: int,
                       king_buckets: int, mirror: bool, table: list[int], threat_inputs: int,
                       psqt_buckets: int = 1) -> bytes:
    """ZQB6: ZQB5 with the threat weight block stored i8 (clamped to [-127,127]) in a
    separate block AFTER the readout, and output material buckets supported:
        [l0w HALFKA*H i16][l0b H i16][l1w B*2H i16][l1b B i16]
        [threat_w8 THREAT*H i8][psqtw (HALFKA+THREAT) f32][psqtb 1 f32]
    The bullet quantised.bin keeps threat rows inside l0w (i16, rows [HALFKA, HALFKA+THREAT));
    this splits them out and clamps to i8 (measured on the SB1200/768 net: 0.051% of weights
    clipped, <=1cp eval drift). For B>1 the trainer must save l1w TRANSPOSED (bucket-major)."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    i16_count = total * hidden + hidden + buckets * 2 * hidden + buckets
    f32_count = total * psqt_buckets + psqt_buckets  # psqtw [feat*pb + b] + psqtb[pb]
    need = i16_count * 2 + f32_count * 4
    if len(quantised) < need:
        sys.exit(f"quantised.bin too small: {len(quantised)} < {need} "
                 f"(hidden={hidden} buckets={buckets} king_buckets={king_buckets} threat_inputs={threat_inputs}?)")
    if len(table) != 64:
        sys.exit("internal: expanded table must be 64 entries")
    if max(table) + 1 != king_buckets:
        sys.exit(f"layout declares {max(table) + 1} buckets but king_buckets={king_buckets}")

    l0w = np.frombuffer(quantised, dtype="<i2", count=total * hidden, offset=0)
    halfka_rows = l0w[: halfka * hidden]
    threat_rows = l0w[halfka * hidden:].astype(np.int32)
    clipped = int((np.abs(threat_rows) > 127).sum())
    threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
    print(f"[zqb6] threat rows -> i8: {clipped} weights clipped "
          f"({100.0 * clipped / threat_rows.size:.4f}%)")

    rest_i16_off = total * hidden * 2
    rest_i16_len = (hidden + buckets * 2 * hidden + buckets) * 2  # l0b + l1w + l1b
    psqt_off = rest_i16_off + rest_i16_len
    psqt_len = f32_count * 4

    magic = b"ZQB7" if psqt_buckets > 1 else b"ZQB6"
    if psqt_buckets > 1 and psqt_buckets != buckets:
        sys.exit(f"ZQB7 requires psqt_buckets == output buckets ({psqt_buckets} != {buckets})")
    header = (magic
              + struct.pack("<IIIIIIiii", halfka, hidden, buckets, king_buckets, int(mirror), threat_inputs, scale, qa, qb)
              + bytes(table))
    return (header
            + halfka_rows.tobytes()
            + quantised[rest_i16_off: rest_i16_off + rest_i16_len]
            + threat_i8.tobytes()
            + quantised[psqt_off: psqt_off + psqt_len])


def convert_threats_ls(quantised: bytes, hidden: int, scale: int, qa: int, qb: int,
                       king_buckets: int, mirror: bool, table: list[int], threat_inputs: int,
                       l2: int, l3: int, buckets: int = 1, magic: bytes = b"ZQB8") -> bytes:
    """ZQB8: the modern-SF readout on the threats stack — ZQB6's FT (HalfKA i16 +
    threat rows i8) + seeded PSQT head, with the single readout replaced by the
    SFNNv5-style layerstack (crelu+pairwise FT activation; l1 i8, l2/l3 f32; SINGLE
    stack, no output buckets). bullet quantised.bin layout (save_format order):
        [l0w (HALFKA+THREAT)*H i16][l0b H i16]
        [l1w L2*H i8 (transposed)][l1b L2 f32][l2w L3*L2 f32 (T)][l2b L3 f32]
        [l3w L3 f32 (T)][l3b 1 f32][psqtw (HALFKA+THREAT) f32][psqtb 1 f32]
    ZQB8 blob = header + [l0w halfka i16][l0b i16][layer blob verbatim]
                [threat_w8 THREAT*H i8][psqtw f32][psqtb f32]."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    l0_i16 = total * hidden + hidden
    layer_len = buckets * (l2 * hidden) + buckets * 4 * (l2 + l3 * l2 + l3 + l3 + 1)  # l1w i8 + f32 rest (bucket-major)
    psqt_len = (total + 1) * 4
    need = l0_i16 * 2 + layer_len + psqt_len
    if len(quantised) < need:
        sys.exit(f"quantised.bin too small: {len(quantised)} < {need} "
                 f"(hidden={hidden} l2={l2} l3={l3} king_buckets={king_buckets} threat_inputs={threat_inputs}?)")
    if len(table) != 64 or max(table) + 1 != king_buckets:
        sys.exit("bad expanded king-bucket table")

    l0w = np.frombuffer(quantised, dtype="<i2", count=total * hidden, offset=0)
    halfka_rows = l0w[: halfka * hidden]
    threat_rows = l0w[halfka * hidden:].astype(np.int32)
    clipped = int((np.abs(threat_rows) > 127).sum())
    threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
    print(f"[{magic.decode().lower()}] threat rows -> i8: {clipped} weights clipped "
          f"({100.0 * clipped / threat_rows.size:.4f}%)")

    l0b_off = total * hidden * 2
    layers_off = l0b_off + hidden * 2
    psqt_off = layers_off + layer_len

    header = (magic
              + struct.pack("<IIIIIIIIiii", halfka, hidden, buckets, king_buckets, int(mirror),
                            l2, l3, threat_inputs, scale, qa, qb)
              + bytes(table))
    return (header
            + halfka_rows.tobytes()
            + quantised[l0b_off: l0b_off + hidden * 2]
            + quantised[layers_off: layers_off + layer_len]
            + threat_i8.tobytes()
            + quantised[psqt_off: psqt_off + psqt_len])


def convert_mrl(quantised: bytes, hidden: int, prefix: int, scale: int, qa: int, qb: int,
                king_buckets: int, mirror: bool, table: list[int], threat_inputs: int,
                l2: int, l3: int, buckets: int) -> tuple[bytes, bytes]:
    """Matryoshka dual-head checkpoint -> TWO standalone ZQB8 blobs (full, prefix).
    bullet save_format order (zqHalfKA8_mrl1536p768_relabel26):
        [ft1w (HALFKA+THREAT)*P i16][ft1b P i16][ft2w ..*P i16][ft2b P i16]
        [p1w B*L2*P i8 T][p1b][p2w][p2b][p3w][p3b]    (prefix head, f32 rest)
        [l1w B*L2*H i8 T][l1b][l2w][l2b][l3w][l3b]    (full head)
        [psqtw (HALFKA+THREAT) f32][psqtb 1 f32]
    Full net FT = per-feature interleave concat(ft1[f], ft2[f]) == the sliced
    single matrix; prefix net FT = ft1 alone."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    assert hidden == 2 * prefix, "MRL converter assumes hidden == 2*prefix"
    def layer_len(h):
        return buckets * (l2 * h) + buckets * 4 * (l2 + l3 * l2 + l3 + l3 + 1)
    off = 0
    ft1w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft1b = quantised[off: off + prefix * 2]; off += prefix * 2
    ft2w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft2b = quantised[off: off + prefix * 2]; off += prefix * 2
    p_layer = quantised[off: off + layer_len(prefix)]; off += layer_len(prefix)
    l_layer = quantised[off: off + layer_len(hidden)]; off += layer_len(hidden)
    psqt = quantised[off: off + (total + 1) * 4]; off += (total + 1) * 4
    tail = quantised[off:]
    if len(tail) >= 64 or (tail and tail != (b"bullet" * 11)[: len(tail)]):
        sys.exit(f"MRL parse mismatch: consumed {off} of {len(quantised)} bytes "
                 f"(tail is not bullet's 64-byte alignment pad)")

    ft1m = ft1w.reshape(total, prefix)
    ft2m = ft2w.reshape(total, prefix)
    fullm = np.hstack([ft1m, ft2m])  # (total, hidden): per-feature column concat

    def pack(l0m, l0b_bytes, h, layers):
        halfka_rows = l0m[:halfka].astype("<i2")
        threat_rows = l0m[halfka:].astype(np.int32)
        clipped = int((np.abs(threat_rows) > 127).sum())
        threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
        print(f"[zqb8-mrl h={h}] threat rows -> i8: {clipped} clipped "
              f"({100.0 * clipped / threat_rows.size:.4f}%)")
        header = (b"ZQB8"
                  + struct.pack("<IIIIIIIIiii", halfka, h, buckets, king_buckets, int(mirror),
                                l2, l3, threat_inputs, scale, qa, qb)
                  + bytes(table))
        return header + halfka_rows.tobytes() + l0b_bytes + layers + threat_i8.tobytes() + psqt

    return pack(fullm, ft1b + ft2b, hidden, l_layer), pack(ft1m, ft1b, prefix, p_layer)


def convert_m3(quantised: bytes, hidden: int, widths: list[int], scale: int, qa: int, qb: int,
               king_buckets: int, mirror: bool, table: list[int], threat_inputs: int,
               l2: int, l3: int, buckets: int) -> list[tuple[int, bytes]]:
    """M=3 nested-specialist checkpoint (zqHalfKA8_m3_512_896_1536_relabel26) ->
    one standalone ZQB8 blob PER head: the full head (hidden) plus one per nested
    width. bullet save_format order (P = hidden/2, two stacked FTs):
        [ft1w (HALFKA+THREAT)*P i16][ft1b P i16][ft2w ..*P i16][ft2b P i16]
        [head layers for widths[0]] .. [head layers for widths[-1]]   (ascending)
        [head layers for hidden]                                      (generalist)
        [psqtw (HALFKA+THREAT) f32][psqtb 1 f32]
    where each head-layer blob = [l1w B*L2*w i8 T][l1b B*L2 f32][l2w][l2b][l3w][l3b].
    Full FT = per-feature column concat(ft1[f], ft2[f]) == the sliced single
    1536 matrix; a nested width w reads FT columns [0, w) of that matrix (and
    bias entries [0, w)), so every export shares the same nested rows. The
    shared PSQT head is appended to every blob. Returns [(width, blob), ...],
    full head last."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    prefix = hidden // 2
    assert hidden == 2 * prefix, "M3 converter assumes hidden == 2*prefix"
    widths = sorted(widths)
    for w in widths:
        if not 0 < w < hidden:
            sys.exit(f"nested width {w} outside (0, {hidden})")
    def layer_len(h):
        return buckets * (l2 * h) + buckets * 4 * (l2 + l3 * l2 + l3 + l3 + 1)
    off = 0
    ft1w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft1b = quantised[off: off + prefix * 2]; off += prefix * 2
    ft2w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft2b = quantised[off: off + prefix * 2]; off += prefix * 2
    layers = {}
    for w in widths + [hidden]:
        layers[w] = quantised[off: off + layer_len(w)]; off += layer_len(w)
    psqt = quantised[off: off + (total + 1) * 4]; off += (total + 1) * 4
    tail = quantised[off:]
    if len(tail) >= 64 or (tail and tail != (b"bullet" * 11)[: len(tail)]):
        sys.exit(f"M3 parse mismatch: consumed {off} of {len(quantised)} bytes "
                 f"(tail is not bullet's 64-byte alignment pad)")

    fullm = np.hstack([ft1w.reshape(total, prefix), ft2w.reshape(total, prefix)])  # (total, hidden)
    fullb = ft1b + ft2b  # bias bytes, column-concat order matches fullm

    def pack(h):
        l0m = fullm[:, :h]
        halfka_rows = np.ascontiguousarray(l0m[:halfka]).astype("<i2")
        threat_rows = np.ascontiguousarray(l0m[halfka:]).astype(np.int32)
        clipped = int((np.abs(threat_rows) > 127).sum())
        threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
        print(f"[zqb8-m3 h={h}] threat rows -> i8: {clipped} clipped "
              f"({100.0 * clipped / threat_rows.size:.4f}%)")
        header = (b"ZQB8"
                  + struct.pack("<IIIIIIIIiii", halfka, h, buckets, king_buckets, int(mirror),
                                l2, l3, threat_inputs, scale, qa, qb)
                  + bytes(table))
        return header + halfka_rows.tobytes() + fullb[: h * 2] + layers[h] + threat_i8.tobytes() + psqt

    return [(w, pack(w)) for w in widths] + [(hidden, pack(hidden))]


def convert_m3_zqb10_eg(quantised: bytes, hidden: int, widths: list[int], eg: int,
                        scale: int, qa: int, qb: int, king_buckets: int, mirror: bool,
                        table: list[int], threat_inputs: int,
                        l2: int, l3: int, buckets: int) -> bytes:
    """M=3 bolt checkpoint -> ONE standard ZQB10 with the EG (narrow endgame
    specialist) head as the PREFIX head and the generalist head as the FULL
    head. The m3bolt save layout is convert_m3's: trunk ft1/ft2 (stacked FTs,
    P = hidden/2 each), then one head-layer blob per nested width ASCENDING,
    then the generalist (hidden) head, then the shared PSQT. Heads other than
    `eg` (e.g. the conv896 head) are parsed and SKIPPED — ZQB10 carries exactly
    two readouts.

    Nesting: the eg head reads FT columns [0, eg) of the concat matrix (the
    same slice convert_m3 exports as the standalone ZQB8), and the engine's
    ZQB10 prefix readout pairs lane i with i+prefix/2 over lanes [0, prefix) —
    identical to the standalone eg net's pairwise (i, i+eg/2). The ZQB10
    header stores the prefix width, so prefix=512 (!= hidden/2) is just data;
    the loader's constraint is 0 < prefix < hidden, prefix even."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    prefix_ft = hidden // 2
    assert hidden == 2 * prefix_ft, "m3bolt converter assumes hidden == 2 * (per-FT width)"
    widths = sorted(widths)
    if eg not in widths:
        sys.exit(f"--zqb10-eg width {eg} not in the checkpoint's nested widths {widths}")
    if not 0 < eg < hidden or eg % 2 != 0:
        sys.exit(f"eg width {eg} must be even and inside (0, {hidden}) (ZQB10 prefix constraint)")
    def layer_len(h):
        return buckets * (l2 * h) + buckets * 4 * (l2 + l3 * l2 + l3 + l3 + 1)
    off = 0
    ft1w = np.frombuffer(quantised, dtype="<i2", count=total * prefix_ft, offset=off); off += total * prefix_ft * 2
    ft1b = quantised[off: off + prefix_ft * 2]; off += prefix_ft * 2
    ft2w = np.frombuffer(quantised, dtype="<i2", count=total * prefix_ft, offset=off); off += total * prefix_ft * 2
    ft2b = quantised[off: off + prefix_ft * 2]; off += prefix_ft * 2
    layers = {}
    for w in widths + [hidden]:
        layers[w] = quantised[off: off + layer_len(w)]; off += layer_len(w)
    psqt = quantised[off: off + (total + 1) * 4]; off += (total + 1) * 4
    tail = quantised[off:]
    if len(tail) >= 64 or (tail and tail != (b"bullet" * 11)[: len(tail)]):
        sys.exit(f"m3bolt parse mismatch: consumed {off} of {len(quantised)} bytes "
                 f"(tail is not bullet's 64-byte alignment pad)")

    fullm = np.hstack([ft1w.reshape(total, prefix_ft), ft2w.reshape(total, prefix_ft)])  # (total, hidden)
    halfka_rows = fullm[:halfka].astype("<i2")
    threat_rows = fullm[halfka:].astype(np.int32)
    clipped = int((np.abs(threat_rows) > 127).sum())
    threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
    print(f"[zqb10-eg] threat rows -> i8: {clipped} clipped "
          f"({100.0 * clipped / threat_rows.size:.4f}%)")
    skipped = [w for w in widths if w != eg]
    print(f"[zqb10-eg] full head = generalist (h={hidden}); prefix head = eg (h={eg}); "
          f"skipped nested heads: {skipped}")
    header = (b"ZQBA"
              + struct.pack("<IIIIIIIII", halfka, hidden, buckets, king_buckets, int(mirror),
                            l2, l3, threat_inputs, eg)
              + struct.pack("<iii", scale, qa, qb)
              + bytes(table))
    return (header + halfka_rows.tobytes() + ft1b + ft2b
            + layers[hidden] + layers[eg] + threat_i8.tobytes() + psqt)


def convert_mrl_zqb10(quantised: bytes, hidden: int, prefix: int, scale: int, qa: int, qb: int,
                      king_buckets: int, mirror: bool, table: list[int], threat_inputs: int,
                      l2: int, l3: int, buckets: int) -> bytes:
    """Matryoshka dual-head checkpoint -> ONE ZQB10 blob (deduped: the full FT +
    threat rows + PSQT stored once, plus BOTH readout layerstacks). Same
    quantised.bin parse as convert_mrl; see docs/MATRYOSHKA_PLAN.md (zigqueen)
    for the format spec. Header = ZQB8's header + u32 prefix appended:
        b"ZQBA" + <IIIIIIIII inputs hidden buckets king_buckets mirror l2 l3
        threat_inputs prefix> + <iii scale qa qb> + u8 table[64]
    Body: [l0w full][l0b full][full head layers][prefix head layers]
          [threat_w8 full i8][psqtw][psqtb]."""
    import numpy as np
    halfka = BASE_INPUTS * king_buckets
    total = halfka + threat_inputs
    assert hidden == 2 * prefix, "MRL converter assumes hidden == 2*prefix"
    def layer_len(h):
        return buckets * (l2 * h) + buckets * 4 * (l2 + l3 * l2 + l3 + l3 + 1)
    off = 0
    ft1w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft1b = quantised[off: off + prefix * 2]; off += prefix * 2
    ft2w = np.frombuffer(quantised, dtype="<i2", count=total * prefix, offset=off); off += total * prefix * 2
    ft2b = quantised[off: off + prefix * 2]; off += prefix * 2
    p_layer = quantised[off: off + layer_len(prefix)]; off += layer_len(prefix)
    l_layer = quantised[off: off + layer_len(hidden)]; off += layer_len(hidden)
    psqt = quantised[off: off + (total + 1) * 4]; off += (total + 1) * 4
    tail = quantised[off:]
    if len(tail) >= 64 or (tail and tail != (b"bullet" * 11)[: len(tail)]):
        sys.exit(f"MRL parse mismatch: consumed {off} of {len(quantised)} bytes "
                 f"(tail is not bullet's 64-byte alignment pad)")

    fullm = np.hstack([ft1w.reshape(total, prefix), ft2w.reshape(total, prefix)])  # (total, hidden)
    halfka_rows = fullm[:halfka].astype("<i2")
    threat_rows = fullm[halfka:].astype(np.int32)
    clipped = int((np.abs(threat_rows) > 127).sum())
    threat_i8 = np.clip(threat_rows, -127, 127).astype(np.int8)
    print(f"[zqb10] threat rows -> i8: {clipped} clipped "
          f"({100.0 * clipped / threat_rows.size:.4f}%)")
    header = (b"ZQBA"
              + struct.pack("<IIIIIIIII", halfka, hidden, buckets, king_buckets, int(mirror),
                            l2, l3, threat_inputs, prefix)
              + struct.pack("<iii", scale, qa, qb)
              + bytes(table))
    return (header + halfka_rows.tobytes() + ft1b + ft2b
            + l_layer + p_layer + threat_i8.tobytes() + psqt)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("quantised", help="bullet checkpoint quantised.bin")
    ap.add_argument("out", help="output .zqb path")
    ap.add_argument("--hidden", type=int, default=256)
    ap.add_argument("--buckets", type=int, default=1, help="output material buckets")
    ap.add_argument("--scale", type=int, default=400)
    ap.add_argument("--qa", type=int, default=255)
    ap.add_argument("--qb", type=int, default=64)
    ap.add_argument("--king-buckets", type=int, default=1,
                    help="input king buckets (1 = Chess768; >1 emits ZQB3)")
    ap.add_argument("--mirror", action="store_true",
                    help="horizontally-mirrored king buckets (32-entry layout)")
    ap.add_argument("--bucket-layout", type=str, default=None,
                    help="comma-separated king-bucket layout (32 ints if --mirror, else 64); "
                         "required when --king-buckets>1")
    ap.add_argument("--multilayer", action="store_true",
                    help="ZQB4 layerstack net (l0->l1->l2->l3); needs --l2/--l3")
    ap.add_argument("--l2", type=int, default=16, help="l1 output width (== l2 input)")
    ap.add_argument("--l3", type=int, default=32, help="l2 output width (== l3 input)")
    ap.add_argument("--threats", action="store_true",
                    help="ZQB5 HalfKA + lean threats + seeded PSQT material head")
    ap.add_argument("--threats-i8", action="store_true",
                    help="ZQB6: like --threats but the threat block is clamped to i8 "
                         "(separate block; supports output material buckets)")
    ap.add_argument("--threat-inputs", type=int, default=7680, help="lean threat feature count")
    ap.add_argument("--m3", type=str, default=None, metavar="W1,W2",
                    help="M=3 nested-specialist checkpoint: comma list of nested head widths "
                         "(e.g. 512,896; --hidden is the full/generalist width). Emits ONE "
                         "standalone ZQB8 per head: <out> = full head, <out>.m<W>.zqb per "
                         "nested width; needs --layerstack args (--l2/--l3/--buckets)")
    ap.add_argument("--zqb10", type=int, default=0, metavar="PREFIX",
                    help="matryoshka checkpoint: prefix width (e.g. 768); emits ONE deduped "
                         "dual-head ZQB10 (shared FT/PSQT + both layerstacks); needs --layerstack args")
    ap.add_argument("--zqb10-eg", type=int, default=0, metavar="EGWIDTH",
                    help="M=3 bolt checkpoint -> ONE standard ZQB10 with the EG head (this "
                         "nested width, e.g. 512) as the PREFIX head and the generalist head "
                         "as the FULL head; other nested heads are skipped. Requires --m3 "
                         "W1,W2 describing ALL the checkpoint's nested widths (the save "
                         "layout) plus the --layerstack args")
    ap.add_argument("--mrl-prefix", type=int, default=0,
                    help="matryoshka checkpoint: prefix width (e.g. 768); emits TWO ZQB8s "
                         "(<out> = full head, <out>.prefix.zqb = prefix head); needs --layerstack args")
    ap.add_argument("--layerstack", action="store_true",
                    help="ZQB8: threats stack + SFNNv5 layerstack readout (needs --l2/--l3)")
    ap.add_argument("--zqb9", action="store_true",
                    help="ZQB9: v6 full-threats (60,144, spec r2) — ZQB8 body layout with magic ZQB9; "
                         "needs --l2/--l3 and --threat-inputs 60144")
    ap.add_argument("--psqt-buckets", type=int, default=1,
                    help="PSQT head buckets (>1 with --threats-i8 emits ZQB7; must equal --buckets)")
    a = ap.parse_args()

    table: list[int] = []
    if a.king_buckets > 1:
        if not a.bucket_layout:
            sys.exit("--bucket-layout is required when --king-buckets>1")
        layout = [int(x) for x in a.bucket_layout.split(",")]
        table = expand_table(layout, a.mirror)
        derived = max(table) + 1
        if derived != a.king_buckets:
            sys.exit(f"--king-buckets={a.king_buckets} but layout declares {derived} buckets")

    if a.zqb10_eg:
        if a.king_buckets <= 1:
            sys.exit("--zqb10-eg requires king buckets (HalfKA)")
        if not a.m3:
            sys.exit("--zqb10-eg needs --m3 W1,W2 (the checkpoint's nested head widths, "
                     "which define the m3bolt save layout)")
        widths = [int(x) for x in a.m3.split(",")]
        blob = convert_m3_zqb10_eg(open(a.quantised, "rb").read(), a.hidden, widths, a.zqb10_eg,
                                   a.scale, a.qa, a.qb, a.king_buckets, a.mirror, table,
                                   a.threat_inputs, a.l2, a.l3, a.buckets)
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB10 eg-deploy] hidden={a.hidden} prefix={a.zqb10_eg} "
              f"buckets={a.buckets} l2={a.l2} l3={a.l3} king_buckets={a.king_buckets} "
              f"threat_inputs={a.threat_inputs} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.m3:
        if a.king_buckets <= 1:
            sys.exit("--m3 requires king buckets (HalfKA)")
        widths = [int(x) for x in a.m3.split(",")]
        blobs = convert_m3(open(a.quantised, "rb").read(), a.hidden, widths,
                           a.scale, a.qa, a.qb, a.king_buckets, a.mirror, table,
                           a.threat_inputs, a.l2, a.l3, a.buckets)
        for w, blob in blobs:
            path = a.out if w == a.hidden else f"{a.out}.m{w}.zqb"
            open(path, "wb").write(blob)
            kind = "full/generalist" if w == a.hidden else "nested"
            print(f"wrote {path}: {len(blob)} bytes [ZQB8 {kind} head] hidden={w} "
                  f"buckets={a.buckets} l2={a.l2} l3={a.l3} king_buckets={a.king_buckets} "
                  f"threat_inputs={a.threat_inputs} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.zqb10:
        if a.king_buckets <= 1:
            sys.exit("--zqb10 requires king buckets (HalfKA)")
        blob = convert_mrl_zqb10(open(a.quantised, "rb").read(), a.hidden, a.zqb10,
                                 a.scale, a.qa, a.qb, a.king_buckets, a.mirror, table,
                                 a.threat_inputs, a.l2, a.l3, a.buckets)
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB10 dual-head] hidden={a.hidden} prefix={a.zqb10} "
              f"buckets={a.buckets} l2={a.l2} l3={a.l3} king_buckets={a.king_buckets} "
              f"threat_inputs={a.threat_inputs} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.mrl_prefix:
        if a.king_buckets <= 1:
            sys.exit("--mrl-prefix requires king buckets (HalfKA)")
        full_blob, prefix_blob = convert_mrl(open(a.quantised, "rb").read(), a.hidden, a.mrl_prefix,
                                             a.scale, a.qa, a.qb, a.king_buckets, a.mirror, table,
                                             a.threat_inputs, a.l2, a.l3, a.buckets)
        open(a.out, "wb").write(full_blob)
        pout = a.out + ".prefix.zqb"
        open(pout, "wb").write(prefix_blob)
        print(f"wrote {a.out}: {len(full_blob)} bytes [ZQB8 full head] hidden={a.hidden}")
        print(f"wrote {pout}: {len(prefix_blob)} bytes [ZQB8 prefix head] hidden={a.mrl_prefix}")
        return

    if a.zqb9:
        if a.king_buckets <= 1:
            sys.exit("--zqb9 requires king buckets (HalfKA)")
        if a.threat_inputs != 60144:
            sys.exit(f"--zqb9 requires --threat-inputs 60144 (spec r2), got {a.threat_inputs}")
        blob = convert_threats_ls(open(a.quantised, "rb").read(), a.hidden, a.scale, a.qa, a.qb,
                                  a.king_buckets, a.mirror, table, a.threat_inputs, a.l2, a.l3,
                                  a.buckets, magic=b"ZQB9")
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB9] hidden={a.hidden} buckets={a.buckets} l2={a.l2} l3={a.l3} "
              f"king_buckets={a.king_buckets} threat_inputs={a.threat_inputs} mirror={a.mirror} "
              f"scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.layerstack:
        if a.king_buckets <= 1:
            sys.exit("--layerstack requires king buckets (HalfKA)")
        blob = convert_threats_ls(open(a.quantised, "rb").read(), a.hidden, a.scale, a.qa, a.qb,
                                  a.king_buckets, a.mirror, table, a.threat_inputs, a.l2, a.l3, a.buckets)
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB8] hidden={a.hidden} buckets={a.buckets} l2={a.l2} l3={a.l3} "
              f"king_buckets={a.king_buckets} threat_inputs={a.threat_inputs} mirror={a.mirror} "
              f"scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.threats_i8:
        if a.king_buckets <= 1:
            sys.exit("--threats-i8 requires king buckets (HalfKA)")
        blob = convert_threats_i8(open(a.quantised, "rb").read(), a.hidden, a.buckets, a.scale, a.qa, a.qb,
                                  a.king_buckets, a.mirror, table, a.threat_inputs, a.psqt_buckets)
        open(a.out, "wb").write(blob)
        fmt = "ZQB7" if a.psqt_buckets > 1 else "ZQB6"
        print(f"wrote {a.out}: {len(blob)} bytes [{fmt}] hidden={a.hidden} buckets={a.buckets} "
              f"king_buckets={a.king_buckets} threat_inputs={a.threat_inputs} mirror={a.mirror} "
              f"scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.threats:
        if a.king_buckets <= 1:
            sys.exit("--threats requires king buckets (HalfKA)")
        blob = convert_threats(open(a.quantised, "rb").read(), a.hidden, a.buckets, a.scale, a.qa, a.qb,
                               a.king_buckets, a.mirror, table, a.threat_inputs)
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB5] hidden={a.hidden} king_buckets={a.king_buckets} "
              f"threat_inputs={a.threat_inputs} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    if a.multilayer:
        if a.king_buckets <= 1:
            sys.exit("--multilayer currently requires king buckets (HalfKA)")
        blob = convert_multilayer(open(a.quantised, "rb").read(), a.hidden, a.l2, a.l3,
                                  a.buckets, a.scale, a.qa, a.qb, a.king_buckets, a.mirror, table)
        open(a.out, "wb").write(blob)
        print(f"wrote {a.out}: {len(blob)} bytes [ZQB4] hidden={a.hidden} l2={a.l2} l3={a.l3} "
              f"king_buckets={a.king_buckets} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")
        return

    blob = convert(open(a.quantised, "rb").read(), a.hidden, a.buckets, a.scale, a.qa, a.qb,
                   a.king_buckets, a.mirror, table)
    open(a.out, "wb").write(blob)
    fmt = "ZQB3" if a.king_buckets > 1 else ("ZQB1" if a.buckets == 1 else "ZQB2")
    print(f"wrote {a.out}: {len(blob)} bytes [{fmt}] hidden={a.hidden} buckets={a.buckets} "
          f"king_buckets={a.king_buckets} mirror={a.mirror} scale={a.scale} qa={a.qa} qb={a.qb}")


if __name__ == "__main__":
    main()
