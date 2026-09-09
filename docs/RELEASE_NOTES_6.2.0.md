# zigqueen 6.2.0

This release promotes the externally tested candidate with the SEE changes,
locally retuned pruning policy and quantization-aware NNUE head. It also
includes move-generation, search and evaluation runtime improvements, and
live search-policy controls in tuning builds.

The embedded network keeps its existing feature transformer and PSQT
weights; its nonlinear heads were continued with deployed arithmetic in
training. Provenance documentation now distinguishes inherited search
parameters from local retunes and records the training-data score changes.
The recorded data alterations and a replay method accompany the release.

Portable Linux and Windows builds, Android raw binaries and signed Android
OEX packages are provided. The public source continues the existing release
history.

See [STRENGTH.md](STRENGTH.md) for validation results and their limits,
[NETWORK.md](NETWORK.md) for the model and training record, and
[PROVENANCE.md](PROVENANCE.md) for attribution and licensing.
