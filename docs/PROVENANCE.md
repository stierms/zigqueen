# Provenance and licensing record

**Status:** first version, September 2026, covering the 6.1.0 release. Facts were taken from the public tree, the
internal development ledger and direct comparison with the referenced sources. This is an engineering statement, not
legal advice; it is updated when new facts come to light (dated list at the end).

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
| zigqueen itself | GPL-3.0 (`LICENSE`), © 2026 stierms | — |
| Stormphrax 8.0.0 (Ciekce) | GPL-3.0 | Search-shaping parameter set initialised from its published defaults (§1). No code. GPL-compatible. |
| Stockfish 18 (the Stockfish developers) | GPL-3.0 | Published forms only: HalfKA-family features, SFNNv5-style layer stack, PSQT head, threat-input concept, null-move verification form, corrhist form (§2, §3). No code. Training data: see next row. |
| Stockfish NNUE training data (`official-stockfish/master-binpacks`, Hugging Face) | **ODbL-1.0** | Training data for the shipped network (§4). ODbL notice below. |
| Stockfish test-run datasets published by linrock (`linrock/test80-2023`, `test80-2024`, test78/79/60 collections) | **No license stated** on the dataset cards (checked 2026-09-03) | Training data (§4), used as the NNUE-training community uses them: published by a Stockfish maintainer for that purpose. <!-- AUTHOR: confirm the basis, or ask the publisher --> |
| Lc0-derived data (`leela96-filt-v2`, LCZero self-play rescored by Stockfish) | ODbL-1.0 / DBCL-1.0 (LCZero) | One component of the shipped network's training mix (§4). ODbL notice below. |
| bullet (Jamie Whiting) | MIT | NNUE trainer, used as a personal fork with a full-threats input extension written for zigqueen (§4). Not linked into the engine. |
| Fathom (Ronald de Man, basil00, Jon Dart) | MIT | Vendored in `deps/fathom`, compiled into the engine, two local modifications (§5). |
| chessenginesupport-androidlib (gkalab) | Apache-2.0 | Vendored unmodified in `android/oex/…/com/kalab/chess/enginesupport/` for the OEX APK (§5). |
| Gradle wrapper | Apache-2.0 | `android/oex/gradle/wrapper/gradle-wrapper.jar` (§5). |
| Opening books used for testing (UHO, Stefan Pohl) | not redistributed | Used to run gauntlets only. |
| Coda (Adam Twiss) | GPL-3.0 | Studied as the model for this document; no code or constants. |
| AGPL engines (Reckless, PlentyChess, Viridithas ≥ v21, …) | AGPL-3.0 | **Not used as a source.** No AGPL engine source has been on the development machine; only binaries are used as gauntlet opponents (§7). |

## 1. Search shaping: a parameter set taken from Stormphrax

**What was taken.** In July 2026 the search's reduction and pruning configuration was replaced as one coherent unit
(`src/search/basin.zig`, shipped since 6.1.0). The formulas and every default constant in that file come from
Stormphrax 8.0.0's published tunable defaults: the two log-based fractional LMR tables (0.78/2.36 quiet,
−0.10/2.49 noisy, 1/1024 ply units), the eleven additive LMR terms, the LMR-depth term, the null-move margin and
`R = 6 + depth/5`, the late-move-pruning curve, the reverse-futility margin, the quiet-futility, history-pruning and
SEE-pruning thresholds, the linear history bonus/malus shape, the re-search "deeper" threshold and the TT-PV
extension trigger. Constants expressed in Stormphrax's internal evaluation units were multiplied by one locally
chosen factor (`UNIT_PERCENT = 25`, selected by our own sweep at 25/41/100 %); dimensionless terms were taken as-is.
The source was read to extract this specification; the extraction (constants and formulas with source line
references, no code) is kept in our private notes and is not in this repository.

**What was not taken.** No source text. The Zig implementation, its integration with zigqueen's stack, TT, move
ordering, evaluator and diagnostics, the guards, the correction-history units, the honest node accounting and the
root-LMR scouting are zigqueen's. Time management, SEE, TT, eval cache, qsearch, aspiration, probcut, singular
extensions, correction history and move ordering use zigqueen's own designs and constants — a fingerprint of all 169
Stormphrax tunable defaults against our source finds matches only in `basin.zig`.

