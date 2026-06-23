# TODO

Date: 2026-06-23

## Status

- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.006.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.006.zip`.
- Done: Windows client archive built as `RustAdmin_Release_2.0.2.009.zip`.
- Done: Windows experimental revision `009` runs the service-launched `--server` privileged and uses a user-token shared-memory capture helper for DXGI/WGC on normal interactive desktops, while locked/prelogin/secure desktop stays on the privileged direct capture path.
- Done: Windows service launch is Administrator Protection-compatible in revision `009`: the service-launched `--server` stays privileged for LogonUI/secure desktop, while DXGI/WGC capture can run through the interactive user-token helper.
- Done: Current `hbb_common` `PreferCodec::AV1Vulkan` is handled as ordinary AV1 until a separate AV1 Vulkan encoder path exists.
- Blocked: macOS client build requires a macOS/Xcode Flutter toolchain; current environment is WSL2/Linux and `flutter build` has no `macos` subcommand here.
- Done: During first-contact host-client trust, if `allow unverified peer trust` is disabled, the Flutter trust prompt now offers to enable it before approving and saving the peer key.
- Done: Local rendezvous-direct sessions now use TCP-only connection candidates; UDP/KCP candidates are skipped for LAN MTU compatibility, including VPN paths such as WireGuard.
- Done: Quality Monitor has a `Debug mode` checkbox. When disabled, it shows the basic metrics; when enabled, it shows the full diagnostics/debug fields added during FPS and capture-backend troubleshooting.
- Done: Quality Monitor `Debug mode` checkbox has a visible border in dark Android/mobile UI.
- Done: Android About and Quality Monitor now use full Rust version strings with revision when available.
- Done: `Capture` backend menu is gated by a Windows-host capability instead of platform text alone.
