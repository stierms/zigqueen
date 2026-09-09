# 6.2.0 release validation

The public 6.2.0 source is the gauntlet-tested SEE/pruning/QAT snapshot
plus version and packaging metadata, provenance comments and two developer
tool defaults. No search or evaluation change was made after the gauntlets.

## Checks

- ReleaseFast unit suites (normal, search-statistics and tuning flavours),
  source hygiene and formatting.
- UCI compliance, repeated-search stability, network symmetry and material
  checks. The engine identifies as `zigqueen 6.2.0` and exposes the seven
  options listed in the README.
- Native Linux and all six portable builds reproduce the frozen candidate's
  depth-14 nodes, score, PV and best move on the positions below (Hash
  64 MB, no tablebases). The AVX2 build was also run on AVX2-only hardware.
- Windows executables ran natively. ARMv8 ran under QEMU (Cortex-A53; the
  dotprod/i8mm variant under QEMU's `max` CPU). These are execution checks,
  not a new physical-device test.
- Both OEX APKs carry the published signing certificate, version code 620
  and version name 6.2.0. Their embedded engine bytes match the tested ARM
  binaries; both include the license notices.
- The exact public export passed a secret scan. The release commit descends
  from the previous public main; private history is not published.

| Position | Nodes | Score (cp) | Best move |
|---|---:|---:|---|
| Start position | 133472 | 29 | d2d4 |
| `r1bq1rk1/2p1bppp/p1np1n2/1p2p3/4P3/1BP2N2/PP1P1PPP/RNBQR1K1 w - - 0 10` | 81768 | 49 | h2h3 |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 29154 | 62 | b4f4 |

## Provenance

- The [retune table](PROVENANCE.md#1-search-shaping-a-parameter-set-taken-from-stormphrax)
  was checked against the original defaults and the shipped values: 12
  coordinates, 11 changed.
- The shipped network differs from the 6.0.0 base only inside the dense head
  tensors (34,579 bytes); feature-transformer and PSQT bytes are identical.
  Hashes in [NETWORK.md](NETWORK.md).
- All 13,584 data sidecars match their manifests: 210,791,379 tablebase
  replacements and 223 anchor replacements over the full local corpus. The
  [replay tool](data-r1/README.md) reproduced the recorded SHA-256 of a
  complete 16-million-position file containing both kinds of change. This
  checks the replay, not the upstream teacher labels.

`SHA256SUMS` covers the six zips, two APKs and the data archive. Match
results are in [STRENGTH.md](STRENGTH.md).
