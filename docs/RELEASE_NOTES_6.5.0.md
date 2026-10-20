# zigqueen 6.5.0

## Strength

3717 (95%: 3713–3721) at one thread, from 3,256 games against 22 engines
centred on 3700 on the CCRL Blitz list; our own estimate, not a CCRL rating.
6.4.0's 3701 was measured against a weaker field (mean 3667), so the two
numbers are not directly comparable.

## What's new

- About 20% faster, with the same search.
- The x86-64 release binaries are profile-guided (PGO) builds.
- New time manager: it always has a searched move ready and spends extra time
  when the best move or the score is unstable.
- Own Syzygy tablebase prober, replacing Fathom.
- Exchange evaluation no longer lets a piece pinned to its king recapture,
  so some winning captures, mates included, are no longer skipped as losing.
- New UCI option `NNUE Shared Weights` (default off): zigqueen processes of
  the same user share one copy of the network, about 90 MB less per extra
  process.

## Fixes

- A negative clock value from the GUI no longer makes zigqueen ignore `go`.
- Tablebase root play: a win the fifty-move rule may turn into a draw ranks
  below certain wins, and repetitions on the board are respected.
- FENs without move counters are accepted; impossible castling rights are
  dropped; positions with a pawn on the first or last rank are rejected.
- An unknown word in front of a UCI command is skipped.
- A failed `Hash` or `Threads` change restores the previous settings.

## Downloads

- `avx512` for CPUs with AVX-512 (AMD Zen 4 and newer, Intel Ice Lake or newer
  with AVX-512), otherwise `avx2`; Windows and Linux zips.
- Android: OEX APKs for chess GUIs, raw binaries in the android zips;
  `armv8-dotprod` needs the dotprod and i8mm extensions, otherwise take
  `armv8`. The APKs are signed with the same key as 6.4.0 and install over it;
  uninstall 6.3.0 or older first.
- The network is 6.4.0's; its training-data offer is attached again
  ([data-r2/README.md](data-r2/README.md)). `SHA256SUMS` has the checksums.
