# Trainer extensions (bullet patches)

zigqueen's networks are trained with [bullet](https://github.com/jw1912/bullet)
(MIT, Jamie Whiting) plus changes written for zigqueen. This directory
publishes those changes as patches against upstream bullet commit `d372d48`,
so that anyone can see how the shipped networks were trained and build the
same trainer programs. The patches carry bullet's MIT license.

| Patch | Network | What it builds |
|---|---|---|
| `bullet-v2.patch` | 6.4.0 | `zq_v2`: seeded init, float run, resume, export |
| `bullet-v2-extend.patch` | 6.4.0 | adds `zq_v2 extend`, the full-network QAT stage; applies on top of `bullet-v2.patch` |
| `bullet-bt4-full.patch` | 6.3.0 | `zq_bt4_full`: main run, finish, checkpoint averaging, resume |
| `bullet-bt4-head-qat.patch` | 6.3.0 | `zq_bt4_head_qat`: head-only QAT stage |
| `bullet-fullthreats.patch` | 6.0.0–6.2.0 | the original base network's recipe |

SHA-256 of the published files:

```
a8d88916a40eabd6a8018fb9de33cbb3f9a020145988eb400f754492c81b0e47  bullet-v2.patch
aa3a3f1289579ee9e18c3a6fe7ea28956080a63a16310d408e49f8941f021b83  bullet-v2-extend.patch
063336346f79ab5d468b1c0b78a43cda363ac45824f101f5cf29790049753581  bullet-bt4-full.patch
8761297c844b0bd1f551dbf7e63437a734ab09c6e85b16a7c0bcbbfea444c7e8  bullet-bt4-head-qat.patch
9946e426906921b2f4066bd4d9003d3b2245dcdb39b552721f6acc96f46239a5  bullet-fullthreats.patch
f92c120b032cf2af6fc3ece4885dbbe51a0e0846c1fc4ba4a4b6584d15060236  tools/v2_net.py
b3a1b93e2f1423e03fb0f154e617dbcb4cbff4e5e2feaddaab061dbcb05bdc11  tools/quantised_to_zqb.py
8ca55ac83d2043df2d87bd7c338fe7b274f0376d16a47586d2021791a568de26  tools/bt4_head_qat.py
```

## 6.4.0 network

One program, `zq_v2`, trained the 6.4.0 network in two stages. Each stage
ran a binary built from our private bullet fork:

| Stage | Fork commit | Binary SHA-256 | Source |
|---|---|---|---|
| Float run: init, 5,902 superbatches | `fc75c39` | `d94a540c51ee4048…` | `d372d48` + `bullet-v2.patch` |
| QAT: 330 superbatches (`extend`) | `fa41efd` | `501cea7b735c1bb6…` | the above + `bullet-v2-extend.patch` |

Both were built with Rust 1.94.1 and bullet's `cuda` feature (CUDA 12
runtime). The second build only adds code: the `init`, `train` and `export`
paths are those of the first.

**`bullet-v2.patch`** (20 files):

- `examples/zq_v2.rs`, the recipe. It is the 6.3.0 graph with 16 king
  buckets and a pawn-pair block: 768 factoriser + 12,288 HalfKA + 60,144
  threat + 1,488 pawn-pair rows = 74,688 trainer rows (73,920 deployed). It
  keeps 6.3.0's seeded initialisation, schedule, checkpoint, averaging and
  resume rules. The 210 dead pawn-pair rows start at zero, and the run stops
  if one moves. Modes: `init`, `train`, `export`, `probe`, `features`,
  `stream-scan`, `constants`.
- `examples/zq_bt4_state.rs`: unchanged from `bullet-bt4-full.patch`.
- `game/inputs/pawn_pairs.rs` (new): the pawn-pair input (dictionary PP1, see
  [NETWORK.md](../NETWORK.md)), plus the scrambled control of our pilot.
- `crates/trainer/src/model/zq_deployed.rs` (new) and two ops in
  `model/builder.rs`: CUDA kernels that reproduce the engine's dense-head
  float arithmetic (rounded multiply, then rounded add, in the engine's
  summation order) for the QAT graph.
- `crates/trainer/src/optimiser/adam.rs`: AdamW counts non-finite updates so
  the trainer can stop on them. The update arithmetic is unchanged.
- `game/inputs.rs` and `crates/trainer/src/model.rs` each gain the line
  that registers the new module. The remaining library files and
  `Cargo.lock` are byte-identical to `bullet-bt4-head-qat.patch`'s.
  `crates/bullet_lib/Cargo.toml` names the loader by the relative path
  `../../zq-bt4-loader`.

