# zigqueen quality gates

Mandatory gates for changes and strength candidates.

## Global gate

Run for normal source changes (requires Zig 0.15.2 on `PATH`):

```bash
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

Also ensure:

- the working tree is understandable and reversible;
- no hot-path heap allocation is introduced (see
  `docs/PERFORMANCE_PRINCIPLES.md`);
- `zig fmt --check src` is clean.

## Correctness gates

When touching board, movegen, or search fundamentals:

- representation/FEN/mailbox/occupancy tests;
- attack and legal movegen/perft tests;
- make/unmake/hash restoration tests;
- UCI compliance (`fastchess --compliance ./zig-out/bin/zigqueen`);
- fixed-depth stability (`./zig-out/bin/zigqueen stability 5`);
- no heap allocation in hot make/move/search paths.

## Performance changes

Performance work must be exact-output and profile-justified:

- fixed-depth node counts and PV must be identical before/after
  (`scripts/compare-fixed-output.py` helps ignore volatile timing fields);
- a profile or perf-stat artifact should justify the change
  (`scripts/perf-ab-compare.sh`, `scripts/compare-perf-stat.py`).

A performance change that alters search behavior is a strength candidate and
takes the full validation ladder instead.

## Strength candidate gate

A serious strength candidate may proceed only after:

1. the global gate passes;
2. the patch is small enough to interpret;
3. for a new net, the net-sanity gate passes (`scripts/net-sanity.py`:
   color-mirror symmetry ~0 cp, material monotonicity).

Validation ladder:

1. a self-play screen vs the current baseline (`scripts/selfplay-vs-baseline.sh`);
2. head-to-head SPRT vs the current baseline (`scripts/sprt-vs-baseline.sh`);
3. a periodic external gauntlet against other engines as a transfer /
   anti-overfit check — per release, not per step (a few hundred games cannot
   resolve a small gain; SPRT decides individual steps).

Speed-for-eval trades (wider nets, expensive pruning) can read positive at
very fast time controls and wash out at longer ones; confirm such candidates
at a deploy-relevant time control before shipping.

## Promotion gate

No new accepted baseline without:

- a passing validation ladder;
- a summary recording commands, settings, and results;
- the exact commit/tag and net hashes;
- a version bump and tag per the policy in `README.md`.
