# 6.3.0 release validation

The public 6.3.0 source is the externally tested build plus version and
packaging metadata and two developer-tool defaults. The engine source is
unchanged from the build that played the gauntlet and the self-play tests
(`2d7193418` in our private history). No search or evaluation change was
made after those tests. Build names such as "pre-multicore" and "6.3 base"
are explained at the top of [STRENGTH.md](STRENGTH.md).

## Checks

- ReleaseFast unit suites in the normal, search-statistics and tuning
  flavours, plus the fresh-process initialisation tests. The tests that
  need tablebase files ran with 3–6 piece Syzygy tables. Source hygiene and
  formatting checks pass.
- UCI compliance (fastchess, 40 steps), repeated-search stability, and the
  network's colour-symmetry and material checks. The engine identifies as
  `zigqueen 6.3.0` and exposes the seven options listed in the README.
- All six portable builds and a native Linux build reproduce the tested
  binary's `bench 16` node count (309,747) and its depth-14 nodes, score,
  PV and best move on the positions below (Hash 64 MB, one thread, no
  tablebases). The AVX2 build ran on AVX2-only hardware.
- The Windows executables ran natively on Windows 11. The ARM builds ran
  under QEMU user-mode emulation: the generic build on a Cortex-A53 model,
  the dotprod/i8mm build on QEMU's `max` CPU. The dotprod build stops with
  an illegal instruction on the Cortex-A53 model, as it should. These are
  execution checks, not tests on a physical device, and ARM speed was not
  measured.
- A short smoke at 1, 4 and 8 threads (depth, movetime, `go infinite` with
  `stop`, node limits, thread-count changes) ran cleanly on the Linux AVX2
  build with tablebases and on both ARM builds under QEMU: one best move per
  search, clean exit.
- Both OEX APKs carry the published signing certificate, version code 630
  and version name 6.3.0. Their embedded engine bytes match the tested ARM
  binaries, and both include the license notices.
- The exact public export passed a secret scan. The release commit descends
  from the previous public main; private history is not published.

| Position | Nodes | Score (cp) | Best move |
|---|---:|---:|---|
| Start position | 131288 | 28 | e2e4 |
| `r1bq1rk1/2p1bppp/p1np1n2/1p2p3/4P3/1BP2N2/PP1P1PPP/RNBQR1K1 w - - 0 10` | 160438 | 38 | h2h3 |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 20067 | 187 | b4f4 |

## Speed at one thread

The speed work changes no search result: at fixed depth, nodes, scores and
moves are identical, and only the time changes.

- Windows: the recursive search no longer calls the stack probe or saves ten
  XMM registers on every call.
- With tablebases loaded, an inline check skips the probe call for positions
  the tables cannot cover.
- Threat-feature updates touch only the attacker groups a move changes, and
  AVX2 groups its first-layer dot product.
- Hot functions are aligned to 64 bytes, so unrelated code changes move the
  speed less.
- AVX-512: the network kernels now run 512 bits wide. The x86-64-v4 build had
  been running them at 256 bits because of LLVM's default tuning for that
  target. Both builds also get a row-blocked first-layer finisher.

Formal qualification, independently reviewed: time for identical work at
`Threads=1` on native Windows, against the pre-multicore build with the same
network, 24 interleaved pairs per cell, 95% intervals in brackets. Negative
means less time. Ryzen 5 7600X3D (Zen 4), Windows 11, Balanced power plan,
256 MB hash, no large pages. The timed build has all of the speed work but
not the cut-node change, which changes the search and was measured in games
instead. With tablebases on, the comparator is the pre-multicore build with
the root tablebase fix ported, so both sides do the same work.

| | Tablebases off | Tablebases on |
|---|---:|---:|
| AVX2 | −3.6% (−4.3 to −2.8) | −5.4% (−6.2 to −4.5) |
| AVX-512 | −7.7% (−8.8 to −6.6) | −8.2% (−8.9 to −7.5) |

An earlier qualification, before the AVX-512 network step, measured 1.9–3.3%
less time on all four cells on a Ryzen 9 9950X3D (Zen 5) with large pages.
Don't compare numbers across the two machines. There is no direct
speed measurement against the 6.2.0 binary.

## Multithreading

- At `Threads=1` the threaded code runs no helper threads. Against the
  pre-multicore build it measured +0.5 Elo (95%: −3.5 to +4.5) over 6,614
  games at 60s+0.6s: no change, as intended.
- Final build on Linux: fault and protocol tests at 4 and 8 threads, in the
  release build and in a safety-checked build (thread-count changes, network
  reloads, tablebase roots, `go infinite` and `stop`), gave no illegal, extra
  or early best moves. Tablebase and draw regression positions at 1, 4 and 8
  threads all pass. 64 games at 8 threads each against the 6.3 base had no
  illegal moves, time losses or crashes.
- Stop latency with tablebases (96 stops per thread count, warm and cold file
  cache): worst 13.1 ms at one thread, 9.1 ms at 4 and 9.0 ms at 8. Of 288
  `go movetime 100` searches, 3 ended late, by at most 0.83 ms.
- Final build on native Windows 11 (Zen 4): a runtime check at 1 and 4
  threads (movetime, clock, `stop`, thread-count changes, node limits) passed
  with both builds. 8 threads on Windows was not checked for the final build;
  the multithreading code passed correctness tests on Windows and Linux at
  2–32 threads earlier in the cycle.
- Resident memory at the default Hash 256: 544 MiB at 1 thread, 1.2 GiB at 4,
  2.0 GiB at 8 and 3.6 GiB at 16. Each thread's private caches take half of
  `Hash` (at most 1 GB) plus a quarter (at most 64 MB). Changing `Threads`
  briefly holds both setups (8 to 16 threads peaked at 5.3 GiB) and clears
  the hash.

## Known issue

In one 6.3 RC gauntlet game the search reported a false tablebase-loss score.
At roots the tables cover, the root tablebase filter now ignores such scores;
the cause inside the search has not been found.

## Network and data

- The embedded network is SHA-256
  `a63732096ec9f2afdb0e18ddf09a7a04b6cdd5c1b6c8844b200afaf48f9da731`
  (74,587,732 bytes), the same file used in every 6.3.0 match. Recipe and
  data sources are in [NETWORK.md](NETWORK.md).
- The [data offer](data-r2/README.md) was checked from a fresh unpack of
  the archive: its manifests reproduce the admitted totals (131,124,072,315
  training rows, 7,998,177 held out), the 42 score tables and the quotas.
  Re-running the admission on one complete 16-million-row file reproduced its
  recorded index byte for byte. 1,159,467 rows from four components (two of
  our re-encoded copies and two published files, `dfrc_n5000` among them)
  were rebuilt from the published data by the documented rules and matched
  the training loader's rows and targets bit for bit. For each of the 37
  re-encoded components, the copy program reproduced the first block of our
  copy from the published file. These are samples, not a full-corpus replay.

`SHA256SUMS` covers the six zips, two APKs and the data archive. Match
results and the self-play tests are in [STRENGTH.md](STRENGTH.md).
