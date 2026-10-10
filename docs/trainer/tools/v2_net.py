#!/usr/bin/env python3
"""v2 nets (16 king buckets + PP1 pawn pairs, ZQBA): CPU replica of bullet's export, conversion of
quantised.bin to ZQBA, the range gate, and stripping to ZQB9. Adapted from the B3 pilot's
b3_net.py (8 buckets) and lane b12's b12_check_net.py (range gate); the ZQB9 part is produced by the
pinned production converter (quantised_to_zqb.py b3a1b93e..., convert_threats_ls with 16 king
buckets and the B2 arm (e) table), so it is byte-identical to the standard exporter by construction.

  replica  --weights W.bin --out quantised.bin       (CPU copy of bullet save_quantised, float layout)
  convert  --quantised Q.bin --out NET.zqba [--report R.json]
  check    --net NET.zqba --out R.json               (range gate; exit 1 on failure)
  strip    --net NET.zqba --out NET.zqb9
  attach   --net K16.zqb9 --seed S --out NET.zqba    (parity-only: seeded pawn block on a 16-bucket ZQB9)
"""
import argparse
import hashlib
import importlib.util
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent
FT, FAC, KB, THREAT, PP1 = 1024, 768, 16, 60144, 1488
HALFKA = 768 * KB
NB, L2, L3 = 8, 16, 32
ROWS = FAC + HALFKA + THREAT + PP1
DEPLOYED = HALFKA + THREAT + PP1
PAWN0 = FAC + HALFKA + THREAT
PP1_LAYOUT = 2
PP1_MAX_ACTIVE = 120
ZQB9_HEADER = 112
ZQBA_HEADER = 120
LAYER_BYTES = NB * L2 * FT + NB * (L2 + L3 * L2 + L3 + L3 + 1) * 4
ZQB9_BYTES = ZQB9_HEADER + HALFKA * FT * 2 + FT * 2 + LAYER_BYTES + THREAT * FT + (HALFKA + THREAT + 1) * 4
ZQBA_BYTES = ZQB9_BYTES + 8 + PP1 * FT + PP1 * 4
PINNED = {"quantised_to_zqb.py": "b3a1b93e2f1423e03fb0f154e617dbcb4cbff4e5e2feaddaab061dbcb05bdc11"}
BUCKET_LAYOUT = [0, 1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 12, 12, 13, 13, 14, 14, 15, 15, 14, 14, 15, 15]
f32 = np.float32
assert ZQB9_BYTES == 87195220 and ZQBA_BYTES == 88724892


