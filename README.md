# zigqueen

zigqueen is a UCI chess engine written in Zig (0.15.2) with a from-scratch
NNUE evaluation and a single-threaded alpha-beta search. Engine code is a
clean-room implementation (see `CLEAN_ROOM_RULES.md`); the network is trained
from publicly available Stockfish fishtest data.

**zigqueen is a human/AI collaboration**: developed by
[stierms](https://github.com/stierms) (project direction, engineering
decisions, validation methodology and budgets) working with Anthropic's
Claude as an AI pair-engineer (implementation, analysis, optimization).
Every change was gated by empirical validation — statistical game testing
(SPRT), bit-exactness proofs, and fixed-workload benchmarks — rather than
taken on trust. Commit trailers preserve the co-authorship record.

Copyright (C) 2026 stierms — licensed under GPLv3 (see `LICENSE`). The
vendored Fathom tablebase prober (`deps/fathom`) is distributed under its own
MIT-style license, kept intact in its source headers.

## Strength

| Rating list | Engine version | Rating | Status |
|---|---|---|---|
| Self-assessment (blitz 180s+1s) | v5.8.0 | ~3588 | 1,620-game anchored gauntlet, 2026-07-19 — see [docs/STRENGTH.md](docs/STRENGTH.md) |
| CCRL Blitz (2'+1") | — | — | submission planned |
| CCRL 40/15 | — | — | submission planned |

The self-assessment anchors a private gauntlet to published CCRL Blitz
ratings; treat it as an estimate (~±15).

## Features

**Evaluation** — pure NNUE ("ZQB8" format, ~30 MB net embedded in the binary):

- HalfKA feature transformer, 8 king buckets with horizontal mirroring, width 1536
- lean threat-feature set (7,680 attacker->target features) with custom
  incremental non-local update algorithms
- PSQT head and a bucketed SFNNv-style layerstack readout (l1/l2 with i8
  VNNI matmul)
- incremental accumulators with lazy materialization and a finny-style
  refresh cache
- trained with the [bullet](https://github.com/jw1912/bullet) trainer on
  public Stockfish fishtest data

**Search** — negamax + iterative deepening, aspiration windows:

- clustered transposition table with static-eval caching, huge-page backed;
  dedicated 2-way eval cache
- null move with verification, probcut, singular extensions,
  desperation-conditioned check extensions
- LMR (runtime-shaped table), RFP, razoring, futility, history and SEE pruning
- killer/countermove/main/continuation/correction history; staged
  TT-move-first generation at depth 1
- SEE-gated quiet checks at the first qsearch ply
- Syzygy WDL probing via Fathom

**Performance** — AVX-512/AVX2 SIMD via Zig `@Vector` (portable, bit-exact),
LTO, transparent-huge-page self-enable on Linux/WSL2, Windows large pages,
optional llvm-bolt post-link pass.

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
cross-compile with `-Dtarget=x86_64-windows-gnu`. `scripts/package-release.sh`
builds and zips all four release variants into `release/`.

## UCI options

| Option | Type | Default | Description |
|---|---|---|---|
| `Hash` | spin | 64 | Transposition table size in MB (1-65536); also sizes the eval cache. |
| `Threads` | spin | 1 | Search threads. The engine is single-threaded; fixed at 1. |
| `Move Overhead` | spin | 20 | Per-move time reserve in ms for GUI/connection latency (0-1000). |
| `NNUE Scale Percent` | spin | 66 | Eval scaling in percent (0-400). The default is the calibrated value; changing it is not recommended. |
| `SyzygyPath` | string | empty | Directories containing Syzygy tablebases (WDL probing). |
| `Contempt` | spin | 0 | Draw contempt in centipawns (-200 to 200); 0 = classical draw scoring. |
| `EvalFile` | string | `<builtin>` | Path to an external `.zqb` net; leave at `<builtin>` for the embedded net. |

## Platform notes

- **Linux/WSL2:** the engine transparently enables 2 MB huge pages for its
  large tables (THP `madvise`), no setup needed.
- **Windows:** large pages need `SeLockMemoryPrivilege` — grant "Lock pages
  in memory" (secpol.msc) once and re-login; otherwise the engine silently
  uses regular pages. See `docs/WINDOWS_BUILD.md`.

## Documentation

- `docs/STRENGTH.md` — gauntlet methodology and per-opponent results
- `docs/ARCHITECTURE.md` — module map, NNUE and search architecture
- `docs/TUNING.md`, `docs/QUALITY_GATES.md` — validation methodology
- `docs/WINDOWS_BUILD.md` — Windows builds and large pages
- `CLEAN_ROOM_RULES.md` — clean-room policy

## Acknowledgments

- The [Stockfish](https://stockfishchess.org/) project and the fishtest
  community, whose public training data made the network possible.
- [bullet](https://github.com/jw1912/bullet), the NNUE trainer.
- [Fathom](https://github.com/jdart1/Fathom) for Syzygy probing.
- The engine-testing ecosystem, especially
  [fastchess](https://github.com/Disservin/fastchess), and the computer
  chess community's published research.

## License

GPLv3 — see `LICENSE`. `deps/fathom` retains its original MIT-style license
notice.
