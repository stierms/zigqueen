# zigqueen 6.3.0 — full-threats NNUE chess engine

<p align="center"><img src="docs/logo/zigqueen-logo.png" alt="zigqueen logo" width="220"></p>

zigqueen is a UCI chess engine written in Zig (0.15.2) with a from-scratch
NNUE evaluation and an alpha-beta search that runs on 1 to 32 threads. The
engine code was written for this project; no code was copied or translated
from other engines. What was learned from where is credited in `docs/PROVENANCE.md`
(rules: `ORIGINALITY.md`). The ZQB9 network is
trained from random initialization on publicly published Stockfish NNUE
training datasets.

Copyright (C) 2026 stierms — licensed under the GNU GPL, version 3 or (at
your option) any later version (see `LICENSE`). The
vendored Fathom tablebase prober (`deps/fathom`) is MIT-licensed; all
third-party notices are collected in `THIRD_PARTY_LICENSES.md`.

## Strength

| Version | [Self-assessment](docs/STRENGTH.md), 1 thread | [CCRL Blitz](https://computerchess.org.uk/ccrl/404/) (120+1) | [CCRL 40/15](https://computerchess.org.uk/ccrl/4040/) (40 moves in 15 min) | [CCI](https://github.com/computer-chess-index/cci/blob/main/engines/Zigqueen.md) VLTC (144+1.12) |
|---|---|---|---|---|
| 6.3.0 | **3676** (95%: 3670–3683) — 1,628 games, 22 opponents, 2026-09-25, new field | — | — | — |
| 6.2.0 | **~3672** — 1,620 games, 27 opponents, 2026-09-09 | — | — | — |
| 6.1.1 | as 6.1.0 (compliance release, engine bit-identical) | — | — | 3475 ±45 |
| 6.1.0 | ~3644 — 1,620 games, 2026-08-31 | — | — | 3490 ±41 |
| 6.0.0 | ~3602 — 1,620 games, 2026-08-19 | — | **3498 ±18** ([#80, 572 games](https://computerchess.org.uk/ccrl/4040/cgi/engine_details.cgi?print=Details&eng=ZigQueen%206.0.0%2064-bit)) | 3401 ±45 |
| 5.8.3 | ~3590 — 1,620 games, 2026-07-26 | **3559 ±14** ([#80, 1,295 games](https://computerchess.org.uk/ccrl/404/cgi/engine_details.cgi?print=Details&eng=ZigQueen%205.8.3%2064-bit)) | — | 3384 ±33 |
| 5.8.0 | ~3588 — 1,620 games, 2026-07-19 | — | — | — |

Time controls are seconds per game + increment per move. Self-assessments
are our own gauntlets anchored to CCRL Blitz ratings, not official numbers;
method and caveats in [docs/STRENGTH.md](docs/STRENGTH.md). Up to 6.2.0 they
used a 27-opponent roster at a fixed 180+1. 6.3.0 uses a new 22-opponent field
from the 2026-09-21 CCRL list and CCRL's 120+1 scaled to our hardware with a
Stockfish 10 benchmark, so its number cannot be compared with the rows below
it. At 8 threads the 6.3 release candidate measured 3697 (95%: 3685–3709)
against an 8-CPU field. CCRL and CCI figures as of 2026-09-25.
The [Computer Chess Index](https://computer-chess-index.github.io/cci/)
uses its own Bayesian-Elo scale on an i5-7500T (Stockfish 19 = 3555 at
STC), so its numbers are not comparable to CCRL's; STC and LTC are on the
engine page.

## Features

**Evaluation** — pure NNUE (`zqHalfKA9` in a `ZQB9` container, 74.6 MB net embedded):

- HalfKA feature transformer, 8 king buckets with horizontal mirroring,
  width 1024
- full-threat feature set with 60,144 sparse attacker/target relations and
  custom incremental non-local update algorithms
- PSQT head and eight material-bucketed `1024 -> 16 -> 32 -> 1` layer stacks
  with i8 VNNI/dot-product matmul
- 6.3.0 network trained from scratch on 42 published relabelled data
  components, finished with a quantization-aware head stage that uses the
  deployed integer arithmetic
- incremental accumulators with lazy materialization and a finny-style
  refresh cache
- trained with the [bullet](https://github.com/jw1912/bullet) trainer on
  the publicly published Stockfish NNUE training datasets — see
  [docs/NETWORK.md](docs/NETWORK.md) for exactly what was and was not used

**Search** — negamax + iterative deepening, aspiration windows:

- Lazy SMP on 1 to 32 threads: independent searches of the same root that
  share one transposition table; `Threads=1` is the single-threaded search
- fractional "basin" reductions: interior LMR and the pruning families
  (null move, reverse futility, futility, late-move, history) share one
  depth-dose scheme initially parameterised from Stormphrax 8.0.0;
  this release includes a local pruning retune (see `docs/PROVENANCE.md`)
- root late-move reductions: post-PV root moves are scouted at reduced
  depth and re-searched at full depth on a fail-high
- clustered transposition table with static-eval caching, huge-page backed;
  dedicated 2-way eval cache
- null move with verification, probcut, singular extensions,
  desperation-conditioned check extensions
- killer/countermove/continuation history, and a quiet history kept in
  four tables by whether the move's from- and to-squares are attacked
  (correction history is implemented but parked: its tables are not
  allocated in this release)
- honest node accounting: one visited position, one node
- Syzygy via Fathom: WDL probes in the search; at a covered root, a DTZ
  probe of every legal move keeps the search to the moves that hold the
  tablebase result; tablebase-decided root results are proven once and
  reused instead of re-searched every iteration
- time management with an instability-armed burst: the hard per-move
  deadline extends only after a completed iteration changed its best move
  or dropped the score
- SEE-gated quiet checks at the first qsearch ply (the six built-in root
  book moves of 6.0.0/6.1.0 are gone as of 6.1.1 — see `docs/PROVENANCE.md`)

**Performance** — AVX-512 (512-bit NNUE kernels) and AVX2 SIMD via Zig
`@Vector` (portable, bit-exact), hot functions aligned for stable code
placement, LTO, transparent-huge-page self-enable on Linux/WSL2, Windows large
pages, optional llvm-bolt post-link pass.

## Development hardware

Three privately owned desktops, no cluster:

| Role | CPU | GPU | RAM |
|---|---|---|---|
| Development, native Windows speed tests, gauntlets | Ryzen 9 9950X3D (AVX-512) | RTX 4090 (training of the 6.0.0 base) | 128 GB |
| SPRTs, AVX2 and 8-thread gauntlets | Ryzen 9 5950X (AVX2) | — | 128 GB |
| Network training, 6.3.0 Windows speed qualification | Ryzen 5 7600X3D (AVX-512) | RTX 5080 | 64 GB |

Training and most development testing run under WSL2; the Ryzen 9 5950X
runs native Linux. Release binaries are cross-built with Zig; GitHub Actions
builds the same tagged sources.

## How this engine was built (AI disclosure)

zigqueen is developed by [stierms](https://github.com/stierms) with AI
assistants (Anthropic's Claude, OpenAI's Codex). The assistants write and
review code and run experiments; the author sets the goals, approves every
experiment that costs machine time and decides what ships.

Correctness rests on perft, make/unmake invariants and NNUE parity against
an independent reference. Strength changes go through short paired screens,
SPRT self-play at two time controls and an external gauntlet; performance
changes must be node-identical at fixed depth. Not every accepted change
reached an SPRT boundary. What was accepted on what evidence is recorded in
[STRENGTH.md](docs/STRENGTH.md).

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
| `Hash` | spin | 256 | Transposition table size in MB (1-65536), one table shared by all threads; also sizes each thread's private caches. |
| `Threads` | spin | 1 | Search threads (1-32). 1 is the single-threaded search; more threads share the hash table (Lazy SMP). |
| `Move Overhead` | spin | 20 | Per-move time reserve in ms for GUI/connection latency (0-1000). |
| `NNUE Scale Percent` | spin | 48 | Eval scaling in percent (0-400). The default is keyed to the embedded net; changing it is not recommended. |
| `SyzygyPath` | string | empty | Syzygy tablebase directories, separated by `:` (Linux, Android) or `;` (Windows). WDL files are probed in the search, DTZ files at the root. |
| `Contempt` | spin | 0 | Draw contempt in centipawns (-200 to 200); 0 = classical draw scoring. |
| `EvalFile` | string | `<builtin>` | Path to an external `.zqb` net; leave at `<builtin>` for the embedded net. |

That is the complete list. Development builds compiled with `-Dtuning=true`
additionally expose the search-policy parameters (`Basin*` and friends).
Both build flavours share the same defaults; tuning options take effect
between searches.

**Threads and memory.** Each thread keeps private caches sized from `Hash`:
half of it (at most 1 GB) plus a quarter (at most 64 MB). At `Hash` 256 we
measured 544 MiB resident at 1 thread, 2.0 GiB at 8 and 3.6 GiB at 16.
A change of `Threads` or `Hash` is applied between searches, briefly holds the
old and new tables, and clears the hash. `nodes`, `nps` and `go nodes` count
all threads together. Playing strength was measured up to 8 threads; see the
[6.3.0 release notes](docs/RELEASE_NOTES_6.3.0.md) for the limits.

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

- `docs/RELEASE_NOTES_6.3.0.md` — what changed in 6.3.0, and its known limits
- `docs/RELEASE_NOTES_6.2.0.md` — what changed in 6.2.0
- `docs/RELEASE_NOTES_6.1.1.md` — what changed in 6.1.1
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
  whose openly published NNUE training datasets made the network possible,
  and the people behind the relabelled collections the 6.3.0 network is
  trained on: Linmiao Xu (linrock), Joost VandeVondele (vondele), xushawn and
  the contributors to the community BT4 relabelling.
  Parts of that data are made available under the Open Database License
  (ODbL-1.0, http://opendatacommons.org/licenses/odbl/1.0/) by the Stockfish
  project and, for the LCZero-derived components, by the
  [LCZero](https://lczero.org/) project; see `docs/NETWORK.md`. Our
  changes to that data for the 6.3.0 network are offered in
  `docs/data-r2/README.md`.
- [Stormphrax](https://github.com/Ciekce/Stormphrax) (Ciekce, GPL-3.0): the
  search's reduction/pruning formulas and initial constants follow its
  published parameter set; selected pruning values have since been retuned locally (`docs/PROVENANCE.md`, section 1). No code.
- [bullet](https://github.com/jw1912/bullet), the NNUE trainer.
- [Fathom](https://github.com/jdart1/Fathom) for Syzygy probing (MIT), and
  [chessenginesupport-androidlib](https://github.com/gkalab/chessenginesupport-androidlib)
  (Apache-2.0) for the Android OEX provider.
- The engine-testing ecosystem, especially
  [fastchess](https://github.com/Disservin/fastchess), and the computer
  chess community's published research.

## License

GNU GPL version 3 or (at your option) any later version — see `LICENSE`
(SPDX: `GPL-3.0-or-later`). Third-party components keep their own licenses
(Fathom: MIT; the Android OEX support library and Gradle wrapper:
Apache-2.0); their notices are in `THIRD_PARTY_LICENSES.md`.
