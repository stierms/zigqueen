# Strength

zigqueen's playing strength is self-assessed with a large anchored gauntlet
against CCRL-rated opposition. The current estimate for **zigqueen 5.8.0** is
**~3588 CCRL Blitz Elo** (treat as an estimate, ~±15).

## Methodology

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

**Result:** 255 wins, 1,125 draws, 240 losses — 50.46% overall.

## Per-opponent results

Score% is zigqueen's score from 60 games against each opponent, sorted by
the opponent's CCRL Blitz anchor.

| Engine | Version | CCRL Blitz | Games | Score% |
|---|---|---:|---:|---:|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | 17.1 | 3773 | 60 | 23.3% |
| [Reckless](https://github.com/codedeliveryservice/Reckless) | 0.9.0 | 3767 | 60 | 26.7% |
| [Viridithas](https://github.com/cosmobobak/viridithas) | 20.0.0 | 3751 | 60 | 32.5% |
| [Stormphrax](https://github.com/Ciekce/Stormphrax) | 8.0.0 | 3747 | 60 | 27.5% |
| [Hobbes](https://github.com/kelseyde/hobbes-chess-engine) | 2.1 | 3726 | 60 | 33.3% |
| [Renegade](https://github.com/pkrisz99/Renegade) | 1.3.0 | 3698 | 60 | 28.3% |
| [Starzix](https://github.com/zzzzz151/Starzix) | 6.0 | 3692 | 60 | 41.7% |
| [Heimdall](https://github.com/nocturn9x/heimdall) | 1.4.3 | 3662 | 60 | 45.0% |
| [Velvet](https://github.com/mhonert/velvet-chess) | 8.1.1 | 3650 | 60 | 48.3% |
| [Minke](https://github.com/enfmarinho/Minke) | 6.0.0 | 3595 | 60 | 46.7% |
| [Eleanor](https://github.com/rektdie/Eleanor) | 4.1 | 3587 | 60 | 49.2% |
| [Turbulence](https://github.com/ksw0518/Turbulence_v4) | 0.0.8 | 3580 | 60 | 53.3% |
| [akimbo](https://github.com/jw1912/akimbo) | 1.0.0 | 3569 | 60 | 54.2% |
| [Serendipity](https://github.com/xu-shawn/Serendipity) | 1.0 | 3550 | 60 | 56.7% |
| [Patricia](https://github.com/Adam-Kulju/Patricia) | 5.0 | 3540 | 60 | 60.8% |
| [Yukari](https://github.com/yukarichess/yukari) | 2025.11.1 | 3537 | 60 | 51.7% |
| [Willow](https://github.com/Adam-Kulju/Willow) | 4.0 | 3533 | 60 | 68.3% |
| [Lunar](https://github.com/Synthetica9/lunar) | 0.4.0 | 3516 | 60 | 59.2% |
| [Lambergar](https://github.com/jabolcni/Lambergar) | 1.5 | 3509 | 60 | 62.5% |
| [Schoenemann](https://github.com/Jochengehtab/Schoenemann) | 0.5.0 | 3506 | 60 | 60.8% |
| [Oxide](https://github.com/Miguevrgo/Oxide) | 2.0.0 | 3493 | 60 | 58.3% |
| [Leorik](https://github.com/lithander/Leorik) | 3.2.1 | 3491 | 60 | 65.8% |
| [Tucano](https://github.com/alcides-schulz/Tucano) | 12.00 | 3489 | 60 | 67.5% |
| [Celeris](https://github.com/Hin-Yu-Evan-Fung/Celeris) | 2.0 | 3482 | 60 | 65.0% |
| [Prelude](https://github.com/Quinniboi10/Prelude) | 2.1 | 3465 | 60 | 53.3% |
| [Arcanum](https://github.com/LarsAur/Arcanum) | 2.8 | 3465 | 60 | 65.0% |
| [Saturn](https://github.com/egormoroz/saturn) | 1.3 | 3453 | 60 | 57.5% |

Heimdall's primary home is
[git.nocturn9x.space/heimdall-engine/heimdall](https://git.nocturn9x.space/heimdall-engine/heimdall);
the link above is the author's official GitHub mirror.

## Acknowledgments

Thanks to the authors of all the engines listed above. These games were
private testing matches, not endorsed by or affiliated with the opposing
projects; the links credit their work — every one of these engines
represents a substantial engineering effort, and a strong, open field is
what makes meaningful self-assessment possible in the first place.
