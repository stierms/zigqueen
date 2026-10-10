# 6.4.0 release validation

The public 6.4.0 source is the build that played both 6.4.0 gauntlets
(`c08456bcc` in our private history) plus version and packaging metadata, two
developer-tool defaults, reworded comments and one corrected unit-test count.
No search or evaluation code changed after the gauntlets.

## Checks

- ReleaseFast unit suites in the normal, search-statistics and tuning
  flavours, the tablebase tests with 3–6 piece Syzygy tables, and the Debug
  suites that CI runs. The source hygiene check passes.
- UCI compliance (fastchess, 40 steps), repeated-search stability and the
  network's colour-symmetry check. The engine identifies as `zigqueen 6.4.0` and
  exposes the seven options listed in the README.
- All six portable builds and a native Linux build reproduce the gauntlet
  binary's `bench 16` node count (119,576) and its depth-14 nodes, score, PV
  and best move on the positions below (Hash 64 MB, one thread, no
  tablebases).
- The Windows executables ran natively on Windows 11. The ARM builds ran under
  QEMU user-mode emulation: the generic build on a Cortex-A53 model, the
  dotprod/i8mm build on QEMU's `max` CPU; the dotprod build stops with an
  illegal instruction on the Cortex-A53 model, as it should. ARM speed was not
  measured.
- A short smoke at 1, 4 and 8 threads ran cleanly on the Linux AVX2 build with
  tablebases and on both ARM builds under QEMU.
- Both OEX APKs carry the new signing certificate (see
  [ANDROID.md](ANDROID.md)), version code 640 and version name 6.4.0. Their
  embedded engine bytes match the tested ARM binaries.
- The public export passed a secret scan.

| Position | Nodes | Score (cp) | Best move |
|---|---:|---:|---|
| Start position | 51809 | 35 | e2e4 |
| `r1bq1rk1/2p1bppp/p1np1n2/1p2p3/4P3/1BP2N2/PP1P1PPP/RNBQR1K1 w - - 0 10` | 66316 | 41 | a2a4 |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 9232 | 138 | b4f4 |

## Network

The embedded network has SHA-256
`1342ac4691324a632418d6e1fc8696807c364d9a8bb63fbbc9b74e771cf1ffac`
(88,724,892 bytes, `ZQBA` format, default scale 44).
