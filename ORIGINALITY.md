# zigqueen originality rules

This document records the rules zigqueen was developed under, published for
provenance transparency: originality questions matter in the chess-engine
community, and this is our answer in advance. The same rules apply to
contributions.

## Purpose

Every line of `zigqueen`'s engine code was written for this project. Ideas
are taken from the public literature and from open-source engines and are
credited in `docs/PROVENANCE.md`; code is not. That page also lists the two
cases where 6.1.0 falls short of these rules and what is being done about
them.

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

These rules stand. One exception is on record, and it is being corrected,
not accepted: in 6.1.0 the reduction and pruning constants in
`src/search/basin.zig` are Stormphrax 8.0.0's published defaults rather
than values derived here. The code is ours; the numbers are not.
`docs/PROVENANCE.md` discloses this, and the constants are being replaced
by values derived from zigqueen's own measurements.

Two third-party libraries are vendored under their own licenses: Fathom
(Syzygy probing, MIT) and the Android OEX provider library (Apache-2.0).
See `THIRD_PARTY_LICENSES.md`.

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
2. Treat other engines as benchmark opponents, not behavior oracles.
3. Every subsystem should have explicit ownership.
4. No global mutable search state.
5. Diagnostics should be designed in, not bolted on.
6. Correctness gates come before Elo work.

## Rewrite scope

The rules cover all engine code:
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
