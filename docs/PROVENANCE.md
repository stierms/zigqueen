# Provenance and licensing record

**Status:** first version, September 2026, covering the 6.1.0 release. Every statement here can be checked against
the public tree and the referenced sources. This is an engineering statement, not legal advice; it is updated when
new facts come to light (dated list at the end).

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
- **Published forms are shared property.** Search techniques, NNUE architectures, feature-set definitions, training
  recipes and tuning constants are ideas and functional facts; re-implementing them is normal and expected. When we
  took not just the form but the *numbers* from a specific engine, we say so below and say what we did about it.
- **Attribution in the docs**, and license notices wherever a license asks for them.

## License landscape

| Component / source | License | How zigqueen relates to it |
|---|---|---|
| zigqueen itself | GPL-3.0-or-later (`LICENSE`), © 2026 stierms | — |
| Stormphrax 8.0.0 (Ciekce) | GPL-3.0 | Search-shaping parameter set initialised from its published defaults (§1). No code. GPL-compatible. |
| Stockfish 18 (the Stockfish developers) | GPL-3.0 | Published forms only: HalfKA-family features, SFNNv5-style layer stack, PSQT head, threat-input concept, null-move verification form, corrhist form (§2, §3). No code. Training data: see next row. |
| Stockfish NNUE training data (`official-stockfish/master-binpacks`, Hugging Face) | **ODbL-1.0** | Training data for the shipped network (§4). ODbL notice below. |
| Stockfish test-run datasets published by linrock (`linrock/test80-2023`, `test80-2024`, test78/79/60 collections) | **No license stated** on the dataset cards (checked 2026-09-03) | Training data (§4), used as the NNUE-training community uses them: published by a Stockfish maintainer for that purpose. <!-- AUTHOR: confirm the basis, or ask the publisher --> |
| Lc0-derived data (`leela96-filt-v2`, LCZero self-play rescored by Stockfish) | ODbL-1.0 / DBCL-1.0 (LCZero) | One component of the shipped network's training mix (§4). ODbL notice below. |
| bullet (Jamie Whiting) | MIT | NNUE trainer, used with a full-threats input extension written for zigqueen and published as a patch (§4). Not linked into the engine. |
| Fathom (Ronald de Man, basil00, Jon Dart) | MIT | Vendored in `deps/fathom`, compiled into the engine, two local modifications (§5). |
| chessenginesupport-androidlib (gkalab) | Apache-2.0 | Vendored unmodified in `android/oex/…/com/kalab/chess/enginesupport/` for the OEX APK (§5). |
| Gradle wrapper | Apache-2.0 | `android/oex/gradle/wrapper/gradle-wrapper.jar` (§5). |
| Opening books used for testing (UHO, Stefan Pohl) | not redistributed | Used to run gauntlets only. |
| Coda (Adam Twiss) | GPL-3.0 | Studied as the model for this document; no code or constants. |
| AGPL engines (Reckless, PlentyChess, Viridithas ≥ v21, …) | AGPL-3.0 | **Not used as a source.** No AGPL engine source has been on the development machine; only binaries are used as gauntlet opponents (§7). |

## 1. Search shaping: a parameter set taken from Stormphrax

**What is in the tree.** `src/search/basin.zig`, shipped since 6.1.0 (2026-08-31), defines the interior LMR formula
and the null-move, late-move, reverse-futility, futility, history-pruning and SEE-pruning thresholds, the history
bonus/malus shape and the LMR re-search threshold. Its formulas and every default constant were taken from
Stormphrax 8.0.0's published tunable defaults (Ciekce, GPL-3.0). Constants expressed in Stormphrax's evaluation units
are scaled by one factor chosen here (`UNIT_PERCENT = 25`); dimensionless terms are unchanged.

**What was not taken.** No source text. The Zig implementation and its integration with the rest of the search are
zigqueen's, and everything else in the search — time management, SEE, transposition table, eval cache, quiescence,
aspiration, probcut, singular extensions, move ordering and the history tables — uses zigqueen's own designs and
constants. A comparison of all 169 Stormphrax tunable defaults against this tree finds matches only in `basin.zig`.

**License.** Both engines are GPL-3.0, so there is no license conflict, and tuning constants are functional values,
not protectable expression. We still treat a parameter port as a provenance matter in its own right, which is why it
is disclosed here and in the file header.

**Status.** In 6.1.0 the constants are Stormphrax's defaults. They are being replaced by values derived from
zigqueen's own measurements; this section will be updated when the replacement ships.

## 2. NNUE evaluation: published forms, our own implementation

