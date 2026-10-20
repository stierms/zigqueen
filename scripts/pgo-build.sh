#!/usr/bin/env bash
# pgo-build.sh — context-sensitive PGO for the x86-64 release binaries: one committed profile per
# packaged variant and tree. No engine change; nothing instrumented ships.
#
# Zig 0.15.2 has no PGO flag, but its LTO build leaves the whole program as one LLVM bitcode unit
# in the cache, and replaying Zig's own link line (zig ld.lld / zig lld-link) reproduces the
# shipped code. CS-PGO runs at that link (after the LTO inliner):
#
#   train VARIANT OUTDIR [zig args]          build, instrumented relink (--lto-cs-profile-generate),
#                                            training run: OUTDIR/VARIANT.profdata (+ .proftext)
#   use VARIANT OUTDIR PROFILE [zig args]    build, optimized relink (--lto-cs-profile-file), gates
#   merge OUT.profdata TEXT...               optional single file for several links
#                                            (pgo/profunion.py: union by (name, CFG hash), no summing)
#
# VARIANT is a packaged x86-64 build: linux-avx2, linux-avx512, windows-avx2 or windows-avx512.
# Each is built with exactly the flags of scripts/package-release.sh (ReleaseFast,
# -Dcpu-baseline, -Dversion from build.zig, -Dtarget=x86_64-windows-gnu for Windows), and
# scripts/package-release.sh runs `use` with scripts/pgo/profiles/VARIANT.profdata.
#
# One profile per variant: the OS builds share only about half their function names (Zig's
# __anon_N instances differ), so a profile trained on one OS leaves the other's hot path
# unprofiled, and a merged file costs the Windows link measurably against its own profile. A
# profile belongs to its tree: __anon_N names shift with almost any source change, so retrain
# whenever the source changes; `use` fails on a stale profile (any hash mismatch, or any function
# without profile data outside the startup stubs).
#
# Training (pgo/profsnap.py) needs neither a profile runtime nor a dump hook: it runs a fixed UCI
# workload (startpos depth 16 + pgo/train-positions.json x PGO_NODES) on the instrumented
# relink of the normal bitcode and reads the counters out of the live process (Linux
# /proc/PID/mem; Windows ReadProcessMemory via powershell.exe through WSL interop), then writes
# the LLVM 20 raw profile. Windows' instrumented relink gets a one-symbol stub (pgo/rthook.c).
# -disable-vp in all relinks: no value profiling, so neither side needs runtime support for it.
# Training a variant needs a CPU that runs it (AVX-512 for the avx512 variants) and, for Windows,
# WSL with interop.
#
# env: LLVM_PROFDATA (train/merge: LLVM 20.x, the LLVM of `zig ld.lld --version`), PGO_TB
#      (Syzygy dir for training, optional), PGO_NODES (1000000), PGO_BENCH (1; 0 skips the
#      `use` bench gate on a host that cannot run the variant)
# out: train: OUTDIR/VARIANT.profdata and .proftext; use: OUTDIR/zigqueen-pgo[.exe],
#      OUTDIR/zigqueen-plain[.exe], OUTDIR/SHA256. OUTDIR must be fresh (a path without spaces).
set -euo pipefail

