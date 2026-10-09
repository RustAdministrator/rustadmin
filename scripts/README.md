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
  -FFmpegRoot F:\FFmpeg-hardware-only `
  -CargoTargetDir F:\GH\rustdesk-target-win `
  -PubCache F:\GH\flutter-pub-cache-win
```

Use `-NoHwCodec` to build without the `hwcodec` feature. The packaging gate
still runs in this mode: it expects `hwcodec_enabled=false`, validates the
VP8/VP9/AV1 core roundtrips, and expects an empty optional software decoder
list.
Use `-FFmpegRoot` for a separately verified FFmpeg prefix. The build keeps
other native dependencies under `-DepsRoot`, searches both prefixes, and
packages runtime DLLs from both. Distributed RustAdmin builds must use an
FFmpeg prefix without libx264/libx265 software encoders; H.264/H.265 encoding
is hardware/platform-only and software fallback uses AV1/VP9/VP8.

Build that prefix from the reviewed `ssh4net/ffmpeg-cmake` source with:

```powershell
.\scripts\build_windows_ffmpeg_hardware_only.ps1 `
  -SourceRoot C:\rustadmin\ffmpeg-cmake `
  -InstallPrefix C:\rustadmin\FFmpeg-hardware-only `
  -DependencyPrefix C:\rustadmin\DVS\DVS `
  -CMakeExe C:\rustadmin\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe `
  -Clean
```

The script fails if a software H.26x encoder is registered, if GPL/nonfree is
enabled, if a requested hardware encoder is absent, or if the H.264/HEVC
parsers are absent. Native H.264/HEVC decoder registration is optional. The
script does not disable those registrations because FFmpeg hardware paths such
as D3D11VA and DXVA2 can share them; their presence is not a GPU test.
Pass `-IncludeSoftwareDecoders` to explicitly request the optional native
software decoder entries for a private/custom build:

```powershell
.\scripts\build_windows_ffmpeg_hardware_only.ps1 `
  -SourceRoot C:\rustadmin\ffmpeg-cmake `
  -InstallPrefix C:\rustadmin\FFmpeg-private `
  -DependencyPrefix C:\rustadmin\DVS\DVS `
  -IncludeSoftwareDecoders
```

That switch emits a distribution warning and is not approved for public
distribution. Review applicable implementation licenses and patent obligations.
Use `-Clean` to force-refresh Flutter metadata, Windows build intermediates,
and shared generated Flutter assets. This prevents debug-only assets from a
Lab run, such as `kernel_blob.bin`, from entering a release bundle.
The Windows build script sets `RUSTDESK_WINDOWS_CODEC_ROOT` to the selected
`-FFmpegRoot` (or `-DepsRoot` when no override is supplied). `CMAKE_PREFIX_PATH`
contains both dependency roots. Optional static x264/x265/OpenH264 libraries
are linked only when the selected FFmpeg `libavcodec.pc` declares them; merely
installing a library in a shared prefix does not enable that codec.

The release gate runs the bundled executable with
`--verify-codec-integration` in both normal and `-NoHwCodec` builds. Its v2
report requires exactly three validated core roundtrips (VP8, VP9, and AV1).
With `hwcodec` enabled, `optional_software_decoders` must contain h264/H264
and hevc/H265 with status `validated` or `not_built`; a present decoder with
status `failed` is an error. With `hwcodec` disabled, that array must be empty.
`registered_encoders` and `registered_decoders` are registry inventories, make
no GPU claim, and may be empty when optional implementations are unbuilt;
headless runtime status is separate. Report warnings are
printed with `Write-Warning` and retained in the bundle's `CODEC-POLICY.txt`.
The command writes one versioned JSON report to stdout and diagnostics to
stderr. On a failed gate, the wrapper keeps both files under the reported
`%TEMP%\rustadmin-codec-integration-*` directory as `stdout.log` and
`stderr.log`.

Use `--probe-hwcodec-config` as the standalone Windows runtime/GPU diagnostic;
it prints fresh runtime JSON. `--check-hwcodec-config` is the IPC worker path
used by an integrated check, not the primary standalone diagnostic. Neither
command is part of the report gate, and the v2 inventory does not claim that
any registered hardware codec is usable on the build machine.