def sha(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def sha_bytes(b):
    return hashlib.sha256(b).hexdigest()


def require(cond, msg):
    if not cond:
        raise SystemExit(f"FAIL: {msg}")


def round_away(x):
    x = np.asarray(x, dtype=np.float64)
    return np.copysign(np.floor(np.abs(x) + 0.5), x)


def pp1_live_mask():
    live = np.ones(PP1, dtype=bool)
    for c in range(4):
        l_opp, r_opp = bool(c & 2), bool(c & 1)
        for f in range(7):
            for lr in range(1, 7):
                for rr in range(1, 7):
                    if abs(lr - rr) != 1:
                        continue
                    lower_opp, upper_opp = (l_opp, r_opp) if lr < rr else (r_opp, l_opp)
                    if not (lower_opp and not upper_opp):
                        live[480 + c * 252 + f * 36 + 6 * (lr - 1) + (rr - 1)] = False
    assert int(live.sum()) == 1278
    return live


def expected_table():
    return bytes(BUCKET_LAYOUT[rank * 4 + min(f, 7 - f)] for rank in range(8) for f in range(8))


def read_net(path_or_bytes):
    """Parse a v2 ZQB9 (16 buckets) or ZQBA file into arrays (views into the bytes)."""
    raw = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else Path(path_or_bytes).read_bytes()
    magic = raw[:4]
    require(magic in (b"ZQB9", b"ZQBA"), f"magic {magic!r}")
    fields = struct.unpack_from("<8I", raw, 4)
    require(fields == (HALFKA, FT, NB, KB, 1, L2, L3, THREAT), f"ZQB9 header fields {fields}")
    off = 36
    pawn = 0
    if magic == b"ZQBA":
        pawn, layout = struct.unpack_from("<2I", raw, off)
        require(pawn == PP1 and layout == PP1_LAYOUT, f"pawn header {pawn} {layout}")
        off += 8
    require(struct.unpack_from("<3i", raw, off) == (400, 255, 64), "scales")
    off += 12
    require(raw[off:off + 64] == expected_table(), "king bucket table")
    off += 64
    out = {"magic": magic, "raw": raw}
    for name, dtype, shape in [
        ("base", "<i2", (HALFKA, FT)), ("bias", "<i2", (FT,)),
        ("l1w", "i1", (NB * L2, FT)), ("l1b", "<f4", (NB * L2,)),
        ("l2w", "<f4", (NB * L3, L2)), ("l2b", "<f4", (NB * L3,)),
        ("l3w", "<f4", (NB, L3)), ("l3b", "<f4", (NB,)),
        ("threat", "i1", (THREAT, FT)), ("psqtw", "<f4", (HALFKA + THREAT,)), ("psqtb", "<f4", (1,)),
    ] + ([("pawn", "i1", (PP1, FT)), ("pawn_psqtw", "<f4", (PP1,))] if pawn else []):
        n = math.prod(shape) * np.dtype(dtype).itemsize
        out[name] = np.frombuffer(raw, dtype=dtype, count=math.prod(shape), offset=off).reshape(shape)
        off += n
    require(off == len(raw), f"size {len(raw)} != parsed {off}")
    return out


def strip(raw):
    """ZQBA -> ZQB9 bytes (magic, drop the two pawn header words and the appended block)."""
    require(raw[:4] == b"ZQBA", "not ZQBA")
    body_end = len(raw) - PP1 * FT - PP1 * 4
    return b"ZQB9" + raw[4:36] + raw[44:body_end]


def attach(zqb9, pawn_i8, pawn_psqt):
    require(zqb9[:4] == b"ZQB9" and len(zqb9) == ZQB9_BYTES, "attach needs a v2-shaped ZQB9")
    header = b"ZQBA" + zqb9[4:36] + struct.pack("<2I", PP1, PP1_LAYOUT) + zqb9[36:ZQB9_HEADER]
    return header + zqb9[ZQB9_HEADER:] + np.asarray(pawn_i8, "i1").tobytes() + np.asarray(pawn_psqt, "<f4").tobytes()


# ------------------------------------------------------------------ range gate

def gate(raw):
    """lane b12's range gate for ZQB9 (any king buckets) extended by the pawn block: f32 parts
    finite, threat and pawn i8 inside +-127, dead PP1 rows exactly zero, per-row L1 bound
    254*sum|q| < 2^24, and the per-coordinate i16 accumulator bound: |bias| + per king bucket the
    32 largest per-square maxima over the 12 piece planes + top-128 |threat| (per 64-lane block,
    b12 rule) + top-120 |pawn| (PP1 legal maximum)."""
    net = read_net(raw)
    require(net["magic"] == b"ZQBA", "not ZQBA")
    live = pp1_live_mask()
    base, threat, bias, pawn = net["base"], net["threat"], net["bias"], net["pawn"]
    q = net["l1w"].reshape(NB * L2, FT).astype(np.int64)
    l1 = int((254 * np.abs(q).sum(axis=1)).max())
    ab = np.abs(base.astype(np.int64))
    naive_b = np.sort(ab, axis=0)[-32:].sum(axis=0)
    per_square = ab.reshape(KB, 12, 64, FT).max(axis=1)
    legal_b = np.sort(per_square, axis=1)[:, -32:, :].sum(axis=1).max(axis=0)
    th = np.zeros(FT, dtype=np.int64)
    for s in range(0, FT, 64):
        th[s:s + 64] = np.sort(np.abs(threat[:, s:s + 64].astype(np.int64)), axis=0)[-128:].sum(axis=0)
    pw = np.sort(np.abs(pawn.astype(np.int64)), axis=0)[-PP1_MAX_ACTIVE:].sum(axis=0)
    b0 = np.abs(bias.astype(np.int64))
    naive, legal = int((b0 + naive_b + th + pw).max()), int((b0 + legal_b + th + pw).max())
    finite = all(bool(np.isfinite(net[n]).all()) for n in ("l1b", "l2w", "l2b", "l3w", "l3b", "psqtw", "psqtb", "pawn_psqtw"))
    pp = net["pawn_psqtw"]
    rep = {"bytes": len(raw), "sha256": sha_bytes(raw), "zqb9_part_sha256": sha_bytes(strip(raw)), "king_buckets": KB,
           "f32_finite": finite, "threat_min": int(threat.min()), "threat_max": int(threat.max()),
           "pawn_min": int(pawn.min()), "pawn_max": int(pawn.max()),
           "dead_pp1_rows_zero": bool(np.all(pawn[~live] == 0) and np.all(pp[~live].view("<u4") == 0)),
           "psqt_abs_max": float(max(np.abs(net["psqtw"]).max(), np.abs(pp).max())),
           "max_l1_bound_254_sum_abs_q_per_row": l1, "l1_bound_ok": l1 < 2 ** 24,
           "accumulator_naive_bound": naive, "accumulator_legal_bound": legal, "accumulator_i16_safe": legal <= 32767,
           "pawn_nonzero_weights": int(np.count_nonzero(pawn)), "pawn_block_worst_lane_bound": int(pw.max())}
    rep["pass"] = bool(finite and rep["threat_min"] >= -127 and rep["pawn_min"] >= -127 and rep["pawn_max"] <= 127
                       and rep["dead_pp1_rows_zero"] and rep["psqt_abs_max"] < 2048 and rep["l1_bound_ok"]
                       and rep["accumulator_i16_safe"])
    return rep


# ------------------------------------------------------------------ named masters, export replica

def write_named(path, named):
    with open(path, "xb") as f:
        for name in sorted(named):
            v = np.asarray(named[name], dtype="<f4").ravel()
            require(np.isfinite(v).all(), f"nonfinite {name}")
            f.write(name.encode() + b"\n" + struct.pack("<Q", v.size))
            f.write(v.tobytes())


def read_named(path):
    raw = Path(path).read_bytes()
    out, p = {}, 0
    while p < len(raw):
        e = raw.index(b"\n", p)
        name = raw[p:e].decode()
        n = struct.unpack_from("<Q", raw, e + 1)[0]
        out[name] = np.frombuffer(raw, dtype="<f4", count=n, offset=e + 9)
        p = e + 9 + 4 * n
    return out


def replica(named):
    """CPU copy of the v2 trainer's save_quantised (float layout masters)."""
    w = named["l0w"].reshape(ROWS, FT)
    out = np.empty((DEPLOYED, FT), dtype=f32)
    out[:HALFKA] = (w[FAC:FAC + HALFKA] + w[np.arange(HALFKA) % FAC]).astype(f32)
    out[HALFKA:] = w[FAC + HALFKA:]

    def q(x, mult, dtype, lo, hi):
        v = round_away(np.asarray(x, dtype=f32).astype(np.float64) * mult)
        require(v.min() >= lo and v.max() <= hi, f"quantisation range {dtype}")
        return v.astype(dtype).tobytes()
    parts = [q(out, 255, "<i2", -32768, 32767), q(named["l0b"], 255, "<i2", -32768, 32767),
             q(named["l1w"].reshape(FT, NB * L2).T, 64, "i1", -128, 127),
             np.asarray(named["l1b"], "<f4").tobytes(),
             np.ascontiguousarray(named["l2w"].reshape(L2, NB * L3).T).astype("<f4").tobytes(),
             np.asarray(named["l2b"], "<f4").tobytes(),
             np.ascontiguousarray(named["l3w"].reshape(L3, NB).T).astype("<f4").tobytes(),
             np.asarray(named["l3b"], "<f4").tobytes()]
    ps = named["psqtw"]
    pout = np.empty(DEPLOYED, dtype=f32)
    pout[:HALFKA] = (ps[FAC:FAC + HALFKA] + ps[np.arange(HALFKA) % FAC]).astype(f32)
    pout[HALFKA:] = ps[FAC + HALFKA:]
    parts += [pout.astype("<f4").tobytes(), np.asarray(named["psqtb"], "<f4").tobytes()]
    buf = b"".join(parts)
    pad = len(buf) % 64
    if pad:
        buf += bytes((b"bullet"[i % 6] for i in range(64 - pad)))
    return buf


# ------------------------------------------------------------------ quantised.bin -> ZQBA

def production_converter():
    path = TOOLS / "quantised_to_zqb.py"
    require(sha(path) == PINNED["quantised_to_zqb.py"], "pinned production converter changed")
    spec = importlib.util.spec_from_file_location("quantised_to_zqb", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def convert(qbytes):
    l0_bytes = DEPLOYED * FT * 2
    need = l0_bytes + FT * 2 + LAYER_BYTES + (DEPLOYED + 1) * 4
    require(len(qbytes) >= need and len(qbytes) - need < 64, f"quantised.bin size {len(qbytes)} vs {need}")
    l0 = np.frombuffer(qbytes, dtype="<i2", count=DEPLOYED * FT).reshape(DEPLOYED, FT)
    rest = qbytes[l0_bytes:l0_bytes + FT * 2 + LAYER_BYTES]
    psqt = np.frombuffer(qbytes, dtype="<f4", count=DEPLOYED + 1, offset=l0_bytes + FT * 2 + LAYER_BYTES)
    # ZQB9-layout quantised buffer (pawn rows removed) through the production converter.
    q9 = (l0[:HALFKA + THREAT].tobytes() + rest + psqt[:HALFKA + THREAT].tobytes() + psqt[-1:].tobytes())
    mod = production_converter()
    table = list(expected_table())
    zqb9 = mod.convert_threats_ls(q9, FT, 400, 255, 64, KB, True, table, THREAT, L2, L3, NB, magic=b"ZQB9")
    require(len(zqb9) == ZQB9_BYTES, "production ZQB9 size")
    rows = l0[HALFKA + THREAT:].astype(np.int32)
    clipped = int((np.abs(rows) > 127).sum())
    pawn_i8 = np.clip(rows, -127, 127).astype("i1")
    pawn_psqt = np.asarray(psqt[HALFKA + THREAT:HALFKA + THREAT + PP1], dtype="<f4")
    zqba = attach(zqb9, pawn_i8, pawn_psqt)
    require(strip(zqba) == zqb9, "strip(convert) != production ZQB9")
    report = {"zqb9_sha256": sha_bytes(zqb9), "pawn_weights_clipped": clipped, "zqba_sha256": sha_bytes(zqba), "bytes": len(zqba)}
    return zqba, report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("replica"); s.add_argument("--weights", required=True); s.add_argument("--out", required=True)
    s = sub.add_parser("convert"); s.add_argument("--quantised", required=True); s.add_argument("--out", required=True)
    s.add_argument("--report")
    s = sub.add_parser("check"); s.add_argument("--net", required=True); s.add_argument("--out", required=True)
    s = sub.add_parser("strip"); s.add_argument("--net", required=True); s.add_argument("--out", required=True)
    s = sub.add_parser("attach"); s.add_argument("--net", required=True); s.add_argument("--seed", type=int, required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.cmd == "replica":
        buf = replica(read_named(a.weights))
        with open(a.out, "xb") as f:
            f.write(buf)
        print(json.dumps({"replica_sha256": sha_bytes(buf), "bytes": len(buf)}))
    elif a.cmd == "convert":
        out, report = convert(Path(a.quantised).read_bytes())
        with open(a.out, "xb") as f:
            f.write(out)
        report.update({"quantised_sha256": sha(a.quantised), "out_sha256": sha(a.out)})
        if a.report:
            Path(a.report).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
    elif a.cmd == "check":
        rep = gate(Path(a.net).read_bytes())
        rep["net"] = str(a.net)
        Path(a.out).write_text(json.dumps(rep, indent=1) + "\n")
        print(json.dumps(rep, indent=1))
        raise SystemExit(0 if rep["pass"] else 1)
    elif a.cmd == "strip":
        out = strip(Path(a.net).read_bytes())
        with open(a.out, "xb") as f:
            f.write(out)
        print(json.dumps({"zqb9_sha256": sha(a.out)}))
    else:
        # Parity-only: live rows mostly |w| <= 25 (i8), about 0.2 % at 60..127 (the clip edge), PSQT
        # |p| <= 0.05; dead rows zero. Never a training start.
        zqb9 = Path(a.net).read_bytes()
        rng = np.random.default_rng(a.seed)
        live = pp1_live_mask()
        block = rng.integers(-25, 26, size=(PP1, FT))
        big = rng.random((PP1, FT)) < 0.002
        block[big] = rng.integers(60, 128, size=int(big.sum())) * rng.choice([-1, 1], size=int(big.sum()))
        block[~live] = 0
        ps = rng.uniform(-0.05, 0.05, size=PP1).astype(f32)
        ps[~live] = 0
        out = attach(zqb9, block.astype("i1"), ps)
        with open(a.out, "xb") as f:
            f.write(out)
        print(json.dumps({"zqba_sha256": sha(a.out), "seed": a.seed, "source_sha256": sha(a.net)}))


if __name__ == "__main__":
    main()
