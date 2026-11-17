# Strength

## Method

Our gauntlet: zigqueen at one thread plays a field of engines from the CCRL
Blitz single-CPU list, every opening with both colours. The rating is the
value at which the expected score against the opponents' CCRL ratings, held
fixed, equals the actual score; the 95% interval comes from the
reversed-opening pairs and ignores the uncertainty of those ratings. These are
our own estimates, not CCRL ratings.

Since 6.3.0 the clock is CCRL's 120s+1s scaled to our machine with a
Stockfish 10 benchmark: 86.349s+0.720s on a Ryzen 9 5950X with 16 games at a
time, Hash 256 MB and 3–6 piece Syzygy tables for every engine that supports
them. Opponent forfeits count as their losses. The field changes between
versions, so ratings from different fields cannot be subtracted.

## 6.6.0

**3738 (95%: 3734–3742)** from 3,256 games against 22 engines centred on 3700,
against 3717 for 6.5.0 on the same openings: **+21 (95%: +15 to +26)**. Score:
433 wins, 2,737 draws, 86 losses = 1801.5/3256 (55.3%), including ten opponent
time forfeits (Minke seven, Hobbes three). No zigqueen forfeits. Build
`e92e0170d` (our private history), the PGO build of the AVX2 binary, built-in
network, November 17–18, 2026.

- Field, anchors, clock and machine are those of the 6.5.0 run: CCRL Blitz
  single-CPU list of 2026-10-03, 22 engines from 3614 to 3774 (mean 3700.4),
  exact listed versions.
- Openings: the same 74 eight-move openings per opponent as in the 6.5.0 run,
  in the same order, each played with both colours (148 games per opponent).
  The difference to 6.5.0 and its interval are taken game for game over the
  1,628 opening pairs both runs played.

The implied rating is the rating at which the expected score against that one
opponent equals the actual score.

| Opponent | Anchor | W–D–L | Points / 148 | Implied rating | 6.5.0 points / 148 |
|---|---:|---:|---:|---:|---:|
| PlentyChess 8.0.0 | 3774 | 0–133–15 | 66.5 | 3739 | 68 |
| Reckless 0.9.0 | 3766 | 2–136–10 | 70 | 3747 | 64 |
| Integral 8 | 3753 | 6–128–14 | 70 | 3734 | 64 |
| Stormphrax 8.0.0 | 3745 | 1–140–7 | 71 | 3731 | 66.5 |
| Triumviratus 6.0 | 3744 | 2–143–3 | 73.5 | 3742 | 70 |
| Berserk 14 | 3738 | 5–136–7 | 73 | 3733 | 65.5 |
| Hobbes 2.1 | 3723 | 12–133–3 | 78.5 | 3744 | 72 |
| Horsie 1.1.0 | 3709 | 13–131–4 | 78.5 | 3730 | 74 |
| Raphael 4.1.1 | 3708 | 14–129–5 | 78.5 | 3729 | 76 |
| Devre 7.0 | 3705 | 13–132–3 | 79 | 3729 | 70 |
| Minke 7.0.0 | 3701 | 20–125–3 | 82.5 | 3741 | 78 |
| Igel 3.7.0 | 3694 | 17–130–1 | 82 | 3732 | 80 |
| Lizard 11.2 | 3694 | 19–129–0 | 83.5 | 3739 | 83.5 |
| Renegade 1.3.0 | 3693 | 23–120–5 | 83 | 3735 | 75 |
| RubiChess 20240817 | 3692 | 23–123–2 | 84.5 | 3742 | 77.5 |
| Starzix 6.0 | 3690 | 23–124–1 | 85 | 3742 | 79.5 |
| Uralochka 3.42a | 3689 | 17–130–1 | 82 | 3727 | 78.5 |
| Tcheran 13.0 | 3683 | 18–129–1 | 82.5 | 3723 | 83 |
| Clover 6.1 | 3639 | 37–111–0 | 92.5 | 3728 | 85 |
| Clarity 8.0.0 | 3632 | 60–88–0 | 104 | 3781 | 100 |
| Arasan 25.1 | 3622 | 51–97–0 | 99.5 | 3747 | 99 |
| Caissa 1.13.1 | 3614 | 57–90–1 | 102 | 3752 | 96.5 |

