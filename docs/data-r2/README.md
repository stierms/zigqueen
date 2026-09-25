# Training-data alterations for the 6.3.0 network (r2)

The 6.3.0 network (SHA-256 `a63732096ec9f2afdb0e18ddf09a7a04b6cdd5c1b6c8844b200afaf48f9da731`)
was trained on 42 published data files whose positions other people scored with
Leela's BT4 network. We did not score, relabel or add any position. We did choose
the files, keep local re-encoded copies of 37 of them, filter positions, hold some
out, mix the components by quota and turn the published scores into training
targets. This page lists each of those steps with its exact rule and totals. The
archive holds the manifests, the per-file admission indexes and the code needed to
repeat them.

Download **zigqueen-training-data-r2-alterations.tar.xz** from the
[6.3.0 release](https://github.com/stierms/zigqueen/releases/tag/v6.3.0). The
archive and the method are offered free of charge, without registration or
restrictions beyond the applicable open licenses. This offer covers the 6.3.0
network; the 6.0.0–6.2.0 network is covered by [data-r1](../data-r1/README.md).

## Attribution and license

We credit the LCZero contributors, Linmiao Xu (linrock), Joost VandeVondele
(vondele), the Stockfish data contributors, xushawn and the contributors to the
community BT4 relabelling. The sources and their terms are described in
[NETWORK.md](../NETWORK.md); `sources/components.tsv` pins every repository,
revision, file and SHA-256.

Parts of these data are made available by the Stockfish project and LCZero under
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/), with LCZero contents
under [DbCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/). The two
`xushawn` files declare ODbL-1.0. The `vondele` relabel repositories state no
terms of their own; we treat them as continuing their sources' ODbL terms.

The database we derived from these files, and our alterations, are offered under
ODbL-1.0; individual contents stay under DbCL-1.0. We added no individual
contents: every training score is a fixed arithmetic function of a published
score. The code we wrote (in `code/` and `tools/`) is GPL-3.0-or-later. Its
third-party Rust crates keep their own licenses (sfbinpack GPL-3.0, bulletformat
MIT; sha2, serde, serde_json and their dependencies under MIT, Apache-2.0,
Unlicense or Unicode-3.0 terms) and are fetched by Cargo at the versions in
`Cargo.lock`, not vendored. This page and the archive are our offer
under ODbL section 4.6: all alterations and the method to reproduce the
derivative database from the published files.

## What we changed

**1. Selection.** 42 files from six Hugging Face repositories, one per
component (list in `sources/components.tsv`). We did not use: the Q-value
versions (`.q.binpack`) of the same files, compressed (`.zst`) copies, the
two-part split of test80 October 2022 (same positions as the single file we
used), `xushawn/SerendipityBlends` (an interleave of test77 December 2021 and
test78 January–May 2022, which we already use as separate components),
`anematode/bt4-relabel` (a second rescoring of `wrongIsRight_nodes5000pv2`),
`vondele/rescored` (tablebase data and Stockfish rescoring experiments, not BT4
labels), `xushawn/Clockwork-BT4-Relabel` and `Viren6/Monty-BT4-SF-v8-dd-v0-data`
(outside this collection; no card, or mixed teachers under AGPL).
`sources/excluded.tsv` lists each of them with its SHA-256 and the reason.

**2. Local copies.** Five components were read straight from the published file,
unchanged (SHA-256 equal to the published one): test80 October 2022,
`dfrc_n5000`, `fishpack32`, `multinet_pv-2_diff-100_nodes-5000` and
`nodes5000pv2_UHO`. The other 37 were read from local copies we made in July
2026 for earlier networks, 11,467 files in all. They were made with
`code/house-chunks` (the original program, unchanged), which reads the published
file entry by entry and writes the same entries, in the same order, into files
of 16,000,000 entries. It changes one thing, the score:

```
stored = sign(p) * floor(|p| * f + 0.5)    if |p| < 30000   (binary64; ties away from zero)
stored = p                                 if |p| >= 30000
```

where `p` is the published score and `f` the component's factor (0.8426 to
0.9869, column `factor`). The program's clamp to ±29999 never applies, because
every factor is below one. No entry was dropped, added or reordered. Position,
side to move, castling and en-passant state, rule-50 counter, move, ply and game
result are the published ones. The factors come from an earlier unit calibration
of ours; step 4 undoes them. Shard `k` of a component holds published entries
16,000,000·k onwards (`published_first_ordinal` in `sources/files.tsv`).

Evidence: for every one of the 37 components, running `house-chunks` on the first
3 MiB of the pinned published file reproduces the first block of the local copy
byte for byte, and all 28,129,129 decoded rows of those runs match the local
rows. Earlier checks matched 7,278,434 beginning-of-file records and, aligned at
the end of each file, the last 3,696,474 rows across the 37 components; every
shard but the last holds exactly 16,000,000 entries. We have not compared the middle of the local copies with the
published files row by row; rebuilding them with the command below and checking
each shard's SHA-256 does that.

**3. Position filter.** This is the filter the network was trained with. The
admission reads every row once and keeps it only if it passes these rules, in
this order. Each row is counted at the first rule it fails.

