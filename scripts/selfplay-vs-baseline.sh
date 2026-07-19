#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/selfplay-vs-baseline.sh

Build current HEAD and the accepted baseline, then run the default 192-game
selfplay screen through benchmark-entry.sh.

Environment:
  BASELINE_REF        baseline ref (default: newest v* tag)
  ENGINE1_NAME        candidate label (default: zigqueen-current)
  ENGINE2_NAME        baseline label (default: zigqueen-baseline)
  ARTIFACT_DIR        parent artifact directory (default: artifacts/)
  GAMES               benchmark-entry game count (default there: 192)

Requires zig 0.15.2 and fastchess on PATH.
USAGE
  exit 0
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_REF="${BASELINE_REF:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 --match 'v*')}"
ENGINE1_NAME="${ENGINE1_NAME:-zigqueen-current}"
ENGINE2_NAME="${ENGINE2_NAME:-zigqueen-baseline}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
RUN_DIR="$ARTIFACT_DIR/selfplay-vs-baseline-$TIMESTAMP"
WORKTREE_DIR="$RUN_DIR/baseline-worktree"
CURRENT_BIN="$ROOT_DIR/zig-out/bin/zigqueen"
BASELINE_BIN="$WORKTREE_DIR/zig-out/bin/zigqueen"

mkdir -p "$RUN_DIR"

cleanup() {
  if git -C "$ROOT_DIR" worktree list --porcelain | grep -Fq "$WORKTREE_DIR"; then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

zig build -Doptimize=ReleaseFast

git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" "$BASELINE_REF" >/dev/null
(
  cd "$WORKTREE_DIR"
  zig build -Doptimize=ReleaseFast >/dev/null
)

ENGINE1_NAME="$ENGINE1_NAME" \
ENGINE2_NAME="$ENGINE2_NAME" \
ARTIFACT_DIR="$RUN_DIR" \
"$ROOT_DIR/scripts/benchmark-entry.sh" "$CURRENT_BIN" "$BASELINE_BIN"

echo "$RUN_DIR"
