# Strength

The 6.3.0 and 6.2.0 gauntlets used different fields, clocks and machines, so
their numbers cannot be subtracted from each other.

Development builds are named by their commit in our private history:

| Name | Build | Contents |
|---|---|---|
| 6.2.0 | `v6.2.0` | previous release |
| pre-multicore | `0190c8c9b` | 6.2.0 + AVX2 pair layout + threat-split quiet history; 6.2.0 network; single-threaded |
| 6.3 RC | `48d6a0dcf` | pre-multicore + new network + multithreading + UCI and Fathom fixes; played the 2026-09-22 gauntlets |
| 6.3 base | `e57c20976` | 6.3 RC + root tablebase fix |
| 6.3.0 | tested as `2d7193418` (engine source of `4844f5509`) | 6.3 base + speed pass + cut-node labels |

## 6.3.0 at one thread: CCRL-calibrated gauntlet

**3676 (95%: 3670–3683)** from 1,628 games against 22 engines anchored on
their CCRL Blitz ratings. This is our own performance estimate, not a CCRL
rating. The interval comes from the 814 reversed-opening pairs and holds the
opponents' anchors fixed.

Score: **152 wins, 1,370 draws, 106 losses = 837/1628 (51.4%)**. No
forfeits by either side.

### Method

- September 25, 2026. Build 6.3.0 as tested: `2d7193418` (engine source of
  `4844f5509`), AVX2 (x86-64-v3) binary, network `a6373209…`.
