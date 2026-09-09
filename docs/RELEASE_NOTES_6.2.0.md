# zigqueen 6.2.0

6.1.0 changed the shape of the search. 6.2.0 is a batch of smaller search
wins, a speed pass, a retune of the pruning constants and a continuation of
the network's head with quantization-aware training. On the anchored
gauntlet it lands at ~3672 against ~3644 for 6.1.0; method, per-opponent
results and caveats in [STRENGTH.md](STRENGTH.md).

## Search

- PV bug: the first child of a PV node was searched as a non-PV node. A
  two-line fix and the largest single gain of the release (+36 ±11 Elo at
  20s+0.2s, +32 ±10 at 60s+0.6s in self-play).
- Hash move first: when the transposition-table move is legal it is searched
  before any move is generated. At nodes where it fails high, generation,
  legality filtering and SEE scoring never happen. About 9% more nodes per
  second; +7 ±5 Elo pooled over both time controls.
- Low-depth singular extension: at depth 7 and below, a hash move with a
  lower-bound entry is extended when the static eval sits below alpha, and
  extended twice at non-PV nodes with a deep enough entry. +9 ±5 pooled.
- Pruning retune: an SPSA run over the basin pruning constants moved 11 of
  the 12 selected values (null-move margins, reverse futility, futility,
  history pruning and the two SEE thresholds). The before/after table is in
  [PROVENANCE.md](PROVENANCE.md#1-search-shaping-a-parameter-set-taken-from-stormphrax).
- `go searchmoves` is supported.

## Speed

All of these are node-identical at fixed depth; only the time changes.

- Gives-check information is computed once per node and shared by the six
  pruning sites and the child's in-check test (+1.7%).
- Static exchange evaluation: quiet-move SEE runs only when a pruning
  decision needs it, threshold tests stop as soon as the sign is decided,
  and moves already known to give check skip the noisy filter (+3.8%).
- NNUE threat bookkeeping: pending threat rows are dense pointers and move
  deltas read the stored threat words directly (+1.5%).

## Network

Same feature transformer and PSQT as 6.0.0. The three dense head layers were
continued for 1.07 billion positions with the trainer modelling the deployed
integer arithmetic (quantization-aware training), so the weights were fitted
to the arithmetic the engine actually runs. Training data was a prefix of a
locally corrected copy of the published corpus: tablebase-exact scores for
positions with at most five pieces and 223 rescored six-piece anchors. The
corrections ship with the release as `zigqueen-training-data-r1-alterations.tar.xz`
with a replay tool ([data-r1/README.md](data-r1/README.md)). Self-play read
+9 ±8 Elo, SPRT unresolved; the author took it. Model hashes and the recipe
are in [NETWORK.md](NETWORK.md).

## Odds and ends

- An `EvalFile` that fails to load is now fatal instead of silently falling
  back to the embedded net.
- `-Dtuning=true` builds expose the basin pruning parameters as `Basin*` UCI
  options. Release and tuning builds share the same defaults, so a tuned
  vector transfers unchanged.
- New developer subcommands `relabel`, `tb_rescore` and `result_backfill`
  (the corpus-correction toolchain behind the data archive).
- PROVENANCE.md separates the inherited Stormphrax parameters from the local
  retune; NETWORK.md records the head continuation and both model hashes.

Single-threaded UCI engine, default Hash 256 MB. Official binaries identify
as `zigqueen 6.2.0`. Ten release assets: six raw-binary zips, two signed OEX
APKs, the data-alteration archive and `SHA256SUMS`.