**`bullet-v2-extend.patch`** (`examples/zq_v2.rs` only, +405 lines, none
removed):

- `zq_v2 extend --config E.tsv --output DIR [--resume CP]` continues a
  sealed `train` checkpoint, weights and Adam moments, for `total_sb`
  superbatches. The learning rate follows a cosine from `lr_start` to
  `lr_end`. It runs under the deployed-arithmetic graph (`graph qat`) or the
  float graph. Each pass reads the same stream from record 0 with its own
  shuffle seed. `master_range` clamps the threat and pawn masters in the
  optimizer. The output is the raw endpoint, with no averaging. It keeps its
  own checkpoint schema, and resume refuses any changed setting.
- `zq_v2 heldout`: held-out MSE of any weights under either graph.

### As built

A clean `d372d48` checkout with the patches applied reproduces the fork
commits above for every file the patches touch. Before the loader is copied
in, `git add -A && git write-tree` prints `bd2144d2eb340e9844365e311d811a4dd358ee39`
after `bullet-v2.patch` and `d30b464e61c63112fa569434deb356e04ad2cd6a` after
both. The `crates/` tree hash equals the fork's. Pinned files:

```
zq_v2, float run (fc75c39)
  19b82a853a06bb88613558c4ff375b2d96360526e9aa7ffc993cf232210091c2  examples/zq_v2.rs
  f4a0d5aef86cd5849de6ed45cf449c2ef0ebbd17d567eb8e6f2406cde4bff85e  examples/zq_bt4_state.rs
  e07de5a0fae487bde53ab77f2ef0eb843aef65940f1ca6c8d4e456a0d1fb28a7  crates/bullet_lib/src/game/inputs/pawn_pairs.rs
  09ec8388f037a9cda535352a1397085b5ab2a7cbb0593c59225460e9bab755d5  crates/trainer/src/model/zq_deployed.rs
  5b521339ced3a77de332b27335b6d869dbf2d372913418c3bd22f2c6a4796707  crates/bullet_lib/Cargo.toml
  c44e9d1789debc1adcb4df118659620fe14b5562722db442463289aed2c74a75  Cargo.lock

zq_v2 with extend (fa41efd); other files as above
  1463fecdfdabe1042401444a54246f732d8bafbb718ae1f7ce7831fd1494ea57  examples/zq_v2.rs
```

Both `zq_v2.rs` hashes match the source snapshots archived with the two
binaries. The fork's upstream base was identified by
content, because its history starts from a copy rather than from an
upstream commit. The fork changes 13 upstream files (+914/−36 lines) and
deletes none. Every other upstream file is byte-identical to `d372d48`.
Each neighbouring upstream commit needs a larger diff: `872ad6f`, its
parent, needs +916/−38, and the next commit already touches 64 files.

### Data loader

This is the 6.3.0 crate, `zq-bt4-loader` (GPL-3.0-or-later), published in the
r2 data archive as `code/bt4-loader`. Copy it to `zq-bt4-loader/` at the
top of the bullet checkout. Its sources are byte-identical to the copy the
6.4.0 trainer was built with. Only `DESIGN.md` differs: local paths were
removed.

### Apply and build

```
git clone https://github.com/jw1912/bullet && cd bullet && git checkout d372d48
git apply /path/to/bullet-v2.patch
git apply /path/to/bullet-v2-extend.patch     # needed for the QAT stage
cp -r /path/to/r2-archive/code/bt4-loader zq-bt4-loader
CUDA_PATH=/path/to/cuda cargo build --release --locked \
  -p bullet_lib --features cuda --example zq_v2
```

`patch -p1` gives the same tree. The unit tests need no GPU:
`cargo test --locked -p bullet_lib --example zq_v2` (10 tests, with or
without the extend patch). This was checked for this release on fresh
checkouts without CUDA: both patches apply, the tree hashes match, 10/10
tests pass at both stages and the release build of `zq_v2` compiles.

`Cargo.toml` is kept byte for byte, so it still lists examples that are not
published. Cargo reads only the example you build.

### Running: the 6.4.0 recipe

1. `zq_v2 init --seed 62020914 --output DIR` writes the initial weights,
   SHA-256 `1f09225f9afc4931…`. Repeated runs are byte-identical.
