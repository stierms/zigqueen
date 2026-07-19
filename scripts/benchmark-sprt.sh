#!/usr/bin/env bash
# Sequential Probability Ratio Test (SPRT) wrapper for strength candidate gating.
#
# Resolves H1 / H0 far faster than fixed-game matches for decisive candidates
# while refusing to accept neutral/noisy ones. Pentanomial model via
# `model=normalized` (nElo) is default per fastchess.
#
# Environment:
#   SPRT_ELO0, SPRT_ELO1     : SPRT bounds. Defaults 0 / 10 — rejects regressions fast,
#                              accepts real gains in 2-3 min. Anything between 0 and 10 Elo
#                              is treated as "too small to care" and will hit the cap.
#   SPRT_ALPHA, SPRT_BETA    : Type I/II error. Default 0.05 / 0.05.
#   SPRT_MAX_ROUNDS          : Safety cap. Default 200 rounds = 400 games. Interpret
#                              unresolved caps through docs/TUNING.md; positive
#                              unresolved candidates get one documented extended SPRT.
#   TC, HASH_MB, THREADS, MOVE_OVERHEAD_MS, OPENINGS_FILE, OPENING_PLIES, SEED, MAXMOVES, CONCURRENCY, ARTIFACT_DIR
#                            : Standard match knobs shared with benchmark-entry.sh.

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE1_CMD="${1:-$ROOT_DIR/zig-out/bin/zigqueen}"
ENGINE2_CMD="${2:-$ROOT_DIR/zig-out/bin/zigqueen}"
ENGINE1_NAME="${ENGINE1_NAME:-zigqueen-current}"
ENGINE2_NAME="${ENGINE2_NAME:-zigqueen-baseline}"
ENGINE1_UCI_OPTIONS="${ENGINE1_UCI_OPTIONS:-}"
ENGINE2_UCI_OPTIONS="${ENGINE2_UCI_OPTIONS:-}"
CONCURRENCY="${CONCURRENCY:-$(nproc)}" # default: your core count
TC="${TC:-3+0.1}"
HASH_MB="${HASH_MB:-64}"
THREADS="${THREADS:-1}"
MOVE_OVERHEAD_MS="${MOVE_OVERHEAD_MS:-20}"
OPENINGS_FILE="${OPENINGS_FILE:-$ROOT_DIR/openings/real-openings-96.pgn}"
OPENING_PLIES="${OPENING_PLIES:-8}"
SEED="${SEED:-1}"
MAXMOVES="${MAXMOVES:-200}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"

SPRT_ELO0="${SPRT_ELO0:-0}"
SPRT_ELO1="${SPRT_ELO1:-10}"
SPRT_ALPHA="${SPRT_ALPHA:-0.05}"
SPRT_BETA="${SPRT_BETA:-0.05}"
SPRT_MAX_ROUNDS="${SPRT_MAX_ROUNDS:-200}"

TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
MATCH_BASENAME="fastchess-sprt-${SPRT_ELO0}-${SPRT_ELO1}-${TC//[^[:alnum:]]/-}-${TIMESTAMP}"
PGN_FILE="$ARTIFACT_DIR/${MATCH_BASENAME}.pgn"
LOG_FILE="$ARTIFACT_DIR/${MATCH_BASENAME}.log"
STDOUT_FILE="$ARTIFACT_DIR/${MATCH_BASENAME}.stdout.txt"

mkdir -p "$ARTIFACT_DIR"

build_engine_args() {
  local cmd="$1"
  local name="$2"
  local extra_options="$3"
  local -n out_ref="$4"

  out_ref=(-engine "cmd=$cmd" "name=$name")
  if [[ -n "$extra_options" ]]; then
    IFS=';' read -r -a option_pairs <<< "$extra_options"
    for option_pair in "${option_pairs[@]}"; do
      [[ -z "$option_pair" ]] && continue
      out_ref+=("option.$option_pair")
    done
  fi
}

build_engine_args "$ENGINE1_CMD" "$ENGINE1_NAME" "$ENGINE1_UCI_OPTIONS" engine1_args
build_engine_args "$ENGINE2_CMD" "$ENGINE2_NAME" "$ENGINE2_UCI_OPTIONS" engine2_args

fastchess \
  "${engine1_args[@]}" \
  "${engine2_args[@]}" \
  -each proto=uci tc="$TC" option.Hash="$HASH_MB" option.Threads="$THREADS" option.Move\ Overhead="$MOVE_OVERHEAD_MS" \
  -openings file="$OPENINGS_FILE" format=pgn order=sequential plies="$OPENING_PLIES" \
  -srand "$SEED" \
  -rounds "$SPRT_MAX_ROUNDS" -repeat -concurrency "$CONCURRENCY" \
  -sprt elo0="$SPRT_ELO0" elo1="$SPRT_ELO1" alpha="$SPRT_ALPHA" beta="$SPRT_BETA" model=normalized \
  -draw movenumber=40 movecount=8 score=20 \
  -resign movecount=4 score=700 \
  -maxmoves "$MAXMOVES" \
  -pgnout file="$PGN_FILE" notation=uci pv=true append=false \
  -log file="$LOG_FILE" level=info append=false engine=true \
  2>&1 | tee "$STDOUT_FILE"

"$ROOT_DIR/scripts/summarize-match-pgn.py" \
  --pgn "$PGN_FILE" \
  --log "$LOG_FILE" \
  --out "$ARTIFACT_DIR/summary.txt" \
  --transcript "$STDOUT_FILE" \
  --engine1 "$ENGINE1_NAME" \
  --engine2 "$ENGINE2_NAME" \
  --metadata "sprt_elo0=$SPRT_ELO0" \
  --metadata "sprt_elo1=$SPRT_ELO1" \
  --metadata "sprt_alpha=$SPRT_ALPHA" \
  --metadata "sprt_beta=$SPRT_BETA" \
  --metadata "sprt_max_rounds=$SPRT_MAX_ROUNDS" \
  --metadata "tc=$TC" \
  --metadata "concurrency=$CONCURRENCY" \
  --metadata "openings_file=$OPENINGS_FILE" \
  --metadata "seed=$SEED"