- **Feature transformer.** Mirrored HalfKA with 8 king buckets (each perspective's own king; files e–h mirrored onto
  a–d; black's frame rank-flipped), width 1024, i16 accumulators. The bucket layout (rank 1 split a-b/c-d, rank 2
  split, then ranks 3, 4, 5–6, 7–8) is the common 8-bucket layout used by many bullet-trained engines
  (it is not the layout of bullet's bundled examples, which use ten buckets); it is stored in the net header, not
  hard-coded in the engine.
- **Layer stack and PSQT head.** SFNNv5-style: clipped ReLU + pairwise multiply on the accumulator halves,
  `1024 → 16` (i8) → squared-clipped-ReLU → `16 → 32` → `32 → 1`, eight material buckets, plus a per-feature PSQT head
  bucketed alongside the output buckets. These are Stockfish's published network shapes.
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

- **Weights.** The shipped `ZQB9` network (embedded, 74.6 MB) was trained by the author on a single desktop GPU from
  random initialisation. It was never initialised from, fine-tuned from, or distilled logit-wise from another
  engine's network. The weights are zigqueen's.
- **Trainer.** bullet (MIT), used as a personal fork whose only changes are a HalfKA + full-threats input type, the
  matching grader and the run recipe, written for zigqueen and published as `docs/trainer/bullet-fullthreats.patch`
  (against upstream commit `d372d48`; see `docs/trainer/README.md`).
- **Training data.** Twenty-seven published components, interleaved: `leela96-filt-v2` (split 0); `test60` 2021-11
  and 2021-12; `test78` 2022-01..05 and 2022-06..09; `test79` 2022-04 and 2022-05; `test80` monthly 2022-06 to
  2024-02; `wrongIsRight_nodes5000pv2`. All are Stockfish-project training data (played-out games carrying a
  Stockfish search score and result; the `leela96` component is LCZero self-play rescored by Stockfish). Sources:
  `official-stockfish/master-binpacks` (ODbL) for `wrongIsRight`; the Hugging Face datasets `linrock/test60`,
  `linrock/test78`, `linrock/test79`, `linrock/test80-2022`, `linrock/test80-2023` and `linrock/test80-2024` (no
  license stated on any of them) for the test60/78/79/80 components; the download source of the `leela96-filt-v2`
  component was not recorded. <!-- AUTHOR: leela96 source --> Our own self-play data generator exists but did not
  contribute to the shipped network.
- **Notice (ODbL).** Parts of the training data are made available under the Open Database License
  (http://opendatacommons.org/licenses/odbl/1.0/) by the Stockfish project (`official-stockfish/master-binpacks`)
  and, for the Lc0-derived component, by the LCZero project, with the rights in individual contents under the
  Database Contents License (http://opendatacommons.org/licenses/dbcl/1.0/). A trained network is a "Produced Work"
  under ODbL; we distribute the network, never the databases, so the share-alike terms attach to nothing we ship; the
  obligation is this notice.
- **What Stockfish contributed.** Openly published training data and published architecture descriptions. Nothing
  else — no code, no weights, no logits.

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

- Idea sources are GPL-compatible projects only (GPL-3.0, MIT, BSD, Apache, WTFPL). AGPL engines are gauntlet
  opponents (binaries) and nothing more; their source is not kept on the development machine.
- Ideas, never expression: we read published descriptions and, where we read source, we take the technique and
  write zigqueen's own implementation. Where a parameter set was taken from a specific engine rather than derived
  here, we say so and replace it (§1).
- Six opening-book root moves (`src/search/opening_book.zig`, present from the first public release 5.8.0 through
  6.1.0) were chosen with Stockfish analysis of a test opening set. Engine output is not licensed material; we mention
  it because our rules say other engines are opponents, not oracles. The file is removed in the next release.

## 8. Repository structure and git history

The public repository starts at the 5.8.0 release (2026-07-19) as a single squashed commit; every change since
is in its history, and no file has ever been removed from it. It has never contained other engines' code.
Development notes and experiment records are kept privately.

## 9. How the engine was built

See README, "How this engine was built (AI disclosure)": Claude wrote most of the source under the author's
continuous direction; the author set goals, chose and approved experiments, and decided what shipped; strength
changes required SPRT at two time controls plus an external gauntlet; performance changes had to be node-identical;
commit trailers preserve co-authorship. The originality rules the code was developed under are the ones on this
page.

## Position

We believe zigqueen carries no copied code and no copied weights, that every third-party component it ships is
GPL-compatible and now carries its notice, and that the one place where we took another engine's numbers rather
than only its idea — the search-shaping parameter set from Stormphrax — is disclosed above, license-compatible, and
still at the ported defaults in 6.1.0 while its locally derived replacement is being built. If anyone believes
specific third-party expression
remains in zigqueen, please open an issue with the specifics; we will review it promptly and fix it — by removal
where a license requires it, or by correcting the attribution where a license permits reuse with credit.

*Changes since first publication:*

- 2026-09 — first version: Stormphrax parameter-set disclosure (§1); ODbL notice and the full training-data component
  list added to `docs/NETWORK.md`; `THIRD_PARTY_LICENSES.md` added and packaged; Fathom relabelled MIT (was "BSD" in two
  comments) and its two local modifications documented; README/ARCHITECTURE corrected on correction history (parked,
  not live) and on the origin of the six opening-book moves (removed for the next release); `CLEAN_ROOM_RULES.md`
  renamed to `ORIGINALITY.md` and reworded to what was done.