2. `zq_v2 train --config C.tsv --output DIR [--resume CP]`, config schema
   `zq_v2_train_v1`. The 6.4.0 values:
   - seed 62020914, shuffle window 2^26;
   - 6,104 batches × 16,384 per superbatch;
   - main phase 4,721 superbatches, cosine 1e-3 → 2.43e-6;
   - tail 1,181 superbatches, cosine → 2.43e-7;
   - checkpoint every 25 superbatches, `finish_qat off`, 6 loader threads;
   - 6.3.0's data index and holdout fixture.

   The run was resumed three times from sealed checkpoints, at superbatches
   3,401, 3,601 and 3,676. It recorded 375,179 s on an RTX 5080.
3. `zq_v2 extend --config E.tsv --output DIR`, config schema
   `zq_v2_ext_v1`. The 6.4.0 values:
   - `from`: step 2's raw superbatch-5,902 checkpoint, not its averaged model;
   - `graph qat`, `total_sb 330`, `pass_sb 210`, `seeds 62021008,62021009`;
   - `lr_start 2.43e-6`, `lr_end 2.43e-7`, `master_range 0.496`;
   - 6,104 batches per superbatch, shuffle 2^26, 6 threads, checkpoint
     every 25.

   It recorded 37,642 s on the RTX 5080. Outputs: `final/raw-endpoint.weights.bin`
   and bullet's `final/quantised.bin`.
4. Export with `tools/v2_net.py`. It loads `quantised_to_zqb.py` from its own
   directory and refuses any other version of that file:

   ```
   python3 v2_net.py replica --weights raw-endpoint.weights.bin --out replica.bin  # must equal quantised.bin
   python3 v2_net.py convert --quantised quantised.bin --out net.zqba --report convert.json
   python3 v2_net.py check --net net.zqba --out check.json                          # range gate
   ```

   `convert` writes the ZQB9 part through `quantised_to_zqb.py` with 16 king
   buckets, then appends the pawn-pair block as ZQBA.

Reproduction of the shipped bytes, checked for this release on step 3's
outputs (`raw-endpoint.weights.bin` `2afb6618…`, `quantised.bin` `cfe65137…`):

- `replica` equals `quantised.bin`;
- `convert` gives the ZQB9 part `12bca0fe…` and the ZQBA
  `1342ac4691324a632418d6e1fc8696807c364d9a8bb63fbbc9b74e771cf1ffac`, which is
  byte-identical to the embedded net;
- `check` passes, with threat and pawn weights within ±126.

[NETWORK.md](../NETWORK.md) explains why the recipe is built this way.

### Not included

- `zq_v2_head_qat` and its preparation script. They built the head-QAT
  sibling `v2` that NETWORK.md compares against, not the shipped network.
- The fork's other examples (earlier experiments and the pawn-pair pilot),
  the job scripts that started, resumed and checked the runs, and the
  engine-against-reference parity checker.
- The training data. It is the same as 6.3.0's; see
  [data-r2/README.md](../data-r2/README.md).
- Bit-exact retraining. GPU training is not bitwise deterministic.

### License and origin

The patched bullet files and the recipe are offered under bullet's MIT
license. `tools/v2_net.py` is GPL-3.0-or-later. All of it was written for
zigqueen. Two ideas come from elsewhere; no code does:

- Pawn-pair inputs, meaning pairs of pawns on the same or adjacent files, are
  a published idea (Stockfish's SFNNv16, credited to Pawnocchio's author).
  The PP1 dictionary, its index layout and the threat-duplicate exclusion
  are ours.
- Training through the deployed integer arithmetic with straight-through
  estimators is standard quantisation-aware training.

See [PROVENANCE.md](../PROVENANCE.md).

## 6.3.0 network

The 6.3.0 network was trained by two bullet example programs. Each has its
own patch, and each patch applies by itself to a clean `d372d48` checkout.
The two share most of their library changes but not all of them, so use one
checkout per patch.

**`bullet-bt4-full.patch`** builds `zq_bt4_full`, which does everything
before QAT:

- `examples/zq_bt4_full.rs`, the recipe: network graph, seeded
  initialisation, AdamW limits, the main and finish learning-rate schedules,
  checkpoints, resume, and the export of the averaged model;
- `examples/zq_bt4_state.rs`: schedule arithmetic, sealed checkpoints (every
  file is checksummed before a checkpoint becomes visible), strict resume
  checks, and the equal-weight average of the late checkpoints, kept as
  64-bit sums;
- `examples/zq_bt4_adapter.rs`: the thin link between bullet and the data
  loader described below.

**`bullet-bt4-head-qat.patch`** builds `zq_bt4_head_qat`:

