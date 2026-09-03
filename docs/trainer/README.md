# Trainer extension (bullet patch)

The ZQB9 network was trained with [bullet](https://github.com/jw1912/bullet)
(MIT) plus a project-specific extension that teaches bullet zigqueen's
HalfKA + full-threats input mapping. `bullet-fullthreats.patch` is that
extension as a single patch against upstream bullet commit `d372d48`:

- `crates/bullet_lib/src/game/inputs/halfka_threats.rs` (new): the input
  type — mirrored HalfKA with 8 king buckets plus the 60,144 full-threat
  features, in the index layout the engine uses (`src/eval/fullthreats.zig`);
- small hooks in `inputs.rs`, `value.rs`, `value/builder.rs`,
  `value/dataloader.rs`, `value/loader.rs` to register the input type and
  the data mixing used by the recipe;
- `examples/zqHalfKA9_fullthreats_w1024_relabel26.rs` (new): the training
  recipe of the shipped network (architecture, schedule, and the data
  components listed in `../NETWORK.md`; data paths are local);
- `tools/fullthreats_grader.py` (new): the reference grader that checks the
  trainer's feature indices against the engine's tables.

Apply with:

```
git clone https://github.com/jw1912/bullet && cd bullet && git checkout d372d48
git apply /path/to/bullet-fullthreats.patch
```

then add an `[[example]]` entry for `zqHalfKA9_fullthreats_w1024_relabel26`
to `crates/bullet_lib/Cargo.toml` and run it with cargo as any bullet
example. The patch is offered as documentation of provenance and for
reproducibility; it carries bullet's MIT license for the modified files.
