# Local training-data score alterations

The original full-threat base used the published-label corpus. The 6.2.0
head-only QAT continuation used a prefix of the later local `r1` corpus.
This page provides its recorded alterations and additional score contents.

Download **zigqueen-training-data-r1-alterations.tar.xz** from the
[6.2.0 release](https://github.com/stierms/zigqueen/releases/tag/v6.2.0).
It contains all recorded alterations for the full local 27-component corpus,
including files beyond the prefix consumed by QAT. The archive and replay
method are offered free of charge, without registration or restrictions
beyond the applicable open licenses.

## Attribution and license

The underlying published collections and their providers are identified in
[NETWORK.md](../NETWORK.md). Parts are made available by the Stockfish
project and LCZero under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
with LCZero contents under [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
Our database alterations are offered under ODbL-1.0; our individual added
contents are offered under DBCL-1.0. Existing upstream notices remain in
effect. This is the recorded-alterations offer for ODbL section 4.6(b).
The independently written replay utility is GPL-3.0-or-later; its sfbinpack
dependency retains its own license and is fetched by Cargo, not vendored.

## Contents and identity

- `source-manifest.tsv`: exact input chunk names, SHA-256, byte sizes and
  decoded counts. A row identity is `(relative_path, zero-based decoded
  occurrence ordinal)`, before the training filter or shuffle.
- `output-manifest-full.tsv`: recorded rewritten file identities.
- `tb-sidecar-manifest.tsv` and `anchor-sidecar-manifest.tsv`: sidecar
  hashes and counts.
- `tb-sidecars/`: every changed tablebase score.
- `sidecars/`: accepted decisive-anchor scores, including the measured
  engine scores. Empty sidecars have only their eight-byte magic.

Only the signed evaluation score changes. Position, side to move, stored
move, ply and game result are preserved. Raw occurrence ordering is
preserved; identical positions in different occurrences are not deduplicated.
Original chunks generally contain 16 million decoded occurrences; use
the manifest's exact file identities, rather than assuming arbitrary
download partitions have the same ordinal numbering.

Tablebase replacements affect eligible quiet, non-check positions at ply
16 or later with at most five pieces and original absolute score at most
10000; castling-rights cases are skipped. Root tablebase and rule-50
outcomes map to -10000, 0 or 10000. The separate anchor pass accepted 223
decisive score replacements among selected six-piece near-draw positions.
The archive stores the actual accepted results, so reproducing a timed
anchor search or tablebase installation is unnecessary.

## Replay

Check the input SHA-256 against `source-manifest.tsv` and the sidecars
against their manifests before processing. Build the utility:

```sh
cargo build --release --locked --manifest-path docs/data-r1/replay/Cargo.toml
```

For each relative input name `COMPONENT/FILE.binpack`, run:

```sh
docs/data-r1/replay/target/release/zigqueen-data-replay \
  source/COMPONENT/FILE.binpack \
  alterations/tb-sidecars/COMPONENT/FILE.binpack.tb \
  alterations/sidecars/COMPONENT/FILE.binpack.anchors \
  output/COMPONENT/FILE.binpack
```

Create output parent directories first. The tool refuses existing outputs,
invalid/duplicate ordinals, old-score mismatches and unconsumed alterations.
It preserves every other decoded field and re-encodes with sfbinpack 0.6.2.
Compare the output with `output-manifest-full.tsv`; the original pipeline
also checked decoded field equality independently. Re-encoding byte
identity depends on the specified codec, not just on equal positions.

### Sidecar format

All integers are little-endian. TB magic is `ZQTBSC1\n`, followed by records
`u32 ordinal, i16 new_score, i16 old_score`. Anchor magic is `ZQANCH1\n`,
followed by `u64 ordinal, i16 new_score, i16 old_score, i32 engine_score`.
Records within each sidecar have strictly increasing ordinals. These are
complete replacement contents, not probabilities or instructions to
regenerate scores from another engine.