- `examples/zq_bt4_head_qat.rs`: trains only the dense head (`l1`–`l3`)
  through a forward pass that models the engine's integer arithmetic. The
  feature transformer, PSQT and output combiner stay frozen. It can resume
  from its own checkpoints and measures held-out loss before and after.

Both patches also contain the library changes the programs were compiled
with:

- the full-threat input type and the `Combined` input
  (`game/inputs.rs`, `game/inputs/halfka_threats.rs`,
  `game/inputs/combined.rs`); the first two are unchanged from the 6.2.0
  patch, and `combined.rs` is the file that patch left out;
- auxiliary and per-row extra inputs (`value.rs`, `value/builder.rs`,
  `value/dataloader.rs`, `value/loader.rs`), also as in the 6.2.0 patch;
- seeded weight initialisation (`crates/trainer/src/model/rng.rs`; the QAT
  patch seeds each tensor by its name in `crates/trainer/src/model/builder.rs`);
- a seeded shuffle for bullet's binpack loader (`value/loader/rng.rs`,
  `value/loader/sfbinpack.rs`);
- small read-only hooks (`crates/gpu/src/function.rs`,
  `crates/trainer/src/model.rs`); in the QAT patch, `model.rs` also keeps
  frozen tensors out of the optimizer;
- `crates/bullet_lib/Cargo.toml` and `Cargo.lock`, exactly as built.

### As built

Applied to a clean checkout, each patch reproduces the bullet sources of its
training program: every file it touches is byte-identical to the copy the
program was built from. These files were pinned by SHA-256 when the
programs were built:

```
zq_bt4_full
  c10e99aec89de3974bf43a18428bbbc72504318f51b967b84243a1020cf3a25d  examples/zq_bt4_full.rs
  f4a0d5aef86cd5849de6ed45cf449c2ef0ebbd17d567eb8e6f2406cde4bff85e  examples/zq_bt4_state.rs
  23a251ab11c91bb21aba2fb66426fade68bc28b761b3fd98bdee3a26fa37c14b  examples/zq_bt4_adapter.rs
  f22b65ca4a66379d12d069bbcbb7e14c495b3a533d6d5d2da7f1b8cf49b5839e  crates/bullet_lib/Cargo.toml
  a441c88629044dd3257f9fcc0cc856d343e425ebe948623ac31219bca4ede158  Cargo.lock

zq_bt4_head_qat
  d40e1035cc09effc9bbc9572375163e15b3daa3da89254179e3a98dea229a3b3  examples/zq_bt4_head_qat.rs
  b7f051829f1b7eb4b57482a52ef3b76a957df864b2f5916fecb0d9f5f1ec6a76  crates/bullet_lib/Cargo.toml
  c44e9d1789debc1adcb4df118659620fe14b5562722db442463289aed2c74a75  Cargo.lock
```

Both programs were built with Rust 1.94.1 and bullet's `cuda` feature
(CUDA 12 runtime).

The trainer branches also held earlier experimental recipes and helper
scripts. They were not part of either program and are left out. Because
`Cargo.toml` is kept byte for byte, it still lists those examples, and in
`bullet-bt4-full.patch` one of them points outside the tree. Cargo only
reads the example you ask it to build, so this does not get in the way.

### The data loader

Choosing, weighting and streaming the 42 training components is done by
`zq-bt4-loader`, a small Rust crate written for zigqueen
(GPL-3.0-or-later). It is not a bullet change, so it is not in these
patches. It is included in the 6.3.0 training-data archive, described in
[data-r2/README.md](../data-r2/README.md). The version used
is `tools/bt4-loader` at zigqueen commit `eac94bac4`; its combined source
hash, as recorded at build time, is
`595a88ab1781b7cbb014e326acecffe433d432bf8062d949ffc509954dd51ed7`.

`crates/bullet_lib/Cargo.toml` names the loader by its path on the training
machine. Change that one line to point at your copy.

### Apply and build

```
git clone https://github.com/jw1912/bullet && cd bullet && git checkout d372d48
git apply /path/to/bullet-bt4-full.patch
# edit the zq-bt4-loader path in crates/bullet_lib/Cargo.toml
CUDA_PATH=/path/to/cuda cargo build --release --locked \
  -p bullet_lib --features cuda --example zq_bt4_full
```

For the QAT stage, do the same in a fresh checkout with
`bullet-bt4-head-qat.patch` and `--example zq_bt4_head_qat`. The unit tests
need no GPU: `cargo test --locked -p bullet_lib --example <name>`
(6 tests for `zq_bt4_full`, 4 for `zq_bt4_head_qat`).

