# zigqueen architecture

zigqueen is a UCI chess engine written in Zig, built around a bitboard
position model, an NNUE evaluation with incrementally updated accumulators,
and a PVS/negamax search with a modern pruning and extension stack. Since
6.3.0 the search can run on up to 32 threads (Lazy SMP). This document maps
the source tree and records the design decisions that matter for correctness
and performance.

## Module map

```
src/
  main.zig        entry point: UCI loop plus diagnostic subcommands (bench, perft, ...)
  core/           board fundamentals: bitboards, squares, pieces, moves,
                  Position/StateInfo, FEN, zobrist hashing
  movegen/        attack tables (magics), pseudo-legal generation, legality
                  filtering, make/unmake, perft
  eval/           NNUE runtime (nnue768.zig), full-threat enumeration/deltas
                  (fullthreats.zig), pawn-pair block (pawnpairs.zig), eval
                  backend dispatch, embedded default net
  search/         engine state, search context/stack, TT, eval cache, qsearch,
                  root/negamax, pruning, reductions (basin), fail-soft returns,
                  move ordering, history and correction-history tables, SEE,
                  repetition, fifty-move rule, PV, Syzygy probing, time
                  management, tunables (compiled in; exposed only in
                  `-Dtuning` builds)
  uci/            UCI protocol, options, search worker integration
  tools/          offline diagnostics: bench, stability, search/eval profiling,
                  data extraction
  util/           huge-page allocation for large tables
deps/fathom/      Syzygy tablebase prober (C, vendored, MIT license)
```

Structural rules:

- No global mutable search state. Long-lived state (options, TT, history
  tables, NNUE weights) lives in `Engine`; per-search state (counters, stop
  control, search stack, PV, repetition history) lives in `SearchContext`.
- `Position` owns placement, occupancies, mailbox, side, castling, en passant,
  clocks, and hash; `StateInfo` owns reversible per-ply data. Make/unmake is
  the model, not copy-make.
- No heap allocation in search, movegen, make/unmake, or hot eval paths. Move
  lists, the search stack, and history tables are fixed-capacity dense arrays.

## NNUE evaluation

![Network dataflow, 6.3.0 (ZQB9) layout](diagrams/net-architecture-annotated.svg)

The diagram shows the 6.3.0 `ZQB9` network. 6.4.0 doubles the king buckets
to 16 and adds the pawn-pair block.

The evaluator is a pure NNUE (no hand-crafted evaluation) in the engine's own
`ZQB` family of net formats, loaded from an embedded 88.7 MB net
(`src/eval/default_net.zqb`) or an external file via the `EvalFile` UCI
option. The deployed generation is **ZQBA** (6.4.0), which is `ZQB9` plus a
pawn-pair block; `ZQB9` files still load:

- **Feature transformer — HalfKA-16.** Standard Chess768 features (color x
  piece type x square, 768 per block) replicated over 16 king buckets with
  horizontal mirroring: per perspective, the bucket is chosen by that side's
  own king square (black's frame is rank-flipped via `sq ^ 56`), and files
  e-h are mirrored onto a-d. The bucket map is read from the net header
  (6.0.0–6.3.0 nets: 8 buckets). Accumulator width is 1024 per perspective,
  i16 quantized.
- **Threat features.** The `zqHalfKA9` full-threat mapping has 60,144 sparse
  attacker/target-relation inputs. Threat rows are stored as i8 weights and
  maintained in a separate incremental half before the readout combines them
  with the HalfKA accumulator.
- **Pawn-pair features (ZQBA).** 1,488 inputs (1,278 live): pairs of pawns
  on ranks 2–7 on the same or adjacent files, in the same oriented frame.
  Pairs that duplicate a pawn-on-pawn threat feature are left out. The rows
  are i8 and live in the threat half, because they depend on the mirror flip
  but not on the king bucket.
- **PSQT head.** One per-feature scalar head, added outside the eight
  material-bucketed nonlinear stacks.
- **Layerstack readout.** An SFNNv5-style output stack per material bucket:
  clipped-ReLU + pairwise multiply on the accumulator halves, then
  `1024 -> 16` l1 (i8 weights, VNNI/dot-product matmul) ->
  squared-clipped-ReLU -> `16 -> 32` l2 -> `32 -> 1` l3, blended with the
  PSQT head. There are eight material buckets.
- **Output scale.** `NNUE Scale Percent` defaults to 44 for `ZQBA` and
  `ZQB9` nets (6.3.0: 48 for `ZQB9`); the default follows the loaded net's
  format.

Inference uses portable `@Vector` SIMD (lowers to AVX-512/AVX2/NEON with a
scalar fallback); integer SIMD is bit-exact, so eval output is identical
across targets. The AVX-512 build runs the accumulator and activation kernels
512 bits wide; since 6.3.0 this is forced explicitly, because LLVM's default
tuning for x86-64-v4 had kept them at 256 bits.

### Incremental update machinery

- **Per-ply accumulators.** `applyMove` edits the parent HalfKA and threat
  state instead of rebuilding. Threat features are non-local (a move can
  create or destroy discovered attack relations across the board), so threat
  deltas are computed by a dedicated attacker-group algorithm and unwind log
  rather than piece-list diffs.
- **Lazy materialization.** Accumulator edits are deferred until a node
  actually evaluates; nodes that cut off on TT hits or never reach a static
  eval skip the accumulator work entirely.
- **Refresh caches and barriers.** HalfKA uses a per-(side,
  king-bucket/flip) finny cache. Full-threat updates use lazy per-ply deltas,
  with barrier records and a small flip cache when a king changes the
  perspective's bucket/mirror orientation. Pawn-pair rows change only on
  moves that change a pawn set; their deltas go into the same batch as the
  threat deltas.

The net is trained with the [bullet](https://github.com/jw1912/bullet)
trainer on the publicly published Stockfish NNUE training datasets
(relabeled played-out game positions) — [NETWORK.md](NETWORK.md) documents
the data, trainer and provenance in detail; the engine-side
mapping is validated bit-for-bit against a trainer-faithful reference.

## Search

![Search pipeline](diagrams/search-pipeline.png)

Iterative deepening with aspiration windows around a PVS/negamax core. Once
an aspiration delta reaches its cap, the failing side of the window opens
fully (6.4.0), so a search near a mate score can no longer fail low or high
forever.

- **Threads (Lazy SMP).** With `Threads` above 1, every thread runs its own
  iterative deepening on the same root. The threads share one transposition
  table; move histories, the eval cache, the hint table and NNUE
  accumulators are private to each thread. Thread 0 owns the clock, the
  root tablebase decision, all UCI output and the final move, and one
  job-wide node budget covers `go nodes`. Helper threads are created when
  `Threads` changes and park between searches; nothing is allocated during a
  search. `Threads=1` runs the serial search with no helper threads. Since
  6.4.0 the threads split the single-thread budget for hint tables and eval
  caches between them; before, each thread sized its own from `Hash`.
- **Transposition table.** Clustered, generation-based depth-preferred
  replacement, prefetched, and it caches the raw static eval so a TT hit
  without a cutoff still skips the NNUE forward pass. At one thread a
  cluster holds two 24-byte entries (48 bytes). The shared table used with
  more threads has 64-byte clusters of two entries behind a sequence word:
  a writer takes the cluster with one compare-and-swap or skips the store,
  and a reader that sees a concurrent write treats it as a miss, so a torn
  entry is never used.
- **Dedicated eval cache.** A 2-way set-associative, 1-bit-LRU memo of the
  raw static eval keyed by the full 64-bit zobrist key, sized off `Hash`.
  It gives TT-evicted positions a second chance: the TT's depth-preferred
  replacement evicts shallow entries whose static eval is still worth
  remembering.
- **Pruning/reductions:** interior reductions and the forward-pruning
  families (null move with verification, reverse futility with a prefetched
  hint table read only at zero windows, futility, late-move and history
  pruning, SEE pruning) share one fractional "basin" depth-dose scheme. The
  formulas and initial constants of that scheme were taken from Stormphrax
  8.0.0's published parameter set and re-implemented in Zig, then partly
  retuned by local SPSA runs in 6.2.0 and 6.4.0 (`docs/PROVENANCE.md`,
  section 1);
  probcut and razoring sit alongside it with zigqueen's own constants. At the
  root, post-PV moves are scouted at reduced depth and re-searched at full
  depth on a fail-high. Null move is not tried inside a singular verification
  (excluded-move) search.
- **Fail-soft cutoffs (6.4.0):** reverse futility and quiescence stand-pat
  return beta moved part of the way toward the static eval. Null move
  returns its search score, and capture and check cutoffs in quiescence
  return their score. Decisive values fall back to the bound. TT entries
  store the returned values.
- **Correction history (6.4.0):** per-thread tables learn during search how
  far the raw static eval misses. The classes are pawn structure, each
  colour's non-pawn pieces, minor pieces, major pieces, and the previous two
  moves. A mean error per side to move and pawn-count bucket is learned and
  subtracted; only class deviations correct the eval.
  - The corrected eval feeds the pruning decisions (reverse futility,
    null-move gates, razoring, ProbCut, futility, bad-capture pruning), the
    extension gates and `improving`.
  - TT and eval-cache slots keep the raw eval, and so does the quiescence
    stand-pat.
  - The size of the correction widens the reverse-futility and futility
    margins and shrinks late-move reductions.
- **Extensions:** a singular-extension family, plus desperation-conditioned
  check extensions (checks extend at shallow depth always, and at any depth
  only when the static eval is at or below alpha — never while ahead, which
  keeps the branching factor position-aware). Since 6.4.0 there is no
  desperation extension when alpha is a mate bound.
- **Move ordering:** TT move first, captures by SEE, killers, countermove,
  quiet history (kept in four tables by whether the move's from- and
  to-squares are attacked by the opponent), continuation history.
- **SEE:** a king may capture in the exchange sequence only onto a square
  the opponent no longer attacks (6.4.0; before, every king recapture counted
  as free).
- **Quiescence:** captures/promotions plus SEE-gated quiet checks at the
  first qsearch ply (a direct-check generator keeps the horizon
  check-aware without a movegen pass).
- **Node accounting:** one visited position, one node — `nodes`/`nps` are
  honest counts.
- **Fifty-move rule:** a node at halfmove clock 100 is a draw unless the side
  to move is checkmated (6.4.0).
- **Endgames:** Syzygy WDL probing at search time via the vendored Fathom
  prober (`SyzygyPath`). At a root the tables cover, a clock-aware DTZ probe
  of every legal move restricts the search to the moves that keep the best
  tablebase result (respecting `go searchmoves`), and a search score that
  contradicts that result is not accepted. Only thread 0 probes the root;
  helpers receive the same move restriction. Tablebase-decided root results
  are proven once (two agreeing completed iterations past a depth floor) and
  reused instead of re-searched every iteration.
- **Time management:** iteration-based budgeting with a `Move Overhead`
  guard; the hard per-move deadline extends beyond its normal ceiling only
  for the iteration after a completed iteration that changed its best move
  or dropped the score. No plan may exceed the remaining clock (6.4.0;
  earlier versions could at `movestogo 1`). The per-node clock check is
  throttled off the hot path.

At `Threads=1`, search behavior at fixed depth is bit-deterministic, which
the tooling exploits: performance work is validated by node-identity
(identical node counts and PV at fixed depth) before any strength testing.
With more threads the result depends on scheduling and is not reproducible.

## Performance design decisions

- **Huge-page backing for random-access tables.** The TT, RFP-hint table,
  eval cache, continuation history, and multi-MB NNUE weight blocks are
  zobrist- or feature-indexed random accesses over tens of MB; on 4 KB pages
  nearly every probe is a dTLB walk (a 64 MB table spans 16,384 pages). On
  Linux the allocator ladder is `MAP_HUGETLB` -> THP via
  `madvise(HUGEPAGE)` on a 2 MB-aligned region -> plain heap; on Windows it
  is `VirtualAlloc(MEM_LARGE_PAGES)` (self-enabling `SeLockMemoryPrivilege`
  when the account has been granted "Lock pages in memory") with a silent
  fallback to regular pages. Since 6.4.0 the search context (about 2.4 MB of
  search stack and accumulator state) is mapped the same way.
- **Prefetching.** TT and RFP-hint probes for the child position are
  prefetched at make time. Any new per-node randomly indexed table should be
  audited for the same treatment.
- **Cache-conscious layouts.** TT clusters and eval-cache sets are sized to
  cache lines (4 eval-cache entries per 64-byte line); the accumulator and
  weight blocks are 64-byte aligned.
- **Stable code placement.** The hottest search and NNUE functions are
  aligned to 64 bytes, so unrelated code changes do not shift their cache-line
  placement and with it the measured speed.
- **Exact-output discipline.** Performance changes must preserve fixed-depth
  node identity; speed and strength are then judged separately. An optional
  llvm-bolt post-link pass (`scripts/bolt-optimize.sh`) reorders the hot
  text (layout-only, gated by the same node-identity check).

## Validation

- `zig build test` runs the unit/property suite (perft, make/unmake hash
  restoration, incremental-vs-refresh accumulator equivalence, TT and
  eval-cache invariants, UCI parsing).
- `./zig-out/bin/zigqueen stability 5` checks fixed-depth run-to-run
  stability; `bench` provides a fixed-node signature.
- Strength changes are gated by SPRT self-play plus periodic external
  gauntlets against other engines (see `docs/TUNING.md` and
  `docs/QUALITY_GATES.md`).