| Rule | Rows removed | Share |
|---|---:|---:|
| Stored score has no published value (the published \|score\| ≥ 30000 range) | 15,869,575,576 | 7.04% |
| Ply below 16 | 10,861,890,611 | 4.82% |
| Recorded move is a capture, promotion, castling or en passant | 36,258,429,089 | 16.08% |
| Side to move in check | 13,077,485,131 | 5.80% |
| \|0.9256841495771224 × reconstructed score\| > 10000 | 18,321,427,504 | 8.12% |
| `dfrc_n5000` row with any castling right | 0 | 0.00% |
| Held out (step 5) | 7,998,177 | 0.004% |
| **Kept for training** | **131,124,072,315** | 58.14% |
| Rows read | 225,520,878,403 | |

Each file's counts, per block of the binpack file, are in `admission/indexes/`
and summed in `sources/files.tsv` and `sources/components.tsv`.
`target-contract.json` calls this filter a proposal; it is the one applied.
Both trainers take their rows only from the loader, which runs the same rules
on every block it reads and stops if a block's counts differ from its index;
the trainers add no filter of their own.

**4. Score reconstruction.** For each component, `admission/target-tables/NN.published-cp.f32le`
maps a stored score to the midpoint of all published integers that the step-2
formula turns into it. Every stored value has one or two such integers, so the
reconstructed score is within 0.5 cp of the published one and twice it is an
exact integer. For the five unchanged components the factor is 1 and the table
is the identity. `tools/make_target_tables.py` rebuilds all 42 tables from the
factors and checks their SHA-256.

**5. Holdout.** A position key is the SHA-256 of `ZQ-BT4-KEY-v1\0` followed by
seven little-endian 64-bit boards: the side to move's pieces, then all pawns,
knights, bishops, rooks, queens and kings. If Black is to move, every board is
flipped vertically; then, if the side to move's king stands on files e–h, every
board is mirrored horizontally. Castling, en passant and the rule-50 counter are
ignored (schema `bt4-stm-mirror-seven-u64le-sha256-v1`). A row is held out when
the low 14 bits of digest bytes 16–23, read as a little-endian integer, are all
zero, which selects about 1 key in 16,384. Every occurrence of such a key is
held out, in every component: 7,998,177 rows. From them, 65,184 records (the
lowest-ranked keys in each component, material bucket and side-to-move cell) form
the validation set used only to measure the head-QAT loss. Its SHA-256 are in
`admission/validation/fixture.json`; the records are not included.

**6. No deduplication.** Repeated positions within a component and across
components are kept, apart from the holdout keys.

**7. Mixing.** Components are drawn by quota, not by size. A second 14-bit test
on digest bytes 24–31 samples about 1 key in 16,384 from each component's
training rows. Each sampled key contributes 1/k to each of the k components that
contain it, which shares overlapping coverage equally. Each component gets one
slot of a 2^20 period plus a share of the remaining 1,048,534 slots in
proportion to that mass, with leftover slots going to the largest remainders
(`bt4_finalize.py`, `admission/coverage.json`, column `quota`). Presentation `n`
takes its component from slot `(a·(n mod 2^20) + b) mod 2^20` of the cumulative
quota ranges, with `a` and `b` derived from seed 62020914 (`quota.rs`). Each
component yields its training rows in file, block and row order and starts again
when it runs out. Windows of 67,108,864 presentations are then shuffled with a
seeded Fisher–Yates shuffle. The full training read presentations 0 to
590,246,838,271 of this stream, about 4.5 passes; interrupted runs resumed from
checkpoints at their recorded position.

**8. Training target.** The prepared score is `s = 2 × reconstructed score`
(half centipawns, side to move). The target is

```
0.9 × sigmoid(s / 864.2256652719631) + 0.1 × r
  = 0.9 × sigmoid(0.9256841495771224 × reconstructed score / 400) + 0.1 × r
```

with `r` = 1, 0.5 or 0 for a win, draw or loss of the side to move, taken
unchanged from the published game result. The trainers compute it in 32-bit
floats as `0.1·r + 0.9·sigmoid(s · (1 / 864.2256469726562))`: the divisor is
rounded to the nearest float, 864.2256469726562, and multiplied as its
reciprocal. That is the only difference from `target-contract.json`. Two of
its notes describe checks, not training steps: rule-50 and repeated endgames
were only reported, and the Q-value files only served to check the published
scores. The common factor 0.9256841495771224 is the
average of the 27 earlier factors weighted by the 60,717,525,976 rows of the
6.0.0 training set (column `accepted_27_weight`; `make_target_tables.py`
recomputes it bit for bit). It keeps our score scale and was fixed before
training, not tuned. The head-QAT stage read the first 1,073,741,824
presentations of the same stream, with the same targets.

No score was replaced by one from another engine, a tablebase or a search, and
no position, move or game result was changed. Everything in the derivative
database follows from the published files and this archive, so the archive holds
no data rows.

We checked this on a small sample, not the full corpus. 1,159,467 rows from four
components (two re-encoded; two read unchanged, one of them `dfrc_n5000`),
rebuilt from the published data with the rules above, agree bit for bit with
the rows and filter decisions the loader gave the trainers and with the targets
the trainers computed from them. One full training file also re-admits to a
byte-identical index.

