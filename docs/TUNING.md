# zigqueen tuning and validation loop

How strength candidates are screened, measured, and accepted.

## Tier 0 — correctness gate

Run before any serious candidate screen (requires Zig 0.15.2 and
[fastchess](https://github.com/Disservin/fastchess) on `PATH`):

- `zig build -Doptimize=ReleaseFast`
- `zig build test -Doptimize=ReleaseFast`
- `./zig-out/bin/zigqueen stability 5`
- `fastchess --compliance ./zig-out/bin/zigqueen`

## Tier 1a — self-play screen

- `scripts/selfplay-vs-baseline.sh` builds HEAD and a baseline ref and runs a
  fixed-game screen (default 192 games).
- Default TC `3+0.1`; set `CONCURRENCY` to your core count.
- Openings: `openings/real-openings-96.pgn` (or set `OPENINGS_FILE`).
- Passing the screen only earns an SPRT; it does not promote.

## Tier 1b — SPRT

- `scripts/sprt-vs-baseline.sh` (wrapping `scripts/benchmark-sprt.sh`).
- Defaults: `elo0=0`, `elo1=10`, `alpha=beta=0.05`, pentanomial
  `model=normalized`, cap 400 paired games (`SPRT_MAX_ROUNDS=200`).
- H1 reached: accept (subject to Tier 2). H0 reached: reject.
- Unresolved at the cap and non-positive: reject.
- Unresolved and positive: one extended SPRT (e.g. `SPRT_MAX_ROUNDS=1000`)
  may be run before a final decision.

Fast-TC caveat: gains that buy depth or trade speed for eval compress or
invert at longer time controls. For ships that matter, confirm with a leg at
a deploy-relevant TC (e.g. `60+0.6` or longer).

## Tier 2 — external check

SPRT decides individual steps; an external gauntlet against other engines is
the periodic transfer / anti-overfit check (per release or per tuning batch,
never per step — a few-hundred-game gauntlet has several-percentage-point
noise). Run it from a clean tagged commit and record binaries, options, and
results with the release.

## Runtime NNUE candidates

Swap a candidate net at runtime instead of rebuilding:

- `EvalFile=/path/to/net.zqb` (omit for the embedded default net)

Gate any new net with `scripts/net-sanity.py` (color-mirror symmetry and
material monotonicity) before spending games on it. Training loss is only a
prefilter; match play decides.

## Record keeping

Candidate summaries should record: status and decision; source/net hashes;
exact commands and settings; and the match results. Keep summaries with the
match artifacts, not in the docs.
