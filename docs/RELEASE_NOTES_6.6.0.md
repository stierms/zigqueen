# zigqueen 6.6.0

## Strength

3738 (95%: 3734–3742) at one thread, from 3,256 games against 22 engines
centred on 3700 on the CCRL Blitz list; our own estimate, not a CCRL rating.
6.5.0 scored 3717 against the same engines with the same openings: +21 (95%:
+15 to +26), game for game.

## What's new

- A more compact hash table: more positions in the same `Hash` setting.
- Deeper search: from depth 6 on the engine tests whether the hash move
  stands alone, and searches it deeper where it does and shallower where it
  does not. It reports about two plies more depth in the same time; depth
  figures are not comparable with 6.5.0's.
- Won games are converted more often: once its score has reached +3.00 in a
  game, the engine presses for progress against the fifty-move counter. The
  score shown can sink while that counter rises and returns after a pawn
  move or a capture; a position analysed on its own is searched without it.
- A mate found stays a mate from move to move.
- Move ordering remembers the reply that refuted a move after captures and
  promotions too, and orders the root moves by the search each one needed.
- Where a position has been searched before, the pruning rules trust that
  result over the static evaluation.
- A draw inside the search scores +0.01 or −0.01, not 0.00; a draw that can
  already be claimed and a tablebase draw stay 0.00. The engine repeats less
  readily in a drawn position, so drawn games run longer (about one move in
  seven more in our gauntlet) and more of them end by the fifty-move rule.
- With `movestogo`, the last move before a time control is no longer
  planned with the whole remaining clock.

## Fixes

- `go movetime` answers within the movetime less `Move Overhead`; 6.5.0
  ignored the overhead and answered late about one move in eleven.
- A `stop` within milliseconds of `go` gets a searched move.
- With a draw score, a move that repeats an earlier position of the game is
  searched before it is preferred; the opponent need not repeat.
- A stalemate with pieces on the board is a draw, a mate in one behind an
  empty capture list is seen, and close to the fifty-move draw a static
  value or an old hash score is no longer trusted.

## Downloads

- `avx512` for CPUs with AVX-512 (AMD Zen 4 and newer, Intel Ice Lake or newer
  with AVX-512), otherwise `avx2`; Windows and Linux zips.
- Android: OEX APKs for chess GUIs, raw binaries in the android zips;
  `armv8-dotprod` needs the dotprod and i8mm extensions, otherwise take
  `armv8`. The APKs are signed with the same key as 6.4.0 and 6.5.0 and
  install over them; uninstall 6.3.0 or older first.
- The UCI options are 6.5.0's eight. The network is 6.4.0's; its
  training-data offer is attached again
  ([data-r2/README.md](data-r2/README.md)). `SHA256SUMS` has the checksums.
