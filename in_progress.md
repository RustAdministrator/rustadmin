# RustAdmin Windows Build Status

Date: 2026-06-23

## Current Status

Latest client/code pass is revision `011`.

What changed in this pass:

- Experimental branch `codex/privileged-user-token-capture` keeps the Windows service-launched `--server` process privileged so Administrator Protection and the secure desktop path stay compatible.
- Added a Windows user-token capture helper (`--user-capture-helper`) for DXGI and WGC. The privileged server launches the helper in the current interactive session, receives CPU BGRA frames through shared memory, and marks helper capture as CPU-only so the VRAM texture path is not selected for helper frames.
- Automatic DXGI capture, manual DXGI, manual WGC, and the DXGI-to-WGC fallback now try the user-token helper first when RustAdmin is installed, running privileged, and the session is not locked/prelogin/secure-desktop; the old direct backend path remains the fallback if the helper cannot start.
- Follow-up from host logs: user-token helpers were exiting with `Access is denied` while opening the privileged server's shared-memory flink. The helper shmem file now receives an explicit ACL grant for authenticated interactive users, and the main capturer detects a dead helper so it can fail over instead of waiting forever.
- Follow-up from the next host test: the helper now opened shared memory and created DXGI, but helper DXGI could still sit in `WouldBlock` on startup because the old startup GDI snapshot path is not available on the helper capturer. Revision `010` now treats that as a backend fallback trigger and tries WGC, WinMag, then GDI instead of waiting forever. The helper log also reports first-frame and would-block status.
- Follow-up from manual backend switching: manual/fallback WGC was still checked for support in the privileged server process before launching the user-token helper, so WGC could be skipped and the stream would cycle back to WinMag. Revision `011` attempts WGC through the interactive helper first, checks direct-process WGC support only if the helper cannot be used, and logs helper eligibility, direct-process WGC support, fallback reason, helper backend requests, helper WGC support, shared-memory ACL grants, first frames, and would-block status.
- `rustadmin_revision.txt` was bumped to `011`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.011.zip`, size `41,220,688` bytes, sha256 `88ed2c4a819022a58fe3e9b0b866c7a55a8e098fe20e0c359a44bc63ca794a34`.
- `rustadmin_revision.txt` was bumped to `010`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.010.zip`, size `41,216,871` bytes, sha256 `a6bbebc6d20af1aa0001ded937e4b16d4d9368fc07e9ffa6ceaafc603d2e90e6`.
- Windows archive was copied back to WSL as `RustAdmin_Release_2.0.2.010.zip` and verified with `unzip -t`; no compressed data errors.
- `rustadmin_revision.txt` was bumped to `009`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.009.zip`, size `41,216,345` bytes, sha256 `c04690a2d1277167609ce9046b84a763d7c91312e9884d0c41f0d09a83c76678`.
- Windows archive was copied back to WSL as `RustAdmin_Release_2.0.2.009.zip` and verified with `unzip -t`; no compressed data errors.
- Revision `008` tried switching unlocked Administrator Protection sessions to an interactive user-token `--server`; logs showed WGC working, but secure desktop access still failed. Revision `009` supersedes that by keeping `--server` privileged and moving DXGI/WGC capture into the user-token helper.
- The service still tracks the effective launch mode, but this branch no longer selects the interactive-user launch mode for `--server`.
- `rustadmin_revision.txt` was bumped to `008`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.008.zip`, size `41,213,520` bytes, sha256 `b80cebcb2ce91aaab31ce425c4b66dc387948d4c944584bee4f2cfa499649e8b`.
- Windows archive was copied back to WSL as `RustAdmin_Release_2.0.2.008.zip` and verified with `unzip -t`; no compressed data errors.
- Previous revision `007` restored the privileged `winlogon.exe` launch path. Revision `008` keeps that path for locked/prelogin sessions and uses an interactive user token only when it is needed for WGC in an unlocked Administrator Protection session.
- `libs/scrap/src/common/codec.rs` now treats `PreferCodec::AV1Vulkan` from current `hbb_common` as ordinary AV1 until a separate AV1 Vulkan encoder path exists, fixing the Windows build against the current shared proto.
- `rustadmin_revision.txt` was bumped to `007`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.007.zip`, size `41,214,152` bytes, sha256 `61e1ba4a05d8fffd6bc897c7455594d412a34fec5916de079160e1363de0abc2`.
- Windows archive was copied back to WSL as `RustAdmin_Release_2.0.2.007.zip` and verified with `unzip -t`; no compressed data errors.
- Android/mobile Quality Monitor `Debug mode` checkbox now uses theme border/check colors, so the unchecked box is visible on dark backgrounds.
- Quality Monitor host version now uses peer `full_version` when the host advertises it, with fallback to the old plain version for older hosts.
- Mobile About now reads `bind.mainGetVersion()`, so Android shows the Rust full version with revision instead of only the package version.
- Hosts now advertise `platform_additions.full_version` on every platform and `support_capture_backend` only on Windows. The client shows the `Capture` menu only for Windows peers that advertise the capability, so old/non-Windows hosts do not expose a dead switcher.
- `rustadmin_revision.txt` and `../hbb_common/rustadmin_revision.txt` were bumped to `006`.
- Android release APK built successfully: `RustAdmin_Android_Release_2.0.2.006.apk`, size `27,826,333` bytes, sha256 `4c3c9e5651bc150e1fd269ad517b2c944c60e6f2211e5b60ce685646b5294696`.
- Android release ZIP built successfully: `RustAdmin_Android_Release_2.0.2.006.zip`, size `27,229,498` bytes, sha256 `6f050bb359af9724c3566d7e8c909a11faee1616b243d7d7707f0459e3fa70ff`.
- Windows release archive built successfully on VM `192.168.189.137`: `RustAdmin_Release_2.0.2.006.zip`, size `41,196,430` bytes, sha256 `ad32cf7a977e4137cb139c706826ee29d349058f81ce6303247c6d92e8e9ba43`.
- macOS client build is blocked in the current WSL2/Linux environment. `/home/w0w/flutter/bin/flutter build macos` reports that `macos` is not a supported `flutter build` subcommand here; a macOS/Xcode Flutter toolchain is required.

Recent verification:

- `dart analyze lib/consts.dart lib/common/widgets/toolbar.dart lib/models/model.dart lib/mobile/pages/remote_page.dart lib/mobile/pages/settings_page.dart`: passed with info/deprecation warnings only.
- Android Rust library built for `aarch64-linux-android` with `flutter,hwcodec,mediacodec`, then copied and stripped into `flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so`.
- Android APK verified with `apksigner verify --verbose`; `aapt dump badging` reports `versionName='2.0.2'`, `versionCode='2202'`, native code `arm64-v8a`.
- Windows revision `011` archive copied back from the VM and verified with `unzip -t`; no compressed data errors.
- `cargo check --lib --no-default-features`: blocked by the same missing `gstreamer-1.0` pkg-config dependency.

Latest test build is `RustAdmin_Release_2.0.2.011.zip`.

Earlier capture-backend menu test details:

- Added a connection menu entry next to `Codec`: `Capture`.
- `Capture` supports `Auto`, `DXGI`, `WGC`, `WinMag`, and `GDI` for Windows hosts.
- `Auto` is the default and keeps the existing fallback chain. Manual choices are stored per peer and sent to the host as a capture backend preference; fallback protection remains active if the selected backend cannot produce frames.
- New clients always send `Auto` or the saved manual value during login, so a previous manual host preference does not leak into a later default session.
- The menu is shown based on the remote host platform, so Android/mobile clients can switch capture backend while connected to a Windows host.
- The host restarts the video stream after a backend change so the selected capturer takes effect immediately.
- `src/server/video_service.rs`: capped server-side video frame fetch/send wait to the current frame interval, max `50 ms`. This replaces the old wait loop that could block the capture/encode loop for up to `3 seconds`.
- `src/server/connection.rs`: lowered stale queued video frame drop threshold from `3 seconds` to `200 ms`, so delayed frames are discarded instead of being played back after a stall.

Built and copied locally:

- VM archive: `C:\rustadmin\rustadmin\dist\windows\RustAdmin_Release_2.0.2.004.zip`
- Local copy: `RustAdmin_Release_2.0.2.004-capture-backend-menu-test.zip`
- Size: `41,193,454` bytes
- SHA256: `e2238c77593a2dde1f29ed19bdb2795072fb046d1562cf192e30d36ef1cbf74e`

Next test should check:

- open the connection toolbar display/options menu and switch `Capture` between `Auto`, `DXGI`, `WGC`, `WinMag`, and `GDI`;
- compare smoothness and Quality Monitor `HostBackend` / `HostFallback` for each backend;
- whether image movement feels smoother after a `200+ ms` delay spike;
- Quality Monitor `HostWait max` should stay near `33-50 ms` at 30 FPS;
- if `Delay` still spikes but `HostWait` is low, the remaining issue is likely network/transport jitter and may need a small client-side jitter buffer instead of more host pacing changes.

## Result

Windows build completed successfully on VM `192.168.189.137`.

Artifacts:

- Bundle: `C:\rustadmin\rustadmin\flutter\build\windows\x64\runner\Release`
- Archive: `C:\rustadmin\rustadmin\dist\windows\RustAdmin_Release_2.0.2.002.zip`

Verified artifact metadata:

- `RustAdmin_Release_2.0.2.002.zip`: 41,176,573 bytes, last written `2026-06-22 07:44:14` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 07:44:00` on the VM.

