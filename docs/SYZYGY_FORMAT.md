# Syzygy WDL/DTZ format and probing specification

Status: the specification the engine's own Syzygy prober (`src/tb/`, in the
engine since 6.5.0) was built from. It was written first (phase 1, 2026-10-14),
then implemented from it (phase 2, the same day) and extended with Windows
mapping and the storage budget (phase 3). Two statements the implementation
proved wrong are corrected in place (§5.3 tie, §11.2 self-test), each marked
"Corrected in phase 2"; the maintainer's answers to §13 are recorded there.
This is the design record as written during development: it mentions files of
the earlier Fathom-based engine that 6.5.0 removed, and private records
(audits, test artifacts) that are not part of this repository.

**Scope**
- In scope: Syzygy WDL (`.rtbw`) and DTZ (`.rtbz`) files for standard chess,
  3 to 6 pieces. 7 pieces is not precluded, and every 7-piece difference is
  marked.
- Out of scope: DTM (`.rtbm`), variant tables (giveaway, atomic and so on),
  checksum verification, and any change to root or search policy.

**What this document is.** No official format specification exists. The
author's own probing code is the de facto reference, and the community says
so ([DMF] thread, 2022). This document restates that format, together with
the probing algorithms, in our own words. It is written so that a Zig
implementation can be built from it without reading any reference code.

**Provenance**
- No code was copied, and no function is transcribed.
- Index tables are defined by generating rules, which the implementation will
  evaluate at comptime. Where a table is a published form, the rule reproduces
  it bit for bit. §1.3 records the check, run against the vendored Fathom
  arrays.
- Fixed format facts (magic numbers, field layout, flag bits, constants such
  as 462 and 31332) are forced by the files. They are stated here as facts,
  each tagged with the references that confirm it.
- The forbidden sources in `ORIGINALITY_RULES.md` were not used.

Citation keys used throughout: [FA] [DM] [DMF] [SF] [PC] [SK] [TB] [LI] [CEN]
(defined in §1).

---

## Contents

1. References, licences and local evidence
2. Conventions
3. Table set, file names, material keys, colour mirroring
4. File layout
5. Position index
6. Decompression
7. WDL probing
8. DTZ probing and the 50-move rule
9. Root move ranking
10. Reference disagreements and known defects
11. Test-oracle plan (G0/G1)
12. Module layout proposal (interfaces only)
13. Open questions for the maintainer
- Appendix A: test vectors

---

## 1. References, licences and local evidence

### 1.1 References

Each licence was verified on 2026-10-14 from the source itself: the file
header, the LICENSE/COPYING file, PyPI or crates.io metadata, or the GitHub
licence API.

