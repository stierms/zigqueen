# zigqueen scripts

Match harnesses, validation gates, and build helpers. Everything assumes Zig
0.15.2 on `PATH`; the match scripts additionally need
[fastchess](https://github.com/Disservin/fastchess).

## SPRT / self-play

- `selfplay-vs-baseline.sh` — build HEAD and a baseline ref (default: newest
  `v*` tag) and run a fixed-game self-play screen.
- `sprt-vs-baseline.sh` — build HEAD and a baseline ref and run the SPRT gate.
- `benchmark-entry.sh`, `benchmark-sprt.sh` — the underlying match/SPRT
  harness entry points for two arbitrary engine binaries.
- `summarize-match-pgn.py` — summarize a fastchess PGN into a compact
  two-engine score summary.

See `docs/TUNING.md` for the validation ladder these implement.

## NNUE

- `net-sanity.py` — pre-test gate for a candidate net: color-mirror symmetry,
  material monotonicity, magnitude, startpos ~= 0.

## Performance

- `compare-fixed-output.py` — diff fixed-depth outputs while ignoring
  volatile timing fields (exact-output/node-identity checks).
- `perf-ab-compare.sh`, `compare-perf-stat.py` — perf-stat A/B comparison of
  two built binaries.
- `bolt-optimize.sh` — optional llvm-bolt post-link layout optimization,
  gated by a fixed-depth node-identity check.

## Release build

- `package-release.sh` — build and zip the six release binaries into
  `release/`. The four x86-64 ones are PGO builds from the committed profiles
  (`PGO=0` for plain builds); the Android ones are plain.
- `pgo-build.sh` — context-sensitive PGO at Zig's LTO link: `train` a profile
  for one packaged x86-64 variant (needs LLVM 20's `llvm-profdata`, and WSL
  interop for the Windows variants), or `use` a profile, with gates for a
  stale profile and for `bench 16` equality with the plain build. Helpers in
  `pgo/`: `profsnap.py` (training run, counters read from the live process),
  `profunion.py` (optional union of profiles), `rthook.c` (Windows stub),
  `train-positions.json` (training workload); `pgo/profiles/` holds the
  committed profiles.

## Windows build

- `build-windows-revision.sh` — build a packaged native `zigqueen.exe` from a
  git revision via WSL interop. Drivers: `windows-build.ps1`,
  `windows-ensure-zig.ps1`, `windows-verify-uci.ps1`; compat shim
  `patch-windows-build-compat.py`. See `docs/WINDOWS_BUILD.md`.

## Misc

- `source-hygiene-audit.py` — conservative unused-private-function audit;
  counts call sites and value references.
- `uci-movetime-probe.py` — probe an engine's movetime/clock behavior over
  UCI.
