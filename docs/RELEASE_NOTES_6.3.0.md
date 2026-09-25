# zigqueen 6.3.0

This is the first zigqueen that can use more than one core. It also comes
with a new network, better handling of tablebase endings and a faster search.

## What's new

### Multithreading

`Threads` now goes up to 32. The default is still 1. All threads share one
hash table, so `Hash` sets its size as before.

In self-play, 4 threads were about 100 Elo stronger than 1, and 8 threads
about 25 Elo stronger than 4. At 8 threads, a 6.3 release candidate reached a
performance of about 3700 against engines from the CCRL 8-CPU list.

### New network

The network was trained from scratch on more public data than before: 42
data sets relabelled with evaluations from Leela Chess Zero's BT4 network,
where 6.2.0 used 27. With everything else the same, the new network came out
about 8–11 Elo ahead of the old one. It is still embedded in the binary.
Leave `NNUE Scale Percent` at 48.

### Tablebase endings

If the position on the board is covered by your Syzygy tables, zigqueen now
only looks at moves that keep the tablebase result. 6.2.0 could still pick a
losing move in a drawn tablebase position. This needs the DTZ files
(`.rtbz`) as well as the WDL files; without them this check stays off.

### Speed

At one thread, the speed improvements cut search time by about 4–5% with the
AVX2 build and about 8% with the AVX-512 build, compared with the last
single-threaded development build on the same network. We measured this on a
Ryzen 5 7600X3D under Windows 11, without large pages. Part of the AVX-512
gain comes from its network code now running at the full 512-bit width;
before, it only used half.

### Search

Two small changes: one to move ordering, and one to how the search decides
which moves to reduce. In self-play at one thread, the move-ordering change
gained about 9 Elo. The reduction change and the speed improvements together
gained 8–17 Elo, depending on the time control.

### Fixes

- Games longer than about 400 moves no longer stop the engine.
- `go infinite` now always waits for `stop`, even when the result is clear
  straight away.
- Output lines no longer get mixed together, so GUIs read them reliably.
- A `setoption` with a very long unknown name no longer crashes the engine.
- If a new `Hash` or `Threads` value can't be allocated, the engine keeps the
  old one.
- Tablebase files that fail to load are cleaned up properly on Linux and
  Windows.

## Strength

At one thread, 6.3.0 performed at **3676** in our gauntlet against 22 engines
near its level on the CCRL Blitz list, with the clock set the way CCRL does
it. That's our own measurement, not a CCRL rating, and it can't be compared
with 6.2.0's number, which came from a different field and clock.
[STRENGTH.md](STRENGTH.md) has the full results and method.

## Things to know

- Use at most one thread per physical core. We measured strength up to 8
  threads and never with more threads than cores; 16 and 32 threads were only
  tested for correctness. With more than one thread, the same search can give
  a different move from run to run.
- Memory grows with the thread count. With the default 256 MB hash, expect
  about 0.5 GB at 1 thread, 2 GB at 8 and 3.6 GB at 16. Changing `Threads`
  clears the hash.
- The AVX2 and AVX-512 builds play the same moves and differ only in speed.
  Some older Intel CPUs slow down when running AVX-512 code. If the AVX-512
  build is slower on your machine, use AVX2.
- We checked the Android builds under emulation, not on a phone, and didn't
  measure their speed. [ANDROID.md](ANDROID.md) explains which build fits
  your device.
- `SyzygyPath` accepts several folders, separated by `:` on Linux and Android
  and `;` on Windows. The tablebase change above only applies when the
  position is in your tables.
- Once in testing, the search reported a false tablebase loss. In positions
  your tables cover, that can no longer affect the move, but we haven't found
  the cause yet.

## Training data

The network was trained on public data, parts of it under the Open Database
License. As with 6.2.0, we publish what we changed in that data, and the
code to repeat it, in `zigqueen-training-data-r2-alterations.tar.xz`
([data-r2/README.md](data-r2/README.md)). [NETWORK.md](NETWORK.md) covers the
data sources and training, and [trainer/README.md](trainer/README.md) our
changes to the trainer.

## Downloads

- Windows and Linux zips, each for AVX2 and AVX-512
- Android zips (armv8 and armv8-dotprod) and signed OEX APKs for Android
  chess apps
- the training-data file above and `SHA256SUMS`

[RELEASE_VALIDATION_6.3.0.md](RELEASE_VALIDATION_6.3.0.md) has the release
checks and the detailed speed and multithreading results.
