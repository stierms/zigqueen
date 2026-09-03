# zigqueen 6.1.0 — full-threats NNUE chess engine

<p align="center"><img src="docs/logo/zigqueen-logo.png" alt="zigqueen logo" width="220"></p>

zigqueen is a UCI chess engine written in Zig (0.15.2) with a from-scratch
NNUE evaluation and a single-threaded alpha-beta search. The engine code was
written for this project; no code was copied or translated from other
engines. What was learned from where is credited in `docs/PROVENANCE.md`
(rules: `ORIGINALITY.md`). The ZQB9 network is
trained from random initialization on publicly published Stockfish NNUE
training datasets.

Copyright (C) 2026 stierms — licensed under GPLv3 (see `LICENSE`). The
vendored Fathom tablebase prober (`deps/fathom`) is MIT-licensed; all
third-party notices are collected in `THIRD_PARTY_LICENSES.md`.

## Strength

| Engine version | Self-assessment (blitz 180s+1s) | CCRL Blitz (2'+1") | CCRL 40/15 |
|---|---|---|---|
| v6.1.0 | **~3644** — 1,620-game, 27-opponent anchored gauntlet, 2026-08-31 ([methodology](docs/STRENGTH.md)) | pending | — |
| v6.0.0 | ~3602 — 1,620-game anchored gauntlet, 2026-08-18/19 ([methodology](docs/STRENGTH.md)) | pending | — |
| v5.8.3 | ~3590 — 1,620-game anchored gauntlet, 2026-07-26 ([methodology](docs/STRENGTH.md)) | **3569 ±16** (#76–77, [official listing](https://computerchess.org.uk/ccrl/404/cgi/engine_details.cgi?print=Details&eng=ZigQueen%205.8.3%2064-bit)) | — |
| v5.8.0 | ~3588 — 1,620-game anchored gauntlet, 2026-07-19 ([methodology](docs/STRENGTH.md)) | — | — |

The 5.8.3 CCRL result is the latest authoritative public number. The
self-assessments anchor a private gauntlet to published CCRL ratings;
methodology and caveats in [docs/STRENGTH.md](docs/STRENGTH.md).

## Features

**Evaluation** — pure NNUE (`zqHalfKA9` in a `ZQB9` container, 74.6 MB net embedded):

- HalfKA feature transformer, 8 king buckets with horizontal mirroring,
  width 1024
- full-threat feature set with 60,144 sparse attacker/target relations and
  custom incremental non-local update algorithms
- PSQT head and eight material-bucketed `1024 -> 16 -> 32 -> 1` layer stacks
  with i8 VNNI/dot-product matmul
- incremental accumulators with lazy materialization and a finny-style
  refresh cache
- trained with the [bullet](https://github.com/jw1912/bullet) trainer on
  the publicly published Stockfish NNUE training datasets — see
  [docs/NETWORK.md](docs/NETWORK.md) for exactly what was and was not used

**Search** — negamax + iterative deepening, aspiration windows:

- fractional "basin" reductions: interior LMR and the pruning families
  (null move, reverse futility, futility, late-move, history) share one
  depth-dose scheme whose formulas and default constants were taken from
  Stormphrax 8.0.0's published parameter set (see `docs/PROVENANCE.md`)
- root late-move reductions: post-PV root moves are scouted at reduced
  depth and re-searched at full depth on a fail-high
- clustered transposition table with static-eval caching, huge-page backed;
  dedicated 2-way eval cache
- null move with verification, probcut, singular extensions,
  desperation-conditioned check extensions
- killer/countermove/main/continuation history (correction history is
  implemented but parked: its tables are not allocated in this release)
- honest node accounting: one visited position, one node
- Syzygy WDL probing via Fathom; tablebase-decided root results are proven
  once and reused instead of re-searched every iteration
- time management with an instability-armed burst: the hard per-move
  deadline extends only after a completed iteration changed its best move
  or dropped the score
- six exact-root book moves, chosen from Stockfish analysis of the gauntlet
  opening set (see `docs/PROVENANCE.md`); SEE-gated quiet checks at the
  first qsearch ply

**Performance** — AVX-512/AVX2 SIMD via Zig `@Vector` (portable, bit-exact),
LTO, transparent-huge-page self-enable on Linux/WSL2, Windows large pages,
optional llvm-bolt post-link pass.

## Development hardware

Everything — engine development, NNUE training, and all strength testing —
was done on a single desktop machine:

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X3D (16 cores / 32 threads, 128 MB V-cache) |
| GPU | NVIDIA GeForce RTX 4090 (24 GB) — NNUE training only |
| RAM | 128 GB |
| OS | Windows 11 with WSL2 (Ubuntu) — training and testing run under WSL2; Windows binaries are cross-compiled with Zig |

No cluster and no external compute; release binaries are built by GitHub
Actions so anyone can reproduce them from the tagged source.

## How this engine was built (AI disclosure)

zigqueen was written by [stierms](https://github.com/stierms) together with
an AI assistant (Anthropic's Claude). Claude wrote most of the source code
under continuous human direction: stierms set the goals, chose which ideas
to pursue or abandon, approved every experiment that cost machine time, and
decided what shipped.

Nothing was accepted because it sounded plausible. Strength changes had to
pass SPRT self-play at two time controls and a gauntlet against outside
engines; performance changes had to be node-identical at fixed depth;
correctness rests on perft suites, make/unmake invariants, and bit-exact
NNUE inference checks against an independent reference. Failed experiments
are part of the record — the git history documents both, and commit
trailers preserve co-authorship.

`ORIGINALITY.md` documents the originality rules: no code was copied
or translated from other engines. `docs/PROVENANCE.md` records what was
learned from which engine or dataset and under which license, including the
search-shaping parameter set that was taken from Stormphrax's published
defaults rather than derived locally.

## Build

Requires Zig 0.15.2:

```bash
zig build -Doptimize=ReleaseFast
zig build test
./zig-out/bin/zigqueen
```

The default build targets the native CPU. Portable release binaries use
`-Dcpu-baseline=avx2` (x86-64-v3: AVX2, no AVX-512 — runs on Haswell/Zen 1
and newer) or `-Dcpu-baseline=avx512` (x86-64-v4 + VNNI — Ice Lake/Zen 4 and
newer); all variants are bit-exact, only speed differs. Windows binaries
cross-compile with `-Dtarget=x86_64-windows-gnu`. Android uses the `armv8`
and `armv8-dotprod` baselines. `scripts/package-release.sh` builds and zips
all six raw-binary release variants into `release/`; signed OEX APKs are
packaged locally from `android/oex/`.

## UCI options

| Option | Type | Default | Description |
|---|---|---|---|
| `Hash` | spin | 256 | Transposition table size in MB (1-65536); also sizes the eval cache. |
| `Threads` | spin | 1 | Search threads. The engine is single-threaded; fixed at 1. |
| `Move Overhead` | spin | 20 | Per-move time reserve in ms for GUI/connection latency (0-1000). |
| `NNUE Scale Percent` | spin | 48 | Eval scaling in percent (0-400). The default is keyed to the embedded net; changing it is not recommended. |
| `SyzygyPath` | string | empty | Directories containing Syzygy tablebases (WDL probing). |
| `Contempt` | spin | 0 | Draw contempt in centipawns (-200 to 200); 0 = classical draw scoring. |
| `EvalFile` | string | `<builtin>` | Path to an external `.zqb` net; leave at `<builtin>` for the embedded net. |

That is the complete list. Development builds compiled with `-Dtuning=true`
additionally expose the internal search-tuning scaffold; in 6.1.0 those
knobs drive the legacy reduction/pruning path, which the live "basin"
substrate bypasses, so they do not tune the shipped search.

## Platform notes

**Android**: each release ships OEX engine APKs (auto-discovered by Chess for
Android, DroidFish and other OEX-compatible GUIs) plus raw aarch64 binaries;
the ARM build is bit-identical to x86 by design. See [docs/ANDROID.md](docs/ANDROID.md).

- **Linux/WSL2:** the engine transparently enables 2 MB huge pages for its
  large tables (THP `madvise`), no setup needed.
- **Windows:** large pages need `SeLockMemoryPrivilege` — grant "Lock pages
  in memory" (secpol.msc) once and re-login; otherwise the engine silently
  uses regular pages. See `docs/WINDOWS_BUILD.md`.

## Documentation

- `docs/RELEASE_NOTES_6.1.0.md` — what changed in 6.1.0
- `docs/STRENGTH.md` — gauntlet methodology and per-opponent results
- `docs/ARCHITECTURE.md` — module map, NNUE and search architecture
- `docs/TUNING.md`, `docs/QUALITY_GATES.md` — validation methodology
- `docs/WINDOWS_BUILD.md` — Windows builds and large pages
- `ORIGINALITY.md` — originality rules
- `docs/PROVENANCE.md` — provenance and licensing record (ideas, parameters,
  data, third-party code)
- `THIRD_PARTY_LICENSES.md` — notices for the vendored components

## Acknowledgments

- The [Stockfish](https://stockfishchess.org/) project and its community,
  whose openly published NNUE training datasets made the network possible.
  Parts of that data are made available under the Open Database License
  (ODbL-1.0, http://opendatacommons.org/licenses/odbl/1.0/) by the Stockfish
  project and, for the Lc0-derived component, by the
  [LCZero](https://lczero.org/) project; see `docs/NETWORK.md`.
- [Stormphrax](https://github.com/Ciekce/Stormphrax) (Ciekce, GPL-3.0): the
  search's reduction/pruning formulas and their default constants follow its
  published parameter set (`docs/PROVENANCE.md`, section 1). No code.
- [bullet](https://github.com/jw1912/bullet), the NNUE trainer.
- [Fathom](https://github.com/jdart1/Fathom) for Syzygy probing (MIT), and
  [chessenginesupport-androidlib](https://github.com/gkalab/chessenginesupport-androidlib)
  (Apache-2.0) for the Android OEX provider.
- The engine-testing ecosystem, especially
  [fastchess](https://github.com/Disservin/fastchess), and the computer
  chess community's published research.

## License

GPLv3 — see `LICENSE`. Third-party components keep their own licenses
(Fathom: MIT; the Android OEX support library and Gradle wrapper:
Apache-2.0); their notices are in `THIRD_PARTY_LICENSES.md`.