Latest rebuild after DXGI startup snapshot change:

- `RustAdmin_Release_2.0.2.002.zip`: 41,179,996 bytes, last written `2026-06-22 13:26:06` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 13:25:54` on the VM.

Latest rebuild after frozen-one-frame DXGI fix:

- `RustAdmin_Release_2.0.2.002.zip`: 41,180,963 bytes, last written `2026-06-22 14:00:44` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 14:00:32` on the VM.

Latest rebuild after Windows Administrator Protection user-token server launch test:

- `RustAdmin_Release_2.0.2.002.zip`: 41,180,546 bytes, last written `2026-06-22 14:22:47` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 14:22:34` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.002-admin-protection-test.zip`, sha256 `93c5afaea4efae47a6c7c8c353c841302eb0217076db55db374b4060ef5ab5d1`.

Latest rebuild after WinMag fallback test:

- `RustAdmin_Release_2.0.2.002.zip`: 41,181,068 bytes, last written `2026-06-22 15:00:48` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 15:00:33` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.002-mag-fallback-test.zip`, sha256 `ac2269eddee80dbdc849a21867b7004d3cada48dc0d485d410f7a8f64b3437a4`.

Latest rebuild after WinMag fast-copy test:

- `RustAdmin_Release_2.0.2.002.zip`: 41,181,478 bytes, last written `2026-06-22 19:52:14` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 19:52:00` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.002-mag-fastcopy-test.zip`, sha256 `99b697073eded3eed2e796c477167144223969a26d0f66737f63ebace13ddd45`.
- Result: not kept. It did not raise WinMag above ~20 FPS and adaptive QoS reduced target/quality during the test, so the code was reverted.

