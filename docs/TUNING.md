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
- Openings: `UHO_4060_v4.epd` from Stefan Pohl's UHO collection (not shipped
  in this repository; download it and set `OPENINGS_FILE`). The UHO
  book is White-favoured by construction; every opening is played twice
  with colours reversed.
- Passing the screen only earns an SPRT; it does not promote.

## Tier 1b — SPRT

- `scripts/sprt-vs-baseline.sh` (wrapping `scripts/benchmark-sprt.sh`).
- Bounds `elo0=0`, `elo1=5`, `alpha=beta=0.05`. H1 reached: accept
  (subject to the second leg). H0 reached, or unresolved at the cap and
  non-positive: reject.
- Accepted changes are confirmed with a second SPRT leg at a
  deploy-relevant TC (`60+0.6`, tablebases on) — H1 at both legs or no
  merge. Fast-TC gains that buy depth or trade speed for eval can compress
  or invert at longer time controls; the second leg is what catches that.
- Time-management candidates additionally pass a fast-TC screen with an
  any-time-loss veto.

## Tier 2 — external check

SPRT decides individual steps; an external gauntlet against other engines is
the periodic transfer / anti-overfit check (per release or per tuning batch,
never per step — a few-hundred-game gauntlet has several-percentage-point
noise). Run it from a clean tagged commit and record binaries, options, and
results with the release.

## Tuning builds

Release builds expose exactly the seven documented UCI options. The runtime
search-tuning scaffold (the SPSA knobs) exists only in builds compiled with
`-Dtuning=true`; SPSA drivers and parameter sweeps must build with that
flag. The compiled-in default values are identical in both flavours.

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