If a report is malformed or a core/optional probe fails, first inspect the
kept stdout/stderr logs, selected prefix, and native RustAdmin relink. Rebuild
the FFmpeg prefix with `scripts\build_windows_ffmpeg_hardware_only.ps1` only
when its inventory or component configuration is actually missing or wrong.
If an FFmpeg diagnostic binary lists a codec but the verifier logs
`avcodec_find_decoder_by_name` failures, correct stale linked libraries or
bundled DLLs and force a RustAdmin native relink against the selected prefix.
Windows `-Clean` refreshes Flutter/intermediate assets and does not clear Cargo
output.

The standalone encoder policy scan remains strict by default:

```powershell
python scripts\verify_hardware_only_h26x.py path\to\RustAdmin.exe
python scripts\verify_hardware_only_h26x.py path\to\RustAdmin.zip
python scripts\verify_hardware_only_h26x.py --self-test
```

For an explicitly private/custom build, pass `--private-build` before the
paths. Detected software H.264/H.265 encoders then return success with a strong
warning that the build is not approved for public distribution; invalid paths,
unreadable archives, and scan errors still fail.

The scripts also generate `flutter_rust_bridge` files when they are missing or
older than `src/flutter_ffi.rs`. Install the generator once:

```powershell
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked --force
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

Mobile remote UI lab:

```powershell
.\scripts\run_mobile_remote_lab_windows.ps1
```

Final bundle:

```text
flutter\build\windows\x64\runner\Release
```

## Linux

The Linux wrapper discovers Flutter from `PATH`, or from
`RUSTADMIN_FLUTTER_ROOT` when set. Native codec dependencies can come from
system `pkg-config` packages, from `RUSTADMIN_LINUX_CODEC_ROOT`, or from the
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
RUSTADMIN_FLUTTER_ROOT=/path/to/flutter \
RUSTADMIN_LINUX_CODEC_ROOT=/path/to/codec-prefix \
scripts/build_linux.sh --clean

scripts/build_linux.sh --hwcodec
```

Legacy `RUSTDESK_*` Linux variable names are still accepted for compatibility
with inherited build code.

Toolbar lab:

```bash
scripts/run_toolbar_lab_linux.sh
```

Mobile remote UI lab:

```bash
scripts/run_mobile_remote_lab.sh
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

Hardware codecs are enabled by default. If FFmpeg/hwcodec dependencies are not
available, the script writes `build/macos-build-report.md`, reports the fallback
as an error, and exits nonzero so the issue is not missed. Use `--no-hwcodec`
when a non-hardware-codec build is intentional, or set
`RUSTADMIN_MACOS_ALLOW_HWCODEC_FALLBACK=1` to allow an automatic fallback.

Override the report path when needed:

```bash
RUSTADMIN_MACOS_BUILD_REPORT=/tmp/rustadmin-macos-report.md \
scripts/build_macos.sh
```

Optional codec prefix:

```bash
RUSTADMIN_FLUTTER_ROOT=/path/to/flutter \
RUSTADMIN_MACOS_CODEC_ROOT=/path/to/prefix \
scripts/build_macos.sh --screencapturekit
```

Explicitly disable hardware codecs:

```bash
scripts/build_macos.sh --no-hwcodec
```

Toolbar lab:

```bash
scripts/run_toolbar_lab_macos.sh
```

Mobile remote UI lab:

```bash
scripts/run_mobile_remote_lab.sh
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

The DMG contains `RustAdmin.app`, the separately launchable
`RustAdminUpdate.app` with its light icon, and an Applications shortcut.
The updater is also retained inside the main app for in-app upgrades.
See [the macOS update workflow](../docs/macos-updater.md) for usage and validation.

Fast signing and dependency verification without creating a DMG:

```bash
SKIP_NOTARY=1 SKIP_DMG=1 SIGN_IDENTITY=- scripts/package_macos.sh
```

For notarization with an existing `notarytool` keychain profile:

```bash
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="rustadmin-notary" \
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

## Keyboard diagnostics (macOS)

Run `scripts/macos_keyboard_probe.sh` to open a focused typing window and print
native key codes, modifiers, input-source/keyboard-layout metadata, and the
resulting Unicode text as JSON Lines. It needs Apple's command-line developer
tools, but no RustAdmin build or Python packages. Only the probe window's events
are observed.

See [the keyboard probe guide](macos_keyboard_probe.md) for JIS/tilde diagnosis,
recording a sample, and the distinction between physical keys and committed text.

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