Latest rebuild after reverting WinMag fast-copy test:

- `RustAdmin_Release_2.0.2.002.zip`: 41,181,067 bytes, last written `2026-06-22 20:35:44` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 20:35:32` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.002-mag-stable-revert.zip`, sha256 `12ccdfdb4bf747dabef14d7e9252ae614e1a01f317e92176a7950b0d7976d6f7`.

Latest rebuild after WGC fallback test:

- `RustAdmin_Release_2.0.2.002.zip`: 41,182,391 bytes, last written `2026-06-22 20:56:33` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 20:56:21` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.002-wgc-test.zip`, sha256 `55ef772a86f58fba5cdb50ff1e8b807b507f1249105296aac56db19f23f725c1`.
- Expected test signal: after DXGI reports `dxgi_no_frame_after_snapshot`, host should try `HostBackend WGC` with `HostFallback dxgi_no_frame_after_snapshot_wgc`. If WGC does not produce frames, it falls back to `HostBackend WinMag` with `HostFallback wgc_no_frame_mag`.

Latest rebuild after server video pacing / stale-drop smoothing test:

- `src/server/video_service.rs`: video frame send/fetch wait is capped to the current frame interval, with a hard max of 50 ms, instead of looping for up to 3 seconds. Expected test signal: `HostWait max` should stay near `33-50` ms at 30 FPS instead of spiking above 200 ms.
- `src/server/connection.rs`: stale queued video frames are dropped after 200 ms instead of 3 seconds, so the sender does not play delayed frames after a network or socket stall.
- `RustAdmin_Release_2.0.2.003.zip`: 41,183,825 bytes, last written `2026-06-22 21:49:40` on the VM.
- `rustadmin.exe`: 718,848 bytes, last written `2026-06-22 21:49:26` on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.003-smoothing-test.zip`, sha256 `288e52f058c3dd25bbc3a8ea8badb7e544fc6877f2f9c4902429fa4051bfabe2`.
- Next Windows test should compare smoothness and Quality Monitor `HostWait`/`Delay` before deciding whether a larger jitter buffer is needed.

Latest rebuild after capture backend menu test:

- `../hbb_common/protos/message.proto`: added `OptionMessage.capture_backend` with `Auto`, `DXGI`, `WGC`, `WinMag`, and `GDI` values.
- `../hbb_common/src/config.rs`: added persisted peer option key `capture-backend`.
- `src/client.rs`, `src/flutter_ffi.rs`, `src/ui_session_interface.rs`: added per-session save/send path for capture backend selection.
- `src/client.rs`: sends `Auto` explicitly during login when no manual backend is saved, preventing stale host preference from carrying across sessions.
- `src/server/connection.rs`, `src/server/video_service.rs`: host applies the selected capture backend preference and refreshes video after a change.
- `flutter/lib/common/widgets/toolbar.dart`, desktop/mobile remote option pages: added the `Capture` radio menu next to codec selection for Windows hosts.
- `RustAdmin_Release_2.0.2.004.zip`: built successfully on the VM.
- Local test copy: `RustAdmin_Release_2.0.2.004-capture-backend-menu-test.zip`, size `41,193,454` bytes, sha256 `e2238c77593a2dde1f29ed19bdb2795072fb046d1562cf192e30d36ef1cbf74e`.
- Expected test signal: `Auto` should show the active host backend in the menu label and Quality Monitor; manual choices should switch `HostBackend` after the video refresh.

## VM

- SSH target: `root@192.168.189.137`
- SSH key: `/home/w0w/.ssh/rustadmin_vm_ed25519`
- Work root: `C:\rustadmin`
- DVS prefix: `C:\rustadmin\DVS\DVS`

## Environment

- Git: `2.54.0.windows.1`
- Rust MSVC: `rustc 1.96.0`, `cargo 1.96.0`
- VS Build Tools 2022: `C:\rustadmin\BuildTools`, version `17.14.35`
- Windows SDK: `10.0.22621.0`
- CMake/Ninja from VS Build Tools
- LLVM/libclang: `C:\rustadmin\BuildTools\VC\Tools\Llvm\x64`
- Flutter: `3.24.5`, Dart `3.5.4`
- `flutter_rust_bridge_codegen`: `1.80.1`
- `rustfmt`: installed

## Fixes Applied For This Build

- `src/server/video_service.rs`: DXGI startup `WouldBlock` no longer permanently falls back to GDI; host diagnostics work from the existing tree was preserved.
- `src/server/video_service.rs`: follow-up after Android screenshot changed DXGI startup no-frame handling from a permanent `dxgi_startup_no_frame` GDI fallback into a one-shot `dxgi_startup_gdi_snapshot`; after sending that startup GDI frame, the capturer calls `cancel_gdi()` and returns to DXGI.
- `src/server/video_service.rs`: follow-up after frozen-one-frame test. If DXGI still returns only `WouldBlock` for 3 seconds after the one-shot GDI startup snapshot, host now falls back to continuous GDI with `HostFallback dxgi_no_frame_after_snapshot` instead of staying frozen on `HostBackend DXGI`.
- `src/server/video_service.rs`: follow-up after Administrator Protection user-token launch still produced `HostBackend GDI` + `dxgi_no_frame_after_snapshot`. The final fallback now tries `scrap::CapturerMag`/Magnification API first (`HostBackend WinMag`, `HostFallback dxgi_no_frame_after_snapshot_mag`) and falls back to recreated GDI only if WinMag cannot start or errors.
- `libs/scrap/src/dxgi/wgc.rs`, `libs/scrap/src/common/dxgi.rs`, `src/server/video_service.rs`: added a Windows Graphics Capture backend and changed fallback order to `DXGI -> WGC -> WinMag -> GDI`; host diagnostics now report `HostBackend WGC`.
- `src/server/video_service.rs`, `src/server/connection.rs`: low-latency smoothing test caps server-side video frame wait to one frame interval / 50 ms max and drops stale queued video frames after 200 ms to reduce visible catch-up stutter.
- `src/client.rs`, `src/server/connection.rs`, `src/server/video_service.rs`, Flutter toolbar/options pages: added runtime `Capture` backend selection with `Auto`, `DXGI`, `WGC`, `WinMag`, and `GDI`.
- `src/platform/windows.rs`: the Windows Administrator Protection interactive user-token launch experiment was reverted; service-launched `--server` now uses the previous privileged `winlogon.exe` launch path.
- `libs/scrap/src/common/mod.rs`, `libs/scrap/src/common/dxgi.rs`: `TraitCapturer` now exposes `cancel_gdi()` so the video service can return from the temporary GDI snapshot path to DXGI, and `is_mag()` so host diagnostics can report the Magnification API backend distinctly.
- `rustadmin_revision.txt`: bumped to `004`.
- `../hbb_common/rustadmin_revision.txt`: bumped to `002`.
- `scripts/build_windows.ps1`: native command wrapper now checks exit codes without aborting on normal native stderr output.
- DVS compatibility on VM: created junctions under `C:\rustadmin\DVS\DVS\installed\x64-windows-static` for `include`, `lib`, and `bin`.
- `hwcodec` FFmpeg 62 compatibility:
  - profile macro fallback for `AV_PROFILE_*` names,
  - key-frame detection uses `AV_FRAME_FLAG_KEY`,
  - Windows static link set expanded for FFmpeg/DVS dependencies,
  - oneVPL `vpl.lib` is used instead of old `libmfx.lib`.
- Flutter on VM was switched from `3.44.2` to `3.24.5`; the newer Flutter was incompatible with current Dart code and `extended_text 14.2.2`.

## Build Command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\rustadmin\build-rustadmin.ps1
```
