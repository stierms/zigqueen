# Trainer extensions (bullet patches)

zigqueen's networks are trained with [bullet](https://github.com/jw1912/bullet)
(MIT, Jamie Whiting) plus changes written for zigqueen. This directory
publishes those changes as patches against upstream bullet commit `d372d48`,
so that anyone can see how the shipped networks were trained and build the
same trainer programs. The patches carry bullet's MIT license.

| Patch | Network | What it builds |
|---|---|---|
| `bullet-bt4-full.patch` | 6.3.0 | `zq_bt4_full`: main run, finish, checkpoint averaging, resume |
| `bullet-bt4-head-qat.patch` | 6.3.0 | `zq_bt4_head_qat`: head-only QAT stage |
| `bullet-fullthreats.patch` | 6.0.0–6.2.0 | the original base network's recipe |

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
numbers are in [NETWORK.md](../NETWORK.md).

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
  weights are identified by their SHA-256 in [NETWORK.md](../NETWORK.md).

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
  components listed in `../NETWORK.md`; data paths are local);
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
[NETWORK.md](../NETWORK.md) and the data corrections it trained on in
[data-r1/README.md](../data-r1/README.md).

*Added with 6.3.0:* `bullet-fullthreats.patch` declares
`game/inputs/combined.rs` in `inputs.rs` but does not contain that file, so
it does not compile by itself. Both 6.3.0 patches include
`crates/bullet_lib/src/game/inputs/combined.rs`; copy it from either one.
