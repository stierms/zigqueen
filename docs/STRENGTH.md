# Strength

## 6.2.0 anchored gauntlet

**3672 [3661, 3683]** on the project's anchored roster scale, from a
1,620-game gauntlet against 27 CCRL-listed engines. This is a self-assessment,
not an official CCRL rating. The bracket is the model's one-standard-error
interval and ignores uncertainty in the opponents' anchors.

Score: **609 wins, 770 draws, 241 losses = 994/1620 (61.4%)**. Two opponent
forfeits have unresolved causes; counted as losses the score is 992/1620
(61.2%). No zigqueen forfeits.

A second run of the same gauntlet with the AVX2 build on a different machine
(Ryzen 9 5950X) gave **3665 [3654, 3676]**, 979.5/1620 (60.5%), with three
unresolved opponent forfeits (976.5–979.5 range). The two runs differ in CPU,
opponent binary variants and background load and are reported separately,
not pooled.

### Method

- September 8–9, 2026; 27 opponents, 60 games each, 180s+1s.
- One thread per engine, Hash 256 MB, 24 concurrent games on a Ryzen 9
  9950X3D at normal process priority.
- Openings from `UHO_4060_v4`: each opponent gets its own seeded draw of 30
  positions, each played with both colours (seeds 6200–6226).
- zigqueen probes Syzygy 3–6 pieces; default NNUE scale 48.
- Anchors: CCRL Blitz ratings as of July 19, 2026. Installed opponent
  versions can differ from the versions behind those ratings; the anchors
  are a fixed yardstick, not a current ranking.
- The Lunar, Starzix, Heimdall and Velvet legs of the primary run were
  replayed after early machine contention and a Lunar terminal issue, with
  the same opening/colour pairs. The originals are archived; the other 23
  legs are untouched. The result is one gauntlet, not a sum of both.
- The headline fits one rating to all 1,620 outcomes. The arithmetic mean of
  the per-opponent implied ratings below is 3673.8, a different estimator;
  earlier releases reported that mean, so do not subtract across the two.

The first 6.2.0 release candidate (before the SEE work, retune and QAT
head) measured 3664 on the same estimator. The observed +8 is inside the
run uncertainty and does not isolate any one component.

### Per-opponent results

From zigqueen's perspective, forfeits included. The Stockfish leg used 17.1;
Stockfish 19 was installed later and not substituted into the frozen roster.

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

## How the candidate was accepted

The release is the previous RC plus the SEE speed work, the pruning retune
and the head-only QAT continuation. Each step passed the correctness gates
and a short paired screen before longer self-play. The SEE/retune core
reached H1 against the previous RC at 3s+0.1s (+14 ±9 Elo, 1,686 games).
QAT's 2,000-game test read +9 ±8 with the SPRT unresolved; the author
accepted it on that estimate. The combined build was then chosen as the
release after the gauntlet above. Component gains are not summed, and not
every component reached H1 at two time controls.

## History

| Version | Self-assessment | Note |
|---|---:|---|
| 6.2.0 | 3672 | roster-likelihood fit, 1,620 games, AVX-512 |
| 6.2.0 (AVX2 machine) | 3665 | same gauntlet, separate run |
| 6.2.0 first RC | 3664 | same estimator, comparison only |
| 6.1.0 / 6.1.1 | ~3644 | mean of implied ratings, Hash 256 |
| 6.0.0 | ~3602 | mean of implied ratings, Hash 64 |
| 5.8.3 | ~3590 | mean of implied ratings, Hash 64 |

The official CCRL Blitz entry for 5.8.3 is 3569 ±16, about 21 below its
self-assessment; useful calibration, not the development baseline. Earlier
runs, exact results and the CCRL link are in
[STRENGTH_6.1.1.md](STRENGTH_6.1.1.md).
