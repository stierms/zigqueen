# zigqueen on Android

zigqueen runs on 64-bit Android as a native UCI engine. The NNUE evaluation
uses portable integer SIMD, so the ARM build is **bit-identical** to the x86
builds — verified by matching fixed-depth node counts on-device.

## Just want the engine?

Each release ships ready-made artifacts:

- **`zigqueen-<version>-oex-*.apk`** — install like any app; OEX-compatible
  chess GUIs (Chess for Android, DroidFish, Acid Ape Chess, ...) discover the
  engine automatically. This is the recommended route: modern Android blocks
  most GUIs from importing raw binaries from storage.
- **`zigqueen-<version>-android-armv8[-dotprod].zip`** — the raw static
  binaries, for Termux or GUIs that can still execute imported files.

Pick `dotprod` on SoCs from ~2018 onward (it uses the `udot`/`usdot` NNUE
kernels); `armv8` runs on any 64-bit device. If `dotprod` crashes instantly
with an illegal-instruction error, your SoC is older — use `armv8`.

Expect very roughly a third of a modern desktop core's speed on a current
flagship, with thermal throttling in long sessions.

## Verifying an APK is really ours

Official zigqueen APKs are published **only** on this repository's GitHub
releases. Third-party mirror sites sometimes repackage APKs with unwanted
extras; a repackaged APK cannot carry our signature. To verify:

```sh
apksigner verify --print-certs zigqueen-*.apk
```

The signer certificate must be
`CN=Matthias Stier, OU=zigqueen, O=stierms, C=DE` with SHA-256 digest:

```
c919e613db93d244216fe02288dfb1ab9af47ef43035d71b8676b6dc7cfa987e
```

Anything else claiming to be zigqueen is not from us.

## Building it yourself

The cross-compile needs no Android NDK — Zig carries everything:

```sh
zig build -Doptimize=ReleaseFast -Dcpu-baseline=armv8 -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseFast -Dcpu-baseline=armv8-dotprod -Dtarget=aarch64-linux-musl
```

The result (`zig-out/bin/zigqueen-aarch64-*`) is a fully static executable
with the network embedded: copy it to a device and run it. That single
command is the entire Android port.

To package the binaries as installable OEX engine APKs, see
[`android/oex/`](../android/oex/README.md) (needs an Android SDK for the APK
step only).
