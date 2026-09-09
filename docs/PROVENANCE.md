# Provenance and licensing record

**Updated September 9, 2026 for 6.2.0.** This record distinguishes inherited
ideas and initial parameters, local implementations and retunes, trained
weights, data transformations and redistributed third-party code.

## Why this exists

zigqueen is developed agentically (an AI assistant writes most of the code under the author's direction; see README,
"How this engine was built"). Engines built this way face a fair question from the community: what was learned from
other engines, what was taken, under which license, and is the result the author's own work? Coda's 2026-07 audit
showed what the community checks — copied tables, copied index constructions, SIMD kernels of uncertain independence,
mislabelled licenses, undisclosed parameter ports. This page answers those questions for zigqueen in advance and
will be updated when new facts come to light. Corrections from any author are welcome at
https://github.com/stierms/zigqueen/issues.

## The standard we apply

- **No copied code, no copied weights.** Source text — code, names, structure, comments — is the thing that must not
  be taken from another engine. zigqueen's engine code was written for zigqueen; where we say a subsystem "follows"
  another engine we mean the idea or the published parameter form, and we say which.
- **Distinguish concepts from implementation.** Published descriptions inform our work;
  they do not authorise copying implementation text or ignoring a source license. When we
  took not just the form but the *numbers* from a specific engine, we say so below and say what we did about it.
- **Attribution in the docs**, and license notices wherever a license asks for them.

## License landscape

| Component / source | License | How zigqueen relates to it |
|---|---|---|
| zigqueen itself | GPL-3.0-or-later (`LICENSE`), © 2026 stierms | — |
| Stormphrax 8.0.0 (Ciekce) | GPL-3.0 | Search-shaping parameter set initialised from its published defaults (§1). No code. GPL-compatible. |
| Stockfish 18 (the Stockfish developers) | GPL-3.0 | Published forms only: HalfKA-family features, SFNNv5-style layer stack, PSQT head, threat-input concept, null-move verification form, corrhist form (§2, §3). No code. Training data: see next row. |
| Stockfish project relabelled training collections (`vondele/from_kaggle_1_relabel`, `vondele/linrock_relabel_1`, `vondele/linrock_relabel_2`, `vondele/master-binpacks_relabel`, Hugging Face) | **No license stated** on the dataset cards (checked 2026-09-03); publisher and underlying LCZero/Stockfish notices are recorded in §4; upstream provenance is not independently established for every row | Training data for the shipped network (§4): published collections with local score alterations in the QAT continuation. Notice and alteration offer below. |
| `xushawn/test80-bt4-relabel` (Hugging Face) | **ODbL-1.0** | Training data (§4), the 2024 components. |
| Lc0-derived data (`leela96-filt-v2`, LCZero self-play rescored by Stockfish) | ODbL-1.0 / DBCL-1.0 (LCZero) | LCZero-derived components of the training mix (§4). ODbL notice below. |
| bullet (Jamie Whiting) | MIT | NNUE trainer, used with a full-threats input extension written for zigqueen and published as a patch (§4). Not linked into the engine. |
| Fathom (Ronald de Man, basil00, Jon Dart) | MIT | Vendored in `deps/fathom`, compiled into the engine, two local modifications (§5). |
| chessenginesupport-androidlib (gkalab) | Apache-2.0 | Vendored unmodified in `android/oex/…/com/kalab/chess/enginesupport/` for the OEX APK (§5). |
| Gradle wrapper | Apache-2.0 | `android/oex/gradle/wrapper/gradle-wrapper.jar` (§5). |
| Opening books used for testing (UHO, Stefan Pohl) | not redistributed | Used to run gauntlets only. |
| Coda (Adam Twiss) | GPL-3.0 | Studied as the model for this document; no code or constants. |
| AGPL engines (Reckless, PlentyChess, Viridithas ≥ v21, …) | AGPL-3.0 | Opponents and published conceptual research; no AGPL engine implementation is incorporated in the release (§7). |

## 1. Search shaping: a parameter set taken from Stormphrax

**What is in the tree.** `src/search/basin.zig`, shipped since 6.1.0 (2026-08-31), defines the interior LMR formula
and the null-move, late-move, reverse-futility, futility, history-pruning and SEE-pruning thresholds, the history
bonus/malus shape and the LMR re-search threshold. Its formulas and initial default constants were taken from
Stormphrax 8.0.0's published tunable defaults (Ciekce, GPL-3.0). Constants expressed in Stormphrax's evaluation units
are scaled by one factor chosen here (`UNIT_PERCENT = 25`); dimensionless terms are unchanged.

**What was not taken.** No source text. The Zig implementation and its integration with the rest of the search are
zigqueen's, and everything else in the search — time management, SEE, transposition table, eval cache, quiescence,
aspiration, probcut, singular extensions, move ordering and the history tables — uses zigqueen's own designs and
constants. The historical parameter port is confined to this policy module; the local
retune is recorded below.

