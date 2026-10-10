# zigqueen 6.4.0

A new, larger network and a round of search improvements. In our gauntlets
6.4.0 rates **3701** at one thread and **3736** at eight threads, up from 3676
and 3697 for 6.3.

## What's new

- **New network.** It sees more of the position than 6.3.0's network (16 king
  positions instead of 8, plus pairs of pawns) and was trained from scratch on
  the same data. In self-play it gained 15–23 Elo over the old network. The
  binary is about 14 MB larger. The default `NNUE Scale Percent` is now 44;
  leave it there.
- **Search.** The search now learns where its static evaluation tends to be
  wrong and corrects for it. A bug in exchange evaluation, where a king
  capturing onto a defended square counted as free, is fixed. Several search
  parameters were retuned.
- **Time control fix.** With a move-count time control (for example 40 moves in
  2 minutes), earlier versions could lose on time on the last move before the
  control. That can't happen anymore.
- **Multithreading.** 6.4.0 fixes some issues with multi-threaded memory usage.

## Fixes

- `go mate N` now searches for a mate.
- A checkmate is reported as `score mate 0`, even when the fifty-move count
  has run out.
- `go depth N` no longer runs forever in some positions near a mate.
- UCI option names are matched regardless of case.
- Bad commands are answered with an `info string error` and ignored.
- A `SyzygyPath` that fails to load keeps the tables loaded before.

## Strength

| Gauntlet | 6.4.0 | Before |
|---|---|---|
| 1 thread, 22 engines near 3666 on CCRL Blitz | **3701** (95%: 3694–3707) | 6.3.0: 3676 |
| 8 threads, 22 engines from the CCRL 8-CPU list | **3736** (95%: 3726–3746) | 6.3 RC: 3697 |

These are our own performance estimates against CCRL-rated engines, not CCRL
ratings. zigqueen forfeited none of the 2,068 games.
[STRENGTH.md](STRENGTH.md) has the per-opponent results.

The larger network costs some speed: 6.4.0 searches about 4% fewer positions
per second than 6.3.0. The numbers above already include that.

## Things to know

- **The Android APKs are signed with a new key**, so Android won't install
  them over an older zigqueen APK. Uninstall the old app first.
  [ANDROID.md](ANDROID.md) lists the new certificate.
- Use at most one thread per physical core. Playing strength was measured at
  1 and 8 threads.
- The AVX2 and AVX-512 builds play the same moves and differ only in speed.
- The Android builds were checked under emulation, not on a phone.

## Training data

The network was trained on the same public data as 6.3.0's, parts of it under
the Open Database License. The alterations offer published with 6.3.0 covers
it and is attached again (`zigqueen-training-data-r2-alterations.tar.xz`,
[data-r2/README.md](data-r2/README.md)). [NETWORK.md](NETWORK.md) and
[trainer/README.md](trainer/README.md) describe the network and its training.

## Downloads

Windows and Linux zips (AVX2 and AVX-512), Android zips and signed OEX APKs
(armv8 and armv8-dotprod), the training-data file and `SHA256SUMS`.
[RELEASE_VALIDATION_6.4.0.md](RELEASE_VALIDATION_6.4.0.md) has the release
checks.
