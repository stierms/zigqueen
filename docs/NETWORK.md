# The network: data, training, and provenance

zigqueen has shipped the `zqHalfKA9` full-threats network in the engine's
`ZQB9` container since 6.0.0. Version 6.2.0 adds a head-only QAT continuation. This page records
what the network is, how it was trained,
and what was not used to produce its weights.

| | |
|---|---|
| **Training data** | Publicly published Stockfish NNUE training datasets |
| **Trainer** | [bullet](https://github.com/jw1912/bullet), extended for zigqueen's full-threat feature set (the extension is published as [`trainer/bullet-fullthreats.patch`](trainer/README.md)) |
| **Architecture** | 8-bucket mirrored HalfKA + 60,144 full-threat inputs; width 1024; `1024 -> 16 -> 32 -> 1` layer stack in each of 8 output buckets |
| **Weights** | Original base trained from random initialisation; local head-only QAT continuation for 6.2.0 |
| **Engine format** | `ZQB9`, 74.6 MB embedded net, default scale 48 |
| **Engine inference** | Written from scratch in Zig and checked against independent reference calculations |

## Training data

The Stockfish project and its contributors publish NNUE training datasets.
The shipped network was trained on twenty-seven published components,
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

The original base used the published evaluation labels. The 6.2.0 head
continuation used a prefix of the locally corrected `r1` corpus. It
preserves positions, moves and game results while applying recorded
tablebase and decisive-anchor score replacements. Components are
interleaved by byte share. This is not a certified family-disjoint or
globally deduplicated training corpus. Own self-play generation supplied
no positions to the released network.

**ODbL notice.** Parts of these data are made available by the Stockfish
project and LCZero under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
with LCZero contents under [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
The local alterations, additional contents and replay method are offered
free of charge in [data-r1/README.md](data-r1/README.md).

## Trainer and training origin

Stockfish trains its own networks with `nnue-pytorch`. zigqueen uses bullet,
an independent open-source NNUE trainer, plus a project-specific extension
that teaches bullet the 60,144-input full-threat mapping.

The 6.0.0 network was trained **from scratch**, starting from random weights.
Its weights were never:

- initialized from a Stockfish or other third-party network;
- fine-tuned from third-party network weights; or
- distilled logit-wise from Stockfish network outputs.

Stockfish's contribution here is the openly published training data. The
network weights, feature mapping, trainer extension, quantization, and Zig
inference path are zigqueen work.

## 6.2.0 head continuation

The base model SHA-256 is
`c23ef305f8015c9d3e88765c8f43a082ce3cb0e4c8f25a568123df199301a932`.
The released model SHA-256 is
`94da6682065a862dac0af63779ee39055553ba507a21ecd7b10bbe15dbab4a16`.
Both are 74,587,732 bytes. Only nonlinear head tensors change;
feature-transformer and PSQT contents remain byte-identical.

The recorded continuation used 1,073,741,824 training occurrences,
65,536 updates of 16,384 rows, learning rate 0.00001, seed 62020727,
and target `0.9 × sigmoid(score/400) + 0.1 × game_result`.
It used a common 120-file prefix of the `r1` interleave, a 4 GiB shuffle
buffer and 16 windows. QAT models the deployed quantization, floored pair
products and integer head evaluation. Optimizer state was fresh; only
`l1`, `l2` and `l3` weights/biases were trainable.

The published bullet feature patch describes the original base training,
not a complete reconstruction of this continuation. Match evidence is
reported in [STRENGTH.md](STRENGTH.md), separately from training loss.

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