**Why we did it and what we found.** The motivation was diagnostic: at comparable net width Stormphrax reached
~12 plies more at 20 s; adopting a proven, co-tuned configuration wholesale was the only way to test whether depth was
the missing ingredient. It moved our effective branching factor from 1.97 to 1.62 and was worth about +5 Elo at
20+0.2 — the scientific result was that depth was *not* the binding constraint.

**License.** Stormphrax is GPL-3.0, as is zigqueen; there is no license conflict. Tuning constants are functional
facts, not protectable expression. We nevertheless treat a parameter port as a provenance question in its own right.

**Making the operating point ours.** In August 2026 an internal audit of the ladder head flagged that these values
had form-level attribution only and were not locally derived. The basin constants were exposed as tuning knobs and an
SPSA campaign was run at the deploy time control (60+0.6) over the pruning margins; at the 90/266 checkpoint the
six margins sat within ±3 % of the ported defaults (last recorded checkpoint, 2026-08-28).
As with Coda's Viridithas time-management constants, reconvergence is the informative part: the numbers are an
operating point that a tuning run finds on its own. The LMR term weights and the history bonus/malus shape were not
retuned; in 6.1.0 the whole set remains at the ported defaults. A re-derivation of the entire parameterisation from
zigqueen's own measurements — forms and values, not a retune of the ported forms — is in progress (September 2026)
and will replace this section when it ships.

The ladder head after 6.1.0 also adopts the low-depth singular extension (margins 22 and 39 in Stormphrax units,
scaled by the same factor) from the same source; the same disclosure applies to the next release.

## 2. NNUE evaluation: published forms, our own implementation

- **Feature transformer.** Mirrored HalfKA with 8 king buckets (each perspective's own king; files e–h mirrored onto
  a–d; black's frame rank-flipped), width 1024, i16 accumulators. The bucket layout (rank 1 split a-b/c-d, rank 2
  split, then ranks 3, 4, 5–6, 7–8) is the common 8-bucket layout used by many bullet-trained engines
  <!-- AUTHOR: origin — bullet example or own choice -->; it is stored in the net header, not hard-coded in the engine.
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
  matching grader and run recipes, written for zigqueen; the fork is not yet published. <!-- AUTHOR: publish the fork or a patch; link -->
- **Training data.** Twenty-seven published components, interleaved: `leela96-filt-v2` (split 0); `test60` 2021-11
  and 2021-12; `test78` 2022-01..05 and 2022-06..09; `test79` 2022-04 and 2022-05; `test80` monthly 2022-06 to
  2024-02; `wrongIsRight_nodes5000pv2`. All are Stockfish-project training data (played-out games carrying a
  Stockfish search score and result; the `leela96` component is LCZero self-play rescored by Stockfish). Sources:
  `official-stockfish/master-binpacks` (ODbL), `linrock/test80-2023`, `linrock/test80-2024` (no license stated),
  and the corresponding published test60/test78/test79 and leela96 collections. <!-- AUTHOR: record the download
  sources of test60/test78/test79/leela96 --> Our own self-play data generator exists but did not contribute to the
  shipped network.
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
  `github.com/jdart1/Fathom` <!-- AUTHOR: commit/version -->. Two local changes in `tbprobe.c`, both marked
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
- Ideas, never expression: reading a published description or, where we do read source, extracting the technique
  and its parameters into our own notes — then writing zigqueen's implementation. Where a parameter set is taken from
  a specific engine rather than re-derived, we say so here and retune it on zigqueen (§1).
- Study notes that quote other engines' code are kept out of the public repository.
- Six opening-book root moves in 5.x/6.x (`src/search/opening_book.zig`, live in 6.0.0 and 6.1.0) were chosen in
  April 2026 from Stockfish analysis of the gauntlet opening set. Engine output is not licensed material; we mention
  it because our rules say other engines are opponents, not oracles. The entries were removed from the development
  head in September 2026 and will not be in the next release.

## 8. Repository structure and git history

The public repository was created by squashing the development history into an initial 5.8.0 commit
(2026-07-19); it has never contained internal plans, ledgers, agent configuration, study notes or other engines'
code, and no file has been removed from its history. Development ledgers, research notes (including the Stormphrax
extraction of §1) and experiment artefacts live in a private repository. Public history therefore needs no
rewriting.

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
  not live) and on the origin of the six opening-book moves (removed from the development head the same day);
  `CLEAN_ROOM_RULES.md` reworded to what was done.
