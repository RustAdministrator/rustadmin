# TODO

Date: 2026-06-23

## Status

- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.016.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.016.zip`.
- Done: Android revision `016` wraps the adaptive launcher icon foreground in an `18dp` safe-area inset so Android launcher masks do not crop the RustAdmin logo edges.
- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.015.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.015.zip`.
- Done: Windows client archive built as `RustAdmin_Release_2.0.2.015.zip`.
- Done: Android revision `015` shows the established transport in Quality Monitor debug mode as `Conn` (`TCP`, `UDP/KCP`, `UDP/KCP IPv6`, `Relay/TCP`, or `WebSocket`). Actual path MTU is not shown because the current transport state does not expose a reliable path MTU.
- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.006.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.006.zip`.
- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.014.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.014.zip`.
- Done: Android revision `014` removes the remaining left-button release event from empty OS activation during connect.
- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.013.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.013.zip`.
- Done: Android revision `013` includes `libc++_shared.so` in the APK so `librustdesk.so` can load on startup.
- Done: Android client APK built as `RustAdmin_Android_Release_2.0.2.012.apk`.
- Done: Android client ZIP built as `RustAdmin_Android_Release_2.0.2.012.zip`.
- Done: Android/Flutter client revision `012` stops sending a right click during empty OS activation while waiting for the first image.
- Done: Windows client archive built as `RustAdmin_Release_2.0.2.011.zip`.
- Done: Windows revision `011` lets manual/fallback WGC reach the user-token helper before checking direct WGC support in the privileged server process, and expands capture-helper diagnostics.
- Done: Windows client archive built as `RustAdmin_Release_2.0.2.010.zip`.
- Done: Windows revision `010` avoids the helper-DXGI startup wait when a GDI snapshot is unavailable by falling through to WGC, WinMag, then GDI fallback, and logs helper first-frame/would-block status.
- Done: Windows client archive built as `RustAdmin_Release_2.0.2.009.zip`.
- Done: Windows experimental revision `009` runs the service-launched `--server` privileged and uses a user-token shared-memory capture helper for DXGI/WGC on normal interactive desktops, while locked/prelogin/secure desktop stays on the privileged direct capture path.
- Done: Fixed the helper shared-memory ACL issue found in host logs, where `--user-capture-helper` exited with `Access is denied` and left Android waiting for the first image.
- Done: Windows service launch is Administrator Protection-compatible in revision `009`: the service-launched `--server` stays privileged for LogonUI/secure desktop, while DXGI/WGC capture can run through the interactive user-token helper.
- Done: Current `hbb_common` `PreferCodec::AV1Vulkan` is handled as ordinary AV1 until a separate AV1 Vulkan encoder path exists.
- Blocked: macOS client build requires a macOS/Xcode Flutter toolchain; current environment is WSL2/Linux and `flutter build` has no `macos` subcommand here.
- Done: During first-contact host-client trust, if `allow unverified peer trust` is disabled, the Flutter trust prompt now offers to enable it before approving and saving the peer key.
- Done: Local rendezvous-direct sessions now use TCP-only connection candidates; UDP/KCP candidates are skipped for LAN MTU compatibility, including VPN paths such as WireGuard.
- Done: Quality Monitor has a `Debug mode` checkbox. When disabled, it shows the basic metrics; when enabled, it shows the full diagnostics/debug fields added during FPS and capture-backend troubleshooting.
- Done: Quality Monitor `Debug mode` checkbox has a visible border in dark Android/mobile UI.
- Done: Android About and Quality Monitor now use full Rust version strings with revision when available.
- Done: `Capture` backend menu is gated by a Windows-host capability instead of platform text alone.