- Field: the 22 engines closest to 3666 on the CCRL Blitz (2'+1") single-CPU
  list, best version per engine, computed 2026-09-21; all rated 3626–3710,
  mean anchor 3666.5. Exact listed versions only. Where upstream published no
  usable Linux binary, the tagged source was built for x86-64-v3; such local
  builds can run at a different speed from CCRL's.
- Openings: 37 eight-move openings per opponent, each played with both
  colours, 74 games per opponent. They are the same openings, order and
  colours as the 6.3 RC run below.
- Clock: CCRL's 120s+1s reference scaled by the time a Stockfish 10 `bench`
  takes on this machine with 16 copies running, against CCRL's 2,054 ms
  reference. Measured just before the run: **86.349s+0.720s**. This follows
  CCRL's method; it does not reproduce CCRL's hardware.
- Ryzen 9 5950X (Zen 3), native Linux, 16 games at a time on 16 physical
  cores. One thread per engine, Hash 256 MB, pondering off, engine books off.
- zigqueen and the 14 opponents that support Syzygy used the same 3–6 piece
  tables; the other 8 played without. zigqueen used Move Overhead 20 and
  NNUE Scale Percent 48.
- Booot 7.4 (CCRL 3652) was replaced by Revenge 4.0 (CCRL 3649) in the same
  slot with the same openings. During the runs Booot dropped one of its two
  threads and then lost on time or disconnected, on this machine and on the
  Ryzen 9 9950X3D in the 6.3 RC run; zigqueen and the other 21 engines ran
  clean. Outside the match harness, Booot played 72 games against itself
  without a fault. Its 32 games here are kept but not counted.
- The rating is the value at which the expected score against the fixed
  anchors equals the actual score. 6.2.0's gauntlet used a different fit and
  a 1σ bracket.

### Against the 6.3 RC on the same field

The 6.3 RC (`48d6a0dcf`) played this field on 2026-09-22. On the 21
opponents both runs share, with the same openings and colours:

| Run | Machine and build | Clock | Games at a time | Score | Rating (95%) |
|---|---|---|---:|---:|---:|
| 6.3.0 | Ryzen 9 5950X, AVX2, native Linux | 86.349+0.720 | 16 | 800/1554 (51.48%) | 3678 (3671–3684) |
| 6.3 RC | Ryzen 9 9950X3D, AVX-512, Linux under WSL2 | 95.609+0.797 | 24 | 794/1554 (51.09%) | 3675 (3668–3682) |

Differenced opening by opening: +0.39 percentage points (95%: −0.88 to
+1.65), about **+2.7 Elo (95%: −6.1 to +11.5)**. No measurable difference.
Each machine's clock was calibrated separately; CPU, build, concurrency and
fastchess build differ as well. The RC's Minke result includes five Minke
time forfeits scored as RC wins. Over its full field, with Booot, the RC
scored 840/1628 (51.6%), 3678 (3671–3684) on the same estimator.

### Per-opponent results

From zigqueen's perspective. Implied rating is the single-opponent
performance; with 74 games per opponent it is noisy.

| Opponent | Anchor | W–D–L | Points / 74 | Implied rating | 6.3 RC points / 74 |
|---|---:|---:|---:|---:|---:|
| Horsie 1.1.0 | 3710 | 2–64–8 | 34 | 3682 | 32.5 |
| Minke 7.0.0 | 3703 | 5–60–9 | 35 | 3684 | 35.5 |
| Igel 3.7.0 | 3694 | 1–67–6 | 34.5 | 3670 | 34 |
| Lizard 11.2 | 3694 | 4–63–7 | 35.5 | 3680 | 36 |
| Renegade 1.3.0 | 3693 | 3–62–9 | 34 | 3665 | 33 |
| RubiChess 20240817 | 3692 | 4–68–2 | 38 | 3701 | 37 |
| Starzix 6.0 | 3690 | 4–66–4 | 37 | 3690 | 34.5 |
| Uralochka 3.42a | 3689 | 3–66–5 | 36 | 3680 | 34.5 |
| Tcheran 13.0 | 3683 | 3–63–8 | 34.5 | 3659 | 40 |
| Icarus 1.0 | 3672 | 8–60–6 | 38 | 3681 | 38.5 |
| Zangdar 7 | 3670 | 7–59–8 | 36.5 | 3665 | 40 |
| Arasan 26.0 | 3658 | 9–63–2 | 40.5 | 3691 | 37.5 |
| Titan 1.1.0 | 3655 | 4–66–4 | 37 | 3655 | 38 |
| Cataphract 1.5.1 | 3651 | 5–63–6 | 36.5 | 3646 | 37 |
| Revenge 4.0 | 3649 | 6–62–6 | 37 | 3649 | — |
| Velvet 8.1.1 | 3647 | 5–66–3 | 38 | 3656 | 41 |
| Prune 4.0.1 | 3644 | 9–62–3 | 40 | 3672 | 38.5 |
| Clarity 7.2.0 | 3642 | 17–56–1 | 45 | 3718 | 41.5 |
| Seer 2.8.0 | 3640 | 4–68–2 | 38 | 3649 | 40.5 |
| Koivisto 9.0 | 3632 | 15–56–3 | 43 | 3689 | 41.5 |
| rofChade 3.1 | 3628 | 15–57–2 | 43.5 | 3690 | 41 |
| Bread 4.0.0 | 3626 | 19–53–2 | 45.5 | 3707 | 42 |

The RC played Booot 7.4 instead of Revenge: 46/74, including nine Booot
faults scored as RC wins.

## 6.3 RC at eight threads

**3697 (95%: 3685–3709)** from 440 games against 22 engines at 8 threads
each, anchored on the CCRL Blitz 8-CPU list computed 2026-09-21 (anchors
3644–3768, mean 3704.3). Build `48d6a0dcf`: before the root tablebase fix,
the cut-node change and the speed pass.

Score: **25 wins, 381 draws, 34 losses = 215.5/440 (48.98%)**. Three
opponent faults count as their losses: an illegal move by Stormphrax 7.0.0
and two time losses by Quanticade Orion 2.0. Without those games the score is
212.5/437 (48.63%). No zigqueen forfeits.

- September 22–23, 2026; 20 games per opponent (10 openings, both colours).
- Ryzen 9 5950X, 2 games at a time with 8 threads per engine, Hash 256 MB,
  Syzygy 3–6 pieces for engines that support it. Clock 85.531s+0.713s from
  the same Stockfish 10 calibration at 16 active cores.
- Titan was left out: its published binary crashed on this CPU and its
  tagged-source build failed an assertion at 8 threads.
- Twenty games per opponent support the aggregate, not claims about single
  matchups. The 8-thread and 1-thread fields differ, so their ratings are
  not a measure of what the extra threads are worth.

| Opponent | Anchor | W–D–L | Points / 20 |
|---|---:|---:|---:|
| PlentyChess 6.0.2 | 3768 | 0–16–4 | 8 |
| Integral 7.0.0 | 3746 | 0–19–1 | 9.5 |
| Stormphrax 7.0.0 | 3742 | 1–16–3 | 9 |
| Horsie 1.1.0 | 3735 | 0–16–4 | 8 |
| Viridithas 17.0.0 | 3734 | 0–18–2 | 9 |
| Lizard 11.2 | 3732 | 1–17–2 | 9.5 |
| RubiChess 20240817 | 3728 | 1–17–2 | 9.5 |
| Starzix 6.0 | 3728 | 0–18–2 | 9 |
| Quanticade Orion 2.0 | 3715 | 2–18–0 | 11 |
| Velvet 8.1.0 | 3702 | 1–16–3 | 9 |
| Igel 3.6.0 | 3699 | 1–19–0 | 10.5 |
| Uralochka 3.41a | 3697 | 2–15–3 | 9.5 |
| Seer 2.8.0 | 3696 | 1–18–1 | 10 |
| Renegade 1.2.0 | 3688 | 2–18–0 | 11 |
| rofChade 3.1 | 3687 | 1–17–2 | 9.5 |
| Arasan 25.1 | 3686 | 0–18–2 | 9 |
| Clarity 7.2.0 | 3685 | 4–16–0 | 12 |
| Koivisto 9.0 | 3682 | 1–19–0 | 10.5 |
| Astra 5.1.1 | 3670 | 0–20–0 | 10 |
| Peacekeeper 3.01 | 3670 | 2–17–1 | 10.5 |
| Minic 3.40 | 3660 | 2–16–2 | 10 |
| SlowChess Blitz 2.83 | 3644 | 3–17–0 | 11.5 |

## How 6.3.0 was accepted

Each step was accepted on its own evidence against the build before it.
Don't add these numbers together.

| Change | Comparator | Test | Result |
|---|---|---|---|
| AVX2 pair layout | 6.2.0 | exact output, one-search speed on a Zen 3 CPU | +3.1% nodes/s; adopted by the author as a pure speedup |
| Threat-split quiet history | 6.2.0 + pair layout | SPRT [0, +10] at 8s+0.08s, then 60s+0.6s | H1 at 1,038 and at 2,890 games; LTC +8.7 ± 6.3 Elo |
| New network (BT4) | same engine, 6.2.0 net | SPRT [0, +10] at 8s+0.08s, then 60s+0.6s | H1 at 2,554 games (+10.8 ± 7.5) and at 3,368 games (+7.9 ± 6.0) |
| Multithreading, `Threads=1` | pre-multicore `0190c8c9b` | 60s+0.6s, tablebases on | +0.5 Elo (95%: −3.5 to +4.5), 6,614 games; stopped by the author, no verdict; judged no change |
| Multithreading, more threads | 4 vs 1, 8 vs 4 threads | 256 games each, 20s+0.2s, no tablebases | +96 (+75 to +118), +27 (+7 to +48) |
| Root tablebase fix | 6.3 RC | correctness review, tablebase regression positions | accepted as a correctness fix; no Elo claim |
| Speed pass (before the AVX-512 NNUE step) | pre-multicore; 6.3 base | exact output, native Windows timing | 1.9–3.3% less time than pre-multicore on all four cells; 2.2–3.1% less than the 6.3 base (tablebases off) |
| Speed pass with the AVX-512 NNUE step (no cut-node change) | pre-multicore | exact output, native Windows timing on a Zen 4 CPU | 3.6–5.4% less time with AVX2 and 7.7–8.2% with AVX-512 on all four cells; see [RELEASE_VALIDATION_6.3.0.md](RELEASE_VALIDATION_6.3.0.md) |
| Cut-node labels | 6.3 base | SPRT [0, +10] at 8s+0.08s | +5.8 normalized Elo (−0.6 to +12.2), 11,362 games; stopped by the author, accepted because the same games pass a non-regression test |
| Speed pass and cut-node labels together | 6.3 base `e57c20976` | SPRT [0, +10] at three clocks | H1 at 8s+0.08s (+8.4 ± 6.3), 20s+0.2s (+17.1 ± 9.7), 60s+0.6s (+11.3 ± 7.4) |

Self-play used UHO openings with both colours and one thread per engine
unless stated. It ran on the Ryzen 9 5950X with 16 games at a time, except
the threat-split history test and the `Threads=1` check (Ryzen 9 9950X3D, 24
at a time) and the thread-scaling tests (3 and 2 at a time). Self-play
overstates real gains. The external gauntlet above sees no measurable
difference between 6.3.0 and the 6.3 RC.

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

## How the 6.2.0 candidate was accepted

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
| 6.3.0 | 3676 | 2026-09-21 CCRL-calibrated field, 1,628 games, AVX2, 1 thread |
| 6.3 RC | 3678 | same field and estimator, AVX-512 machine, comparison only |
| 6.3 RC, 8 threads | 3697 | 8-CPU field, 440 games |
| 6.2.0 | 3672 | roster-likelihood fit, 1,620 games, AVX-512 |
| 6.2.0 (AVX2 machine) | 3665 | same gauntlet, separate run |
| 6.2.0 first RC | 3664 | same estimator, comparison only |
| 6.1.0 / 6.1.1 | ~3644 | mean of implied ratings, Hash 256 |
| 6.0.0 | ~3602 | mean of implied ratings, Hash 64 |
| 5.8.3 | ~3590 | mean of implied ratings, Hash 64 |

The first three rows use the 2026-09-21 fields and the performance
estimator described above; the rows below them use the older roster and
their own estimators. Do not subtract across that line.

Official numbers as of 2026-09-25: CCRL Blitz lists 5.8.3 at 3559 ±14
(1,295 games), about 31 below its self-assessment; CCRL 40/15 lists 6.0.0
at 3498 ±18 (572 games). Useful calibration, not the development baseline.
The Computer Chess Index's own-scale ratings are in the README table.
Earlier runs and exact results are in [STRENGTH_6.1.1.md](STRENGTH_6.1.1.md).
