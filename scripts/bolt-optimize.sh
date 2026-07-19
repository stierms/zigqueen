#!/usr/bin/env bash
# bolt-optimize.sh — llvm-bolt post-link optimization for the zigqueen binary.
#
# Layout-only transform (function reordering, ext-tsp block reordering, hot/cold
# splitting): behavior-identical by construction, verified by the d14
# node-identity gate below. Typical effect: the hot search/eval function set is
# packed from a multi-hundred-page span down to a handful of pages of hot text.
#
# Prereqs:
#   * llvm-bolt + perf2bolt (LLVM BOLT, e.g. Ubuntu's bolt-19 package). Point
#     BOLTDIR at the directory containing the binaries; a user-local extract
#     works fine: apt-get download bolt-19 && dpkg -x bolt-19_*.deb <dir>
#   * The input binary must be linked with --emit-relocs (build.zig sets
#     exe.link_emit_relocs = true).
#
# Profile notes (no-LBR mode; perf2bolt runs with -nl, which also covers
# environments without LBR such as WSL2):
#   * Record cycles on the EXACT binary you feed to this script, e.g.
#       perf record -e cycles:u -o prof.data -- <binary> search_profile 22 "<FEN>"
#     Plain samples suffice; call-graph dwarf also works (the perf wrapper below
#     adds -G so BOLT can parse the script output). More samples = better layout;
#     tens of thousands of samples across middle+endgame profiles is plenty.
#   * A profile from a NEAR-identical binary works via fdata symbol matching,
#     EXCEPT __anon_NNN suffixes shift between builds — remap them by sorted
#     ordinal per prefix before use, or simply re-record.
#
# Usage:
#   scripts/bolt-optimize.sh --binary zig-out/bin/zigqueen \
#       [--perf-data a.data [--perf-data b.data ...] | --fdata merged.fdata] \
#       [--out zig-out/bin/zigqueen-bolt]
set -euo pipefail

BOLTBIN_DEFAULT="$HOME/.local/bolt/extracted/usr/lib/llvm-19/bin"
BOLTDIR="${BOLTDIR:-$BOLTBIN_DEFAULT}"
REAL_PERF="${REAL_PERF:-$(command -v perf || true)}"

BINARY="" OUT="" FDATA=""
PERF_DATA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)    BINARY="$2"; shift 2 ;;
        --perf-data) PERF_DATA+=("$2"); shift 2 ;;
        --fdata)     FDATA="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$BINARY" && -x "$BINARY" ]] || { echo "need --binary <emit-relocs zigqueen>" >&2; exit 2; }
[[ -x "$BOLTDIR/llvm-bolt" ]] || { echo "llvm-bolt not found in $BOLTDIR (set BOLTDIR)" >&2; exit 2; }
OUT="${OUT:-${BINARY}-bolt}"
readelf -S "$BINARY" | grep -q '\.rela\.text' || {
    echo "ERROR: $BINARY has no .rela.text — rebuild with exe.link_emit_relocs = true" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "$FDATA" ]]; then
    [[ ${#PERF_DATA[@]} -gt 0 ]] || { echo "need --perf-data or --fdata" >&2; exit 2; }
    # perf wrapper: our profiles carry dwarf callchains, which make
    # `perf script -F pid,event,ip` emit multi-line samples BOLT cannot parse;
    # -G (--hide-call-graph) restores the single-line format. Also dodges
    # Ubuntu's /usr/bin/perf WSL-kernel shim by pinning the real perf.
    mkdir -p "$WORK/perfwrap"
    cat > "$WORK/perfwrap/perf" <<EOF
#!/bin/sh
case "\$*" in
  *script*-F*ip*) exec $REAL_PERF "\$@" -G ;;
  *) exec $REAL_PERF "\$@" ;;
esac
EOF
    chmod +x "$WORK/perfwrap/perf"

    parts=()
    for pd in "${PERF_DATA[@]}"; do
        part="$WORK/$(basename "$pd").fdata"
        PATH="$WORK/perfwrap:$PATH" "$BOLTDIR/perf2bolt" -nl -p "$pd" -o "$part" \
            --ignore-build-id "$BINARY" 2>&1 | grep -E 'read [0-9]+ samples|out of range|wrote' >&2
        parts+=("$part")
    done
    # merge-fdata rejects the no_lbr legacy format -> merge by summing counts.
    FDATA="$WORK/merged.fdata"
    head -1 "${parts[0]}" > "$FDATA"
    awk 'FNR==1{next} {c[$1" "$2" "$3]+=$NF} END{for(k in c) print k, c[k]}' \
        "${parts[@]}" >> "$FDATA"
fi

"$BOLTDIR/llvm-bolt" "$BINARY" -o "$OUT" -data "$FDATA" \
    --reorder-blocks=ext-tsp --reorder-functions=cdsort \
    --split-functions --split-all-cold --dyno-stats 2>&1 | \
    grep -E 'have non-empty execution profile|splitting separates|WARNING' >&2

# Gate: d14 node-identity vs the input binary on the standard 3-FEN suite.
FENS=(
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    "r1b1k2r/2qnbppp/p2ppn2/1p4B1/3NPPP1/2N2Q2/PPP4P/2KR1B1R w kq - 0 11"
    "8/2k5/3p4/p2P1p2/P2P1P2/8/8/4K3 w - - 0 1"
)
for fen in "${FENS[@]}"; do
    ref=$("$BINARY" search_profile 14 "$fen" | grep -m1 '^nodes')
    got=$("$OUT"    search_profile 14 "$fen" | grep -m1 '^nodes')
    if [[ "$ref" != "$got" ]]; then
        echo "NODE-IDENTITY FAIL: '$fen' ref=$ref got=$got" >&2
        exit 1
    fi
    echo "node-identity ok: $ref  ($fen)" >&2
done
echo "BOLTed binary: $OUT" >&2
