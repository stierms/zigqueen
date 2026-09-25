# The network: data, training, and provenance

zigqueen has shipped a `zqHalfKA9` full-threats network in the engine's
`ZQB9` container since 6.0.0. 6.3.0 ships a new one with the same
architecture, trained from scratch on a wider set of published data. The
6.0.0–6.2.0 network is described further down.

| | |
|---|---|
| **Training data** | 42 published, relabelled components of Stockfish and LCZero training data |
| **Trainer** | [bullet](https://github.com/jw1912/bullet), extended for zigqueen's full-threat feature set; the extensions are published as patches in [`trainer/`](trainer/README.md) |
| **Architecture** | 8-bucket mirrored HalfKA + 60,144 full-threat inputs; width 1024; `1024 -> 16 -> 32 -> 1` layer stack in each of 8 output buckets |
| **Weights** | 6.3.0: trained from seeded random initialisation, then a head-only QAT stage |
| **Engine format** | `ZQB9`, 74.6 MB embedded net, default scale 48 |
| **Engine inference** | Written from scratch in Zig and checked against independent reference calculations |

## 6.3.0 network

| | |
|---|---|
| Released model | SHA-256 `a63732096ec9f2afdb0e18ddf09a7a04b6cdd5c1b6c8844b200afaf48f9da731` |
| Averaged model before QAT | SHA-256 `9066cabe9e9aee4a41158a0b744b35b54a843d98e29f4f012bf58206116e825b` |
| Size | 74,587,732 bytes, both |
| Initialisation | seeded random weights (seed 62020914); nothing taken from the 6.2.0 network or any other network |
| Positions | 131,124,072,315 admitted training positions from 42 components, not deduplicated across components; 7,998,177 held out by position key |
| Main schedule | 4,721 superbatches of 100,007,936 samples, cosine learning rate 0.001 → 2.43e-6 |
| Finish | 1,181 further superbatches, cosine 2.43e-6 → 2.43e-7; 590,246,838,272 samples in all, about 4.5 passes |
| Averaging | mean of 13 checkpoints from the last quarter of the finish (superbatches 5,621 to 5,902) |
| QAT | dense head tensors only, 65,536 updates × 16,384 rows = 1,073,741,824 samples, learning rate 1e-5, fresh optimizer state; feature transformer and PSQT bytes unchanged by this stage |
| Target | `0.9 × sigmoid(0.92568 × score / 400) + 0.1 × game_result` |

Components are sampled by quota, not by file size. The
score in the target is the published teacher score in centipawns; where our
older copies stored it pre-multiplied by a per-source factor, the original
integer is reconstructed (at most 0.5 cp error). The single factor 0.92568
keeps our existing score scale; it was fixed in advance, not tuned for
strength.

Self-play against the 6.2.0 network, same engine code: +10.8 ± 7.5 Elo at
8s+0.08s (2,554 games) and +7.9 ± 6.0 Elo at 60s+0.6s (3,368 games), SPRT H1
at both. Match evidence is in [STRENGTH.md](STRENGTH.md).

### 6.3.0 training data

All 42 components are published *relabelled* collections on Hugging Face,
scored with Leela BT4 evaluations:

- [`vondele/from_kaggle_1_relabel`](https://huggingface.co/datasets/vondele/from_kaggle_1_relabel):
  `leela96-filt-v2`, splits 0–4 (6.2.0 used split 0 only);
- [`vondele/from_kaggle_2_relabel`](https://huggingface.co/datasets/vondele/from_kaggle_2_relabel):
  the `T60T70wIsRightFarseerT60T74T75T76` blend, splits 0–4 (new);
- [`vondele/linrock_relabel_1`](https://huggingface.co/datasets/vondele/linrock_relabel_1):
  `test60` 2021-11 and 2021-12, `test77` 2021-12 (new), `test78` 2022-01 to
  2022-09, `test79` 2022-04 and 2022-05, `test80` 2022-06 to 2022-11;
- [`vondele/linrock_relabel_2`](https://huggingface.co/datasets/vondele/linrock_relabel_2):
  `test80` 2023-01 to 2023-12;
- [`vondele/master-binpacks_relabel`](https://huggingface.co/datasets/vondele/master-binpacks_relabel):
  `wrongIsRight_nodes5000pv2`, plus `dfrc_n5000`, `fishpack32`,
  `multinet_pv-2_diff-100_nodes-5000` and `nodes5000pv2_UHO` (new);
- [`xushawn/test80-bt4-relabel`](https://huggingface.co/datasets/xushawn/test80-bt4-relabel):
  `test80` 2024-01 and 2024-02 (ODbL-1.0).

The `xushawn` card declares ODbL-1.0. The `vondele` cards state no license;
their sources are the LCZero training data (ODbL-1.0, individual contents
DbCL-1.0) and the Stockfish project's published binpacks (ODbL-1.0), and some
original Kaggle uploads also carry CC0 declarations. We treat the relabelled
copies as continuing their sources' ODbL terms. We credit the LCZero
contributors, Linmiao Xu (linrock), Joost VandeVondele (vondele), the
Stockfish data contributors, xushawn and the contributors to the community
BT4 relabelling. No self-play positions went into the network.

**ODbL notice.** Parts of these data are made available by the Stockfish
project and LCZero under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
with LCZero contents under [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
We relabelled nothing, but we did change how these data reach the network:
the choice of files, local copies of 37 of them that store each score
multiplied by a per-source factor, reconstruction of the published score from
those copies, the position filter, a holdout by position key, per-component
quotas and the conversion of scores into targets with the common factor.
[data-r2/README.md](data-r2/README.md) lists each change with its rule and
totals, and the release asset `zigqueen-training-data-r2-alterations.tar.xz` on
the [6.3.0 release](https://github.com/stierms/zigqueen/releases/tag/v6.3.0)
holds the manifests, indexes, tables and code to repeat them. Both are free of
charge. The derivative database and our alterations are offered under
ODbL-1.0, individual contents under DbCL-1.0. The `r1` archive below covers
the 6.2.0 network only.

**Trainer changes.** The bullet changes that trained this network are
published in [trainer/](trainer/README.md) as two patches against the same
upstream commit as before (`d372d48`): `bullet-bt4-full.patch` for the main
run, the finish, checkpoint averaging and resuming, and
`bullet-bt4-head-qat.patch` for the head-only QAT stage. Applied to a clean
bullet checkout, each reproduces byte for byte the bullet source files its
training program was built from. The main run was interrupted and resumed
four times, each time from a checksummed checkpoint that holds the optimizer
state, the data position and the running average; the trainer refuses to
resume if any setting or the program itself has changed. The data loader
that samples the 42 components is zigqueen's own code rather than a bullet
change, and is published with the data offer above. GPU training is not
bitwise repeatable, so rebuilding the trainer gives the same programs, not
these exact weights.

## Trainer and training origin

Stockfish trains its own networks with `nnue-pytorch`. zigqueen uses bullet,
an independent open-source NNUE trainer, plus a project-specific extension
that teaches bullet the 60,144-input full-threat mapping.

Both zigqueen network lineages were trained **from scratch**, starting from
random weights: the 6.0.0 base, and the 6.3.0 network from a new seed. Their
weights were never:

- initialized from a Stockfish or other third-party network;
- fine-tuned from third-party network weights; or
- distilled logit-wise from Stockfish network outputs.

The contribution of Stockfish, LCZero and the relabelling contributors is the
openly published training data. The network weights, feature mapping, trainer
extension, quantization, and Zig inference path are zigqueen work.

## The 6.0.0–6.2.0 network

### Training data

The Stockfish project and its contributors publish NNUE training datasets.
The 6.0.0–6.2.0 network was trained on twenty-seven published components,
interleaved:

- `leela96-filt-v2` (split 0) — LCZero-derived positions from the
  published relabel collection;
- `test60` 2021-11 and 2021-12;
- `test78` 2022-01 to 2022-09;
- `test79` 2022-04 and 2022-05;
- `test80` monthly, 2022-06 to 2024-02;
- `wrongIsRight_nodes5000pv2`.

All 27 components are the Stockfish project's published *relabelled*
training collections on Hugging Face, the diet its own master networks are
trained on (Stockfish's `threats.yaml`):
[`vondele/from_kaggle_1_relabel`](https://huggingface.co/datasets/vondele/from_kaggle_1_relabel)
(leela96),
[`vondele/linrock_relabel_1`](https://huggingface.co/datasets/vondele/linrock_relabel_1)
(test60, test78, test79, test80 2022),
[`vondele/linrock_relabel_2`](https://huggingface.co/datasets/vondele/linrock_relabel_2)
(test80 2023),
[`xushawn/test80-bt4-relabel`](https://huggingface.co/datasets/xushawn/test80-bt4-relabel)
(test80 2024; ODbL-1.0) and
[`vondele/master-binpacks_relabel`](https://huggingface.co/datasets/vondele/master-binpacks_relabel)
(wrongIsRight). The `vondele` dataset cards did not state a license at the recorded
September 3 check. Underlying publisher notices include Stockfish's
ODbL data and LCZero's ODbL/DBCL data. Twenty-six components have
LCZero-derived position ancestry; `wrongIsRight` ancestry remains unresolved.
Publisher teacher metadata is inherited attribution, not a verified
per-row teacher execution record.

The 6.0.0 base was trained on the published labels. The 6.2.0 head
continuation used a prefix of a locally corrected copy (`r1`): positions,
moves and game results unchanged, tablebase and decisive-anchor scores
replaced where recorded. Components are interleaved by byte share. The
corpus is not deduplicated or certified family-disjoint. No self-play
positions went into the released network.

**ODbL notice.** Parts of these data are made available by the Stockfish
project and LCZero under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
with LCZero contents under [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
The local alterations, additional contents and replay method are offered
free of charge in [data-r1/README.md](data-r1/README.md).

### 6.2.0 head continuation

| | |
|---|---|
| Base model (6.0.0) | SHA-256 `c23ef305f8015c9d3e88765c8f43a082ce3cb0e4c8f25a568123df199301a932` |
| Released model | SHA-256 `94da6682065a862dac0af63779ee39055553ba507a21ecd7b10bbe15dbab4a16` |
| Size | 74,587,732 bytes, both |
| Changed | dense head tensors only (`l1`, `l2`, `l3` weights and biases); feature transformer and PSQT byte-identical |
| Data | 120-file prefix of the `r1` interleave, 1,073,741,824 positions, 4 GiB shuffle buffer, 16 windows |
| Schedule | 65,536 updates × 16,384 rows, learning rate 1e-5, seed 62020727, fresh optimizer state |
| Target | `0.9 × sigmoid(score/400) + 0.1 × game_result` |
| QAT | forward pass models the deployed quantization, floored pair products and integer head evaluation |

The published bullet patch covers the original base training, not this
continuation. Match evidence is in [STRENGTH.md](STRENGTH.md), separate from
training loss.

## Architecture

The `zqHalfKA9` network combines two sparse input families per perspective:

- **Mirrored HalfKA.** Eight king buckets; files e-h mirror onto a-d. Each
  side selects a bucket in its own oriented frame.
- **Full threats.** 60,144 sparse attacker/target relation inputs, retaining
  the richer relation set used by the v6 architecture rather than the 7,680
  lean-threat inputs shipped in the 5.x network.

Those inputs feed a width-1024 feature transformer. The readout is a
material-bucketed layer stack with eight buckets, each
`1024 -> 16 -> 32 -> 1`, plus the network's PSQT head. Integer weights and
activations are quantized in the `ZQB9` file format.

The engine maintains HalfKA and full-threat accumulator state incrementally.
Threat relationships are non-local—a move may create or remove attacks away
from its source and destination—so the runtime uses a dedicated threat-delta
engine, lazy materialization, and refresh barriers for king-orientation
changes. Integer inference is designed to be bit-exact across supported
x86-64 and AArch64 release targets.

## Validation

The feature mapping and incremental path are tested against full refreshes,
including castling, en passant, promotions, king-bucket changes, and mirrored
positions. Release builds must also agree on fixed-depth search node counts
and on the standard evaluation probe suite.

Candidate networks are screened for color symmetry and material ordering,
then judged by match play; training loss alone does not decide promotion.

## Clean-room boundary

The engine source contains no copied functions or mechanical translations
from Stockfish or another engine. The network's weights likewise do not come
from another engine's weights or logits. [`ORIGINALITY.md`](../ORIGINALITY.md)
states the repository's implementation boundary and
[`PROVENANCE.md`](PROVENANCE.md) the full provenance and licensing record.
