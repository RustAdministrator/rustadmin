# RustDesk Guide 

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Build Commands
- `cargo run` - Build and run the desktop application (requires libsciter library)
- `python3 build.py --flutter` - Build Flutter version (desktop)
- `python3 build.py --flutter --release` - Build Flutter version in release mode
- `python3 build.py --hwcodec` - Build with hardware codec support
- `python3 build.py --vram` - Build with VRAM feature (Windows only)
- `cargo build --release` - Build Rust binary in release mode
- `cargo build --features hwcodec` - Build with specific features

### Flutter Mobile Commands
- `cd flutter && flutter build android` - Build Android APK
- `cd flutter && flutter build ios` - Build iOS app
- `cd flutter && flutter run` - Run Flutter app in development mode
- `cd flutter && flutter test` - Run Flutter tests

### Testing
- `cargo test` - Run Rust tests
- `cd flutter && flutter test` - Run Flutter tests

### Platform-Specific Build Scripts
- `flutter/build_android.sh` - Android build script
- `flutter/build_ios.sh` - iOS build script
- `flutter/build_fdroid.sh` - F-Droid build script

## Project Architecture

### Directory Structure
- **`src/`** - Main Rust application code
  - `src/ui/` - Legacy Sciter UI (deprecated, use Flutter instead)
  - `src/server/` - Audio/clipboard/input/video services and network connections
  - `src/client.rs` - Peer connection handling
  - `src/platform/` - Platform-specific code
- **`flutter/`** - Flutter UI code for desktop and mobile
- **`libs/`** - Core libraries
  - `libs/scrap/` - Screen capture functionality
  - `libs/enigo/` - Platform-specific keyboard/mouse control
  - `libs/clipboard/` - Cross-platform clipboard implementation
- **`../hbb_common/`** - Shared protocol, config, network wrapper, protobuf, and file transfer utilities used by client and server

### Key Components
- **Remote Desktop Protocol**: Custom protocol implemented in `src/rendezvous_mediator.rs` for communicating with rustdesk-server
- **Screen Capture**: Platform-specific screen capture in `libs/scrap/`
- **Input Handling**: Cross-platform input simulation in `libs/enigo/`
- **Audio/Video Services**: Real-time audio/video streaming in `src/server/`
- **File Transfer**: Secure file transfer implementation in `../hbb_common/`

### UI Architecture
- **Legacy UI**: Sciter-based (deprecated) - files in `src/ui/`
- **Modern UI**: Flutter-based - files in `flutter/`
  - Desktop: `flutter/lib/desktop/`
  - Mobile: `flutter/lib/mobile/`
  - Shared: `flutter/lib/common/` and `flutter/lib/models/`

## Important Build Notes

### Repository Policy
- Use the `woffko` GitHub fork family as the active sync and push target for this workspace.
- Do not fetch, merge, rebase, or push `ssh4net` repositories unless the user explicitly requests a `ssh4net` synchronization.
- Treat existing `origin` remotes that point at `ssh4net` or upstream projects as legacy/reference-only remotes.
- Active RustAdmin work should stay on `woffko/rustadmin` branch `codex/privileged-user-token-capture`.
- Active shared dependency branches are `woffko/hbb_common` and `woffko/hwcodec`, both on `codex/privileged-user-token-capture`.
- The RustAdmin checkout depends on local sibling/shared repos: `../hbb_common` from the root `Cargo.toml`, and `../../../hbb_common` plus `../../../hwcodec` from `libs/scrap/Cargo.toml`.

### Dependencies
- This RustAdmin fork does not use vcpkg as the default dependency manager and prefers to avoid it for project work.
- Prefer explicit system packages, native SDKs, CMake/pkg-config prefixes, or local WSL build prefixes for C/C++ dependencies.
- Existing upstream docs/scripts may still mention vcpkg as a RustDesk compatibility option, but do not introduce new required vcpkg build steps unless the user explicitly asks for them.
- Some upstream build logic may still read `VCPKG_ROOT`; when unavoidable, treat it only as a compatibility prefix variable, not as a requirement to run vcpkg.
- Download appropriate Sciter library for legacy UI support

### Ignore Patterns
When working with files, ignore these directories:
- `target/` - Rust build artifacts
- `flutter/build/` - Flutter build output
- `flutter/.dart_tool/` - Flutter tooling files

### Cross-Platform Considerations
- Windows builds require additional DLLs and virtual display drivers
- macOS builds need proper signing and notarization for distribution
- Linux builds support multiple package formats (deb, rpm, AppImage)
- Mobile builds require platform-specific toolchains (Android SDK, Xcode)

### Feature Flags
- `hwcodec` - Hardware video encoding/decoding
- `vram` - VRAM optimization (Windows only)
- `flutter` - Enable Flutter UI
- `unix-file-copy-paste` - Unix file clipboard support
- `screencapturekit` - macOS ScreenCaptureKit (macOS only)

### Config
All configurations or options are under `../hbb_common/src/config.rs` file, 4 types:
- Settings
- Local
- Display
- Built-in

## Rust Rules

- In Rust code, do not introduce `unwrap()` or `expect()`.
- Allowed exceptions:
- Tests may use `unwrap()` or `expect()` when it keeps the test focused and readable.
- Lock acquisition may use `unwrap()` only when the locking API makes that the practical option and the failure mode is poison handling rather than normal control flow.
- Outside those exceptions, propagate errors, handle them explicitly, or use safer fallbacks instead of `unwrap()` and `expect()`.

## Editing Hygiene

- Do not introduce formatting-only changes.
- Do not run repository-wide formatters or reflow unrelated code unless the
  user explicitly asks for formatting.
- Keep diffs limited to semantic changes required for the task.
- When making client code changes, bump `rustadmin_revision.txt` by one so
  release archives and runtime version reporting get a new RustAdmin revision
  number. Bump `../hbb_common/rustadmin_revision.txt` only when `hbb_common`
  itself changes. Documentation-only changes do not require a revision bump
  unless the user asks for one.