| Key | Reference | Version / pin | Licence (verified) | Used for |
|---|---|---|---|---|
| FA | Fathom, vendored in `deps/fathom/` | Imported 2026-07-12, with three local patches (`THIRD_PARTY_LICENSES.md`) | MIT. `deps/fathom/LICENSE`: (c) 2013-2018 Ronald de Man, (c) 2015 basil00, (c) 2016-2025 Jon Dart | Primary reference and test oracle. The engine contract today is `tb_probe_wdl` and `tb_probe_root` (`src/search/fathom_bridge.c`) |
| DM | Ronald de Man, `probetool`, `regular/tbprobe.c` (the author's own prober) | github.com/syzygy1/probetool commit `4fb41420efbf` (2025-11-03); `tbprobe.c` sha256 `910a64cb…` | File header: "(c) 2013-2018, 2025 Ronald de Man. This file may be redistributed and/or modified without restrictions." README: "do whatever you want with it" | Cross-check of the original algorithms |
| DMF | Ronald de Man, posts on talkchess.com | Thread "Looking for a specification for Syzygy tablebases", posts of 2022-10-15 and 2022-10-16 (WDL layout). Post of 2016-11-21 (`p=695509`) on header-defined colours | Forum text, not code | The author's published description of the header, the sparse index, block padding and the checksum |
| TB | Ronald de Man, generator `syzygy1/tb` | Commit `0bb8aeee` (2025-10-03); README only | GPL-2.0 (only) for `src/` (GitHub licence API and README) | Statements that WDL is two-sided, DTZ one-sided, and that every file carries an embedded checksum. **No generator code was read** |
| SF | Stockfish `src/syzygy/tbprobe.cpp` | Tag `sf_17.1` (ref object `03e27488f3d2`, release 2025-03-30); blob `cbf8dce5` | GPL-3.0-or-later (file header, `Copying.txt`) | Independent rewrite. Disagreements recorded in §10 |
| PC | python-chess `chess/syzygy.py` | 1.11.2 (PyPI upload 2025-02-25); installed copy sha256 `e10e74b0…` | GPL-3.0+ (PyPI metadata, dist-info licence) | Second oracle (G1). Clean-room check target (§1.3) |
| SK | shakmaty-syzygy | 0.28.1 (crates.io 2026-06-19); source `niklasf/shakmaty` commit `baf3c304` (2026-10-06), dir `shakmaty-syzygy/src`. The old repository `niklasf/shakmaty-syzygy` is archived | GPL-3.0-or-later (crates.io, workspace `COPYING`) | Validation rules, positioned-read design. Disagreements in §10 |
| LI | Lichess blog, "7-piece Syzygy tablebases are complete" | 2018-08-19 | Blog text | 7-piece size and the widened DTZ maps |
| CEN | Local census of the installed tables, this document | 2026-10-14 on our development machine, the complete 3–6-piece set | Our own measurement | Checks every layout claim against 1,020 real files (§1.2) |

Reading GPL code to learn a file format is idea-level use. `ORIGINALITY_RULES.md`
forbids only our own earlier engines. Nothing GPL is copied, linked or vendored
by this project. python-chess runs only as an out-of-process test oracle (see
open question Q7).

### 1.2 Local census (CEN)

We parsed all 1,020 installed files from their headers, using an independent
script that follows §4–§5 of this document:
- 3-4-5: 290 files, 145 materials;
- 6-man: 730 files, 365 materials.

The script is scratch tooling and is not committed; G0 re-implements these
checks as tests. Results:

| Check | Result |
|---|---|
| Magic number per suffix | 1,020 / 1,020 |
| File size ≡ 16 (mod 64) | 1,020 / 1,020 |
| Byte 4: high nibble = piece count, bit 0 = material not colour-symmetric, bit 1 = has pawns, bits 2–3 = 0 | 1,020 / 1,020 (both suffixes) |
| End of the last section computed from §4 (rounded up to 64), plus 16, equals the file size | 1,020 / 1,020 |
| Σ over blocks of (stored length + 1) = table size computed by §5.8 | All 916 compressed subtables of 3-4-5; 73 subtables of a 19-file 6-man sample |
| Header piece colours (every subtable and side) agree with the file-name orientation | 1,020 / 1,020 |
| Leading-pawn code identical in every subtable and side of a pawnful file | all pawnful files |
| File names canonical under the rule in §3.2 | 510 / 510 materials |

Observed field ranges, used later for validation limits:

| Field | 3-4-5 | 6-man |
|---|---|---|
| block size exponent (WDL / DTZ) | 5–6 / 5–10 | 5–6 / 5–10 |
| index-span exponent | 15–20 | 14–20 |
| block-length padding entries | 0–8 | 0–7 |
| code length min / max | 1 / 22 | 1 / 28 |
| symbols per subtable (max) | 4,095 | 4,095 |
| values per symbol (max) | 256 | 256 |
| largest subtable (positions) | 114,675,120 | 6,765,832,080 |
| DTZ flag bits seen | 0–3 | 0–3 (no wide maps) |
| single-valued subtables | WDL 54 (4 draw, 50 win), DTZ 6 (byte 1 = 0) | WDL 34 (win), DTZ 0 |
| symmetric DTZ subtables with stored-side bit 1 | 0 of 8 | 0 of 30 |

Byte totals over all 1,020 files:

| Suffix | Sparse index | Block lengths | Compressed data | Headers |
|---|---|---|---|---|
| WDL | 311 MB | 2.30 GB | 70.6 GB | 23.4 MB (max 98,750 B per file) |
| DTZ | 67.5 MB | 0.50 GB | 87.4 GB | 14.4 MB (max 50,292 B per file) |

94 of the 6-man WDL files contain a subtable with more than 2³² positions, so
**64-bit indices are needed already for 6-man**.

### 1.3 Clean-room checks of this document

These are scratch scripts, written from the text of this document, not from
reference code.

1. **Index tables.** The generating rules of §5.5 and §5.6 reproduce
   Fathom's published arrays exactly:
   - `KKIdx`: all 640 entries, including the unused ones;
   - `Flap[0]` and `PawnTwist[0]`: all entries;
   - `Triangle`, `Lower` and `Diag`: every entry the index computation reads.
     With the obvious symmetry extension, the full 64-entry `Triangle` and
     `Lower` match as well.
2. **Raw values.** An index and decode implementation built from §4–§6 was
   compared with python-chess's raw table values:
   - 9,000 random positions over 30 tables, both colour orientations, biased
     towards diagonal and edge cases;
   - 3-4-5 and 6-man, including subtables above 2³²;
   - result: 0 mismatches over 9,000 WDL values, 3,186 DTZ values and 3,035
     "other side stored" decisions.
3. **Probing algorithms.** §7–§8 on top of check 2 were compared with
   python-chess's `probe_wdl` and `probe_dtz`:
   - 3,280 positions, 750 of them with a legal en-passant capture;
   - result: 0 mismatches.

These checks show that the text is precise enough to implement. They are not
G1 evidence: G1 runs against Fathom with the real engine code.

---

## 2. Conventions

- **Squares.** `sq = 8·rank + file`, with `a1 = 0`, `h1 = 7`, `a8 = 56`, and
  0-based rank and file. This matches `src/core/square.zig` and every
  reference.
- **Transforms.**
  - mirror file: `sq ^ 7`;
  - mirror rank: `sq ^ 56`;
  - transpose (reflect in the a1–h8 diagonal): `(sq >> 3) | ((sq & 7) << 3)`.
- **Diagonal predicates.** On the diagonal: `file = rank`. Below: `file > rank`
  (b1 is below). Above: `file < rank`.
- **Edge distance of a file:** `e(f) = min(f, 7 − f)`. It is 0 for files a and
  h, and 3 for files d and e.
- **Piece codes in files** [DMF][FA][SF][PC]:
  - white: P=1, N=2, B=3, R=4, Q=5, K=6;
  - black: add 8 (9–14);
  - a code is a 4-bit nibble.
- **WDL values**, from the side to move's point of view, assuming the 50-move
  counter is 0 at this position:
  - −2 loss;
  - −1 blessed loss (lost, but the 50-move rule saves it);
  - 0 draw;
  - +1 cursed win (won, but the 50-move rule spoils it);
  - +2 win.
- **Zeroing move:** any capture (including en passant) or any pawn move
  (including promotions). It resets the 50-move counter.
- **Notation.** `C(n, k)` is the binomial coefficient, 0 when `k > n`.
- **Byte order.** All header and table integers are little-endian. The
  compressed bitstream is read most-significant bit first, in big-endian byte
  order.
- **Offsets.** All offsets are file offsets. "Pad to 2" or "pad to 64" means:
  advance to the next file offset that is a multiple of 2 or 64. References pad
  pointers inside a page-aligned mapping, which is the same thing.

---

## 3. Table set, file names, material keys, colour mirroring

### 3.1 Files and magic numbers

There is one file per material and metric:
- `<name>.rtbw`: WDL;
- `<name>.rtbz`: DTZ;
- `<name>.rtbm`: DTM, not used here.

Magic numbers, the first 4 bytes, read as a little-endian u32 [FA][DM][SF][PC][SK][CEN]:

| Suffix | u32 | Bytes on disk |
|---|---|---|
| `.rtbw` | `0x5D23E871` | `71 E8 23 5D` |
| `.rtbz` | `0xA50C66D7` | `D7 66 0C A5` |
| `.rtbm` (DTM, out of scope) | `0x88AC504B` | `4B 50 AC 88` |

Number of canonical materials, KvK excluded (our enumeration under the rule of
§3.2; it matches Fathom's capacity constants and the census):

| Pieces | Materials | Pawnless | Pawnful |
|---|---|---|---|
| 3 | 5 | 4 | 1 |
| 4 | 30 | 20 | 10 |
| 5 | 110 | 60 | 50 |
| 6 | 365 | 170 | 195 |
| ≤ 6 total | 510 | 254 | 256 |
| 7 | 1,001 | 396 | 605 |
| ≤ 7 total | 1,511 | 650 | 861 |

7-piece size: WDL 8.5 TiB plus DTZ 8.3 TiB, 16.7 TiB in total [LI].

### 3.2 Names and canonical orientation

A name is: `K`, then the first side's other pieces in the order Q, R, B, N, P,
then `v`, then `K` and the second side's pieces in the same order. Example:
`KRPvKR`.

Of the two colour assignments of one material, exactly one name exists on
disk, the **canonical** one. The first side is:
1. the side with more pieces; otherwise
2. the side whose piece list is stronger, compared lexicographically by the
   index of each letter in `KQRBNP` (smaller index means stronger); if the
   lists are equal,
3. the material is colour-symmetric.

Sources: the canonical-name rule of [PC], and the name enumeration of [FA].
[CEN] confirms that all 510 local names follow it.

The prober does not have to construct names. A directory scan (§12) parses
every file name it finds. It keys the entry under both colour orientations of
the material and rejects names that are not canonical.

### 3.3 Material key

A material key is any exact encoding of the ten counts: white and black
queens, rooks, bishops, knights and pawns.

**Proposal for zigqueen.** Use a packed 40-bit integer, 4 bits per count:
- the white counts in the low 20 bits;
- the black counts in the high 20 bits;
- the colour-mirrored key swaps the two halves.

This key is collision-free, so no hash-probe chain is needed. A sorted array of
up to 1,511 entries, searched by binary search, or a perfect table, is enough.

Fathom's 64-bit prime-sum keys are an implementation choice, not a format fact.

### 3.4 The file frame, orientation and the side index

Every file has its own **frame**. Its white and black are given by the colour
nibbles of the piece codes in its header (§4.2).

- **The header is authoritative** [DMF 2016]. For regular chess tables the
  frame equals the name orientation (the first side is white).
  - [CEN] confirms this for every subtable and side.
  - [PC] still recomputes the key from the header, because generated giveaway
    tables swap colours. Regular tables are unaffected.
- A position's **orientation** relative to a non-symmetric table:
  - `flip = false` when the position's white material equals the frame's
    white;
  - `flip = true` when it equals the frame's black;
  - anything else is a lookup bug.
- **Colour-symmetric materials** (same pieces on both sides): the position is
  always presented with the side to move as white, so `flip = (black to move)`.
- The **side index** `s` selects the stored per-side table. `s = 0` means the
  side to move is white in the frame:
  - non-symmetric: `s = (black to move) XOR flip`;
  - symmetric: `s = 0`.
- **Applying `flip`:**
  - every piece changes colour;
  - for pawnful tables every square is also rank-mirrored (`^ 56`), so that
    pawn direction is kept;
  - pawnless tables get no square change on flip, because §5.4 normalises by
    symmetry anyway. All references do this [FA][SF][PC][SK].

---

## 4. File layout

The file is a sequence of sections. Every offset follows from the header
(verified by [CEN]: the computed end matches all 1,020 files).

```
0      magic (4)
4      flag byte (1)
5      encoding descriptors (§4.2), then pad to 2
       compressed-table headers, one per (subtable, stored side) (§4.3)
       DTZ only: value maps (§4.4), then pad to 2
       sparse indices, one per compressed (subtable, side)
       block-length tables, one per compressed (subtable, side)
       data sections, one per (subtable, side), each padded to 64 first
       pad to 64
       16-byte trailer (checksum)
```

**Iteration order.** Wherever a section repeats per (subtable, side), the
order is: subtable `t` ascending, and within it side 0 then side 1 (when two
sides are stored).

### 4.1 Flag byte (offset 4)

| Bits | Meaning | Confirmed |
|---|---|---|
| 0 | Set iff the material is not colour-symmetric. In WDL files a set bit means two sides are stored; DTZ files carry the same bit but store one side | DMF, SF, PC, SK, CEN |
| 1 | Set iff the material has pawns. Pawnful files have 4 subtables (leading pawn on file a, b, c or d); pawnless files have 1 | DMF, SF, PC, SK, CEN |
| 2–3 | 0 | CEN |
| 4–7 | Number of pieces N, kings included | DMF, CEN |

Stored sides per subtable:
- WDL: 2 if bit 0 is set, else 1;
- DTZ: always 1 [TB][FA][SF].

### 4.2 Encoding descriptors (offset 5)

There is one descriptor per subtable: 1 for pawnless files, 4 for pawnful
files (subtable `t` is leading-pawn file a, b, c, d). Each descriptor is:

| Bytes | Content |
|---|---|
| 1 | **order** byte: low nibble for side 0, high nibble for side 1 |
| 1, only if both colours have pawns | **order2** byte, same nibble split |
| N | **piece list**: byte `i` holds side 0's i-th piece code in its low nibble and side 1's in its high nibble |

After the last descriptor, pad to 2.

- **DTZ files.** Only the low nibbles are used, whatever side the table stores
  [FA][DM][SF][PC][SK].
- **Piece list.** Pieces with the same code are consecutive. The list defines
  the groups (§5.7) and the order in which squares are listed.
- **Leading group of a pawnful file.** The first code is a pawn. It is the same
  code in every subtable and side, so it names the **leading colour** [CEN].
  When both colours have pawns:
  - the leading colour's pawns come first, then the other colour's pawns, then
    the pieces;
  - the leading colour is the one with fewer pawns. On equal counts the header
    decides; probers only need the counts.
- **Leading group of a pawnless file.**
  - If exactly two piece kinds (code values) occur once, the leading group is
    the first 2 pieces. These are the two kings, giving the "KK" encoding.
  - Otherwise it is the first 3 pieces, all unique (the "3-unique" encoding)
    [FA][SF][PC][CEN].

### 4.3 Compressed-table header

There is one header per (subtable, stored side), in the order of §4. Byte 0 is
the **flags** byte.

**Single-valued table** (flags bit 7 = `0x80`). The header is 2 bytes. The
subtable holds one value for every index, and it has no sparse index,
block-length table or data. Its value:
- WDL: byte 1, a code from 0 to 4 [DMF][FA][SF][PC][SK];
- DTZ: references disagree, so read §10 item 1. Use 0. Every local
  single-valued DTZ subtable has byte 1 = 0 [CEN].

**Compressed table.** The header layout is:

| Offset | Size | Field | Observed range [CEN] |
|---|---|---|---|
| 1 | 1 | `block_bits`: block size is 2^block_bits bytes | 5–10 |
| 2 | 1 | `index_bits`: one sparse entry per 2^index_bits positions (the *span*) | 14–20 |
| 3 | 1 | `pad_entries`: extra block-length entries beyond the real blocks | 0–8 |
| 4 | 4 | `real_blocks` (u32) | |
| 8 | 1 | `max_len`: longest code, in bits | ≤ 28 |
| 9 | 1 | `min_len`: shortest code, in bits | ≥ 1 |
| 10 | 2·h | `first[L]` for L = min_len … max_len (u16 each; h = max_len − min_len + 1): the symbol number of the first code of length L | |
| 10+2h | 2 | `num_syms` (u16) | ≤ 4,095 |
| 12+2h | 3·num_syms | symbol table (§6.1) | |
| | 0 or 1 | pad byte if num_syms is odd | |

Sources: [DMF][FA][DM][SF][PC][SK].

- The header length is `12 + 2h + 3·num_syms + (num_syms mod 2)`. It is always
  even.
- **DTZ flags bits** [FA][SF][PC][SK]:

  | Bit | Name | Meaning |
  |---|---|---|
  | 0 (`0x01`) | stored side | The side to move this subtable stores (0 = white in the frame) |
  | 1 (`0x02`) | mapped | Stored values are indices into a value map (§4.4) |
  | 2 (`0x04`) | win in plies | Values for WDL +2 are in plies; else in moves (doubled when read) |
  | 3 (`0x08`) | loss in plies | Values for WDL −2 are in plies; else in moves |
  | 4 (`0x10`) | wide map | Map entries are u16 rather than u8. Introduced for 7-piece tables [LI]. Absent from all 3-4-5 and 6-man files [CEN] |
  | 7 (`0x80`) | single value | As above |

- For WDL files no flag bit other than bit 7 has a meaning.

### 4.4 DTZ value maps

The maps come immediately after the last compressed-table header. For each
subtable `t` in order, if its flags have the mapped bit, four maps follow, in
this fixed order [FA][SF][PC][SK]:

| Map | Used for WDL |
|---|---|
| 0 | +2 win |
| 1 | −2 loss |
| 2 | +1 cursed win |
| 3 | −1 blessed loss |

Map encoding:
- **Narrow** (wide bit clear): `u8 count`, then `count` u8 values.
- **Wide** (wide bit set): first pad to 2; then each map is `u16 count`
  followed by `count` u16 values.

After all maps, pad to 2. Subtables without the mapped bit contribute nothing.

The references test only the mapped bit, even for a single-valued subtable.
All 6 local single-valued DTZ subtables have flags exactly `0x80` [CEN], so
the case never arises. A loader treats single-valued plus mapped as
`CorruptTable`.

The maps reverse a frequency-sorted relabelling the generator applies [SF]:
stored value `x` means `map[x]`.

### 4.5 Sparse index, block lengths, data, trailer

All sparse indices come first, then all block-length tables, then all data
sections, each in the iteration order of §4.

1. **Sparse index** of a compressed (t, s), with table size `n` from §5.8:
   - `ceil(n / 2^index_bits)` entries of 6 bytes each: `u32 block`, then
     `u16 offset`.
   - Entry `k` names the block that holds the value at index
     `k·2^index_bits + 2^(index_bits−1)`, the **middle** of span `k`, and that
     value's position inside its block [DMF][SF].
2. **Block-length table:** `real_blocks + pad_entries` entries of u16. Entry
   `b` is the number of values in block `b`, minus 1, so 1 to 65,536 values
   per block.
   - Padding entries hold 65,535 [DMF].
   - They exist so the block walk of §6.3 cannot run off the table when the
     middle of the last span lies past the last value [DMF][SF].
   - A padding entry is never a data block.
3. **Data:** pad to 64, then `real_blocks` blocks of 2^block_bits bytes.
4. **Trailer:** after the last data section, pad to 64 and then 16 bytes. This
   is the embedded checksum: CityHash-based, not MD5, and not checked by
   probing code [DMF][TB]. So the file size is ≡ 16 (mod 64).
   - [FA] and [SF] reject files that break this at init.

[DMF] notes that `index_bits` is chosen so that a span is about 16 times the
average number of values per block.

### 4.6 Load-time validation (all errors are `CorruptTable`)

A loader must reject a file, never trust it, when any of these fail:
- the magic number;
- `size % 64 == 16`;
- byte 4 agrees with the parsed name (piece count, pawns, symmetry);
- the header piece material equals the name's material or its mirror;
- every descriptor is consistent:
  - codes are 1–6 or 9–14;
  - equal codes are consecutive;
  - the pawnful leading code is a pawn and the same everywhere;
  - order nibbles name a valid position;
- `min_len ≥ 1`, `min_len ≤ max_len ≤ 32` (the decoder needs a code to fit in
  32 bits, as [SK] checks);
- `num_syms ≤ 4,095` and every child id < num_syms, with symbol expansion free
  of cycles;
- canonical bases decrease (`2·base[L] ≥ base[L+1]`) [SK][SF];
- `block_bits ≤ 10`, i.e. blocks ≤ 1 KiB, as [SK] enforces. This bounds the
  Pread block buffer;
- the section offsets of §4.5, plus 16, equal the file size exactly.

At probe time:
- the walked block number must stay below `real_blocks + pad_entries` during
  the walk and end below `real_blocks` [SK];
- WDL leaf values must be 0–4;
- a mapped DTZ value must be inside its map.

---

## 5. Position index

**Input:** a legal position with no castling rights, whose material has a
table, and the table's parsed descriptors. **Output:** the subtable, the side,
and an index `0 ≤ I < size`. The index is computed the same way for WDL and DTZ
files.

### 5.1 Selecting subtable and side

1. Compute `flip` and `s` (§3.4).
2. Pawnless: subtable `t = 0`.
3. Pawnful:
   - take the leading code from (t=0, s=0);
   - collect all pawns of that colour (colour XOR flip; squares `^ 56` when
     flip);
   - find the leading pawn (§5.3), whose file gives `t`.
4. Choose the descriptor:
   - WDL: `(t, s)`, or `(t, 0)` when only one side is stored;
   - DTZ: `(t)`.
5. **DTZ only, stored-side check.** If the subtable's stored-side bit differs
   from `s`, this table cannot answer for this side to move; §8.3 applies. The
   exception rule for symmetric materials is §10 item 2.

### 5.2 Square list

Fill `p[0..N)` in descriptor piece order:
- each code contributes the squares of all pieces of that code and colour
  (colour XOR flip; `^ 56` when flip and pawnful);
- ascending square order within a code is fine, because every group is sorted
  later;
- for pawnful tables the leading pawns occupy `p[0..k)` (k = leading count).

### 5.3 Pawnful normalisation

- **Leading pawn.** Among the leading pawns, it is the one with the smallest
  `(e(file), rank)`. Ties occur only between mirror-image squares (same rank,
  files f and 7−f). Break a tie towards files a–d: the leader is the leading
  pawn with the largest twist (§5.6). Move it to `p[0]`.
  - *Corrected in phase 2.* This text used to say that either choice gives the
    same result. It does not: choosing the e–h pawn mirrors every other piece
    as well, which is a different placement with a different index. G0 found
    this, and G1 (zero mismatches against Fathom) confirms the a–d rule.
- **Subtable.** `t = e(file of p[0])`, from 0 (a) to 3 (d).
- **Mirror.** If `p[0]` is on files e–h, mirror every square horizontally
  (`^ 7`). Now `p[0]` is on file `t`.

### 5.4 Pawnless normalisation

Apply in this order, each step to **all** squares:
1. If `p[0]` is on files e–h: `^ 7`.
2. If `p[0]` is on ranks 5–8: `^ 56`.
3. Find the first piece, in list order, that is off the a1–h8 diagonal. If it
   belongs to the leading group (index < 2 for KK, < 3 for 3-unique) and lies
   above the diagonal, transpose all squares.
   - If no leading piece is off the diagonal, there is no transpose, even when
     a later piece is above the diagonal [FA][SF][PC].

Afterwards `p[0]` is in the triangle a1–d1–d4: {a1, b1, c1, d1, b2, c2, d2,
c3, d3, d4}.

### 5.5 Leading group, pawnless

Named square sets (generating rules; each reproduces Fathom's arrays, §1.3):

| Set | Members, in this order | Number |
|---|---|---|
| T6 | the six triangle squares below the diagonal, ascending: b1, c1, d1, c2, d2, d3 | 0–5 |
| D4 | the diagonal triangle squares a1, b2, c3, d4 | 0–3 (= rank) |
| Below28 | the 28 squares with file > rank, ascending (b1 = 0 … h7 = 27) | 0–27 |
| Diagonal | a1 … h8 | 0–7 (= rank) |

**KK encoding (462 positions)** [FA][SF][PC][SK]. Define the enumeration of
king pairs `(k1, k2)`:
1. `k1` in T6 order. For each, every `k2` from a1 to h8 in ascending order
   that is neither `k1` nor adjacent to it: 58, 58, 58, 55, 55, 55 → indices
   0–338.
2. `k1` in D4 order. For each, every `k2` strictly below the diagonal (in
   Below28 order) that is not adjacent: 27, 25, 25, 25 → 339–440.
3. `k1` in D4 order. For each, every `k2` on the diagonal, ascending, that is
   neither `k1` nor adjacent: 6, 5, 5, 5 → 441–461.

The leading index is the position of `(p[0], p[1])` in this enumeration. Pairs
outside it (adjacent kings, or `k2` above the diagonal with `k1` on it) cannot
occur after §5.4 for legal positions; treat one as a bug.

**3-unique encoding (31,332 positions)** [FA][SF][PC][SK]:
- Let `a = [p1 > p0]` and `b = [p2 > p0] + [p2 > p1]`, comparing square
  numbers.
- Let `tri(x)` be the T6 number, `dia(x)` the rank, and `low(x)` the Below28
  number.

| Case | Leading index | Range |
|---|---|---|
| `p0` off the diagonal | `tri(p0)·3906 + (p1 − a)·62 + (p2 − b)` | 0 – 23,435 |
| `p0` on it, `p1` off | `23436 + dia(p0)·1736 + low(p1)·62 + (p2 − b)` | 6,944 values |
| `p0`, `p1` on it, `p2` off | `30380 + dia(p0)·196 + (dia(p1) − a)·28 + low(p2)` | 784 values |
| all three on the diagonal | `31164 + dia(p0)·42 + (dia(p1) − a)·6 + (dia(p2) − b)` | 168 values |

(3906 = 63·62, 1736 = 28·62, 196 = 7·28, 42 = 7·6.) The leading pieces need not
be kings, and adjacency is not excluded here.

### 5.6 Leading group, pawnful (file encoding)

**Pawn order.** Sort the 48 pawn squares (ranks 2–7) by the key
`(e(file), rank, file > d)`, ascending. The **twist** of a square is
`τ = 47 − position in that order`. So:
- a2 = 47 and h2 = 46;
- a3 = 45, …, a7 = 37, h7 = 36;
- b2 = 35, …, e7 = 0.

This reproduces Fathom's `PawnTwist[0]`. Every non-leading pawn of the leading
group has a smaller twist than the leading pawn.

With `k` leading pawns, the leading pawn at `(file t, rank r)` with ranks
counted 1 (rank 2) to 6 (rank 7), and the other `k − 1` leading pawns
`q_1 … q_{k−1}` sorted by **decreasing** twist:

```
lead_index = Σ_{r' < r}      C(τ(square(t, r')), k − 1)        // all leader positions before ours on file t
           + Σ_{i=1}^{k−1}   C(τ(q_i), k − i)                  // colex rank of the other leading pawns
lead_size(k, t) = Σ_{r'=1..6} C(τ(square(t, r')), k − 1)
```

The first term is Fathom's cumulative `PawnIdx`. `lead_size` is
`PawnFactorFile` / `LeadPawnsSize`. [CEN] confirms `lead_size` for every
pawnful subtable through the block-length sums.

(The rank encoding, Fathom's `RANK_ENC` with `Flap[1]` and `PawnTwist[1]`, is
used only by DTM and is out of scope.)

### 5.7 Remaining groups

**Second pawn group** (only when both colours have pawns; m pawns of the other
colour). Sort the squares ascending. For each, `adj` is the number of
**leading** pawns on smaller squares, and `c_j = sq_j − 8 − adj`. Then:

```
index = Σ_{j=0}^{m−1} C(c_j, j + 1)     size = C(48 − k, m)
```

**Every other group** (pieces sharing one code, in descriptor order after the
leading and second-pawn groups). Sort ascending. For each, `adj` is the number
of **all previously listed pieces**, from every earlier group in descriptor
order, on smaller squares, and `c_j = sq_j − adj`. Then:

```
index = Σ_{j=0}^{m−1} C(c_j, j + 1)     size = C(64 − placed_before, m)
```

[FA][SF][PC][SK].

### 5.8 Combining the groups

The groups, in descriptor order, are: leading (G0), second pawn group (G1, if
any), then the others. Their **digit order** in a mixed-radix number is given
by the nibbles of the descriptor's side:
- `order` is the digit position of G0;
- `order2` is the digit position of G1, 15 (`0xF`) meaning none;
- every remaining position, counting up from 0 (least significant), is taken by
  the next other group in descriptor order.

The procedure:
1. Walk positions 0, 1, 2, … with a running factor `f = 1`.
2. At each position assign `factor = f` to whichever group belongs there, then
   multiply `f` by that group's size.
3. Stop when every group has a position.
4. The table size is the final `f`.
5. The position's index is `Σ group_index · factor` [FA][SF][PC][SK].

Notes:
- A group's size depends on its place in **descriptor** order (squares already
  placed), not on its digit position.
- Group sizes: leading 462, 31,332 or `lead_size(k, t)`; second pawns
  `C(48 − k, m)`; others `C(64 − placed_before, m)`.
- **Index width:** u64. The 6-man maximum is 6,765,832,080 [CEN]. The sparse
  entry number `I >> index_bits` fits in u32 in every reference [SF][SK].

---

## 6. Decompression

### 6.1 Symbol table

Each symbol is 3 bytes `w0 w1 w2`, holding two 12-bit fields:
- `left = w0 | (w1 & 0x0F) << 8`;
- `right = (w1 >> 4) | w2 << 4`.

If `right = 0xFFF` the symbol is a **leaf** whose value is `left`. Otherwise
it is a **pair** that expands to `left`'s expansion followed by `right`'s
[DMF][FA][SF][PC][SK].

The expansion length is `len(leaf) = 1` and `len(pair) = len(left) +
len(right)`. Precompute it per symbol with an explicit stack (no recursion), and
reject cycles. The local maximum is 256 [CEN], so `len − 1` fits in a u8.

The compression scheme is "recursive pairing" (Re-Pair) over the value
sequence, with the pair symbols Huffman-coded [SF].

### 6.2 Canonical code

Codes are canonical. All codes of one length L map to consecutive symbol
numbers starting at `first[L]`, and longer codes have numerically **smaller**
values. So:
- `first[L]` does not increase with L;
- the number of codes of length L+1 is `first[L] − first[L+1]`.

Bases:
- `base[max_len] = 0`;
- for L from max_len − 1 down to min_len:
  `base[L] = (base[L+1] + first[L] − first[L+1]) / 2`;
- left-justify into 64 bits: `B[L] = base[L] << (64 − L)`.

**Decoding one symbol at bit position `x` of a block:**
1. Let `W` be the 64 bits starting at `x`, MSB first.
2. L is the smallest length `≥ min_len` with `W ≥ B[L]`.
3. The symbol is `first[L] + ((W − B[L]) >> (64 − L))`.
4. Advance `x` by L.

### 6.3 Locating the block

For index `I` in a compressed subtable:
1. `k = I >> index_bits`. Read sparse entry `k`: block `b`, offset `o`.
2. `r = o + (I mod 2^index_bits) − 2^(index_bits−1)`. This is a signed
   position relative to the start of block `b`.
3. While `r < 0`: `b ← b − 1` and `r ← r + length[b] + 1`.
4. While `r > length[b]`: `r ← r − length[b] − 1` and `b ← b + 1`.
5. Now value `I` is value number `r`, 0-based, of block `b`. Bounds-check `b`
   (§4.6).

[DMF][FA][SF][PC][SK].

### 6.4 Decoding inside the block

1. Decode symbols from bit 0 of block `b`. While `r ≥ len(symbol)`: subtract
   `len(symbol)` and decode the next symbol.
2. Descend the expansion tree: at a pair, if `r < len(left)` go left;
   otherwise subtract `len(left)` and go right.
3. The leaf's 12-bit value is the stored value.

**Read bound** (relevant for Pread): the target symbol starts inside the
block, so a reader that fetches the 64-bit window at the target position may
touch up to 8 bytes past the block end.
- A Pread buffer is `2^block_bits + 8` bytes, zero-filled past the end of the
  file.
- In a mapped file those bytes always exist: every data section is followed by
  another data section, alignment padding or the 16-byte trailer.

### 6.5 From stored value to result

- **WDL:** stored code `c ∈ 0..4`, so `wdl = c − 2`. Any other code is
  corrupt.
- **DTZ**, given the WDL of the position (needed to pick the map and the
  scale):
  1. `x = stored value` (12 bits).
  2. If the mapped bit is set: `x = map[m][x]`, where `m` is 0, 1, 2 or 3 for
     WDL +2, −2, +1 or −1.
  3. Doubling: `x ← 2x` unless the WDL is +2 with the win-in-plies bit set, or
     −2 with the loss-in-plies bit set. Cursed and blessed values are always
     doubled.
  4. The result `x` feeds §8.2. It is **exact** when it was not doubled. When
     doubled, the true distance may be one ply longer (§8.1).

  [FA][DM][SF][PC][SK].

---

## 7. WDL probing

### 7.1 What a stored WDL value means

Tables index positions **without** en-passant rights and without castling. For
compression the generator stores "don't care" values [SF][DM]:
- if the side to move has a winning capture, any value may be stored;
- if the best result is a draw reached by a capture, a loss may be stored;
- in every other position the stored value is exact.

The working invariant: **stored ≤ true**, and
**true = max(stored, value of the best capture)**.

### 7.2 Capture resolution

The value of a position without en-passant rights is the stored value combined
with the values of all legal captures. Captures include capture-promotions to
each of the four pieces. Each capture is valued by the same rule, recursively,
one piece fewer per level, so the recursion is at most N − 2 deep.

An alpha-beta window may prune this recursion: a bound is enough once a capture
already reaches the caller's target. Inside the recursion there is never an
en-passant right, since only a double push creates one.

- **KvK** has no file and is a draw.
- A capture into a material without a table is `MissingTable`, never a draw.

### 7.3 Top-level WDL, with en passant

The full WDL of a position (the only entry point that may see an en-passant
right):
1. Value every legal capture, keeping two bests: the best non-ep capture `C`,
   and the best en-passant capture `E` (both start at −3, "none"). A capture
   valued +2 ends the probe: the result is +2, with **zeroing-best** set.
2. Read the table value `v`. It belongs to the position without ep rights.
3. If `E > C` and `E > v`: the result is `E`, with zeroing-best set (an ep
   capture, possibly a losing one, is strictly best). If `E > C` but not
   `E > v`, treat `E` as a candidate: `C ← E`.
4. If `C ≥ v`: the result is `C`, with zeroing-best set when `C > 0`.
5. **Stalemate exception.** An ep capture exists, `v = 0`, the side to move is
   not in check, and its only legal moves are ep captures. Then the position
   without ep rights would be stalemate, which is what `v = 0` records, but
   here the ep capture is forced. The result is `E`, with zeroing-best set.
6. Otherwise the result is `v`.

Sources: [FA][DM]. [PC] and [SK] reach the same values by a different route,
probing without ep first and then comparing ep captures; §1.3 check 3 found
them equal on 750 ep positions.

**Zeroing-best** means a zeroing move achieves the position's value. §8 uses
it.

### 7.4 Preconditions and the 50-move counter

- Castling rights → `OutOfScope`.
- More pieces than the largest loaded table → `OutOfScope`.
- An invalid position → `OutOfScope`. Invalid means: not exactly one king per
  side, pawns on ranks 1 or 8, or the side not to move in check.

The WDL result ignores the 50-move counter: it is the value **as if the counter
were 0**. Two consequences:
- **Fathom's convention.** Its `tb_probe_wdl` refuses (`FAILED`) when the
  counter is non-zero. zigqueen's search gate likewise probes WDL only at
  `halfmove_clock == 0` (`src/search/tb_service.zig`).
- **Our API.** It exposes the clock-free value. Which clocks to probe at stays
  a caller decision, so v1 changes no policy.

---

## 8. DTZ probing and the 50-move rule

### 8.1 Meaning

The DTZ of a position is signed from the side to move's point of view
[FA][DM][SF][PC]:

| Value n | WDL | Meaning, with counter 0 at this position |
|---|---|---|
| 1 … 100 | +2 | Win. A winning zeroing move can be forced within n plies |
| > 100 | +1 | Cursed win. A zeroing move can be forced in n plies, or in n − 100 plies when a later phase is what spoils the win |
| 0 | 0 | Draw |
| −1 | −2 | Loss, and the side to move must zero now or is mated |
| −100 … −2 | −2 | Loss. The winner can force a zeroing move within −n plies |
| < −100 | −1 | Blessed loss. Same reading as the cursed win, with signs reversed |

**Rounding.** Values read from tables that store moves are doubled (§6.5). For
those, `+n` can mean a win in `n + 1` plies, and `−n` a loss in `n + 1`. The
generator stores plies wherever rounding could change a 50-move outcome, so
the rounding never alters the WDL [FA][DM][SF][PC].

The practical rule (all references):
- a win is certain when `n + counter ≤ 99`;
- it is also certain when `n = 100` immediately after a zeroing move, and from
  then on the bound to keep is `n + counter ≤ 100`.

The API carries `exact` (§12). Since 2026-10-15 the engine's root policy uses
it (§9.2).

### 8.2 Procedure

`dtz(position)`:
1. Run the full WDL (§7.3). A draw gives **0**.
2. **Zeroing-best:** return ±1 for a win or loss, ±101 for a cursed win or
   blessed loss. The DTZ table holds don't-care values here, and wrong ones
   when the best move is an ep capture [SF].
3. **Winning by a pawn push.** If WDL > 0 and some legal **non-capturing** pawn
   move (pushes, double pushes and promotions) leads to a child whose full WDL
   (§7.3, since the child may have ep rights) is the negation of ours, return 1
   or 101.
4. **Direct table.** If the DTZ subtable stores this side to move (§5.1 step
   5), take `x` from §6.5. Return `+(1 + x)` for a win, `−(1 + x)` for a loss,
   `+(101 + x)` for a cursed win, or `−(101 + x)` for a blessed loss.
5. **Other side stored:** §8.3.

Reaching step 4 implies the best move is not an ep capture. So the WDL equals
the no-ep value, and the table, which has no ep rights, is valid [FA][DM].

### 8.3 Other side stored: one-ply search

DTZ files store one side to move per subtable [TB]. For the other side:
- Search the legal **non-zeroing** moves only. Zeroing moves were covered by
  steps 2–3 for wins, and are covered by the starting value for losses.
- A non-zeroing move keeps the material and pawns, so the child uses the same
  subtable with the stored side to move, and the recursion is one level deep.

The search, for each such move with `d = −dtz(child)`:

| Our WDL | Start | Per move | No legal moves |
|---|---|---|---|
| > 0 | +∞ | If the move gives checkmate (d = 1 and the child is mated): 1. Else, if d > 0: min(best, d + 1) | — |
| < 0 | −1 (loss) or −101 (blessed loss); the worst case is a forced zeroing move | min(best, d − 1); the most negative is the longest resistance | Mate: −1 |

[FA][DM]. [SF] and [SK] run the same search over zeroing moves too, using
their WDL; the results are the same (§10 item 3).

**Exactness** (zigqueen's `exact` flag, §12): the result carries the
exactness of the move that set it. For a loss, a tie with a rounded child also
makes it inexact, because that child may be one ply longer (§6.5) and then
gives the longest resistance (2026-10-16, review round, Opus F-1). A rounded
tie in the win search cannot lower the minimum, so there the first move's flag
stands.

### 8.4 Interplay with the 50-move counter

- Tables assume counter 0 at the probed position. All clock reasoning happens
  outside the table, at the root (§9.2) or in a future rule-50-aware search.
- The +100 offset of cursed and blessed values is an encoding device. A cursed
  win stays cursed at every counter.

---

## 9. Root move ranking

### 9.1 Per-move root DTZ

For each legal move `m`, `r(m)` counts the move itself, from the root's point
of view [FA]. [SF] uses the same rules, plus repetition (§9.5).
- If the root DTZ is > 0 and `m` mates: `r = 1`.
- Else if `m` is zeroing (capture, ep, pawn move or promotion): `w = −WDL(child)`
  by the full §7.3, and `r` is 1, 101, 0, −101 or −1 for `w` = +2, +1, 0, −1,
  −2.
- Else: `d = −dtz(child)`, and `r = d + sign(d)` (0 stays 0).

Each promotion piece is a separate root move. Underpromotions can differ, for
example a knight promotion with check, or avoiding stalemate. Records are keyed
by (from, to, promotion piece), and an ep capture is flagged.

### 9.2 Five states under the root counter c

| r | State |
|---|---|
| > 0 and `r + c ≤ 100` | win |
| > 0 otherwise | cursed win |
| 0 | draw |
| < 0 and `−r + c ≤ 100` | loss |
| < 0 otherwise | blessed loss |

This is Fathom's `tb_probe_root` classification [FA], which zigqueen consumes
today. Keep the five states up to the policy layer. Today's
`src/search/syzygy.zig` collapses cursed and blessed to draw only in
`RootPolicy`.

The boundary `r + c = 100` is labelled win here, although rounding can make it
a 50-move draw by one ply (§8.1). The prober keeps Fathom's classification;
the engine's root policy (`rootPolicy` in `src/search/syzygy.zig`, 2026-10-15,
audit D U-TB-DTZ100) ranks such a win below certain ones, as [SF] does (§10
item 4, Q6):
- a win is **certain** when its DTZ is exact, `r = 1` (mate or a zeroing win),
  or `r + c ≤ 99`;
- only a certain win is played at once; when only uncertain wins remain they
  stay the root move set and the engine searches them;
- only a certain win makes the root's win authoritative
  (`RootPolicy.authoritativeWdl`): with only uncertain wins allowed the search
  decides the reported score, in the pre-iteration fallback, interrupted
  results, info lines and helper publication too (2026-10-16, review round:
  restricted to `a6a2` below, the search found the draw and the engine still
  reported 28000);
- the mirror for a loss: a loss is **certain** when its DTZ is exact, `r = −1`,
  or `−r + c ≤ 99`, and the root's loss is authoritative only when every
  allowed loss is certain (2026-10-16: in `8/8/8/Q7/8/1p6/k6K/8 b - - 94 1`,
  `a2b2` has `r = −6` from a rounded opponent DTZ 5, White needs 6 plies, and
  Black claims the draw; the engine played `a2b2` and reported −28000);
- the root move set matches that authority (2026-10-16, three-way review,
  Astra F1): with no repeated position in the reversible window the moves
  rank certain win > uncertain win > draw > uncertain loss > certain loss,
  and only the best rank is searched, so a proven win or loss holds for
  every move the engine may choose. With a repeated window the classes stay
  whole (win > draw > loss) and nothing is authoritative: a claim may spoil
  a certain win or save a certain loss. Witness:
  `8/8/8/Q5p1/8/8/8/3K2k1 b - - 94 1 moves g1h1 a5a6 h1g1`,
  `searchmoves a6a2 a6a5` (a6a5 certain but into a twofold, a6a2 a rounded
  boundary win that draws) played a6a2 with 28000;
- the outcome is the best of the moves' own states. The root summary state
  never replaces the suggested move's own state: at
  `8/8/8/6p1/8/8/Q7/3K3k w - - 99 2` the summary said win while every move
  reaches the 50-move claim.

Witness: `8/8/Q7/6p1/8/8/8/3K2k1 w - - 97 1`. `a6a2` has a rounded `r = 3`
(`r + c = 100`) and five exact `r = 3` wins exist; the old rule played `a6a2`,
which draws.

### 9.3 Root summary: today's engine contract

`tb_probe_root(rule50 = c)` returns the following, and the replacement must
return the same quantities:
1. **Root DTZ** `D = dtz(root)`. A probe failure means the whole root call
   fails.
2. **No legal moves.**
   - `D < 0`: the checkmate sentinel;
   - `D = 0`: the stalemate sentinel.

   `src/search/syzygy.zig` treats both as "no verdict".
3. **Per-move records** for every legal move: state (§9.2), `|r|`, and the ep
   flag. zigqueen's `rootPolicy` requires exactly one record per legal move.
4. **Suggested move.** Fathom's choice, which is behaviour, not format:
   - `D > 0`: the move with the smallest positive `r`;
   - `D < 0`: the move with the most negative `r`;
   - ties go to the first move in **Fathom's generation order**. That order is:
     king moves first, then queens, rooks, bishops, knights, pawns; origin
     squares ascending; destinations ascending. For a pawn, its ep capture
     comes first, and each promotion destination expands to Q, N, R, B in that
     order;
   - `D = 0`: Fathom picks a drawing move pseudo-randomly from its private
     material hash. **Do not replicate it.** zigqueen plays the suggested move
     at once only when it is a certain, non-repeating win (§9.2, §9.5);
     otherwise the certain non-repeating win with the smallest `r`, or, with
     none, a search (`src/search/engine.zig`, the instant-move branch). The
     own prober suggests the first drawing move in the generation order above.
5. The **reported root state** is §9.2 applied to `D`, and the reported DTZ is
   `|D|`.

Because the engine plays the suggested move instantly in won roots, a
bit-identical G2 needs the same tie-break; see Q4.

### 9.4 Zeroing moves and promotions

Zeroing moves never use the DTZ table of the child:
- they reset the counter;
- their `r` is fixed by the child's WDL alone (§9.1).

Consequences:
- A winning zeroing move always has `r = 1`, so it is preferred over any
  non-zeroing win.
- A drawing capture has `r = 0`. A losing pawn move has `r = −1`, the shortest
  possible resistance.
- Promotions are zeroing moves. A promotion that leads into another table is
  valued by that table's full WDL.

### 9.5 Repetition and rank bands (reference behaviour; not v1 policy)

The prober has no history. The references apply repetition at the ranking
layer.

**[SF]:**
- A non-zeroing root move that completes a repetition, or a 50-move draw when
  the rule is enabled, gets `r = 0`.
- If the root position has repeated since the last zeroing move, the "all
  certain wins rank equal" rule is dropped, so the engine must make DTZ
  progress.

**Rank bands** (Fathom's `tb_probe_root_dtz` and [SF], with the counter c):
- `r > 0`:
  - top band if `r + c ≤ 99` and the position has not repeated;
  - else `1000 − (r + c)`.
- `r < 0`:
  - bottom band if `−2r + c < 100`;
  - else `−1000 + (−r + c)`.
- The display scores interpolate between the bands.

`rankRoot` stays history-free and returns values only. The engine's root
policy applies the game history (2026-10-15, audit D U-TB-REP): a non-zeroing
move whose child would be the third occurrence of its position is a draw (the
opponent can claim it), and a win whose child occurred once (a twofold) stays
a win but is never played at once. Witnesses, both legal histories:
`4k3/8/8/8/8/8/3QK3/8 b - - 1 1 moves e8f8 d2c2 f8e8 c2d2 e8f8 e2e1 f8e8`
(the old instant win `e1e2`) and
`8/8/8/8/8/8/8/R4K1k b - - 1 1 moves h1h2 f1e1 h2h1 e1f1 h1h2 f1e1 h2h1`
(`e1f1`). Driving a win from the start cannot meet this case (DTZ falls every
full move); it needs history from elsewhere or tablebases enabled mid-game.

Since 2026-10-16 (review round, U-TB-REP) the policy also applies the
**window rule**: once any position of the root's reversible window (since the
last zeroing move) has already occurred twice, nothing is played at once and a
win or loss is not authoritative; the engine searches the outcome-preserving
move set and reports the searched score. A draw stays authoritative (a claim
can only draw). Witness: in
`8/8/8/8/8/8/7k/R4K2 w - - 1 1 moves f1e1 h2h3 e1f1 h3h2 f1e1 h2h1` the child of
`e1f1` is new, but Black's only reply `h1h2` recreates the start a third time;
`e1f2` mates in 3. Why the rule suffices: from a certain win the winner can
play DTZ-optimally, DTZ falls every ply until the next zeroing move, so no
position of that line repeats within it; an earlier position of the window can
come back at most once, and it occurred at most once before.

---

## 10. Reference disagreements and known defects

| # | Topic | References | Effect on the 3-4-5/6 data | Ruling for zigqueen |
|---|---|---|---|---|
| 1 | Value of a single-valued **DTZ** subtable | [SF] uses byte 1; [FA][DM] use 0; [PC][SK] use 0, citing a de Man post (talkchess p=698093) | None: byte 1 = 0 in all 6 local cases [CEN] | Use 0. G0 asserts byte 1 = 0 |
| 2 | DTZ stored-side check for **symmetric** materials | [FA][DM] never check symmetric tables. [SF][SK][PC] skip the check only for pawnless symmetric tables and check pawnful ones | None: the stored side is 0 in all 38 symmetric DTZ subtables [CEN] | Check whenever pawnful (the [SF]/[SK] rule). G0 asserts the bit is 0, so the branch is unreachable on today's data and Fathom parity holds |
| 3 | Position where **every legal move is a capture** (WDL) or zeroing (DTZ) | [SF] skips the table and returns the move values (its example: `4K3/4q3/6p1/2k5/6p1/8/8/8 w - - 0 7`). [FA][DM][PC] always read the table and take the maximum | Equal under §7.1's invariant. On that position the table path ([PC] run, 2026-10-14) gives WDL −2 and DTZ −1, which is what the shortcut yields by construction | Follow [FA] (the oracle). G1 has a stratum for it (§11.3) |
| 4 | Root win at `r + c = 100` | [FA] `tb_probe_root` says win (≤ 100). [SF] and [FA]'s own `tb_probe_root_dtz` treat only ≤ 99 as certain | A rounded DTZ can make a labelled "win" a 50-move draw by one ply | The prober keeps [FA]'s states and carries `exact`. Since 2026-10-15 the root policy ranks a non-exact win at `r + c = 100` below certain wins and never plays it at once (§9.2, Q6) |
| 5 | Error masking in the 1-ply DTZ search | [DM] `TB_probe_dtz` (commit `4fb4142`): the loop tests the pointer `success` instead of `*success`, and each recursive call resets `*success = true`. A failed child probe followed by a successful one is reported as success. [FA] checks after every child and fails | Only with missing or unreadable tables | Every error propagates (error unions) |
| 6 | Big-endian hosts | [FA] reads block lengths natively without byte-order conversion | None on x86-64 or ARM64 | Decode all fields as LE explicitly |
| 7 | Colour frame from the header vs the name | [PC] recomputes the key from the header; [FA][SF] use the name | None: they agree for all 1,020 files [CEN]. They differ only for giveaway tables [DMF 2016] | Header authoritative. Name/header mismatch beyond a mirror is `CorruptTable` |
| 8 | Root move choice | [FA] `tb_probe_root` uses the minimum `r` with its generation order and a pseudo-random draw. [SK] `best_move` uses the best WDL, then mate, then zeroing preference, then DTZ. [SF] ranks and lets search decide | Different suggested moves are expected | Only per-move values are format facts. Suggested-move parity is Q4 |
| 9 | Fathom DTM path | Broken (our Fathom audit) | n/a | DTM out of scope |
| 10 | Fathom `tb_init` path list, unchecked mallocs | Our Fathom audit | n/a | Gone with Fathom. The registry parses path lists with fixed bounds |
| 11 | Validation depth | [FA][DM] trust headers (asserts). [SK] checks bounds, code lengths, block size and walk limits | n/a | Adopt §4.6 (the [SK] level, plus the section-size equality) |

---

## 11. Test-oracle plan (G0/G1)

### 11.1 Oracles and their API mapping

**Fathom**, the primary oracle. It lives in a **test-only** build target
(`zig build tb-oracle`), never linked into the engine. It is called through its
public API only:
- **WDL:** `tb_probe_wdl(…, rule50 = 0, castling = 0, ep, turn)` gives 0–4 or
  `FAILED`.
- **DTZ:** `tb_probe_root(…, rule50 = 0, …, results)`.
  - `D = ±TB_GET_DTZ`, with the sign from `TB_GET_WDL`: win and cursed are
    positive, loss and blessed negative, draw 0.
  - The checkmate sentinel means `D = −1`; the stalemate sentinel means
    `D = 0`.
- **Root:** `tb_probe_root(…, rule50 = c, …, results)` gives the root `D`, the
  root state, the suggested move and per-move records.

**python-chess 1.11.2**, the second oracle. It runs as a separate process from
a script; nothing is linked:
- `probe_wdl` and `probe_dtz`;
- per-move root values are rebuilt from the children's `probe_wdl` and
  `probe_dtz` using §9.1.

A Fathom versus python-chess disagreement is logged and triaged separately. It
is not counted as our failure, but it blocks PASS until it is explained.

### 11.2 G0: static and self-tests (no oracle)

**Command:** `ZQ_TB_CENSUS_PATH=<path list> zig build test`, for example
`ZQ_TB_CENSUS_PATH=/path/to/syzygy/3-4-5:/path/to/syzygy/6`.
On Windows, `zig build test-exe -Dtarget=x86_64-windows` installs the same
test binary to run natively there with the variable set to a `;` list.

- **Census as tests (§1.2):**
  - every installed file parses;
  - computed end + 16 equals the size;
  - block-length sums equal table sizes;
  - the §10 assertions hold (DTZ single value 0, symmetric stored side 0);
  - header and name agree.
- **Comptime tables** equal the published arrays. A one-time comparison
  against Fathom's arrays is part of the oracle target.
- **Index self-test** (all 3-piece and 4-piece pawnless tables, every legal
  placement):
  - `I < size`;
  - all 8 board symmetries of a pawnless position give the same `I`, except
    one residual case: when the whole leading group lies on the a1–h8
    diagonal after normalisation, §5.4 does not transpose, so the transposed
    image has its own index (both are stored, with equal values);
  - two positions sharing an `I` are symmetric images.

  For pawnful tables the file mirror gives the same `I`, except when two
  leading pawns tie on mirror files of one rank (§5.3).

  *Corrected in phase 2:* the two exceptions were missing here.
- **Metamorphic invariance** (any table, sampled):
  - the colour-mirrored twin of a position has identical WDL, DTZ and root
    records. The twin swaps colours, mirrors ranks, mirrors the ep square and
    swaps the side to move;
  - pawnless positions are invariant under all 8 symmetries; pawnful under the
    file mirror.
- **Test vectors** in Appendix A.

### 11.3 G1: random legal positions per table

**Tables:** all 510 materials (145 of 3-4-5, 365 of 6-man). 7-man is only
possible if some files are fetched (Q2).

**Generation.**
- Seeded PRNG. Seeds are recorded in the artifact.
- Both colour orientations of each material: generate with the canonical side
  as white, then as black.
- Both sides to move.
- Rejection sampling for legality:
  - one king per side, kings not adjacent;
  - the side not to move not in check;
  - pawns on ranks 2–7;
  - no castling.

**Strata** (each must be non-empty wherever the material allows it; the
artifact reports counts):

| # | Stratum | Construction |
|---|---|---|
| S1 | Uniform | 2,000 per table and side to move (proposed; frozen after the pilot) |
| S2 | En passant | Side to move has a legal ep capture: place the just-pushed pawn on rank 4/5 with empty transit squares and an adjacent capturer. Sub-cases: ep best, ep forced and losing, the stalemate exception of §7.3 step 5, an ep square with no legal capture (must change nothing) |
| S3 | Promotions | Side-to-move pawns on the 7th rank: free square, capture-promotions, underpromotion-relevant (knight check, stalemate trap) |
| S4 | Symmetric materials | Both sides to move, both orientations |
| S5 | Diagonal branches | Pawnless leading pieces on the a1–h8 diagonal: 1, 2 or all 3, and KK with both kings on it |
| S6 | Leading-pawn edge cases | Mirror ties (same rank, files f and 7−f), all four subtables, leaders on files e–h, interleaved files for both-colour pawn tables |
| S7 | Other side stored | Positions whose stm differs from the DTZ stored side, at least 200 per table where the side exists |
| S8 | All moves captures / zeroing | §10 item 3 |
| S9 | Terminal | Checkmate, stalemate, mate in 1 by a non-zeroing and by a zeroing move |
| S10 | Root clocks | Root records at c ∈ {0, 1, 2, 50, 98, 99, 100}, to cover the §9.2 boundaries |
| S11 | Table features | Single-valued subtables; mapped and unmapped DTZ; each plies-flag combination; subtables above 2³² (94 files). Positions are chosen from the census per feature |
| S12 | Capture chains | Multi-capture resolution into smaller tables, down to KvK |

**Exhaustive part:** all legal positions of the five 3-piece tables, with WDL,
DTZ and root records.

**Comparisons**, all **zero mismatches** to PASS:
1. WDL state, ours versus Fathom, for every position. Our WDL ignores the
   clock; Fathom gets `rule50 = 0`.
2. DTZ, ours versus Fathom's `D`, for every position.
3. Root, on a subset (S10 plus 200 positions per table): records as a set keyed
   by (from, to, promotion piece), with fields (state, `|r|`, ep flag); root
   `D` and root state; the suggested move's `r`, and its identity whenever Q4
   is answered "replicate".
4. python-chess, on a subsample (proposed 200 per table and side to move): WDL
   and DTZ against ours; per-move root `r` rebuilt by §9.1.
5. **Failure distinctness.** In a temporary directory of symlinks with one
   dependency table removed, every affected probe returns an error or the
   correct value, never a wrong value. Fathom may fail where we still answer
   correctly (an early exit that never needs the removed table), never the
   reverse.

**Venue:** our development machine, using the complete installed 3–6-piece
set.
- Probe one table's positions together, for page-cache locality: 161 GB
  (150 GiB) of tables against 94 GB of RAM.
- Cost is **unmeasured**. The design note guessed about an hour. Run a pilot
  first: all of 3-4-5 plus 10% of the 6-man tables. Then freeze per-stratum
  counts and the time cap before the full run.

**Artifacts** (private records), containing:
- seeds;
- per-table stratum counts;
- mismatch list (empty for PASS);
- oracle-disagreement list;
- tool and table hashes;
- run times.

**After G1 passes:** G2 engine parity, G3 performance, G4 the Y9AlGOL4 replay
under `RLIMIT_AS`, G5 concurrency under TSAN and G6 games, all as in design
note §6.

---

## 12. Module layout proposal (interfaces only)

This matches design note §5. The signatures are illustrative Zig; there are no
bodies.

```
src/tb/types.zig     shared value types and the error set
src/tb/index.zig     comptime tables (§5.5–§5.6) and index computation (§5)
src/tb/format.zig    file-name parsing, header parsing and validation (§3–§4)
src/tb/decode.zig    block location and symbol decoding (§6)
src/tb/storage.zig   comptime storage interface; MmapAll, MmapBudget, Pread
src/tb/registry.zig  directory scan, immutable Snapshot, swap and lease
src/tb/probe.zig     wdl, dtz, rankRoot (§7–§9) over our Position and movegen
```

`src/search/syzygy.zig` keeps its public surface: `Job`, `probeWdl`,
`probeRoot`, `probeRootMoves`, `RootPolicy` and `wdlScore`. It swaps its
backend to `src/tb`. `src/search/tb_service.zig` (the two gates) is replaced
by the snapshot lease. `deps/fathom` and `fathom_bridge.c` move to the
test-only oracle target (Q3).

### types.zig

```zig
pub const Wdl5 = enum(i8) { loss = -2, blessed_loss = -1, draw = 0, cursed_win = 1, win = 2 };
pub const Dtz = struct { plies: i16, exact: bool };            // §8.1; 0 for draws
pub const ProbeError = error{
    OutOfScope,     // castling rights, too many pieces, invalid position
    MissingTable,   // some needed WDL/DTZ file is absent from the snapshot
    CorruptTable,   // §4.6 validation or a probe-time bound failed
    Io,             // pread failure
    MapFailed,      // mmap failure or address-space budget exhausted with no fallback
};
pub const RootRecord = struct { move: Move, r: i16, state: Wdl5, exact: bool, zeroing: bool, en_passant: bool };
pub const Terminal = enum { none, checkmate, stalemate };
pub const RootRanking = struct {          // caller-owned, fixed capacity (MoveList.MAX_MOVES = 256)
    records: [256]RootRecord, count: u16,
    root_dtz: Dtz, root_state: Wdl5, suggested: ?u8, terminal: Terminal,
};
```

### index.zig

```zig
pub const binomial: [8][65]u64;               // comptime; C(n, k) for k ≤ 7, n ≤ 64
pub const kk_index: [10][64]u16;              // comptime from the §5.5 enumeration; 0xFFFF = impossible
pub const lead_index: [7][64]u64;             // comptime; first term of §5.6 by (k, leading square)
pub const lead_size: [7][4]u64;               // comptime; lead_size(k, t)
pub const twist: [64]u8;                      // comptime pawn order (§5.6)
pub fn encode(desc: *const format.Descriptor, squares: *[7]u6) u64;   // §5.3–§5.8 on a filled list
```

### format.zig

```zig
pub const Descriptor = struct {               // one per (subtable, side), §4.2 + §5.8
    codes: [7]u4, group_start: [7]u3, group_len: [7]u3, group_count: u3,
    lead: enum { kk, three, pawn }, lead_len: u3, second_pawns: u3,
    factor: [7]u64, size: u64,
};
pub const Compressed = struct {               // §4.3 / §6
    block_bits: u4, index_bits: u5, real_blocks: u32, length_entries: u32,
    min_len: u6, max_len: u6, first: [33]u16, base: [33]u64,       // base left-justified
    symbols: []const [3]u8, expand_len: []const u8,                // snapshot arena
    sparse_off: u64, lengths_off: u64, data_off: u64,
};
pub const Pairs = union(enum) { single: u16, compressed: Compressed };
pub const DtzExtra = struct { flags: u8, maps: ?[4]MapRef };       // stored side, plies bits, maps
pub const Subtable = struct { desc: Descriptor, pairs: Pairs, dtz: ?DtzExtra };
pub const Table = union(enum) {
    piece: struct { sides: [2]?Subtable },             // WDL: 1–2 sides; DTZ: 1
    pawn: struct { files: [4][2]?Subtable, lead_code: u4 },
};
pub fn parseName(name: []const u8) ?Material;
pub fn parseHeader(arena: Allocator, header: []const u8, file_size: u64, m: Material, metric: Metric) ProbeError!Table;
```

### decode.zig

```zig
pub fn valueAt(c: *const format.Compressed, io: anytype, file: FileId, index: u64) ProbeError!u16;   // §6.3–§6.4
```

`io` is any storage backend (below). The block buffer `[1024 + 8]u8` is a
local of `valueAt`, so the probe path uses no heap.

### storage.zig

The storage interface is a comptime interface. `Prober(Backend)` is
instantiated at comptime, so dispatch costs nothing.

```zig
// Required shape of a backend:
//   fn view(self: *const B, file: FileId, offset: u64, len: u32, scratch: []u8) ProbeError![]const u8;
// Returns a slice into a mapping (mmap backends) or into `scratch` filled by a
// positioned read (Pread). The slice is valid until the caller's next call.
pub const MmapAll = struct { … };     // map whole file on first touch; publish once (atomic CAS; the loser unmaps)
pub const MmapBudget = struct { … };  // address-space budget; evict only at quiescent epochs; over budget → Pread for that file
pub const Pread = struct { … };       // files kept open; positioned reads; no shared cache in v1
```

The Windows equivalents are `CreateFileMapping` / `MapViewOfFile` and
`ReadFile` with an `OVERLAPPED` offset.

`MmapBudget` falls back per file to positioned reads, so that a full budget
never loses a table. That is G4's "no lost tables" without unmapping during a
search.

### registry.zig

```zig
pub const Snapshot = struct {
    entries: []const Entry,           // sorted by material key; Entry = { key, mirror_key, pieces, wdl: ?FileRef, dtz: ?FileRef, wdl_table: Table, dtz_table: ?Table }
    max_pieces: u8,
    pub fn find(self: *const Snapshot, key: MaterialKey) ?*const Entry;
};
pub fn build(gpa: Allocator, path_list: []const u8, mode: StorageMode) ProbeError!*Snapshot;  // off the search path
pub fn acquire() Lease;               // atomic pointer load + refcount; replaces the `lifetime` gate
pub fn swap(next: ?*Snapshot) void;   // old snapshot freed when its last lease drops
```

**Header parsing.** Headers are parsed eagerly in `build`:
- at most 38 MB of header bytes for 3-4-5 plus 6 [CEN];
- failure is detected at `SyzygyPath` time;
- probes need no lock and no allocation.

The alternative, lazy parsing into preallocated per-file slots, is Q8.

### probe.zig

These are pure functions of (snapshot, position):

```zig
pub fn Prober(comptime Backend: type) type {
    return struct {
        pub fn wdl(snap: *const Snapshot, io: *const Backend, pos: *const Position) ProbeError!Wdl5;      // §7.3
        pub fn dtz(snap: *const Snapshot, io: *const Backend, pos: *const Position) ProbeError!Dtz;       // §8.2
        pub fn rankRoot(snap: *const Snapshot, io: *const Backend, pos: *const Position, c: u16, out: *RootRanking) ProbeError!void; // §9
    };
}
```

**Moves.** Legal moves come from `src/movegen/legal.zig` and positions are
copied with `make_unmake`. Fixed-capacity `MoveList` (256) buffers live on the
stack.

**Recursion depth:**

| Probe | Nesting |
|---|---|
| WDL | ≤ N − 2 levels (captures) |
| DTZ | WDL, plus one 1-ply level, plus the child's WDL |
| Root | one level more |

This is about 8 frames of under 2 KiB each for 7 pieces.

**Threading:**
- the snapshot is immutable;
- the only shared mutable state is per-file mapping publication (atomic) and
  `MmapBudget`'s epoch;
- there is no exclusive root phase and no global first-touch mutex.

### Implementation notes (phase 2, 2026-10-14)

The module layout above is implemented as `src/tb/{types,index,format,decode,
storage,registry,probe}.zig` with `src/tb/tb.zig` as the root. Where the code
differs from the illustrative signatures:
- `Dtz.plies` is `i32`, and `RootRanking.suggested` indexes `records`.
- The snapshot owns its backend instance. Probes take
  `(snap, pos)`; `Prober(B).wdlLegal` is the search entry (it skips the
  validity checks that legal search positions always pass).
- `registry.build(Backend, gpa, path_list, options)` parses every header
  eagerly (Q8). Files that fail §4.6 are rejected one by one and counted; the
  rest load. Tables with more than 6 pieces are skipped (Q2).
- `view(file_index, offset, len, scratch)` is the storage interface. Files
  are opened lazily and their handles published once.
- `MmapBudget` never unmaps while its snapshot lives. Address space comes
  back when the snapshot dies after its last lease, which is the quiescent
  point of v1. Within one snapshot a full budget sends further files to
  positioned reads. The default budget is half of `RLIMIT_AS`, or 64 GiB
  without a limit.
- *Superseded in phase 3:* Windows mapping, the budget default and the
  Fathom-era engine plumbing; see the next section.

### Implementation notes (phase 3, 2026-10-14)

- **Own-only engine.** The engine links only `src/tb`. Fathom and its bridge
  (`src/tb_oracle_fathom.c`) are linked into the test-only `tb-oracle` tool
  alone. `src/search/tb_service.zig` (the Fathom admission gates), the
  trailing-separator guard and the "no standalone probe while holding a Job"
  rule are gone. `-Dtb-storage=budget|mmap|pread` remains.
- **Threading.** One `Job` is one snapshot lease, pinned per search by the
  coordinator; helpers borrow it. WDL and root probes take no lock and nothing
  is exclusive. Releasing a lease never frees: `swap` retires the old
  snapshot and the registry's owner thread (the UCI thread) frees retired
  snapshots without a lease in `swap` and `collect` (called on `isready`,
  `ucinewgame` and `quit`). The engine stops every search before a
  `SyzygyPath` change, so the old snapshot is freed inside that `setoption`.
- **Root policy.** The ranking (§9) feeds `rootPolicy` directly; the Fathom
  `TB_RESULT_*` encode/decode round trip and the coverage check against a
  separately generated move list are gone (the records come from the same
  move generator).
- **Storage.** `MmapAll` and `MmapBudget` share one implementation. A file
  whose mapping fails falls back to positioned reads in both modes and is
  counted (`map_failures`, `pread_files`); `MapFailed` is no longer an error.
  The default budget is unlimited when `RLIMIT_AS` is infinite and on Windows;
  under a finite `RLIMIT_AS` it is half the limit (Q1).
- **Windows mapping.** The file is opened read-only with `FILE_SHARE_READ`,
  mapped with `CreateFileMappingW(PAGE_READONLY)` at its 64-bit size and
  viewed whole with `MapViewOfFile`. Both handles are closed right after the
  view exists (the view keeps the file open); `UnmapViewOfFile` runs when the
  snapshot is destroyed.
- **Search entry guard.** `wdlLegal` also refuses pawns on rank 1 or 8, which
  a malformed GUI FEN could bring into the search (review-v1 finding 1).

Phase-3 review fixes (2026-10-14):
- **Relative paths on Windows.** The mapping opens a file relative to the
  working directory, as the directory scan and positioned reads do; before,
  a cwd-relative `SyzygyPath` loaded and then every mapping failed (ReleaseSafe:
  a panic).
- **Mapping at load.** The engine maps every file when `SyzygyPath` is set
  (as the budget allows; probes no longer map on first touch) and reports one
  line on the UCI thread: `info string Syzygy tables: <n> WDL and <n> DTZ
  files, up to <k> pieces, <r> rejected; storage <mode>: <m> files mapped
  (<MiB>), <p> on positioned reads, <f> mapping failures`.
- **File names on Windows** are matched case-insensitively (spelled
  canonically, e.g. `kqvk.RTBW` as `KQvK.rtbw`, before parsing); elsewhere
  exactly.

Fix round 2 (2026-10-14):
- **Publish, then map.** A load publishes the new snapshot (which frees the
  old one) before it maps, so a reload under a finite `RLIMIT_AS` gets the full
  budget. The guard for this is the RLIMIT reload check
  (a separate script), not `zig build test`.
- **Smallest files first.** Under a finite budget, files are mapped in order
  of size in bytes, ties in file order, so as many files as possible are
  mapped. The rest use positioned reads.
- **Report line** formatted into its own 384-byte buffer; the worst case is
  229 bytes.

---

## 13. Open questions for the maintainer

### Decisions (maintainer, 2026-10-14)

| # | Decision |
|---|---|
| Q1 | Bounded by default: `MmapBudget` with a per-file positioned-read fallback when the budget is full, so no table is ever lost. `MmapAll` stays an option. |
| Q2 | 7-man is unsupported in v1, for now. Indices stay 64-bit so 7-man is not precluded. |
| Q3 | Fathom stays only as a test-only oracle, in a test build target. The engine binary must not link it once the replacement is the default. |
| Q4 | The tie-break among equally good winning root moves copies Fathom's move-generation order in v1, because the engine-parity gate (G2) needs identical transcripts. Our own order is revisited later. |
| Q5 | The missing-DTZ fallback (WDL-only root ranking) comes later, as a separate candidate. Not in v1. |
| Q6 | v1 keeps Fathom's 50-move boundary rule: DTZ + counter = 100 counts as a win. Superseded at the policy layer on 2026-10-15 (audit D, U-TB-DTZ100): the prober's states are unchanged, but the root policy treats a non-exact win at the boundary as uncertain (§9.2). |
| Q7 | python-chess is acceptable as an out-of-process test oracle, and reading GPL references for format facts is acceptable. Their code is never copied or translated. |
| Q8 | Eager header parsing when `SyzygyPath` is set, if feasible; otherwise measure and report. Measured in phase 2: 37.8 MB of headers from 1,020 files in 85–156 ms with a warm page cache, about 67 MB of resident memory per snapshot. Kept eager. |

The questions as they were asked follow.

From design note §8:

**Q1. Default storage mode.** The candidates are:
- `MmapAll`: today's behaviour, and the fastest when there is no cap;
- `MmapBudget` with a per-file Pread fallback;
- `Pread`.

New facts:
- mapping costs address space only;
- the full 3-4-5 plus 6 set is 161 GB (150 GiB) of mappings;
- with a Pread fallback, a bounded budget can never lose a table, and it costs
  nothing until the budget is hit.

*Proposed:* bounded by default (`MmapBudget` with fallback, budget derived from
the `RLIMIT_AS` headroom), and `MmapAll` and `Pread` selectable. Your call.

**Q2. 7-man ever?** Index width is already u64 (forced by 6-man), so what
remains:
- registry capacity: 1,511 materials;
- wide DTZ maps, which no local file exercises, so the oracle cannot test them
  without fetching some 7-piece files;
- 16.7 TiB of storage;
- probably `Pread` as the default.

Decide before the format work is frozen: fetch a handful of small 7-piece files
for G1, or declare 7-man unsupported in v1.

**Q3. How long does Fathom stay as a test-only oracle?** *Proposed:* until the
replacement has shipped in one release and G1 has run on that release
candidate. After that, python-chess remains the regression oracle.

New:

**Q4. Suggested-move tie-break.** The engine plays Fathom's suggested move
instantly in won roots. A bit-identical G2 therefore needs Fathom's generation
order as the tie-break (§9.3). That order is behaviour, not format. *Proposed:*
replicate it in v1 as a documented order key, then revisit it.

**Q5. Missing DTZ with WDL present.** Fathom's root probe then fails (that is
what Y9AlGOL4 hit); [SF] falls back to WDL-only ranking. A fallback is a
behaviour change. *Proposed:* a separate candidate after v1.

**Q6. The rule-50 boundary.** Fathom labels `r + c = 100` a win (§10 item 4).
*Proposed:* keep it for parity in v1 and carry `exact`; a rounding-aware rule
is a later, measured policy candidate.

**Q7. GPL references and oracle.** Please confirm two points:
- python-chess (GPL-3.0+) as an out-of-process test oracle and script
  dependency is acceptable;
- reading Stockfish and shakmaty (GPL) for format facts, with nothing copied,
  is acceptable.

`ORIGINALITY_RULES.md` forbids only our own earlier engines.

**Q8. Header parsing at `SyzygyPath` time.** Eager parsing reads up to 38 MB of
headers from 1,020 files once, which may cost seconds on a cold disk. Lazy
parsing defers that cost and adds a publish-once step in the probe path.
*Proposed:* eager, with the time measured in G3.

---

## Appendix A: test vectors

These were computed by the clean-room implementation of §1.3.

The stored values and final WDL/DTZ agree with python-chess. Phase 2 confirms
the WDL and DTZ columns with the Zig prober on all three storage backends
(G0, `src/tb/tb_test.zig`). Fathom has no public index function, so the index
column stays our own computation; G1 checks the same encoding end to end
through Fathom's probe API instead.

Columns:
- `t`/`s`: subtable and side;
- `I`: WDL index;
- `raw`: stored WDL code;
- WDL and DTZ: the full probe results.

| FEN | Table | t / s | I (WDL) | raw | WDL | DTZ | DTZ subtable |
|---|---|---|---|---|---|---|---|
| `8/8/8/8/8/8/8/R3K2k w - - 0 1` | KRvK | 0 / 0 | 23565 | 4 | 2 | 5 | index 7817 |
| `8/8/8/8/8/8/8/R3K2k b - - 0 1` | KRvK | 0 / 1 | 7817 | 0 | −2 | −10 | other side stored |
| `8/8/8/4k3/8/8/2Q4r/K7 w - - 0 1` | KQvKR | 0 / 0 | 1475562 | 4 | 2 | 1 | index 1842260 |
| `7k/8/8/8/3K4/8/8/R6R b - - 0 1` | KRRvK (KK, both kings on the diagonal) | 0 / 1 | 839597 | 0 | −2 | −6 | other side stored |
| `8/8/8/8/8/8/5P2/K6k w - - 0 1` | KPvK (leader on f → file mirror) | 2 / 0 | 7 | 4 | 2 | 1 | index 7 |
| `8/8/2p5/8/8/5P2/8/K6k b - - 0 1` | KPvKP (symmetric, black to move) | 2 / 0 | 1054240 | 0 | −2 | −1 | index 337403 |
| `7k/8/8/8/3B4/8/1K6/N7 b - - 0 1` | KBNvK (four pieces on the diagonal) | 0 / 1 | 1902459 | 0 | −2 | −49 | index 1904358 |
| `8/8/8/8/1p6/8/P7/K1k5 w - - 0 1` | KPvKP | 0 / 0 | 60574 | 0 | −2 | −1 | index 363444 |
| `8/2k3K1/8/8/3b4/2n5/1R6/7B w - - 0 1` | KRBvKBN (I > 2³²) | 0 / 0 | 6718818595 | 3 | 1 | 125 | index 6700800354 |
| `7b/3P4/2B2K2/8/N4k2/8/8/8 w - - 0 1` | KBNPvKB (I > 2³²) | 3 / 0 | 5053241886 | 4 | 2 | 3 | index 4627461618 |
| `8/8/4P3/8/1p1K4/8/2k4r/R7 w - - 0 1` | KRPvKRP (symmetric, two pawn groups) | 3 / 0 | 1802225865 | 4 | 2 | 3 | index 1782835241 |