## Archive contents

- `NOTICE.txt`, `CODE-LICENSE` (GPL-3.0 text), `IDENTITY.json` (origin and
  SHA-256 of every file, and where a file differs from our recorded copy).
- `sources/components.tsv`: the 42 components with repository, revision, file,
  URL, SHA-256, terms, local form, factor, counts and quota.
- `sources/files.tsv`: the 11,472 training files with relative path, size,
  SHA-256, first published ordinal, counts and index hashes.
- `sources/excluded.tsv`: published files found and not used.
- `admission/`: the manifests of the recorded run (`adapter-manifest.json`,
  `source-manifest.json`, `config.json`, `admission-complete.json`,
  `rights-admission.json`, `target-contract.json`, `coverage.json`,
  `source-mixture.json`, `validation/fixture.json`), the 42 target tables and the
  11,472 per-file indexes. Local paths are rewritten as `house/<component>/<shard>`
  and `published/<file>`; `IDENTITY.json` lists every such change.
- `code/bt4-loader/`: the admission and training-stream crate as used by both
  trainers, with `Cargo.lock`. `code/bt4-loader-admission-time/` holds the three
  source files and one test that differed when the admission ran; they do not
  touch row selection, holdout or targets. `code/scripts/`: the finalizer and the
  orchestration script. `code/house-chunks/`: the copy program and a row printer.
- `tools/`: `verify_offer.py`, `make_target_tables.py`, `admit_local.py`,
  `replay_rows.py` and `replay-rows/` (the loader's rows and targets for a
  training file, for comparison with rows rebuilt from the published data).

## Reproducing

Check the archive itself first; this needs no data:

```sh
python3 tools/verify_offer.py
python3 tools/make_target_tables.py
```

Download each published file from `published_url` in `sources/components.tsv`
(about 701 GB in all) and check `published_sha256`. Put the five unchanged files
under `published/`. Rebuild the other 37 components:

```sh
cargo build --release --locked --manifest-path code/house-chunks/Cargo.toml
ZQ_PURE_FACTOR=<factor> ZQ_CHUNK_ENTRIES=16000000 \
  code/house-chunks/target/release/zq_house_chunks <published file> house/<name> <shard_prefix>
python3 tools/verify_offer.py --data-root . --all-files
```

`factor` and `shard_prefix` come from `components.tsv`; pass the factor exactly
as written there. With sfbinpack 0.6.2 the shards should match `files.tsv` byte
for byte. If an encoder version writes different bytes, `binpack-rows` prints
the decoded rows for comparison.

Re-run the admission on any files and compare the indexes byte for byte:

```sh
cargo build --release --locked --manifest-path code/bt4-loader/Cargo.toml --bin bt4-admit
python3 tools/admit_local.py --bt4-admit code/bt4-loader/target/release/bt4-admit \
  --data-root . --file-id 11054
```

Over all 11,472 files, followed by `code/scripts/bt4_finalize.py`, this
reproduces `coverage.json`, the quotas and the validation set.

Compare rebuilt training rows and targets with the loader's, for the first
block of a component's first file:

```sh
cargo build --release --locked --manifest-path tools/replay-rows/Cargo.toml
python3 tools/replay_rows.py --data-root . --component 35 --blocks 1 \
  --replay-rows tools/replay-rows/target/release/replay-rows \
  --binpack-rows code/house-chunks/target/release/binpack-rows
```

For a re-encoded component, add `--published <published file>`.
`zq_bt4_loader::PrefetchStream` (or `Bt4Stream`) opened on
`admission/adapter-manifest.json` with seed 62020914 and window 67,108,864 yields
the training order; it reads the data files relative to the working directory.

## Formats

- A row's identity is `(relative_path, zero-based decoded row)`. Its published
  ordinal is `published_first_ordinal` plus the row number.
- Index files (`bt4-admission-file-v1`) list each binpack block's offset, length,
  SHA-256 and counts. They also carry the SHA-256 of three sidecars that
  `bt4-admit` writes: the sorted unique 16-byte keys of sampled training rows, the
  32-byte bulletformat records of held-out rows, and 24 bytes of metadata per
  held-out row.
- Target tables are 65,536 little-endian 32-bit floats; the index is the stored
  score plus 32768; NaN means the row is removed.

## Limits

- The middle of the 37 local copies was checked by construction and sampling,
  not row by row (step 2).
- Forty of the 42 files rely on their sources' terms; the `vondele` cards state
  none, and we found no separate notice for rights added by the relabelling.
- `dfrc_n5000` lost no rows to its castling rule. Its rows decode with no
  castling rights under sfbinpack 0.6.2 (none of the 330,724 rows of its first
  block has any, and an independent scan found none among retained rows). We
  have not established whether the published encoding keeps castling rights
  for these positions.
- The holdout key folds colours and board symmetry and ignores castling, en
  passant and the rule-50 counter. Key collisions are possible but negligible.
  The holdout is not independent of the positions earlier networks trained on.
