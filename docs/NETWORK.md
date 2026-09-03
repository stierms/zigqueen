# The network: data, training, and provenance

zigqueen has shipped the `zqHalfKA9` full-threats network in the engine's
`ZQB9` container since 6.0.0; 6.1.0 ships it unchanged. This page records
what the network is, how it was trained,
and what was not used to produce its weights.

| | |
|---|---|
| **Training data** | Publicly published Stockfish NNUE training datasets |
| **Trainer** | [bullet](https://github.com/jw1912/bullet), extended for zigqueen's full-threat feature set (the extension is published as [`trainer/bullet-fullthreats.patch`](trainer/README.md)) |
| **Architecture** | 8-bucket mirrored HalfKA + 60,144 full-threat inputs; width 1024; `1024 -> 16 -> 32 -> 1` layer stack in each of 8 output buckets |
| **Weights** | Trained from random initialisation |
| **Engine format** | `ZQB9`, 74.6 MB embedded net, default scale 48 |
| **Engine inference** | Written from scratch in Zig and checked against independent reference calculations |

## Training data

The Stockfish project and its contributors publish NNUE training datasets.
The shipped network was trained on twenty-seven published components,
interleaved:

- `leela96-filt-v2` (split 0) — LCZero self-play positions rescored by
  Stockfish;
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
(wrongIsRight). No license is stated on the `vondele` collections; the
underlying game data comes from Stockfish's fishtest runs
(`official-stockfish/master-binpacks`, ODbL-1.0) and, for leela96, from
LCZero self-play (ODbL/DBCL).

The rows are played-out positions carrying a game result and an evaluation
label; the labels in these collections are the Stockfish project's
relabels, produced by its `BT4-tf13tune` teacher (an LCZero transformer
network), not the original search scores. zigqueen used the files as
published, re-chunked for its loader; no relabelling of our own. Components
are checked for unit consistency and interleaved so that one dataset
vintage does not dominate a section of the schedule.
zigqueen's own self-play data generator did not contribute to the shipped
network.

**Notice (ODbL).** Parts of the training data are made available under the
Open Database License (http://opendatacommons.org/licenses/odbl/1.0/) by the
Stockfish project and, for the Lc0-derived component, by the LCZero project,
with rights in the individual contents under the Database Contents License
(http://opendatacommons.org/licenses/dbcl/1.0/). The trained network is a
"Produced Work" under the ODbL; zigqueen distributes the network, never the
databases.

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
