#!/usr/bin/env python3
"""Net sanity gate — run BEFORE spending any SPRT/SPSA compute on a candidate net.

A dual-perspective NNUE evals from the side-to-move's view, so a position and its
COLOR-MIRROR (vertical flip + swap colors + swap stm) MUST evaluate near-identically.
A large residual means the net never learned the symmetry => miscalibrated/undertrained.
Also checks material monotonicity, magnitude, and startpos ~= 0.

Usage: net-sanity.py <net.zqb> [path/to/zigqueen]
Exit 0 = PASS, 1 = FAIL (asymmetry or monotonicity violated).
"""
import subprocess, sys, os

NET = sys.argv[1]
ENGINE = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "zigqueen")

# (label, fen, expected_sign_band) — white to move, white up the named material (eval should be +).
SUITE = [
    ("startpos",   "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        "zero"),
    ("P_up",       "rnbqkbnr/1ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        "small"),
    ("N_up",       "r1bqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        "minor"),
    ("B_up",       "rn1qkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        "minor"),
    ("R_up",       "1nbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQk - 0 1",         "rook"),
    ("Q_up",       "rnb1kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",        "queen"),
    ("mid_even",   "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3", "zero"),
    ("italian",    "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 5", "zero"),
    ("KP_end",     "8/8/8/4k3/8/4K3/4P3/8 w - - 0 1",                                 "any"),
    ("3P_end",     "8/3k4/8/8/3K4/8/3PPP2/8 w - - 0 1",                               "rook"),
]


def color_mirror(fen):
    p = fen.split()
    board, stm, castle, ep = p[0], p[1], (p[2] if len(p) > 2 else "-"), (p[3] if len(p) > 3 else "-")
    new_board = "/".join(r.swapcase() for r in reversed(board.split("/")))
    new_stm = "b" if stm == "w" else "w"
    new_castle = "-" if castle == "-" else "".join(c for c in "KQkq" if c in castle.swapcase()) or "-"
    new_ep = "-" if ep == "-" else ep[0] + str(9 - int(ep[1]))
    return " ".join([new_board, new_stm, new_castle, new_ep] + p[4:])


def evals(fens):
    tmp = "/tmp/_sanity_fens.txt"
    open(tmp, "w").write("\n".join(fens) + "\n")
    out = subprocess.run([ENGINE, "nnue_dump", NET, tmp], capture_output=True, text=True).stdout
    return [int(l.split(";")[0]) for l in out.splitlines() if l.strip()]


fens = [f for _, f, _ in SUITE]
mirr = [color_mirror(f) for f in fens]
ev = evals(fens + mirr)
N = len(SUITE)
orig, mr = ev[:N], ev[N:]

print(f"net: {NET}")
print(f"{'pos':10} {'eval':>7} {'mirror':>7} {'|asym|':>7}")
worst = 0
by = {}
for (label, _, band), e, m in zip(SUITE, orig, mr):
    asym = abs(e - m)
    worst = max(worst, asym)
    by[label] = e
    flag = "  <== ASYMMETRIC" if asym > 50 else ("  <- warn" if asym > 15 else "")
    print(f"{label:10} {e:7d} {m:7d} {asym:7d}{flag}")

# monotonicity (white-perspective, up material): Q>=R>=B~=N>=P>=~0
mono_ok = by["Q_up"] >= by["R_up"] >= max(by["B_up"], by["N_up"]) - 30 and min(by["B_up"], by["N_up"]) >= by["P_up"] - 30 >= -30
print()
print(f"symmetry:    worst |asym| = {worst} cp   {'PASS' if worst <= 50 else 'FAIL'}")
print(f"monotonic:   Q{by['Q_up']} R{by['R_up']} B{by['B_up']} N{by['N_up']} P{by['P_up']}   {'PASS' if mono_ok else 'FAIL'}")
print(f"magnitude:   Q_up={by['Q_up']} (info only — WDL-hot; healthy shipped nets span ~1300..2100)")
print(f"startpos:    {by['startpos']} (|.|<100)   {'ok' if abs(by['startpos']) < 100 else 'WARN'}")
ok = worst <= 50 and mono_ok
print(f"\nVERDICT: {'PASS — safe to spend SPRT/SPSA' if ok else 'FAIL — net is miscalibrated; do NOT test, investigate (capacity/init/training/data)'}")
sys.exit(0 if ok else 1)
