# zigqueen 6.0.0

The full-threats NNUE release: a new evaluation network architecture and a
substantially faster inference path.

## Highlights

- New `ZQB9` network: mirrored HalfKA with 8 king buckets, 60,144
  full-threat inputs, width 1024, and eight `1024 -> 16 -> 32 -> 1`
  material-bucketed layer stacks.
- Trained from random initialization with zigqueen's extended bullet trainer
  on published Stockfish training datasets — not initialized from,
  fine-tuned from, or distilled from another engine's network weights. See
  [NETWORK.md](NETWORK.md).
- External check: 52.3% over a 1,620-game gauntlet against 27 CCRL-listed
  engines, ~3602 CCRL Blitz on that instrument. Details and caveats in
  [STRENGTH.md](STRENGTH.md).

## Performance

The new architecture ships with an incremental full-threat accumulator and
nine accepted optimization rounds, together worth about +21% node throughput
on AVX2 with fixed-depth behavior preserved. The AVX2 first-layer kernel
uses a fixed accumulation order, so portable x86 builds keep cross-ISA
fixed-depth identity.

## Search and time management

- Time management moved to a field-confirmed 130% optimum-time spend level.
- Advanced search-tuning UCI options are exposed at their tested defaults.

## Platforms

- Linux and Windows: x86-64-v3/AVX2 and x86-64-v4+VNNI/AVX-512 packages;
  Windows builds use large pages when available, with silent fallback.
- Android: armv8 and armv8-dotprod binaries, plus signed OEX APKs for
  engine-GUI apps.

## Compatibility

Single-threaded UCI engine; default Hash 256 MB. The embedded net is
self-contained; `EvalFile` can load supported external ZQB networks.
Official binaries identify as `zigqueen 6.0.0`.
