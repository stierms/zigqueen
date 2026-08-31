# zigqueen 6.1.0

6.0.0 was the network release. This one is about the search: same net,
noticeably stronger play, and two robustness fixes found in live games.

## Search

- Introduced the basin reduction scheme: the interior search now uses
  fractional reductions and is much more deliberate about where depth
  gets spent.
- At the root, moves after the principal variation are scouted at reduced
  depth first and only get a full-depth search when the scout pushes back.
- The clock manager may now think well past its normal per-move budget —
  but only when the previous iteration changed its mind about the best move
  or saw the score drop. Calm searches keep the old limits.

## Fixes

- Endgames already decided by the tablebases no longer eat the clock. The
  search proves the result once and banks it; before, it could burn the
  whole move budget re-proving a known loss. Found the hard way in a live
  bullet game.
- A tablebase file that fails to load is skipped with a log line. It used
  to take the engine down mid-search.

## Odds and ends

- Node counts are honest now: one visited position, one node. Expect
  `nodes` and `nps` to read about a fifth lower than 6.0.0 for the same
  work.
- The long list of internal tuning options is gone from release builds.
  The engine now exposes just the options a user actually needs; the
  tuning scaffold lives behind a build flag for development.

Strength measurements, methodology and caveats live in
[STRENGTH.md](STRENGTH.md); the short version is a clear step over 6.0.0
in both self-play and the anchored gauntlet.

Single-threaded UCI engine, default Hash 256 MB, same embedded ZQB9
network as 6.0.0. Official binaries identify as `zigqueen 6.1.0`.
