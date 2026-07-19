# zigqueen clean-room rules

## Purpose

`zigqueen` is a genuine clean-room engine: every line of engine code was
written fresh for this project.

The goal is to avoid carrying forward:
- migration-shaped structure
- hidden path dependence
- architecture debt from earlier engines

## Forbidden implementation sources

Do **not** copy engine code from the author's earlier engines (previous Zig
and Go engines that predate this project) or from any other engine's source.

This includes:
- source files
- partial functions
- module layouts copied mechanically
- direct translation of search/eval code
- direct reuse of constants without fresh justification

The one vendored exception is `deps/fathom` (the Syzygy tablebase prober),
which is used as an external library under its own license, not as engine
code.

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
