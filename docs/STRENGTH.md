# Strength

## Official CCRL rating for 5.8.3

The latest official listing at release preparation time remains
**zigqueen 5.8.3: CCRL Blitz (2'+1") 3569 ±16, rank #76-77**, from 951 games,
first listed 2026-08-01
([engine details](https://computerchess.org.uk/ccrl/404/cgi/engine_details.cgi?print=Details&eng=ZigQueen%205.8.3%2064-bit)).

The July anchored self-assessments were ~3588 for 5.8.0 and ~3590 for 5.8.3.
The official 5.8.3 result landed about 21 Elo below its self-assessment, which
is useful calibration context but does not turn the 6.0.0 estimate into an
official rating.


## zigqueen 6.0.0 anchored self-assessment

**zigqueen 6.0.0: ~3602 on the project's anchored gauntlet scale** — a 1,620-game run
against 27 CCRL-listed opponents. The per-opponent implied ratings have a
63-Elo standard-deviation spread; that spread is not a confidence interval.

The run scored **478 wins, 737 draws, and 405 losses: 846.5/1,620, or
52.3% overall**.

Relative to the published historical self-assessments, the estimate is +14
Elo over 5.8.0 (~3588) and +12 over the listed 5.8.3 run (~3590). These are
not strict same-condition deltas: the 6.0.0 run used the `UHO_4060_v4`
opening book and Hash 256 MB, while the July 5.8.0 run used the 96-line suite
and Hash 64 MB. Treat the comparison as an anchored release indicator, not a
controlled head-to-head result.

### Methodology

- **Date:** 2026-08-18 to 2026-08-19
- **Time control:** 180s + 1s increment
- **Games:** 1,620; 60 against each of 27 opponents
- **Openings:** `UHO_4060_v4`
- **Hash:** 256 MB
- **Anchors:** the opponents' listed CCRL Blitz ratings
- **Estimate:** each match score is converted to an implied rating against
  its opponent's anchor, then the 27 equally sized matches are combined

### Per-opponent results

Score is from zigqueen's perspective. The table is ordered by CCRL Blitz
anchor.

| Engine | Version | CCRL Blitz | W-D-L | Games | Score |
|---|---|---:|---:|---:|---:|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | 17.1 | 3773 | 0-24-36 | 60 | 20.0% |
| [Reckless](https://github.com/codedeliveryservice/Reckless) | 0.9.0 | 3767 | 0-25-35 | 60 | 20.8% |
| [Viridithas](https://github.com/cosmobobak/viridithas) | 20.0.0 | 3751 | 1-26-33 | 60 | 23.3% |
| [Stormphrax](https://github.com/Ciekce/Stormphrax) | 8.0.0 | 3747 | 1-27-32 | 60 | 24.2% |
| [Hobbes](https://github.com/kelseyde/hobbes-chess-engine) | 2.1 | 3726 | 3-23-34 | 60 | 24.2% |
| [Renegade](https://github.com/pkrisz99/Renegade) | 1.3.0 | 3698 | 4-29-27 | 60 | 30.8% |
| [Starzix](https://github.com/zzzzz151/Starzix) | 6.0 | 3692 | 5-28-27 | 60 | 31.7% |
| [Heimdall](https://github.com/nocturn9x/heimdall) | 1.4.3 | 3662 | 9-25-26 | 60 | 35.8% |
| [Velvet](https://github.com/mhonert/velvet-chess) | 8.1.1 | 3650 | 9-36-15 | 60 | 45.0% |
| [Minke](https://github.com/enfmarinho/Minke) | 6.0.0 | 3595 | 18-28-14 | 60 | 53.3% |
| [Eleanor](https://github.com/rektdie/Eleanor) | 4.1 | 3587 | 21-23-16 | 60 | 54.2% |
| [Turbulence](https://github.com/ksw0518/Turbulence_v4) | 0.0.8 | 3580 | 11-34-15 | 60 | 46.7% |
| [akimbo](https://github.com/jw1912/akimbo) | 1.0.0 | 3569 | 20-29-11 | 60 | 57.5% |
| [Serendipity](https://github.com/xu-shawn/Serendipity) | 1.0 | 3550 | 16-29-15 | 60 | 50.8% |
| [Patricia](https://github.com/Adam-Kulju/Patricia) | 5.0 | 3540 | 13-33-14 | 60 | 49.2% |
| [Yukari](https://github.com/yukarichess/yukari) | 2025.11.1 | 3537 | 21-33-6 | 60 | 62.5% |
| [Willow](https://github.com/Adam-Kulju/Willow) | 4.0 | 3533 | 42-18-0 | 60 | 85.0% |
| [Lunar](https://github.com/Synthetica9/lunar) | 0.4.0 | 3516 | 21-30-9 | 60 | 60.0% |
| [Lambergar](https://github.com/jabolcni/Lambergar) | 1.5 | 3509 | 31-23-6 | 60 | 70.8% |
| [Schoenemann](https://github.com/Jochengehtab/Schoenemann) | 0.5.0 | 3506 | 29-27-4 | 60 | 70.8% |
| [Oxide](https://github.com/Miguevrgo/Oxide) | 2.0.0 | 3493 | 24-32-4 | 60 | 66.7% |
| [Leorik](https://github.com/lithander/Leorik) | 3.2.1 | 3491 | 29-26-5 | 60 | 70.0% |
| [Tucano](https://github.com/alcides-schulz/Tucano) | 12.00 | 3489 | 28-26-6 | 60 | 68.3% |
| [Celeris](https://github.com/Hin-Yu-Evan-Fung/Celeris) | 2.0 | 3482 | 30-28-2 | 60 | 73.3% |
| [Prelude](https://github.com/Quinniboi10/Prelude) | 2.1 | 3465 | 27-26-7 | 60 | 66.7% |
| [Arcanum](https://github.com/LarsAur/Arcanum) | 2.8 | 3465 | 33-22-5 | 60 | 73.3% |
| [Saturn](https://github.com/egormoroz/saturn) | 1.3 | 3453 | 32-27-1 | 60 | 75.8% |

Heimdall's primary home is
[git.nocturn9x.space/heimdall-engine/heimdall](https://git.nocturn9x.space/heimdall-engine/heimdall);
the GitHub link above is the author's official mirror.

## Acknowledgments

Thanks to the authors of every engine in the roster. These were private test
matches, not endorsements or affiliations; the links above credit the work
that makes a meaningful external strength check possible.
