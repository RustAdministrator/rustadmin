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

Toolbar lab:

```powershell
.\scripts\run_toolbar_lab_windows.ps1
```

Final bundle:

```text
flutter\build\windows\x64\runner\Release
```

## Linux

Default layout:

```text
/mnt/f/GH/flutter
/mnt/f/GH/flutter-pub-cache-linux
/mnt/f/GH/rustdesk-target-linux
.local/linux-codecs, or /mnt/f/UBc/Release
```

Run:

```bash
scripts/build_linux.sh
```

Optional:

```bash
RUSTDESK_LINUX_CODEC_ROOT=/mnt/f/DVS/linux scripts/build_linux.sh --clean
scripts/build_linux.sh --hwcodec
```

Toolbar lab:

```bash
scripts/run_toolbar_lab_linux.sh
```

Final bundle:

```text
flutter/build/linux/x64/release/bundle
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
