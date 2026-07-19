#!/usr/bin/env bash
# NOTE (Windows large pages): the engine tries VirtualAlloc(MEM_LARGE_PAGES) for
# the TT/history/net tables, which needs SeLockMemoryPrivilege ("Lock pages in
# memory" under secpol.msc / gpedit -> User Rights Assignment) granted to the
# user account ONCE, then re-login. Without it the engine silently falls back to
# regular pages. Verify at startup: "info string large_pages: locked" vs
# "fallback (SeLockMemoryPrivilege unavailable)".
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <git-rev> <label> [model-path|-] [uci-options-file-or-text|-] [external-summary-path|-] [optimize]" >&2
  exit 1
fi

PROJECT_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
WINDOWS_BUILD_DIR=${ZIGQUEEN_WINDOWS_BUILD_DIR:-/mnt/c/Users/$USER/zqwin}
WINDOWS_ENGINES_DIR="$WINDOWS_BUILD_DIR/engines"
WINDOWS_TOOLS_DIR="$WINDOWS_BUILD_DIR/tools"

REV="$1"
LABEL="$2"
MODEL_PATH="${3:--}"
UCI_OPTIONS_SPEC="${4:--}"
EXTERNAL_SUMMARY_PATH="${5:--}"
OPTIMIZE="${6:-ReleaseFast}"

cd "$PROJECT_ROOT"
RESOLVED_COMMIT="$(git rev-parse --verify "$REV^{commit}")"
RESOLVED_REV="${RESOLVED_COMMIT:0:8}"
REQUESTED_OBJECT="$(git rev-parse --verify "$REV" 2>/dev/null || true)"
RESOLVED_TREE="$(git rev-parse --verify "$RESOLVED_COMMIT^{tree}")"

PACKAGE_DIR="$WINDOWS_ENGINES_DIR/$LABEL"
BUILD_STAGE_DIR="$WINDOWS_BUILD_DIR/_work/$RESOLVED_REV"
WORKTREE_DIR="$BUILD_STAGE_DIR/w"
OUT_DIR="$PACKAGE_DIR/package"
LOG_DIR="$PACKAGE_DIR/logs"

rm -rf "$PACKAGE_DIR" "$BUILD_STAGE_DIR"
mkdir -p "$WORKTREE_DIR" "$OUT_DIR" "$LOG_DIR" "$WINDOWS_TOOLS_DIR"

git archive "$RESOLVED_COMMIT" | tar -x -C "$WORKTREE_DIR"
python3 "$PROJECT_ROOT/scripts/patch-windows-build-compat.py" "$WORKTREE_DIR" > "$LOG_DIR/windows-patch.stdout.txt"
SOURCE_TREE_SHA256="$(
  python3 - "$WORKTREE_DIR" <<'PY'
import hashlib
import sys
from pathlib import Path
root = Path(sys.argv[1])
h = hashlib.sha256()
count = 0
for path in sorted(root.rglob('*')):
    if not path.is_file():
        continue
    rel = path.relative_to(root).as_posix()
    if rel.startswith('.zig-cache/') or rel.startswith('zig-out/'):
        continue
    h.update(rel.encode('utf-8') + b'\0')
    h.update(path.read_bytes())
    count += 1
print(f'{h.hexdigest()} files={count}')
PY
)"

PS_BUILD_SCRIPT="$(wslpath -w "$PROJECT_ROOT/scripts/windows-build.ps1")"
PS_VERIFY_SCRIPT="$(wslpath -w "$PROJECT_ROOT/scripts/windows-verify-uci.ps1")"
WIN_WORKTREE_DIR="$(wslpath -w "$WORKTREE_DIR")"
WIN_OUT_DIR="$(wslpath -w "$OUT_DIR")"
WIN_TOOLS_DIR="$(wslpath -w "$WINDOWS_TOOLS_DIR")"
WIN_EXE_PATH="$(wslpath -w "$OUT_DIR/zigqueen.exe")"

# UCI `id name` uses the BARE semver from build.zig (no commit suffix) so the
# Windows build matches the local build exactly. The commit is recorded as
# git_rev in the package metadata for traceability instead.
VERSION_STRING="$(sed -n 's/.*const semver = "\([0-9][0-9.]*\)".*/\1/p' "$WORKTREE_DIR/build.zig" | head -1)"

ps_version_args=()
if [[ -n "$VERSION_STRING" ]]; then
  ps_version_args=(-Version "$VERSION_STRING")
fi

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$PS_BUILD_SCRIPT" \
  -ProjectDir "$WIN_WORKTREE_DIR" \
  -OutputDir "$WIN_OUT_DIR" \
  -OutputName 'zigqueen.exe' \
  -ToolRoot "$WIN_TOOLS_DIR" \
  -Optimize "$OPTIMIZE" \
  "${ps_version_args[@]}" \
  < /dev/null > "$LOG_DIR/windows-build.stdout.txt" 2> "$LOG_DIR/windows-build.stderr.txt"

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$PS_VERIFY_SCRIPT" \
  -ExePath "$WIN_EXE_PATH" \
  < /dev/null > "$LOG_DIR/windows-uci.stdout.txt" 2> "$LOG_DIR/windows-uci.stderr.txt"

if [[ "$MODEL_PATH" != "-" ]]; then
  cp "$MODEL_PATH" "$OUT_DIR/model.zqnnue"
  local_summary="${MODEL_PATH%/*}/summary.json"
  if [[ -f "$local_summary" ]]; then
    cp "$local_summary" "$OUT_DIR/model-summary.json"
  fi
fi

uci_options_text=""
if [[ "$UCI_OPTIONS_SPEC" != "-" ]]; then
  if [[ -f "$UCI_OPTIONS_SPEC" ]]; then
    uci_options_text="$(cat "$UCI_OPTIONS_SPEC")"
  else
    uci_options_text="$UCI_OPTIONS_SPEC"
  fi
fi
if [[ -n "$uci_options_text" ]]; then
  printf '%s\n' "$uci_options_text" > "$OUT_DIR/UCI_OPTIONS.txt"
fi

{
  printf 'label=%s\n' "$LABEL"
  printf 'git_rev=%s\n' "$RESOLVED_REV"
  printf 'git_commit=%s\n' "$RESOLVED_COMMIT"
  printf 'git_tree=%s\n' "$RESOLVED_TREE"
  printf 'git_rev_requested=%s\n' "$REV"
  if [[ -n "$REQUESTED_OBJECT" && "$REQUESTED_OBJECT" != "$RESOLVED_COMMIT" ]]; then
    printf 'git_requested_object=%s\n' "$REQUESTED_OBJECT"
  fi
  printf 'source_tree_sha256=%s\n' "$SOURCE_TREE_SHA256"
  printf 'built_at=%s\n' "$(date --iso-8601=seconds)"
  if [[ "$EXTERNAL_SUMMARY_PATH" != "-" ]]; then
    printf 'external_summary_path=%s\n' "$EXTERNAL_SUMMARY_PATH"
  fi
  printf 'optimize=%s\n' "$OPTIMIZE"
  if [[ -n "$VERSION_STRING" ]]; then
    printf 'uci_version=%s\n' "$VERSION_STRING"
  fi
  if [[ "$MODEL_PATH" != "-" ]]; then
    printf 'model_path=%s\n' "$MODEL_PATH"
  fi
  if [[ -n "$uci_options_text" ]]; then
    printf 'uci_options=%s\n' "$uci_options_text"
  fi
} > "$OUT_DIR/BUILD_INFO.txt"

printf 'built %s -> %s\n' "$RESOLVED_REV" "$OUT_DIR/zigqueen.exe"
