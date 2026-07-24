# Strength

zigqueen's playing strength is self-assessed with a large anchored gauntlet
against CCRL-rated opposition. The current estimate for **zigqueen 5.8.2** is
**~3594 CCRL Blitz Elo** (treat as an estimate, ~±15; the v5.8.0 read under
the same protocol was ~3588 — statistically the same engine, as expected for
a node-identical revision).

## Methodology (v5.8.2 run)

- **Date:** 2026-07-25
- **Hash:** 256 MB for all engines (CCRL-standard conditions)

## Methodology (v5.8.0 run)

- **Date:** 2026-07-19
- **Time control:** 180s + 1s increment (CCRL Blitz-comparable), 1,620 games
- **Opponents:** 27 CCRL-listed engines, 60 games each, at the exact
  versions listed on CCRL
- **Openings:** standardized opening suite, each opening played with both
  colors
- **Tablebases:** Syzygy 3-4-5 (WDL) for zigqueen
- **Anchors:** published CCRL Blitz ratings, fetched 2026-07-19
- **Estimate:** games-weighted anchored estimate — each opponent's result is
  converted to an implied rating against its CCRL anchor, then combined
  weighted by games played
- **Hardware:** single thread per engine on an AMD Ryzen 9 9950X3D

**Result (v5.8.2, 2026-07-25):** 272 wins, 1,113 draws, 235 losses — 51.14% overall.

## Per-opponent results (v5.8.2 run, 2026-07-25)

Score% is zigqueen's score from 60 games against each opponent, sorted by
the opponent's CCRL Blitz anchor.

| Engine | Version | CCRL Blitz | Games | Score% |
|---|---|---:|---:|---:|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | 17.1 | 3773 | 60 | 25.0% |
| [Reckless](https://github.com/codedeliveryservice/Reckless) | 0.9.0 | 3767 | 60 | 30.8% |
| [Viridithas](https://github.com/cosmobobak/viridithas) | 20.0.0 | 3751 | 60 | 26.7% |
| [Stormphrax](https://github.com/Ciekce/Stormphrax) | 8.0.0 | 3747 | 60 | 31.7% |
| [Hobbes](https://github.com/kelseyde/hobbes-chess-engine) | 2.1 | 3726 | 60 | 40.0% |
| [Renegade](https://github.com/pkrisz99/Renegade) | 1.3.0 | 3698 | 60 | 35.8% |
| [Starzix](https://github.com/zzzzz151/Starzix) | 6.0 | 3692 | 60 | 35.8% |
| [Heimdall](https://github.com/nocturn9x/heimdall) | 1.4.3 | 3662 | 60 | 42.5% |
| [Velvet](https://github.com/mhonert/velvet-chess) | 8.1.1 | 3650 | 60 | 44.2% |
| [Minke](https://github.com/enfmarinho/Minke) | 6.0.0 | 3595 | 60 | 50.0% |
| [Eleanor](https://github.com/rektdie/Eleanor) | 4.1 | 3587 | 60 | 43.3% |
| [Turbulence](https://github.com/ksw0518/Turbulence_v4) | 0.0.8 | 3580 | 60 | 42.5% |
| [akimbo](https://github.com/jw1912/akimbo) | 1.0.0 | 3569 | 60 | 56.7% |
| [Serendipity](https://github.com/xu-shawn/Serendipity) | 1.0 | 3550 | 60 | 54.2% |
| [Patricia](https://github.com/Adam-Kulju/Patricia) | 5.0 | 3540 | 60 | 59.2% |
| [Yukari](https://github.com/yukarichess/yukari) | 2025.11.1 | 3537 | 60 | 53.3% |
| [Willow](https://github.com/Adam-Kulju/Willow) | 4.0 | 3533 | 60 | 65.0% |
| [Lunar](https://github.com/Synthetica9/lunar) | 0.4.0 | 3516 | 60 | 60.8% |
| [Lambergar](https://github.com/jabolcni/Lambergar) | 1.5 | 3509 | 60 | 64.2% |
| [Schoenemann](https://github.com/Jochengehtab/Schoenemann) | 0.5.0 | 3506 | 60 | 60.8% |
| [Oxide](https://github.com/Miguevrgo/Oxide) | 2.0.0 | 3493 | 60 | 66.7% |
| [Leorik](https://github.com/lithander/Leorik) | 3.2.1 | 3491 | 60 | 60.8% |
| [Tucano](https://github.com/alcides-schulz/Tucano) | 12.00 | 3489 | 60 | 65.0% |
| [Celeris](https://github.com/Hin-Yu-Evan-Fung/Celeris) | 2.0 | 3482 | 60 | 62.5% |
| [Prelude](https://github.com/Quinniboi10/Prelude) | 2.1 | 3465 | 60 | 65.8% |
| [Arcanum](https://github.com/LarsAur/Arcanum) | 2.8 | 3465 | 60 | 70.8% |
| [Saturn](https://github.com/egormoroz/saturn) | 1.3 | 3453 | 60 | 66.7% |

Heimdall's primary home is
[git.nocturn9x.space/heimdall-engine/heimdall](https://git.nocturn9x.space/heimdall-engine/heimdall);
the link above is the author's official GitHub mirror.

## Acknowledgments

Thanks to the authors of all the engines listed above. These games were
private testing matches, not endorsed by or affiliated with the opposing
projects; the links credit their work — every one of these engines
represents a substantial engineering effort, and a strong, open field is
what makes meaningful self-assessment possible in the first place.