## Earlier versions

| Version | Date | Field | Games | Rating | Details |
|---|---|---|---:|---|---|
| 6.5.0 | 2026-10-21 | 22 engines around 3700, CCRL Blitz of 2026-10-03; the field and openings of 6.6.0 | 3,256 | 3717 (95%: 3713–3721) | [6.5.0 STRENGTH.md](https://github.com/stierms/zigqueen/blob/v6.5.0/docs/STRENGTH.md) |
| 6.4.0 | 2026-10-09 | 22 engines around 3667, CCRL Blitz of 2026-09-21 | 1,628 | 3701 (95%: 3694–3707) | [6.4.0 STRENGTH.md](https://github.com/stierms/zigqueen/blob/v6.4.0/docs/STRENGTH.md) |
| 6.3.0 | 2026-09-25 | the same field | 1,628 | 3676 (95%: 3670–3683) | [6.3.0 STRENGTH.md](https://github.com/stierms/zigqueen/blob/v6.3.0/docs/STRENGTH.md) |
| 6.2.0 | 2026-09-09 | 27-engine roster, CCRL Blitz of 2026-07-19, 180s+1s | 1,620 | 3672 (1σ: 3661–3683) | [6.2.0 STRENGTH.md](https://github.com/stierms/zigqueen/blob/v6.2.0/docs/STRENGTH.md) |
| 6.1.0, 6.1.1 | 2026-08-31 | 27-engine roster | 1,620 | ~3644 | [STRENGTH_6.1.1.md](STRENGTH_6.1.1.md) |
| 6.0.0 | 2026-08-19 | 27-engine roster | 1,620 | ~3602 | [STRENGTH_6.1.1.md](STRENGTH_6.1.1.md) |
| 5.8.3 | 2026-07-26 | 27-engine roster | 1,620 | ~3590 | [STRENGTH_6.1.1.md](STRENGTH_6.1.1.md) |

The 6.2.0 rating is a one-standard-error fit on a different roster and
clock; the rows below it are means of per-opponent implied ratings. Neither
can be subtracted from the rows above. The linked documents hold the
per-opponent results, the eight-thread runs of 6.4.0 and the 6.3 release
candidate, and, where published, each release's self-play evidence.

## External lists

As of 2026-11-11 (CCRL lists of 2026-11-07):

| Version | [CCRL Blitz](https://computerchess.org.uk/ccrl/404/) | [CCRL 40/15](https://computerchess.org.uk/ccrl/4040/) |
|---|---|---|
| 6.5.0 | 3709 ±15 (1,088 games), rank 33 in the complete list | — |
| 6.4.0 | — | 3566 ±19 (486 games), rank 56 in the complete list |
| 6.2.0 | 3648 ±15 (1,112 games) | — |
| 6.0.0 | — | 3497 ±18 (582 games) |
| 5.8.3 | 3559 ±14 (1,327 games) | — |

The [Computer Chess Index](https://github.com/computer-chess-index/cci/blob/main/engines/Zigqueen.md)
rates at three time controls (STC 8s+0.08s, LTC 60s+0.6s, VLTC 2m24s+1.12s)
on three machines: E1 and P1 are the efficiency and performance cores of an
Intel Core Ultra 7 265T, T1 is an Intel Core i5-7500T. Its lists per machine
are not comparable with each other, and its scale is not comparable with
CCRL's.

| Version | E1: STC / LTC / VLTC | P1: STC / LTC / VLTC | T1: STC / LTC / VLTC |
|---|---|---|---|
| 6.5.0 | 3406 / 3645 / 3707 | 3573 / 3761 / 3781 | — |
| 6.4.0 | 3337 / 3595 / 3684 | 3505 / 3669 / 3730 | — |
| 6.3.0 | — | — | 3258 / 3487 / 3525 |
| 6.1.1 | 3117 / 3501 / 3542 | 3312 / 3588 / 3653 | 3173 / 3432 / 3478 |
| 6.1.0 | — | — | 3200 / 3351 / 3491 |
| 6.0.0 | — | — | 3125 / 3363 / 3403 |
| 5.8.3 | — | — | 3009 / 3326 / 3386 |

For 6.5.0 on E1 the index gives ±38 at STC and LTC and ±37 at VLTC, from 162
to 172 games per time control.
