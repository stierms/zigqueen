#!/usr/bin/env bash
# Build and package the portable release binaries.
#
# Produces, under release/:
#   zigqueen-<version>-linux-x86_64-avx2.zip
#   zigqueen-<version>-linux-x86_64-avx512.zip
#   zigqueen-<version>-windows-x86_64-avx2.zip
#   zigqueen-<version>-windows-x86_64-avx512.zip
#   zigqueen-<version>-android-armv8.zip
#   zigqueen-<version>-android-armv8-dotprod.zip
# Each zip contains the engine binary (NNUE net embedded), LICENSE and README.md.
# The android binaries are static aarch64-linux-musl executables (usable in
# Termux, Chess for Android "install from SD" where allowed, and as the input
# for the OEX APK packaging under android/oex — see docs/ANDROID.md).
#
# Variants:
#   avx2   = x86-64-v3 baseline (AVX2, no AVX-512) — runs on Haswell/Zen1+.
#   avx512 = x86-64-v4 + AVX512-VNNI — Ice Lake / Zen 4 and newer.
# All variants are bit-exact (identical node counts); only speed differs.
#
# Requirements: zig 0.15.2 on PATH; `zip` or python3 for archiving.
# Usage: scripts/package-release.sh   (from anywhere; paths are repo-relative)
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=$(sed -n 's/^ *const semver = "\([^"]*\)";.*/\1/p' build.zig)
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not read semver from build.zig" >&2
    exit 1
fi
echo "packaging zigqueen $VERSION" >&2

OUT_DIR="$ROOT/release"
STAGE_DIR="$OUT_DIR/stage"
rm -rf "$OUT_DIR"
mkdir -p "$STAGE_DIR"

# make_zip <out.zip> <file>... — flat archive (no directories), executable bit
# preserved. Uses `zip` when available, python3 zipfile otherwise.
make_zip() {
    local out=$1
    shift
    if command -v zip >/dev/null 2>&1; then
        zip -j -q "$out" "$@"
    else
        python3 - "$out" "$@" <<'PYEOF'
import os, sys, zipfile
out, *files = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for path in files:
        info = zipfile.ZipInfo(os.path.basename(path))
        info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(path, "rb") as f:
            z.writestr(info, f.read())
PYEOF
    fi
}

for os_name in linux windows; do
    for variant in avx2 avx512; do
        echo "== building $os_name $variant" >&2
        build_args=(-Doptimize=ReleaseFast "-Dcpu-baseline=$variant")
        ext=""
        if [[ "$os_name" == windows ]]; then
            build_args+=(-Dtarget=x86_64-windows-gnu)
            ext=".exe"
        fi
        zig build "${build_args[@]}"

        built="zig-out/bin/zigqueen-x86_64-${variant}${ext}"
        [[ -f "$built" ]] || { echo "ERROR: expected artifact $built missing" >&2; exit 1; }

        name="zigqueen-${VERSION}-${os_name}-x86_64-${variant}"
        staged="$STAGE_DIR/${name}${ext}"
        cp "$built" "$staged"
        make_zip "$OUT_DIR/${name}.zip" "$staged" "$ROOT/LICENSE" "$ROOT/README.md"
        echo "packaged $OUT_DIR/${name}.zip" >&2
    done
done

for variant in armv8 armv8-dotprod; do
    echo "== building android $variant" >&2
    zig build -Doptimize=ReleaseFast "-Dcpu-baseline=$variant" -Dtarget=aarch64-linux-musl

    built="zig-out/bin/zigqueen-aarch64-${variant}"
    [[ -f "$built" ]] || { echo "ERROR: expected artifact $built missing" >&2; exit 1; }

    name="zigqueen-${VERSION}-android-${variant}"
    staged="$STAGE_DIR/${name}"
    cp "$built" "$staged"
    make_zip "$OUT_DIR/${name}.zip" "$staged" "$ROOT/LICENSE" "$ROOT/README.md"
    echo "packaged $OUT_DIR/${name}.zip" >&2
done

rm -rf "$STAGE_DIR"
echo "done:" >&2
ls -l "$OUT_DIR" >&2
