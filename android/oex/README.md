# OEX engine packaging for Android

Packages the zigqueen Android binaries as Open Exchange (OEX) engine APKs —
the format modern Android chess GUIs (Chess for Android, DroidFish, Acid Ape
Chess, ...) discover automatically. On current Android versions this is the
reliable way to get an engine into a GUI; raw-binary import from storage is
blocked by scoped storage for most apps.

Two product flavors build two independently installable APKs:

- `generic` — baseline armv8 binary, runs on any 64-bit Android device
- `dotprod` — armv8.2 dotprod/i8mm binary (`udot`/`usdot` NNUE kernels),
  for SoCs from roughly 2018 onward

## Build

1. Build the engine binaries (from the repository root; no NDK required):

   ```sh
   zig build -Doptimize=ReleaseFast -Dcpu-baseline=armv8 -Dtarget=aarch64-linux-musl -Dversion=6.0.0
   cp zig-out/bin/zigqueen-aarch64-armv8 android/oex/app/src/generic/jniLibs/arm64-v8a/libzigqueen.so
   zig build -Doptimize=ReleaseFast -Dcpu-baseline=armv8-dotprod -Dtarget=aarch64-linux-musl -Dversion=6.0.0
   cp zig-out/bin/zigqueen-aarch64-armv8-dotprod android/oex/app/src/dotprod/jniLibs/arm64-v8a/libzigqueen.so
   ```

2. Create `gradle.properties` (not tracked — it holds your signing secrets):

   ```
   RELEASE_STORE_FILE=/absolute/path/to/your.keystore
   RELEASE_STORE_PASSWORD=...
   android.useAndroidX=false
   ```

   Any self-signed keystore works (`keytool -genkeypair -keystore your.keystore
   -alias zigqueen -keyalg RSA -keysize 2048 -validity 9125`); the alias must
   be `zigqueen` or adjust `app/build.gradle`.

3. Build both APKs (needs an Android SDK; `ANDROID_HOME` set):

   ```sh
   ./gradlew assembleGenericRelease
   ./gradlew assembleDotprodRelease
   ```

   Build the two large APKs sequentially; concurrent packaging can contend
   for the Android packager's temporary state.

   Outputs land in `app/build/outputs/apk/<flavor>/release/`.

## Provenance

`app/src/main/java/com/kalab/chess/enginesupport/` is vendored unmodified from
the Apache-2.0 [chessenginesupport-androidlib](https://github.com/gkalab/chessenginesupport-androidlib)
(license headers intact) — the reference implementation of the OEX provider
protocol. Everything else in this directory is zigqueen's.
