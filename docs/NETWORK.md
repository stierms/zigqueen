# The network

zigqueen ships one network, embedded in the binary. It was trained from
random weights on public, relabelled Stockfish and LCZero training data and
finished with quantization-aware training (QAT) of the whole network.

| | |
|---|---|
| File | `src/eval/default_net.zqb`, format `ZQBA`, 88,724,892 bytes, SHA-256 `1342ac4691324a632418d6e1fc8696807c364d9a8bb63fbbc9b74e771cf1ffac` |
| Inputs | mirrored HalfKA with 16 king buckets; 60,144 threat features; 1,488 pawn-pair features (1,278 live) |
| Network | feature transformer width 1024; eight material buckets, each `1024 → 16 → 32 → 1`; PSQT head |
| Quantization | HalfKA rows i16; threat and pawn-pair rows i8; `l1` i8 |
| Data | 42 published relabelled components, 131,124,072,315 admitted positions (see Training data) |
| Trainer | [bullet](https://github.com/jw1912/bullet) with our patches ([trainer/](trainer/README.md)) |
| Default scale | `NNUE Scale Percent` 44 |

## Inputs

**King buckets.** Each perspective picks its bucket from its own king square,
with files e–h mirrored onto a–d and black's frame rank-flipped:

| Own-king rank | a | b | c | d |
|---|---|---|---|---|
| 1 | 0 | 1 | 2 | 3 |
| 2 | 4 | 5 | 6 | 7 |
| 3 | 8 | 8 | 9 | 9 |
| 4 | 10 | 10 | 11 | 11 |
| 5–6 | 12 | 12 | 13 | 13 |
| 7–8 | 14 | 14 | 15 | 15 |

**Threats.** A feature is (attacker, attacker square, victim, victim square)
for an attack under the current occupancy: attackers are pawns to queens,
kings are never victims, and the redundant pairs pawn→bishop, pawn→queen,
bishop→queen and rook→queen are left out. Both directions of a mutual attack
count. The index layout is our own ([PROVENANCE.md](PROVENANCE.md) §3).

**Pawn pairs (PP1).** An unordered pair of pawns of either colour on ranks 2–7
whose files differ by at most one, in the same frame as the other inputs:
480 same-file rows and 1,008 adjacent-file rows. The 210 rows that duplicate
a pawn-on-pawn threat feature stay zero, leaving 1,278 live rows, at most 120
active per perspective. The rows depend on the mirror but not on the king
bucket. `ZQBA` is the `ZQB9` layout plus two header words and the appended
pawn-pair weights and PSQT entries; `ZQB9` networks still load through
`EvalFile`.

## Training

| | |
|---|---|
| Initialization | seeded random weights (seed 62020914); nothing taken from any other network |
| Float run | 5,902 superbatches of 100,007,936 samples: 4,721 with cosine learning rate 0.001 → 2.43e-6, then 1,181 with cosine → 2.43e-7 |
| QAT | 330 superbatches (33,002,618,880 samples) continuing the float run's weights and Adam state; every layer runs through the engine's integer arithmetic with straight-through gradients; cosine 2.43e-6 → 2.43e-7; threat and pawn weights clamped to ±126 deployed |
| Endpoint | superbatch 330, fixed in advance; no checkpoint averaging |
| Target | `0.9 × sigmoid(0.92568 × score / 400) + 0.1 × game_result` |
| Scale | 44, from a fixed rule matching the evaluation spread of the previous network |
| Compute | one RTX 5080: float run 375,179 s, QAT 37,642 s |

Without full-network QAT the export loses accuracy: for `v2`, the same float
run finished with head-only QAT, held-out MSE rose 2.8% from float to
deployed, mostly in the feature transformer. The shipped network's deployed
held-out MSE is 1.9% below `v2`'s.

At export, the engine's evaluation equals an exact reference built from the
trainer's feature lists on 3,934 positions (0 mismatches, AVX2 and AVX-512
builds), and a range check rules out overflow of any deployed weight or
accumulator sum.

## Training data

All 42 components are published relabelled collections on Hugging Face,
scored with Leela BT4 evaluations:

