# zigqueen clean-room rules

This document records the rules zigqueen was developed under, published for
provenance transparency: originality questions matter in the chess-engine
community, and this is our answer in advance. The same rules apply to
contributions.

## Purpose

Every line of `zigqueen`'s engine code was written for this project. The
ideas it builds on — search techniques, NNUE architectures, feature sets,
training recipes — come from the public literature and from open-source
engines, and are credited in `docs/PROVENANCE.md`. That page also records
the two documented departures from the rules below (the search-shaping
parameter set initialised from Stormphrax's published defaults, and six
opening-book moves chosen from Stockfish analysis).

The goal is to avoid carrying forward:
- migration-shaped structure
- hidden path dependence
- architecture debt from earlier engines

## Forbidden implementation sources

Do **not** copy engine code from earlier private engines by the author or
from any other engine's source.

This includes:
- source files
- partial functions
- module layouts copied mechanically
- direct translation of search/eval code
- direct reuse of constants without fresh justification

Documented departure: in July 2026 the search's reduction and pruning
parameter set (`src/search/basin.zig`) was initialised from Stormphrax
8.0.0's published default constants under one locally chosen unit factor.
The Zig implementation is zigqueen's; the numbers are disclosed as taken in
`docs/PROVENANCE.md`, and their replacement by values derived from
zigqueen's own measurements is in progress.

The vendored exceptions are `deps/fathom` (the Syzygy tablebase prober, MIT)
and the Android OEX provider library under `android/oex` (Apache-2.0); both
are used as external libraries under their own licenses, not as engine
code (`THIRD_PARTY_LICENSES.md`).

## Allowed references

The following are allowed as **non-implementation** references:
- benchmark methodology
- fastchess commands
- perft position lists
- opening books / PGNs
- artifact formats
- external engine results
- general chess-engine literature (including published papers and
  publicly documented algorithms)
- independent architecture planning written for `zigqueen`

Studying published ideas (null-move verification, LMR shapes, NNUE
architectures, training recipes) is allowed; transcribing another engine's
implementation of them is not.

## Engineering rules

1. Prefer fresh design over parity chasing.
2. Treat other engines as benchmark opponents, not behavior oracles (the
   two departures on record are disclosed in `docs/PROVENANCE.md`).
3. Every subsystem should have explicit ownership.
4. No global mutable search state.
5. Diagnostics should be designed in, not bolted on.
6. Correctness gates come before Elo work.

## Rewrite scope

The clean-room scope covers all engine code:
- board representation
- move encoding
- move generation
- make/unmake
- zobrist
- transposition table
- search
- evaluation
- time management
- UCI

## First success criterion

Before any Elo ambition, `zigqueen` must be:
- architecturally clean
- perft-correct
- UCI compliant
- stable under repeated fixed-depth search
