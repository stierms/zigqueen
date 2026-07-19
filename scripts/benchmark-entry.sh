#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE1_CMD="${1:-$ROOT_DIR/zig-out/bin/zigqueen}"
ENGINE2_CMD="${2:-$ROOT_DIR/zig-out/bin/zigqueen}"
ENGINE1_NAME="${ENGINE1_NAME:-zigqueen-a}"
ENGINE2_NAME="${ENGINE2_NAME:-zigqueen-b}"
ENGINE1_UCI_OPTIONS="${ENGINE1_UCI_OPTIONS:-}"
ENGINE2_UCI_OPTIONS="${ENGINE2_UCI_OPTIONS:-}"
GAMES="${GAMES:-192}"
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

if (( GAMES % 2 != 0 )); then
  echo "GAMES must be even because fastchess rounds are color-paired." >&2
  exit 1
fi

ROUNDS=$(( GAMES / 2 ))
TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
MATCH_BASENAME="fastchess-real-openings-${ROUNDS}x2-${TC//[^[:alnum:]]/-}-${TIMESTAMP}"
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
  -rounds "$ROUNDS" -repeat -concurrency "$CONCURRENCY" \
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
  --metadata "games_requested=$GAMES" \
  --metadata "tc=$TC" \
  --metadata "concurrency=$CONCURRENCY" \
  --metadata "openings_file=$OPENINGS_FILE" \
  --metadata "seed=$SEED"
