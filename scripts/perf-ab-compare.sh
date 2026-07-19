#!/usr/bin/env bash
# Run the standard zigqueen representative perf-stat A/B comparison for two binaries.
#
# Usage:
#   scripts/perf-ab-compare.sh OUT_DIR BASELINE_BIN CANDIDATE_BIN [REPEATS]
#
# The script intentionally compares already-built binaries so a performance probe can
# copy its candidate binary, revert/rebuild the baseline, and then run a same-session
# binary A/B without changing source during measurement.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 OUT_DIR BASELINE_BIN CANDIDATE_BIN [REPEATS]" >&2
  exit 2
fi

OUT_DIR=$1
BASELINE_BIN=$2
CANDIDATE_BIN=$3
REPEATS=${4:-15}

if [[ ! -x "$BASELINE_BIN" ]]; then
  echo "baseline binary is not executable: $BASELINE_BIN" >&2
  exit 2
fi
if [[ ! -x "$CANDIDATE_BIN" ]]; then
  echo "candidate binary is not executable: $CANDIDATE_BIN" >&2
  exit 2
fi
if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || [[ "$REPEATS" -lt 1 ]]; then
  echo "repeats must be a positive integer: $REPEATS" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

KIWIPETE_C42_FEN='r3k2r/p1ppqpb1/bn2pnp1/2P5/1p2P3/2N2N2/PPQPBPPP/R3K2R w KQkq - 0 1'

run_case() {
  local label=$1
  local depth=$2
  local position=$3

  perf stat -r "$REPEATS" -- "$BASELINE_BIN" bench "$depth" "$position" \
    > "$OUT_DIR/baseline-${label}.stdout.txt" \
    2> "$OUT_DIR/baseline-${label}.stderr.txt"
  perf stat -r "$REPEATS" -- "$CANDIDATE_BIN" bench "$depth" "$position" \
    > "$OUT_DIR/candidate-${label}.stdout.txt" \
    2> "$OUT_DIR/candidate-${label}.stderr.txt"
  scripts/compare-perf-stat.py \
    "$OUT_DIR/baseline-${label}.stderr.txt" \
    "$OUT_DIR/candidate-${label}.stderr.txt" \
    > "$OUT_DIR/compare-${label}.tsv"
}

{
  echo "tool=perf-ab-compare"
  echo "baseline_bin=$BASELINE_BIN"
  echo "candidate_bin=$CANDIDATE_BIN"
  echo "repeats=$REPEATS"
  date --iso-8601=seconds
} > "$OUT_DIR/context.txt"

run_case startpos-d13 13 startpos
run_case c42kiwi-d12 12 "$KIWIPETE_C42_FEN"

{
  echo "# perf A/B summary"
  echo
  echo "baseline_bin=$BASELINE_BIN"
  echo "candidate_bin=$CANDIDATE_BIN"
  echo "repeats=$REPEATS"
  echo
  echo "## startpos d13"
  echo
  cat "$OUT_DIR/compare-startpos-d13.tsv"
  echo
  echo "## c42kiwi d12"
  echo
  cat "$OUT_DIR/compare-c42kiwi-d12.tsv"
} > "$OUT_DIR/summary.txt"
