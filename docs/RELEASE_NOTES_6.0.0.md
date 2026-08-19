# zigqueen 6.0.0

zigqueen 6.0.0 is the full-threats NNUE release. It promotes the tested
6.0.0-dev.2 source cutoff (`5353e8f`) without the later dev.3 search changes.

## Highlights

- New `zqHalfKA9`/`ZQB9` network: mirrored HalfKA with 8 king buckets,
  60,144 full-threat inputs, width 1024, and eight
  `1024 -> 16 -> 32 -> 1` material-bucketed layer stacks.
- The network was trained from random initialization with zigqueen's extended
  bullet trainer on published Stockfish training datasets. It was not
  initialized from, fine-tuned from, or logit-distilled from Stockfish network
  weights.
- The embedded network selects its calibrated scale of 48; legacy ZQB1-ZQB8
  files retain scale 66 unless explicitly overridden.
- Anchored 1,620-game external run: 52.3% against the 27-engine roster,
  corresponding to ~3602 CCRL Blitz Elo with a 63-Elo per-opponent spread.

## Full-threat runtime and performance

The v6 runtime adds an incremental full-threat accumulator with lazy per-ply
deltas, orientation-change barriers, and flip-cache refreshes. Its tree tests
compare incremental and full-refresh evaluation through castling, en passant,
promotion, and king-bucket transitions.

Performance rounds r1-r9 reduced the new architecture's cost while preserving
fixed-depth behavior:

- fused split-input activation and accumulator copy/flush work;
- shared attacker-set walks for both perspectives;
- removed dead finny/pending-row initialization;
- reverse-lookup threat deltas plus SIMD skip scans and fused bitset copies;
- one-time move change-list decoding and dual fused accumulator rows;
- mover-piece-keyed history and a branch-free SIMD move-picker argmax;
- occupancy-only SEE, hoisted move-list bounds, and legality fused into move
  generation; and
- direct addressing of zobrist piece-square rows.

Round r6 was tested and reverted; it is not part of the release. The accepted
rounds measured about +21% cumulatively on AVX2 for the v6 path, with rounds
r7-r9 contributing about +5.2% on the shipped network.

The AVX2 first-layer kernel also uses a fixed 16-lane accumulation order so
portable x86 builds retain the release's cross-ISA fixed-depth identity.

## Search and time management since 5.8.3

- Time management now uses the field-confirmed 130% optimum-time spend level.
  The campaign was positive in fast, 20-second, 60-second, and external-field
  reads before promotion.
- The promoted dev.2 identity includes its six deterministic exact-root book
  entries and exposes the advanced search-tuning UCI options at their tested
  defaults. Both are visible behavior differences from the sanitized public
  5.8.3 tree and are documented here rather than silently normalized away.
- The evaluation/search combination was positive against the prior
  time-management baseline at fixed nodes and at 8+0.08, 20+0.2, and 60+0.6.

## Tools and platforms

- New in-process self-play data generator with QC/fan-out tooling.
- Rebuilt conversion-position probe and gauntlet EvalFile/scale overrides.
- Release packages cover Linux and Windows x86-64-v3/AVX2 and
  x86-64-v4+VNNI/AVX-512, plus Android armv8 and armv8-dotprod binaries.
- Signed generic and dotprod OEX APKs are provided for Android chess GUIs.
- Windows packages retain the large-page allocation path with silent regular-
  page fallback when `SeLockMemoryPrivilege` is unavailable.

## Compatibility

zigqueen remains a single-threaded UCI engine. The default Hash is 256 MB.
The embedded net is self-contained; `EvalFile` can still load supported
external ZQB networks. The official binaries identify as
`zigqueen 6.0.0`.
