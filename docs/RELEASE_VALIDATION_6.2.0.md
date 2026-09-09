# 6.2.0 release validation

The public release uses the externally tested SEE/pruning/QAT engine and
network. Release preparation changes version/packaging metadata, provenance
comments and two developer-tool default tablebase paths; it introduces no
new search or evaluation policy after the gauntlets.

## Correctness and packaging

- ReleaseFast unit suites passed with normal, search-statistics and tuning
  build options. Source hygiene and whitespace checks passed.
- UCI compliance, repeated-search stability and network symmetry/material
  checks passed. Release UCI identification is `zigqueen 6.2.0`; its seven
  public options match the README.
- Native Linux plus all six portable builds reproduce the frozen
  gauntlet candidate's depth-14 nodes, score, PV and best move on the three
  positions below, with Hash 64 MB and no tablebases.
- Windows executables were run natively. ARMv8 was exercised under QEMU
  Cortex-A53; the dotprod/i8mm variant under QEMU's `max` CPU. These are
  execution checks, not a new physical Android-device test.
- Both OEX APKs retain the published signing certificate, version code
  620 and version name 6.2.0. Their embedded engine bytes match the tested
  ARM binaries and both carry the current license notices.
- The exact public source export passed a secret scan. The release branch
  descends from the previous public main; private history is not published.

| Position | Nodes | Score (cp) | Best move |
|---|---:|---:|---|
| Start position | 133472 | 29 | d2d4 |
| `r1bq1rk1/2p1bppp/p1np1n2/1p2p3/4P3/1BP2N2/PP1P1PPP/RNBQR1K1 w - - 0 10` | 81768 | 49 | h2h3 |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 29154 | 62 | b4f4 |

## Provenance checks

The [Stormphrax retune table](PROVENANCE.md#1-search-shaping-a-parameter-set-taken-from-stormphrax)
was checked against the original and selected local policy values: 12
coordinates, 11 changed numbers. Original attribution remains.

The network hash is recorded in [NETWORK.md](NETWORK.md). Comparing it
with the original base finds changed bytes only within nonlinear head
tensors; feature-transformer and PSQT bytes remain identical.

All 13,584 recorded data sidecars were checked against their manifests:
210,791,379 tablebase replacements and 223 anchor replacements across the
full local corpus. The [replay utility](data-r1/README.md) reproduced the
recorded rewritten SHA-256 of a complete 16-million-occurrence file
containing both tablebase and anchor changes. This is a replay check,
not a claim to have independently recovered every upstream teacher label.

The release's `SHA256SUMS` covers the six raw-binary archives, two signed
APKs and the data-alteration archive. Match results and their uncertainty
remain in [STRENGTH.md](STRENGTH.md).
