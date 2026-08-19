# The network: data, training, and provenance

zigqueen 6.0.0 ships the `zqHalfKA9` full-threats network in the engine's
`ZQB9` container. This page records what the network is, how it was trained,
and what was not used to produce its weights.

| | |
|---|---|
| **Training data** | Publicly published Stockfish NNUE training datasets |
| **Trainer** | [bullet](https://github.com/jw1912/bullet), extended for zigqueen's full-threat feature set |
| **Architecture** | 8-bucket mirrored HalfKA + 60,144 full-threat inputs; width 1024; `1024 -> 16 -> 32 -> 1` layer stack in each of 8 output buckets |
| **Weights** | Trained from random initialisation |
| **Engine format** | `ZQB9`, 74.6 MB embedded net, default scale 48 |
| **Engine inference** | Written from scratch in Zig and checked against independent reference calculations |

## Training data

The Stockfish project and its contributors publish NNUE training datasets.
zigqueen trains on selections from those published corpora, including:

- [`official-stockfish/master-binpacks`](https://huggingface.co/official-stockfish/master-binpacks)
- [`linrock/test80-2023`](https://huggingface.co/datasets/linrock/test80-2023)
- [`linrock/test80-2024`](https://huggingface.co/datasets/linrock/test80-2024)
- the corresponding published test78, test79, and test60 collections

The rows are played-out self-play positions carrying a search evaluation and
game result. Components are checked for unit consistency and interleaved so
that one dataset vintage does not dominate a section of the schedule.

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
from another engine's weights or logits. [`CLEAN_ROOM_RULES.md`](../CLEAN_ROOM_RULES.md)
states the repository's implementation boundary.
