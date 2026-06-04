# Local Desktop Build Scripts

These wrappers keep platform-specific build state isolated. Use them instead of
calling `flutter build` directly when switching between Linux, Windows, and
macOS from the same checkout.

## Why

Flutter writes absolute SDK and package paths into `flutter/.dart_tool`. If a
Linux build creates that metadata and Windows reuses it, Windows tries to read
paths such as `/home/...` or `/mnt/...` and the build fails with thousands of
cascading Dart errors.

The scripts detect stale cross-platform metadata and refresh `.dart_tool` for
the current platform before building.

## Windows

Default layout:

```text
F:\GH\flutter-win
F:\GH\flutter-pub-cache-win
F:\GH\rustdesk-target-win
F:\DVS
```

Run from PowerShell:

```powershell
.\scripts\build_windows.ps1
```

Optional overrides:

```powershell
.\scripts\build_windows.ps1 `
  -FlutterRoot F:\GH\flutter-win `
  -DepsRoot F:\DVS `
  -CargoTargetDir F:\GH\rustdesk-target-win `
  -PubCache F:\GH\flutter-pub-cache-win
```

Use `-NoHwCodec` to build without the `hwcodec` feature.
Use `-Clean` to force-refresh Flutter metadata and Windows build intermediates.
The Windows build and validation scripts set `RUSTDESK_WINDOWS_CODEC_ROOT` and
`CMAKE_PREFIX_PATH` from `-DepsRoot`, so clean machines do not fall back to an
incomplete Visual Studio vcpkg prefix.

The scripts also generate `flutter_rust_bridge` files when they are missing or
older than `src/flutter_ffi.rs`. Install the generator once:

```powershell
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid
```

If `ffigen` cannot find `libclang.dll`, pass an LLVM root that contains
`bin\libclang.dll`:

```powershell
.\scripts\build_windows.ps1 `
  -BridgeLlvmPath "D:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64"
```

Use `-SkipBridgeGen` when generated files are already current and the generator
is not installed. Use `-ForceBridgeGen` to regenerate them anyway.

Toolbar lab:

```powershell
.\scripts\run_toolbar_lab_windows.ps1
```

Final bundle:

```text
flutter\build\windows\x64\runner\Release
```

## Linux

The Linux wrapper discovers Flutter from `PATH`, or from
`RUSTDESK_FLUTTER_ROOT` when set. Native codec dependencies can come from
system `pkg-config` packages, from `RUSTDESK_LINUX_CODEC_ROOT`, or from the
repo-local `.local/linux-codecs` prefix.

Common system packages on Debian/Ubuntu:

```bash
sudo apt install pkg-config libgtk-3-dev libpam0g-dev libclang-dev \
  libyuv-dev libvpx-dev libaom-dev libopus-dev
```

Run:

```bash
scripts/build_linux.sh
```

By default this builds the Flutter bundle and a release zip under `dist/linux`.
To build a Debian package instead:

```bash
scripts/build_linux.sh --deb
```

To build both:

```bash
scripts/build_linux.sh --package all
```

Optional:

```bash
RUSTDESK_FLUTTER_ROOT=/path/to/flutter \
RUSTDESK_LINUX_CODEC_ROOT=/path/to/codec-prefix \
scripts/build_linux.sh --clean

scripts/build_linux.sh --hwcodec
```

Toolbar lab:

```bash
scripts/run_toolbar_lab_linux.sh
```

Validation tests:

```bash
scripts/run_linux_tests.sh
```

Final bundle:

```text
flutter/build/linux/x64/release/bundle
```

Linux package outputs:

```text
dist/linux/*.zip
dist/linux/*.deb
```

## macOS

Run on macOS:

```bash
scripts/build_macos.sh
```

Optional:

```bash
RUSTDESK_FLUTTER_ROOT=/path/to/flutter \
RUSTDESK_MACOS_CODEC_ROOT=/path/to/prefix \
scripts/build_macos.sh --screencapturekit
```

Toolbar lab:

```bash
scripts/run_toolbar_lab_macos.sh
```

Validation tests:

```bash
scripts/run_macos_tests.sh
```

Final bundle:

```text
flutter/build/macos/Build/Products/Release
```

Package, sign, and optionally notarize a distribution DMG:

```bash
SKIP_NOTARY=1 \
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
scripts/package_macos.sh
```

For notarization with an existing `notarytool` keychain profile:

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="rustdesk-notary" \
scripts/package_macos.sh
```

Portable notarization without storing credentials:

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_APPLE_ID=developer@example.com \
NOTARY_TEAM_ID=TEAMID \
scripts/package_macos.sh
```

If `NOTARY_PASSWORD` is omitted, `xcrun notarytool` prompts for the
app-specific password. The script does not store credentials.

## Do Not Distribute

Do not ship or commit platform build state:

```text
flutter/.dart_tool
flutter/build
flutter/.flutter-plugins-dependencies
target
```

Ship only the final Flutter runner bundle for the target platform.

## Prototype Runners

The toolbar lab wrappers are debug-oriented `flutter run` helpers for fast UI
iteration. They refresh stale `.dart_tool` state the same way as the full build
wrappers, optionally build the native Rust library, and then launch:

- `lib/prototyping/main_toolbar_lab.dart`

Common options:

- Linux/macOS: `--clean`, `--skip-cargo`, `--device DEVICE`, `-- ...extra flutter run args`
- Windows: `-Clean`, `-SkipCargo`, `-Device windows`, `-HwCodec`, plus extra trailing `flutter run` args

## Validation Runners

The Linux/macOS test runners mirror `scripts/run_windows_tests.ps1`: each step
writes a dedicated log under `target/<platform>-test-logs/`, then prints a final
summary table.

Common options:

- `--flutter-root PATH`
- `--pub-cache PATH`
- `--cargo-target-dir PATH`
- `--features flutter,use_dasp`
- `--skip-full-client`
- `--skip-hbb-common`
- `--skip-flutter`
- `--stop-on-failure`
