# Strength

## 6.2.0 external validation

The completed MAIN gauntlet gives **3672 [3661, 3683]** on our anchored
roster-likelihood scale. This is a self-assessment, not an official CCRL
rating. Its bracket is the model's approximate one-standard-error interval;
it excludes uncertainty in opponent anchors and environmental differences.

MAIN recorded **609 wins, 770 draws, 241 losses: 994/1620 (61.36%)**.
Two opponent forfeits have unresolved causes. Counting those as losses
instead gives 992/1620 (61.23%); this 992–994 range is an outcome-sensitivity
bound, not a confidence interval. No candidate forfeits were recorded.

A separate AVX2 run on oldrig completed all 1620 games and estimated
**3665 [3654, 3676]**, with 979.5 points (60.46%). Three unresolved opponent
forfeits give a sensitivity range of 976.5–979.5 points (60.28–60.46%).
We keep the two host results separate: CPU architecture, opponent binary
variants and background load differ. They are not pooled into one rating.

### Method

- September 8–9, 2026; 27 opponents, 60 games each, 180+1 time control.
- One engine thread per process, Hash 256 MB, concurrency 24 on MAIN,
  normal process priority. MAIN is a Ryzen 9 9950X3D; oldrig a Ryzen 9 5950X.
- `UHO_4060_v4.epd`: each opponent receives a separately seeded draw of
  30 openings, each played with reversed colours; seeds 6200 through 6226.
- Candidate Syzygy paths cover 3–6 pieces; default NNUE scale 48.
- CCRL Blitz anchor snapshot dated July 19, 2026. Installed versions can
  differ from the versions behind those historical ratings; these anchors
  are a fixed yardstick, not a current official ranking.
- MAIN's Lunar, Starzix, Heimdall and Velvet legs were rerun after early
  contention and a Lunar terminal-environment issue. The canonical result
  substitutes those complete legs using the exact original opening/colour
  pairs. Original legs are archived; the other 23 are unchanged. This is
  one completed gauntlet, not a sum of original and replacement games.
- The headline fits one common rating to the roster outcomes. The arithmetic
  mean of per-opponent implied ratings below is 3673.8, a different
  descriptive estimator. Earlier published summaries used that mean;
  do not subtract across estimators as if they were identical.

The first RC in this dashboard series was 3664. The observed difference
is **+8**, within the run uncertainty; it does not establish an isolated
causal effect for SEE, pruning or QAT. The completed combined version was
selected as the release baseline.

### MAIN per-opponent results

Results are from zigqueen's perspective, including recorded forfeits.
The Stockfish leg actually used 17.1; the separately installed Stockfish 19
was not substituted into this frozen comparison roster.

| Opponent | Anchor | W–D–L | Points / 60 | Implied rating |
|---|---:|---:|---:|---:|
| Stockfish-17.1 | 3773 | 0–32–28 | 16 | 3597.3 |
| Reckless-0.9.0 | 3767 | 2–31–27 | 17.5 | 3612.9 |
| Viridithas-20.0.0 | 3751 | 2–31–27 | 17.5 | 3596.9 |
| Stormphrax-8.0.0 | 3747 | 2–32–26 | 18 | 3599.8 |
| Hobbes-2.1 | 3726 | 4–30–26 | 19 | 3592.4 |
| Renegade-1.3.0 | 3698 | 9–32–19 | 25 | 3639.5 |
| Starzix-6.0 | 3692 | 13–29–18 | 27.5 | 3663.0 |
| Heimdall-1.4.3 | 3662 | 16–31–13 | 31.5 | 3679.4 |
| Velvet-8.1.1 | 3650 | 15–37–8 | 33.5 | 3690.7 |
| Minke-6.0.0 | 3595 | 25–30–5 | 40 | 3715.4 |
| Eleanor-4.1 | 3587 | 28–26–6 | 41 | 3720.6 |
| Turbulence-0.0.8 | 3580 | 23–33–4 | 39.5 | 3693.9 |
| akimbo-1.0.0 | 3569 | 22–32–6 | 38 | 3663.9 |
| Serendipity-1.0 | 3550 | 32–26–2 | 45 | 3740.8 |
| Patricia-5.0 | 3540 | 27–29–4 | 41.5 | 3680.4 |
| Yukari-2025.11.1 | 3537 | 28–32–0 | 44 | 3712.7 |
| Willow-4.0 | 3533 | 30–24–6 | 42 | 3680.2 |
| Lunar-0.4.0 | 3516 | 34–22–4 | 45 | 3706.8 |
| Lambergar-1.5 | 3509 | 32–25–3 | 44.5 | 3692.2 |
| Schoenemann-0.5.0 | 3506 | 28–32–0 | 44 | 3681.7 |
| Oxide-2.0.0 | 3493 | 31–27–2 | 44.5 | 3676.2 |
| Leorik-3.2.1 | 3491 | 28–30–2 | 43 | 3652.2 |
| Tucano-12.00 | 3489 | 31–26–3 | 44 | 3664.7 |
| Celeris-2.0 | 3482 | 38–21–1 | 48.5 | 3732.0 |
| Arcanum-2.8 | 3465 | 38–21–1 | 48.5 | 3715.0 |
| Prelude-2.1 | 3465 | 33–27–0 | 46.5 | 3679.8 |
| Saturn-1.3 | 3453 | 38–22–0 | 49 | 3712.5 |

## Local candidate evidence and acceptance

The release contains the selected SEE changes, local pruning retune and
head-only QAT continuation on the previous RC. Correctness gates and
short paired screens preceded longer head-to-head tests and these external
runs. QAT's separate 2000-game test was +9.21 ±8.19 Elo with SPRT unresolved;
that is a promising estimate, not an H1 result. The longer pruning test
also remained unresolved when the author accepted its neutral-to-positive
evidence. The combined SEE/pruning/QAT version was explicitly selected
following the completed external validation. No independent gains are
summed, and no claim is made that every component passed H1 at two controls.

## Historical context

| Version / venue | Self-assessment | Measurement |
|---|---:|---|
| 6.2.0 MAIN | 3672 | Roster-likelihood estimate, 1620 games |
| 6.2.0 oldrig | 3665 | Separate AVX2 venue, 1620 games |
| Previous RC, MAIN series | 3664 | Same dashboard estimator; observed comparison only |
| 6.1.0 / 6.1.1 | ~3644 | Historical mean-implied estimate, Hash 256 |
| 6.0.0 | ~3602 | Historical mean-implied estimate, Hash 64 |
| 5.8.3 | ~3590 | Historical mean-implied estimate, Hash 64 |

The historical official CCRL Blitz entry for 5.8.3 was 3569 ±16;
this is not the baseline for current development. Earlier methods, exact
results and the official historical link are retained in
[STRENGTH_6.1.1.md](STRENGTH_6.1.1.md).
