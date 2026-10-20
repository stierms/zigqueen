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

## 6.5.0

**3717 (95%: 3713–3721)** from 3,256 games against 22 engines centred on
3700. Score: 345 wins, 2,721 draws, 190 losses = 1705.5/3256 (52.4%),
including seven opponent time forfeits (Minke five, Hobbes two). No zigqueen
forfeits. Build `617e40d5b` (our private history), the PGO build of the AVX2
binary, built-in network, October 20–21, 2026.

- Field: CCRL Blitz single-CPU list of 2026-10-03, 22 engines from 3614 to
  3774 (mean 3700.4), exact listed versions; nine of them were also in the
  6.4.0 field. Engines without a usable Linux release were built from their
  tagged source and checked against that version's bench signature.
- Openings: 74 eight-move openings per opponent from the same book, disjoint
  from every earlier run, each played with both colours (148 games per
  opponent).
- 6.4.0's 3701 was measured against a weaker field (mean 3667), so the two
  ratings are not directly comparable.

The implied rating is the rating at which the expected score against that
one opponent equals the actual score.

| Opponent | Anchor | W–D–L | Points / 148 | Implied rating |
|---|---:|---:|---:|---:|
| PlentyChess 8.0.0 | 3774 | 0–136–12 | 68 | 3746 |
| Reckless 0.9.0 | 3766 | 0–128–20 | 64 | 3719 |
| Integral 8 | 3753 | 3–122–23 | 64 | 3706 |
| Stormphrax 8.0.0 | 3745 | 2–129–17 | 66.5 | 3710 |
| Triumviratus 6.0 | 3744 | 1–138–9 | 70 | 3725 |
| Berserk 14 | 3738 | 1–129–18 | 65.5 | 3698 |
| Hobbes 2.1 | 3723 | 14–116–18 | 72 | 3714 |
| Horsie 1.1.0 | 3709 | 8–132–8 | 74 | 3709 |
| Raphael 4.1.1 | 3708 | 12–128–8 | 76 | 3717 |
| Devre 7.0 | 3705 | 5–130–13 | 70 | 3686 |
| Minke 7.0.0 | 3701 | 17–122–9 | 78 | 3720 |
| Igel 3.7.0 | 3694 | 15–130–3 | 80 | 3722 |
| Lizard 11.2 | 3694 | 22–123–3 | 83.5 | 3739 |
| Renegade 1.3.0 | 3693 | 10–130–8 | 75 | 3698 |
| RubiChess 20240817 | 3692 | 11–133–4 | 77.5 | 3708 |
| Starzix 6.0 | 3690 | 13–133–2 | 79.5 | 3716 |
| Uralochka 3.42a | 3689 | 18–121–9 | 78.5 | 3710 |
| Tcheran 13.0 | 3683 | 19–128–1 | 83 | 3725 |
| Clover 6.1 | 3639 | 26–118–4 | 85 | 3691 |
| Clarity 8.0.0 | 3632 | 53–94–1 | 100 | 3760 |
| Arasan 25.1 | 3622 | 50–98–0 | 99 | 3744 |
| Caissa 1.13.1 | 3614 | 45–103–0 | 96.5 | 3723 |

## Earlier versions

| Version | Date | Field | Games | Rating | Details |
|---|---|---|---:|---|---|
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

As of 2026-09-29:

| Version | [CCRL Blitz](https://computerchess.org.uk/ccrl/404/) | [CCRL 40/15](https://computerchess.org.uk/ccrl/4040/) | [CCI](https://github.com/computer-chess-index/cci/blob/main/engines/Zigqueen.md) VLTC |
|---|---|---|---|
| 6.3.0 | — | — | 3563 ±81 |
| 6.2.0 | 3649 ±18 (749 games) | — | — |
| 6.1.1 | — | — | 3475 ±45 |
| 6.1.0 | — | — | 3490 ±41 |
| 6.0.0 | — | 3498 ±18 (582 games) | 3402 ±45 |
| 5.8.3 | 3559 ±14 (1,327 games) | — | 3384 ±33 |

The Computer Chess Index uses its own scale, not comparable with CCRL's.
