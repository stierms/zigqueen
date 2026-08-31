# Strength

## Official CCRL rating for 5.8.3

The latest official listing at release preparation time remains
**zigqueen 5.8.3: CCRL Blitz (2'+1") 3569 ±16, rank #76-77**, from 951 games,
first listed 2026-08-01
([engine details](https://computerchess.org.uk/ccrl/404/cgi/engine_details.cgi?print=Details&eng=ZigQueen%205.8.3%2064-bit)).

The July anchored self-assessments were ~3588 for 5.8.0 and ~3590 for 5.8.3.
The official 5.8.3 result landed about 21 Elo below its self-assessment,
useful calibration context for the estimates below.

## zigqueen 6.1.0 anchored self-assessment

**zigqueen 6.1.0: ~3644 on the project's anchored gauntlet scale** — a
1,620-game run against 27 CCRL-listed opponents. The per-opponent implied
ratings have a 56-Elo standard-deviation spread; that spread is not a
confidence interval. The estimate is slightly conservative in one known
direction: several opponents run newer, stronger builds than their
CCRL-listed version.

The run scored **583 wins, 702 draws, and 335 losses: 934/1,620, or 57.7 %
overall** (6.0.0, same instrument: 52.3 %).

### Methodology

- **Date:** 2026-08-30 to 2026-08-31
- **Time control:** 180s + 1s increment
- **Games:** 1,620; 60 against each of 27 opponents
- **Openings:** `UHO_4060_v4`, drawn per opponent (each opponent's match
  uses its own seeded random draw of 30 openings, each played with colours
  reversed). Earlier gauntlets (6.0.0 and before) used Hash 64 MB and one
  30-opening draw shared across all opponents; the 6.1.0 run uses Hash 256
  and the per-opponent draw, so its confidence behaves better and its
  figure starts a fresh measurement series — cross-version comparisons on
  this table are indicative, not controlled deltas.
- **Hash:** 256 MB; **tablebases:** Syzygy up to 6 men (zigqueen only)
- **Anchors:** the opponents' listed CCRL Blitz ratings
- **Estimate:** each match score is converted to an implied rating against
  its opponent's anchor, then the 27 equally sized matches are combined

### Per-opponent results

Score is from zigqueen's perspective. The table is ordered by CCRL Blitz
anchor.

| Engine | Version | CCRL Blitz | W-D-L | Score | Implied |
|---|---|---:|---:|---:|---:|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | 17.1 | 3773 | 0-27-33 | 22.5% | 3558 |
| [Reckless](https://github.com/codedeliveryservice/Reckless) | 0.9.0 | 3767 | 0-27-33 | 22.5% | 3552 |
| [Viridithas](https://github.com/cosmobobak/viridithas) | 20.0.0 | 3751 | 3-27-30 | 27.5% | 3583 |
| [Stormphrax](https://github.com/Ciekce/Stormphrax) | 8.0.0 | 3747 | 2-26-32 | 25.0% | 3556 |
| [Hobbes](https://github.com/kelseyde/hobbes-chess-engine) | 2.1 | 3726 | 6-22-32 | 28.3% | 3565 |
| [Renegade](https://github.com/pkrisz99/Renegade) | 1.3.0 | 3698 | 5-32-23 | 35.0% | 3590 |
| [Starzix](https://github.com/zzzzz151/Starzix) | 6.0 | 3692 | 10-31-19 | 42.5% | 3640 |
| [Heimdall](https://github.com/nocturn9x/heimdall) | 1.4.3 | 3662 | 16-28-16 | 50.0% | 3662 |
| [Velvet](https://github.com/mhonert/velvet-chess) | 8.1.1 | 3650 | 18-25-17 | 50.8% | 3656 |
| [Minke](https://github.com/enfmarinho/Minke) | 6.0.0 | 3595 | 21-26-13 | 56.7% | 3642 |
| [Eleanor](https://github.com/rektdie/Eleanor) | 4.1 | 3587 | 23-27-10 | 60.8% | 3664 |
| [Turbulence](https://github.com/ksw0518/Turbulence_v4) | 0.0.8 | 3580 | 21-29-10 | 59.2% | 3644 |
| [akimbo](https://github.com/jw1912/akimbo) | 1.0.0 | 3569 | 24-29-7 | 64.2% | 3670 |
| [Serendipity](https://github.com/xu-shawn/Serendipity) | 1.0 | 3550 | 19-36-5 | 61.7% | 3633 |
| [Patricia](https://github.com/Adam-Kulju/Patricia) | 5.0 | 3540 | 27-22-11 | 63.3% | 3635 |
| [Yukari](https://github.com/yukarichess/yukari) | 2025.11.1 | 3537 | 28-26-6 | 68.3% | 3671 |
| [Willow](https://github.com/Adam-Kulju/Willow) | 4.0 | 3533 | 41-17-2 | 82.5% | 3802 |
| [Lunar](https://github.com/Synthetica9/lunar) | 0.4.0 | 3516 | 28-27-5 | 69.2% | 3656 |
| [Lambergar](https://github.com/jabolcni/Lambergar) | 1.5 | 3509 | 28-26-6 | 68.3% | 3643 |
| [Schoenemann](https://github.com/Jochengehtab/Schoenemann) | 0.5.0 | 3506 | 34-22-4 | 75.0% | 3697 |
| [Oxide](https://github.com/Miguevrgo/Oxide) | 2.0.0 | 3493 | 34-22-4 | 75.0% | 3684 |
| [Leorik](https://github.com/lithander/Leorik) | 3.2.1 | 3491 | 29-27-4 | 70.8% | 3645 |
| [Tucano](https://github.com/alcides-schulz/Tucano) | 12.00 | 3489 | 29-27-4 | 70.8% | 3643 |
| [Celeris](https://github.com/Hin-Yu-Evan-Fung/Celeris) | 2.0 | 3482 | 32-27-1 | 75.8% | 3681 |
| [Arcanum](https://github.com/LarsAur/Arcanum) | 2.8 | 3465 | 41-18-1 | 83.3% | 3745 |
| [Prelude](https://github.com/Quinniboi10/Prelude) | 2.1 | 3465 | 28-26-6 | 68.3% | 3599 |
| [Saturn](https://github.com/egormoroz/saturn) | 1.3 | 3453 | 36-23-1 | 79.2% | 3685 |

Heimdall's primary home is
[git.nocturn9x.space/heimdall-engine/heimdall](https://git.nocturn9x.space/heimdall-engine/heimdall);
the GitHub link above is the author's official mirror.

## Historical self-assessments

| Version | Estimate | Run |
|---|---|---|
| 6.1.0 | ~3644 | 1,620 games, Hash 256, per-opponent openings, 2026-08-30/31 |
| 6.0.0 | ~3602 | 1,620 games, Hash 64, shared openings, 2026-08-18/19 |
| 5.8.3 | ~3590 | 1,620 games, Hash 64, shared openings, 2026-07-26 |
| 5.8.0 | ~3588 | 1,620 games, Hash 64, shared openings, 2026-07-19 |