usage() { sed -n '2,40p' "$0"; exit 2; }
[[ $# -ge 3 ]] || usage
MODE=$1; shift
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
NODES=${PGO_NODES:-1000000}

need_profdata() {
  PD=${LLVM_PROFDATA:?set LLVM_PROFDATA to an LLVM 20.x llvm-profdata}
  "$PD" --version | grep -q 'LLVM version 20\.' || { echo "llvm-profdata is not LLVM 20.x" >&2; exit 2; }
}

if [[ "$MODE" == merge ]]; then
  need_profdata
  OUTP=$1; shift
  python3 -I "$ROOT/scripts/pgo/profunion.py" "${OUTP%.profdata}.proftext" "$@"
  "$PD" merge -o "$OUTP" "${OUTP%.profdata}.proftext"
  "$PD" show --showcs "$OUTP" | sed -n '2,6p'
  sha256sum "$OUTP"
  exit 0
fi

VARIANT=$1; OUT=$2; shift 2
PROFILE=""
if [[ "$MODE" == use ]]; then
  [[ $# -ge 1 ]] || usage
  PROFILE=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1"); shift
  [[ -f "$PROFILE" ]] || { echo "no profile $PROFILE" >&2; exit 2; }
elif [[ "$MODE" == train ]]; then
  need_profdata
else
  usage
fi
zig ld.lld --version | grep -q '^LLD 20\.' || { echo "zig's LLD is not LLVM 20.x" >&2; exit 2; }

VERSION=$(sed -n 's/^ *const semver = "\([^"]*\)";.*/\1/p' "$ROOT/build.zig")
[[ -n "$VERSION" ]] || { echo "could not read semver from build.zig" >&2; exit 1; }
BUILD_ARGS=(-Doptimize=ReleaseFast "-Dversion=$VERSION")
case "$VARIANT" in
  linux-avx2|linux-avx512)
    EXE=""; LINKER="ld.lld"; LTO_KEY='--lto-O3' ;;
  windows-avx2|windows-avx512)
    EXE=".exe"; LINKER="lld-link"; LTO_KEY='-OPT:lldlto'; BUILD_ARGS+=(-Dtarget=x86_64-windows-gnu) ;;
  *) echo "VARIANT must be linux-avx2, linux-avx512, windows-avx2 or windows-avx512" >&2; exit 2 ;;
esac
CPU=${VARIANT#*-}
BUILD_ARGS+=("-Dcpu-baseline=$CPU")
NAME="zigqueen-x86_64-$CPU"

[[ ! -e "$OUT" ]] || { echo "OUTDIR $OUT exists; use a fresh directory" >&2; exit 2; }
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd)

echo "== zig build ($VARIANT, zigqueen $VERSION)"
(cd "$ROOT" && zig build "${BUILD_ARGS[@]}" "$@" \
  --cache-dir "$OUT/cache" --global-cache-dir "$OUT/gcache" --prefix "$OUT/zig-out" \
  --verbose-link 2> "$OUT/link.log")
LINE=$(grep -- "$LTO_KEY" "$OUT/link.log" | grep -v -- 'zigqueen-stats' | head -1 | sed -E "s/^(error: )?$LINKER //")
[[ -n "$LINE" ]] || { echo "no LTO link line in $OUT/link.log" >&2; exit 1; }
cp "$OUT/zig-out/bin/$NAME$EXE" "$OUT/zigqueen-plain$EXE"

relink() {  # relink OUTFILE EXTRA...
  local o=$1; shift
  local l
  if [[ -z "$EXE" ]]; then
    l=$(echo "$LINE" | sed -E "s| -o [^ ]+| -o $o|")
  else
    local b=${o%.exe}
    l=$(echo "$LINE" | sed -E "s| -OUT:[^ ]+| -OUT:$o|; s| -PDB:[^ ]+| -PDB:$b.pdb|; s| -IMPLIB:[^ ]+| -IMPLIB:$b.lib|")
  fi
  eval "zig $LINKER $l $*"
}

if [[ "$MODE" == train ]]; then
  echo "== instrumented relink"
  GEN="$OUT/zigqueen-pgogen$EXE"
  if [[ -z "$EXE" ]]; then
    relink "$GEN" --lto-cs-profile-generate --lto-cs-profile-file=/dev/null -mllvm -disable-vp=true
  else
    zig cc -target x86_64-windows-gnu -O2 -c "$ROOT/scripts/pgo/rthook.c" -o "$OUT/rthook.obj"
    relink "$GEN" /lto-cs-profile-generate /lto-cs-profile-file:nul /mllvm:-disable-vp=true "$OUT/rthook.obj"
  fi
  echo "== training"
  TB=()
  if [[ -n "${PGO_TB:-}" ]]; then
    if [[ -z "$EXE" ]]; then TB=(--tb "$PGO_TB"); else TB=(--tb "$(wslpath -w "$PGO_TB")"); fi
  fi
  python3 -I "$ROOT/scripts/pgo/profsnap.py" "$GEN" "$OUT/zq.profraw" --depth16 \
    --pos "$ROOT/scripts/pgo/train-positions.json" --nodes "$NODES" "${TB[@]}"
  "$PD" merge -o "$OUT/$VARIANT.profdata" "$OUT/zq.profraw"
  "$PD" merge --text -o "$OUT/$VARIANT.proftext" "$OUT/zq.profraw"
  "$PD" show --showcs "$OUT/$VARIANT.profdata" | sed -n '2,6p'
  sha256sum "$OUT/$VARIANT.profdata"
  exit 0
fi

echo "== optimized relink"
PGO="$OUT/zigqueen-pgo$EXE"
if [[ -z "$EXE" ]]; then
  relink "$PGO" --lto-cs-profile-file="$PROFILE" -mllvm -disable-vp=true \
    -mllvm -pgo-warn-missing-function=true 2> "$OUT/relink-warnings.txt" \
    || { cat "$OUT/relink-warnings.txt" >&2; exit 1; }
else
  relink "$PGO" /lto-cs-profile-file:"$PROFILE" /mllvm:-disable-vp=true \
    /mllvm:-pgo-warn-missing-function=true 2> "$OUT/relink-warnings.txt" \
    || { cat "$OUT/relink-warnings.txt" >&2; exit 1; }
fi

echo "== gates"
# Startup stubs never carry counters; anything else without profile data means a stale profile.
STALE=$(grep -E 'no profile data available|hash mismatch' "$OUT/relink-warnings.txt" \
  | grep -vE 'function (_start|start\.posixCallMainAndExit|os\.linux\.x86_64\.(restore_rt|clone)) Hash' || true)
if [[ -n "$STALE" ]]; then
  echo "GATE FAIL: profile does not match this tree ($(echo "$STALE" | wc -l) functions):" >&2
  echo "$STALE" | head -5 >&2
  exit 1
fi
if [[ "${PGO_BENCH:-1}" != 0 ]]; then
  NA=$("$OUT/zigqueen-plain$EXE" bench 16 | tr -d '\r' | grep '^nodes ')
  NB=$("$PGO" bench 16 | tr -d '\r' | grep '^nodes ')
  echo "plain: $NA, pgo: $NB"
  [[ "$NA" == "$NB" ]] || { echo "GATE FAIL: bench 16 differs" >&2; exit 1; }
else
  echo "bench gate skipped (PGO_BENCH=0)"
fi
cp "$PROFILE" "$OUT/zq.profdata"
(cd "$OUT" && sha256sum "zigqueen-plain$EXE" "zigqueen-pgo$EXE" zq.profdata | tee SHA256)