### Running

`zq_bt4_full init` writes the seeded starting weights, and
`zq_bt4_full train --init <weights>` trains from them. The program derives
the schedule from the number of admitted positions: 3.6 passes in the main
phase and 0.9 in the finish, rounded up to whole superbatches. After an
interruption, `zq_bt4_full train --resume <checkpoint>` continues from a
sealed checkpoint with its optimizer state, data position and running
average. It refuses to start if any recorded setting differs, including the
hash of the program itself. The 6.3.0 run was resumed four times this way.
After the last superbatch the program writes the mean of the late
checkpoints to `averaged/`, and that model is the input to QAT. The recipe
numbers are in [NETWORK.md as of 6.3.0](https://github.com/stierms/zigqueen/blob/v6.3.0/docs/NETWORK.md).

`zq_bt4_head_qat CONFIG OUTPUT [CHECKPOINT]` runs the QAT stage from a
configuration table and inputs prepared from the averaged model.

### Not included

- The job wrappers that started and resumed the runs on our machines. The
  two zigqueen scripts that change the released bytes are published in
  [`tools/`](tools/) (GPL-3.0-or-later): `quantised_to_zqb.py` exports
  bullet's output to the engine's `ZQB9` file (the averaged model before
  QAT), and `bt4_head_qat.py` prepares the QAT inputs from that model and
  writes the final `ZQB9`.
- The training data. The selection, filter, holdout, quotas and target
  rules are offered in [data-r2/README.md](../data-r2/README.md).
- Bit-exact retraining. GPU training is not bitwise deterministic, so a
  rebuild gives the same programs, not the same weights. The released
  weights are identified by their SHA-256 in [NETWORK.md as of 6.3.0](https://github.com/stierms/zigqueen/blob/v6.3.0/docs/NETWORK.md).

### License and origin

The patched bullet files and the new recipe files are offered under
bullet's MIT license, as with the 6.2.0 patch. The code was written for
zigqueen. Two things come from elsewhere as ideas or numbers, not code: the
threat input follows the published idea of Stockfish's full-threat
features, and the PSQT head starts training from the conventional Stockfish
piece values (126, 781, 825, 1276 and 2538 centipawns).

## Original base network (6.0.0–6.2.0)

The original full-threat ZQB9 base network was trained with [bullet](https://github.com/jw1912/bullet)
(MIT) plus a project-specific extension that teaches bullet zigqueen's
HalfKA + full-threats input mapping. `bullet-fullthreats.patch` is that
extension as a single patch against upstream bullet commit `d372d48`:

- `crates/bullet_lib/src/game/inputs/halfka_threats.rs` (new): the input
  type — mirrored HalfKA with 8 king buckets plus the 60,144 full-threat
  features, in the index layout the engine uses (`src/eval/fullthreats.zig`);
- small hooks in `inputs.rs`, `value.rs`, `value/builder.rs`,
  `value/dataloader.rs`, `value/loader.rs` to register the input type and
  the data mixing used by the recipe;
- `examples/zqHalfKA9_fullthreats_w1024_relabel26.rs` (new): the training
  recipe of the original base network (architecture, schedule, and the data
  components listed in [NETWORK.md as of 6.2.0](https://github.com/stierms/zigqueen/blob/v6.2.0/docs/NETWORK.md); data paths are local);
- `tools/fullthreats_grader.py` (new): the reference grader that checks the
  trainer's feature indices against the engine's tables.

Apply with:

```
git clone https://github.com/jw1912/bullet && cd bullet && git checkout d372d48
git apply /path/to/bullet-fullthreats.patch
```

then add an `[[example]]` entry for `zqHalfKA9_fullthreats_w1024_relabel26`
to `crates/bullet_lib/Cargo.toml` and run it with cargo as any bullet
example. The patch is offered as documentation of provenance and for
reproducibility; it carries bullet's MIT license for the modified files.

The 6.2.0 head continuation (quantization-aware, heads only) used a later
trainer change that this patch does not include; its recipe is in
[NETWORK.md as of 6.2.0](https://github.com/stierms/zigqueen/blob/v6.2.0/docs/NETWORK.md) and the data corrections it trained on in
[data-r1/README.md](../data-r1/README.md).

*Added with 6.3.0:* `bullet-fullthreats.patch` declares
`game/inputs/combined.rs` in `inputs.rs` but does not contain that file, so
it does not compile by itself. Both 6.3.0 patches include
`crates/bullet_lib/src/game/inputs/combined.rs`; copy it from either one.