**Local retuning in 6.2.0.** A zigqueen SPSA experiment selected the following
12 pruning coordinates; 11 endpoint values differ from the original
defaults. These are raw policy values before any `UNIT_PERCENT` scaling:

| Parameter | Original default | 6.2.0 |
|---|---:|---:|
| `nmp_margin_base` | 213 | 219 |
| `nmp_margin_depth_coeff` | 1281 | 1327 |
| `nmp_margin_improving_coeff` | 41 | 39 |
| `rfp_linear` | 85 | 84 |
| `rfp_quadratic` | 7 | 7 |
| `rfp_improving_coeff` | 75 | 70 |
| `history_prune_linear` | -2242 | -2482 |
| `history_prune_base` | -1315 | -1313 |
| `futility_base` | 274 | 237 |
| `futility_per_depth` | 68 | 71 |
| `see_quiet_coeff` | -20 | -21 |
| `see_noisy_per_depth` | -111 | -116 |

The before/after values can be checked in the public release history.
The experiment used zigqueen match results, not another engine's updated
parameter values. The initial parameter choice and formula lineage remain
Stormphrax's; unchanged LMR/history and other defaults are still inherited.
This is a partial local retune, not a claim that the complete policy was
independently derived. The Zig implementation, integration, guards and
score-unit calibration remain zigqueen work. Both projects publish under
GPL terms; this attribution is retained independently of the retune.

## 2. NNUE evaluation: published forms, our own implementation

- **Feature transformer.** Mirrored HalfKA with 8 king buckets (each perspective's own king; files e–h mirrored onto
  a–d; black's frame rank-flipped), width 1024, i16 accumulators. The bucket layout (rank 1 split a-b/c-d, rank 2
  split, then ranks 3, 4, 5–6, 7–8) is the common 8-bucket layout used by many bullet-trained engines
  (it is not the layout of bullet's bundled examples, which use ten buckets); it is stored in the net header, not
  hard-coded in the engine.
- **Layer stack and PSQT head.** SFNNv5-style: clipped ReLU + pairwise multiply on the accumulator halves,
  `1024 → 16` (i8) → squared-clipped-ReLU → `16 → 32` → `32 → 1`, eight material buckets, plus a per-feature PSQT head
  shared across the eight nonlinear output buckets. These are Stockfish's published network shapes.
- **Inference.** Written in Zig with portable `@Vector` SIMD (AVX-512 / AVX2 / NEON with a scalar fallback;
  bit-exact across targets). The incremental machinery — lazy accumulator materialisation, the accumulator-refresh
  ("finny") cache, the threat-delta engine with barrier records for king-orientation changes — is zigqueen's design.
  No kernel was modelled on another engine's; inference is checked against an independent reference calculation.

## 3. Threat features: a public feature set, our own index layout

The network's second input family is the "full threats" set of 60,144 sparse attacker/target relations: a feature is
(attacker coloured type, attacker square, victim coloured type, victim square) with attackers P N B R Q, king
victims removed, and the subset-redundant pairs (p→b, p→q, b→q, r→q) removed. This is the "SFNNv12-style" set whose
composition is public: Stockfish's nnue-pytorch documentation describes the FullThreats set and its deduplication
rules, and Stormphrax's PR #293 pins the 60,144 count ("no threats to or from the king"). The idea's lineage —
Monty → yukari → PlentyChess → Stockfish SFNNv10 → Reckless / Stormphrax / Viridithas / Hobbes — is public and belongs
to no single engine.

The **membership** of the set is therefore necessarily identical to other engines' (there is one way to write
"which piece pairs are kept"). The **index layout** — the order in which the 60,144 slots are assigned — is our own
(attacker → attacker square → target position within the attacker's empty-board attack set → victim class), frozen
in a written specification before training, and differs from both the Stockfish and Stormphrax layouts (which order
attacker → victim class → square pair). The activation rule also deviates from Stockfish's (both directions of a
mutual same-type pair activate). The feature space was re-derived arithmetically from the public descriptions
(84/336/560/896/1456 empty-board attack pairs per type; 2 × 30,072) without reading any engine's threat-feature
source; the engine's comptime tables and the trainer-side grader were written independently of each other and are
checked against one another bit-for-bit.

The 5.x networks used a smaller 7,680-input "lean" threat set of our own design (attacker square dropped); it is
no longer shipped.

## 4. The network: weights and data

- **Weights.** The original full-threat base was trained from random
  initialisation on the author's RTX 4090. The 6.2.0 network adds a QAT
  continuation on the RTX 5080, training only its nonlinear heads. Feature
  transformer and PSQT bytes are unchanged. No third-party network weights
  were used for initialisation, fine-tuning or logit distillation.
