# Windows build

## Native build

On Windows with Zig 0.15.2 installed, the normal build works as-is:

```powershell
zig build -Doptimize=ReleaseFast
.\zig-out\bin\zigqueen.exe
```

The engine embeds its net, so the `.exe` is self-contained: point a UCI GUI at
it with no options for full strength.

## Large pages

The engine tries `VirtualAlloc(MEM_LARGE_PAGES)` for its large hash tables,
which needs `SeLockMemoryPrivilege`: grant "Lock pages in memory" to your user
account once (secpol.msc / gpedit -> User Rights Assignment), then log out and
back in. Without it the engine silently falls back to regular pages. Verify at
startup: `info string large_pages: locked` vs
`fallback (SeLockMemoryPrivilege unavailable)`.

## Building from WSL

`scripts/build-windows-revision.sh` builds a packaged native Windows binary
from a WSL checkout: it exports a chosen git revision into a Windows-visible
directory, invokes Windows PowerShell, bootstraps a portable Windows Zig
toolchain if needed, builds with `zig.exe` on the Windows side, and probes the
resulting `.exe` with a UCI smoke test.

- `scripts/build-windows-revision.sh` — build one git revision into a packaged directory
- `scripts/windows-build.ps1` — native Windows Zig build driver
- `scripts/windows-ensure-zig.ps1` — bootstrap portable Windows Zig 0.15.2
- `scripts/windows-verify-uci.ps1` — smoke-test the built `.exe` with `uci` / `quit`

Output goes to `/mnt/c/Users/$USER/zqwin` unless overridden with
`ZIGQUEEN_WINDOWS_BUILD_DIR=/mnt/c/somewhere-else`.

```bash
# usage: rev label [model|-] [uci-options|-] [summary|-] [optimize]
./scripts/build-windows-revision.sh HEAD my-build-label
```

Each package contains `zigqueen.exe`, `BUILD_INFO.txt` (peeled commit SHA, git
tree, version, build settings), optional net/options sidecars, and build/UCI
probe logs under a sibling `logs/`. Packages are exact rebuilds of a committed
revision, so a tested binary can always be reproduced from its recorded
commit.

Notes:

- A short build-root path is deliberate: Windows Smart App Control and some
  build tooling are more reliable with short paths.
- Smart App Control may block larger unsigned `ReleaseFast` binaries; if a
  build is blocked, retry with the `ReleaseSmall` optimize argument.
