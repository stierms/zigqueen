# zigqueen 6.5.0

<p align="center"><img src="docs/logo/zigqueen-logo.png" alt="zigqueen logo" width="220"></p>

zigqueen is a UCI chess engine written in Zig, with its own NNUE evaluation
and an alpha-beta search on 1 to 32 threads. The engine code was written for
this project; credits for ideas, parameters and data are in
[docs/PROVENANCE.md](docs/PROVENANCE.md). License: GPL-3.0-or-later.

## Download

From the [releases page](https://github.com/stierms/zigqueen/releases):

| File | For |
|---|---|
| `…-windows-x86_64-avx512.zip`, `…-linux-x86_64-avx512.zip` | CPUs with AVX-512 (AMD Zen 4 and newer, Intel Ice Lake or newer with AVX-512) |
| `…-windows-x86_64-avx2.zip`, `…-linux-x86_64-avx2.zip` | other x86-64 CPUs from Intel Haswell or AMD Zen 1 on |
| `…-oex-armv8.apk`, `…-oex-armv8-dotprod.apk` | Android chess GUIs that support OEX engines ([docs/ANDROID.md](docs/ANDROID.md)) |
| `…-android-armv8.zip`, `…-android-armv8-dotprod.zip` | raw Android binaries, e.g. for Termux |

All builds play the same moves; they differ only in speed. Take `dotprod`
only if the CPU has both the dotprod and i8mm extensions.

## Strength

| Version | Our gauntlet, 1 thread | [CCRL Blitz](https://computerchess.org.uk/ccrl/404/) | [CCRL 40/15](https://computerchess.org.uk/ccrl/4040/) | [CCI](https://github.com/computer-chess-index/cci/blob/main/engines/Zigqueen.md) VLTC |
|---|---|---|---|---|
| 6.5.0 | 3717 (95%: 3713–3721) | — | — | — |
| 6.4.0 | 3701 (95%: 3694–3707) | — | — | — |
| 6.3.0 | 3676 (95%: 3670–3683) | — | — | 3563 ±81 |
| 6.2.0 | ~3672 | 3649 ±18 | — | — |
| 6.1.1 | ~3644 | — | — | 3475 ±45 |
| 6.0.0 | ~3602 | — | 3498 ±18 | 3402 ±45 |
| 5.8.3 | ~3590 | 3559 ±14 | — | 3384 ±33 |

Our gauntlets are our own estimates against CCRL-rated engines, not official
numbers. The field changed between versions, so the rows are not directly
comparable ([docs/STRENGTH.md](docs/STRENGTH.md)).

## Features

- NNUE: HalfKA with 16 king buckets, threat features and pawn pairs, width
  1024, embedded (88.7 MB).
- Network trained from scratch on public data ([docs/NETWORK.md](docs/NETWORK.md)).
- Integer inference with AVX-512, AVX2 or NEON, identical on every build.
- Lazy SMP on 1 to 32 threads with one shared hash table.
- Search: null move, probcut, singular extensions, correction history.
- Own Syzygy tablebase prober: WDL in the search, DTZ at the root.
- Time manager that always has a searched move ready.
- Large pages: automatic on Linux; on Windows after granting "Lock pages in
  memory".
- Profile-guided (PGO) x86-64 release builds.
- Android OEX engine APKs.

## UCI options

| Option | Default | Description |
|---|---|---|
| `Hash` | 256 | Hash table in MB (1–65536), shared by all threads. |
| `Threads` | 1 | Search threads (1–32). |
| `Move Overhead` | 20 | Time reserve per move in ms for GUI latency (0–1000). |
| `NNUE Scale Percent` | 44 | Evaluation scale; keep the default for the embedded network. |
| `SyzygyPath` | empty | Tablebase directories, separated by `:` (`;` on Windows). |
| `Contempt` | 0 | Draw contempt in centipawns (−200 to 200). |
| `EvalFile` | `<builtin>` | Path to an external `.zqb` network. |
| `NNUE Shared Weights` | false | Share one copy of the network weights between zigqueen processes of the same user (about 90 MB saved per extra process). |

## Build

Requires Zig 0.15.2:

```bash
zig build -Doptimize=ReleaseFast   # ./zig-out/bin/zigqueen, for the native CPU
zig build test
```

Every 6.5.0 build gives `bench 16` = 162,091 nodes.

`scripts/package-release.sh` builds the six release binaries, the x86-64 ones
as PGO builds from the profiles in `scripts/pgo/profiles/`; the method is
described at the top of `scripts/pgo-build.sh`.

## How this engine was built

zigqueen is developed by [stierms](https://github.com/stierms) with AI
assistants (Anthropic's Claude, OpenAI's Codex), which write and review code
and run experiments; the author decides what ships. Every change passes
correctness tests, strength changes are tested in self-play, and releases in
gauntlets against other engines. The rules are in
[ORIGINALITY.md](ORIGINALITY.md), the credits in
[docs/PROVENANCE.md](docs/PROVENANCE.md).

## Documentation

- [Release notes](docs/RELEASE_NOTES_6.5.0.md), [strength](docs/STRENGTH.md),
  [architecture](docs/ARCHITECTURE.md), [network](docs/NETWORK.md)
- [Android](docs/ANDROID.md), [Windows builds](docs/WINDOWS_BUILD.md),
  [all documents](docs/README.md)

## Acknowledgments

- Stockfish, LCZero and the data relabellers (linrock, vondele, xushawn, BT4
  relabelling): training data, partly ODbL-1.0 ([our changes](docs/data-r2/README.md)).
- [Stormphrax](https://github.com/Ciekce/Stormphrax): the search's reduction and pruning parameters.
- [bullet](https://github.com/jw1912/bullet): the NNUE trainer.
- Ronald de Man: Syzygy; [Fathom](https://github.com/jdart1/Fathom): our prober's test reference.
- [chessenginesupport-androidlib](https://github.com/gkalab/chessenginesupport-androidlib): Android OEX.
- [fastchess](https://github.com/Disservin/fastchess): engine testing.

## License

- zigqueen: GPL-3.0-or-later ([LICENSE](LICENSE)).
- Fathom (`deps/fathom`, test tool only): MIT.
- Android OEX support library and Gradle wrapper: Apache-2.0.
- All third-party notices: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