- **Trainer.** bullet (MIT) with locally written feature mapping, loading,
  recipe and deployed-arithmetic training extensions. The published
  `docs/trainer/bullet-fullthreats.patch` documents the original base
  extension against `d372d48`; it does not include the later QAT extension.
  [NETWORK.md](NETWORK.md) records the continuation recipe and model hashes.
- **Data.** Twenty-seven published components, with exact source families
  listed in [NETWORK.md](NETWORK.md). Publisher metadata identifies
  Stockfish-project relabels, including BT4 teacher labels. Twenty-six
  components have LCZero-derived position ancestry; the generation ancestry
  of `wrongIsRight_nodes5000pv2` remains unresolved in our audit. We have
  not reconstructed each row's upstream teacher execution or certified
  source-family independence.
- **Local changes.** The original base used the published-label corpus.
  The later QAT continuation used a prefix of its local `r1` version:
  selected tablebase and decisive-anchor score replacements, preserving
  position, move and game-result fields. The previous statement that the
  shipped model involved no local relabelling was incomplete for 6.2.0.
  Own self-play generation did not supply positions to this release.
- **ODbL notice and alterations.** Parts of the training data are made
  available by the Stockfish project and LCZero under the
  [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/),
  with LCZero individual contents under
  [DBCL 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
  We retain attribution for the trained network and provide the recorded
  local alterations, additional score contents and replay method free of
  charge in [data-r1/README.md](data-r1/README.md). Database alterations are
  offered under ODbL-1.0, with our individual additional contents under
  DBCL-1.0. We do not rely on the earlier assertion that distributing only
  a trained network always removes derivative-database obligations.

## 5. Third-party code compiled or packaged with zigqueen

- **Fathom** (`deps/fathom`, MIT): Syzygy tablebase prober by Ronald de Man, basil00 and Jon Dart, vendored from
  `github.com/jdart1/Fathom` (the unmodified files match upstream commit `c9c6fef`, 2025-12-23). Two local changes in
  `tbprobe.c`, both marked
  `/* zigqueen: … */`: a table that cannot be mapped into memory is treated as a probe miss instead of terminating the
  engine, and an allocation failure disables tablebases instead of exiting. The MIT notice is kept in every source
  header and reproduced in `THIRD_PARTY_LICENSES.md`, which ships in every binary archive.
- **chessenginesupport-androidlib** (Apache-2.0, gkalab): the reference OEX provider implementation, vendored
  unmodified for the Android APKs; license text in `THIRD_PARTY_LICENSES.md` and in the APK.
- **Gradle wrapper** (Apache-2.0): standard build tooling in `android/oex`.
- The Zig build declares no package dependencies; nothing else is linked.

## 6. Conventional tables and constants

Magic bitboard numbers were generated locally by brute-force search (the 2 MB attack table is generated from them
and checked against a stepping reference). Zobrist keys come from a splitmix64 generator with fixed seeds. Piece
values for SEE are the textbook 100/320/330/500/900. None of these were taken from another engine.

## 7. Reference-engine policy

- Published conceptual research may inform independent implementations;
  an engine's license is not permission to copy its code into this project.
  The strict no-copy rule includes the author's earlier private engines.
- We do not claim that AGPL source has never existed anywhere on a
  development machine. Historical research workspaces are distinct from
  code incorporated in this release. No AGPL engine implementation is
  vendored, linked or translated into zigqueen's released engine.
- Parameter origins are disclosed even when later tuned locally (§1).
- Six opening-book root moves (`src/search/opening_book.zig`, present from the first public release 5.8.0 through
  6.1.0) were chosen with Stockfish analysis of a test opening set. We record that use
  because our rules say other engines are opponents, not oracles. Removed in 6.1.1, which is 6.1.0 without those
  entries and otherwise identical.

## 8. Repository structure and git history

The public repository starts at 5.8.0 as a release snapshot. Subsequent
public commits record changes, including removals; the six-move book was
removed in 6.1.1. Releases are prepared on that public history, without
publishing the private development history or experiment workspaces.
The licensed vendored components are listed above.

## 9. How the engine was built

The author develops zigqueen with AI assistants, including Claude and
Codex. Assistants write and review code under human direction; the author
sets scope and decides releases. Correctness gates precede match testing.
The ladder uses screening, SPRT and external validation; not every accepted
small effect reached an SPRT boundary. [STRENGTH.md](STRENGTH.md) records
the evidence and acceptance limits for this release.

Corrections supported by specific source or artifact evidence are welcome
at https://github.com/stierms/zigqueen/issues.

## Record updates

- September 2026: initial parameter, architecture, training-data and
  vendored-license disclosure; internal opening book removed in 6.1.1.
- September 9, 2026: exact local pruning retunes; QAT model lineage and
  local data alteration offer; corrected single-PSQT description and
  overly broad claims about training labels, workstation contents,
  repository removals and universal SPRT acceptance.
