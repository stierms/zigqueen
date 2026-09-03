# zigqueen 6.1.1

A compliance release, not a strength release: 6.1.0 without its six built-in
opening-book entries, with the license texts and documentation the project
owed. Playing strength is unchanged and no new gauntlet was run; the 6.1.0
figures apply.

- The engine no longer carries a hard-coded table of six root positions with
  fixed replies. Every move is now the product of the search. Apart from
  those six positions the play is bit-identical to 6.1.0 (same fixed-depth
  node counts, same bench), so the 6.1.0 strength figures apply unchanged.
- The Android OEX APKs now carry the license texts they must distribute
  (`LICENSE` and `THIRD_PARTY_LICENSES.md` as assets: GPL-3.0-or-later, the
  Fathom MIT notice, Apache-2.0 for the vendored OEX provider library).
- Documentation: `docs/PROVENANCE.md` (new) records where ideas, parameters,
  data and third-party code come from; `THIRD_PARTY_LICENSES.md` ships with
  the binaries; `docs/NETWORK.md` now names the exact published training
  collections and the origin of their labels; the license is stated as
  GPL-3.0-or-later.

No functional change beyond the removal of the book entries.