- [`vondele/from_kaggle_1_relabel`](https://huggingface.co/datasets/vondele/from_kaggle_1_relabel):
  `leela96-filt-v2`, splits 0–4;
- [`vondele/from_kaggle_2_relabel`](https://huggingface.co/datasets/vondele/from_kaggle_2_relabel):
  the `T60T70wIsRightFarseerT60T74T75T76` blend, splits 0–4;
- [`vondele/linrock_relabel_1`](https://huggingface.co/datasets/vondele/linrock_relabel_1):
  `test60` 2021-11 and 2021-12, `test77` 2021-12, `test78` 2022-01 to
  2022-09, `test79` 2022-04 and 2022-05, `test80` 2022-06 to 2022-11;
- [`vondele/linrock_relabel_2`](https://huggingface.co/datasets/vondele/linrock_relabel_2):
  `test80` 2023-01 to 2023-12;
- [`vondele/master-binpacks_relabel`](https://huggingface.co/datasets/vondele/master-binpacks_relabel):
  `wrongIsRight_nodes5000pv2`, `dfrc_n5000`, `fishpack32`,
  `multinet_pv-2_diff-100_nodes-5000` and `nodes5000pv2_UHO`;
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

Components are mixed by quota. 7,998,177 positions are held out by position
key (admission index SHA-256 `e9e87c68…`). Where our local copies store a
score multiplied by a per-source factor, the published integer score is
reconstructed (at most 0.5 cp error). The float run read 590,246,838,272
presentations of one shuffled stream; QAT read two reshuffled passes over its
first 21 billion records.

**ODbL notice.** Parts of these data are made available by the Stockfish
project and LCZero under [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
with LCZero contents under [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
We relabelled nothing, but we changed how the data reach the network: the
choice of files, local copies of 37 of them with scaled scores, score
reconstruction, the position filter, the holdout, the quotas and the target
conversion. [data-r2/README.md](data-r2/README.md) lists each change, and the
release asset `zigqueen-training-data-r2-alterations.tar.xz` holds the
manifests, indexes, tables and code to repeat them, free of charge, under
ODbL-1.0 (individual contents DbCL-1.0). The `data-r1` offer
([data-r1/README.md](data-r1/README.md)) covers the 6.0.0–6.2.0 network.

## Trainer

The float run used `bullet-v2.patch` and QAT `bullet-v2-extend.patch`, both
against upstream bullet `d372d48` and published in [trainer/](trainer/README.md)
with the export script `tools/v2_net.py`, which reproduces the released file
byte for byte from the trainer's output. The data loader is our own code,
published with the data offer. GPU training is not bitwise repeatable, so
retraining gives the same programs, not these exact weights.

## Clean-room boundary

Every zigqueen network lineage started from random weights; later stages
(the 6.2.0 head, QAT) continued our own runs. None was initialized from,
fine-tuned from or distilled from Stockfish's or any other network.
The contribution of Stockfish, LCZero and the relabellers is the published
training data; the weights, feature mapping, trainer patches, quantization
and Zig inference are zigqueen's. [ORIGINALITY.md](../ORIGINALITY.md) states
the implementation rules and [PROVENANCE.md](PROVENANCE.md) the full record.

## Earlier networks

| Versions | Format | Architecture | Data | SHA-256 | Details |
|---|---|---|---|---|---|
| 6.4.0, 6.5.0 | `ZQBA` | this network | as above | `1342ac46…` | this page |
| 6.3.0 | `ZQB9`, 74,587,732 bytes | 8 king buckets, 60,144 threats, width 1024, no pawn pairs | the same 42 components; head-only QAT after checkpoint averaging | `a6373209…` | [v6.3.0 NETWORK.md](https://github.com/stierms/zigqueen/blob/v6.3.0/docs/NETWORK.md) |
| 6.0.0–6.2.0 | `ZQB9`, 74,587,732 bytes | as 6.3.0 | 27 relabelled components; 6.2.0 retrained the head on a locally corrected copy (`r1`, [data-r1](data-r1/README.md)) | 6.0.0 `c23ef305…`, 6.2.0 `94da6682…` | [v6.2.0 NETWORK.md](https://github.com/stierms/zigqueen/blob/v6.2.0/docs/NETWORK.md) |
