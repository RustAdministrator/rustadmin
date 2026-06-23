# RustAdmin Android FPS and Menu Worklog, 2026-06-20

## Repositories

- Main repository: `/home/w0w/rustadmin-fps-diag`
- External proto repository: `/home/w0w/hbb_common`
- Target upstream: `RustAdministrator/rustadmin`
- PR fork: `woffko/rustadmin`

## Original Problem

On Android, when connecting to a host with a 2K resolution such as `2560x1440`,
FPS stayed around `15-16` regardless of the selected codec: VP9, AV1, H.264, or
H.265.

The initial hypothesis was that the bottleneck was not codec selection but the
Android decode/render pipeline:

- H.264/H.265 on Android used MediaCodec, but the result was read back as a
  CPU-accessible YUV/I420 buffer.
- That was followed by CPU YUV/I420 to RGBA conversion through `I420ToARGB` /
  `I420ToABGR`.
- The RGBA buffer was then passed into the Flutter soft-render path.
- `decode_fps` effectively included not only decoder time but also part of the
  render/callback pipeline.
- Adaptive FPS could limit remote FPS through `min_decode_fps`.

## Android Video Pipeline Work

### Decode/Render Pipeline Diagnostics

Android-specific diagnostics were added to separate:

- active codec path;
- render path;
- resolution;
- video queue length;
- measured decode FPS;
- auto FPS;
- direct/relay mode;
- MediaCodec input/output timing;
- YUV/RGBA conversion timing;
- total frame handling timing;
- Flutter handoff timing;
- RGBA buffer size;
- whether the RGBA buffer was reallocated;
- output buffer size;
- MediaFormat/stride/crop/slice-height/color-format details.

Primary files:

- `libs/scrap/src/common/mod.rs`
- `libs/scrap/src/common/codec.rs`
- `libs/scrap/src/common/mediacodec.rs`
- `src/client.rs`
- `src/client/io_loop.rs`
- `src/flutter.rs`
- `flutter/lib/models/model.dart`
- `flutter/lib/common/widgets/overlay.dart`

### Quality Monitor Instead Of logcat

Some data was moved into Quality Monitor so diagnostics do not depend only on
`adb logcat`.

The Android viewer now shows these client-side fields in Quality Monitor:

- `Path`
- `Render`
- `Res`
- `Queue`
- `DecFPS`
- `AutoFPS`
- `Mode`
- `Direct`
- `MC in`
- `MC out`
- `YUV->RGBA`
- `MC dec`
- `Frame`
- `Flutter`
- `Total`
- `RGBA`
- `Realloc`
- `Out buf`
- `Format`

To reduce overhead, frequent pipeline fields in Flutter are throttled to roughly
one update per second.

### Host-Side Data In Quality Monitor

A host-side diagnostic snapshot is now sent through `TestDelay`, so the UI can
show not only Android viewer data but also remote-host data:

- `HostFPS`
- `HostCodec`
- `HostQoS`
- `HostWait`

Changed files:

- `/home/w0w/hbb_common/protos/message.proto`
- `src/server/video_service.rs`
- `src/server/connection.rs`
- `src/ui_session_interface.rs`
- `src/client/helper.rs`
- `src/flutter.rs`
- `flutter/lib/models/model.dart`
- `flutter/lib/common/widgets/overlay.dart`

Important: these rows appear in Quality Monitor only if the remote host is also
built with the updated proto/server code. If the Android APK is updated but the
Windows/Linux host is old, the `Host...` fields stay empty.

### Screenshot Findings

The Android viewer screenshots showed approximately:

- `FPS 15`
- `Codec H264`
- `Path hwram_h264`
- `Render rgba_soft_render`
- `Res 2560x1440`
- `Queue 0`
- `DecFPS 72-94`
- `AutoFPS 30`
- `Mode adaptive`
- `Direct true`
- `Frame 9-17 ms`
- `Flutter around 0.1 ms or less`

For that specific sample, this means:

- the Android viewer queue was not backed up (`Queue 0`);
- the Android decode/render sample did not look like the reason for 15 FPS
  (`DecFPS` was far above 15);
- the adaptive client cap was 30, not 15;
- the connection was direct and latency was low;
- host-side data was needed to determine whether FPS was limited by host
  capture/encode/send.

## MediaCodec Fixes

`libs/scrap/src/common/mediacodec.rs` was reviewed and fixed.

Changes:

- added timing fields for MediaCodec input/output and conversion;
- added MediaFormat diagnostics;
- fixed stride/crop/slice-height handling;
- added warning/fallback for unexpected color formats;
- removed unnecessary RGBA buffer reallocations where possible;
- fixed a duplicate `ImageFormat::ARGB` match arm: the second arm should be
  `ImageFormat::ABGR`;
- kept the fallback to the existing RGBA soft-render path.

The current Android H.264/H.265 pipeline remains byte-buffer based:

```text
MediaCodec decode -> YUV/I420 output buffer -> CPU YUV/RGBA conversion -> RGBA Vec<u8> -> Flutter soft render
```

The desired future pipeline is documented separately:

```text
MediaCodec decode -> Surface/SurfaceTexture -> Flutter texture
```

Document:

- `docs/android-video-pipeline.md`

## Texture Path

The full Android SurfaceTexture/Flutter texture path was not implemented in
this iteration because it is a separate integration with the Flutter texture
registration lifecycle, Surface/SurfaceTexture, and MediaCodec surface output.

Requirements left for a safe future implementation:

- if texture init fails, fall back to RGBA soft render;
- if Flutter texture registration fails, fall back to RGBA soft render;
- if MediaCodec Surface output fails, fall back to byte-buffer decode;
- if texture delivery fails at runtime, fall back to RGBA soft render;
- do not touch VP8/VP9/AV1 software decode paths;
- do not break desktop platforms.

## Quality Monitor And Android Menu Fixes

### Missing Quality Monitor Item

Menu items that had disappeared after mobile toolbar/menu changes were restored.

Affected files:

- `flutter/lib/mobile/pages/remote_page.dart`
- `flutter/lib/mobile/pages/view_camera_page.dart`
- `flutter/lib/common/widgets/setting_widgets.dart`
- `src/lang/ru.rs`

### Clipboard Heading

After restoring menu items, the clipboard section heading was missing. It was
restored in both mobile menus:

- `remote_page.dart`: `Clipboard direction`
- `view_camera_page.dart`: `Clipboard direction`

### Custom Quality FPS Mode Dropdown

On Android, the dropdown used to choose custom quality mode:

- `Adaptive FPS cap`
- `Fixed FPS`

was rendered outside the menu/overlay, making the option almost impossible to
select.

Fix: in the mobile UI, the dropdown was replaced with inline `RadioListTile`
entries inside the menu itself. The desktop UI still uses the dropdown.

File:

- `flutter/lib/common/widgets/setting_widgets.dart`

## Android Build Fixes

The Android build was brought to a successful release APK.

Changes:

- fixed the Gradle proto path in `flutter/android/app/build.gradle`;
- updated/pinned Flutter dependencies in `flutter/pubspec.yaml` and
  `flutter/pubspec.lock`;
- added Flutter/Dart compatibility fixes:
  - `DialogTheme`;
  - deprecated `withOpacity`;
  - removal/replacement of incompatible `selectAllOnFocus`;
  - simplified controller logic in the desktop remote toolbar;
- fixed Android wake lock lifetime and clipboard compile issues;
- updated `flutter/ndk_arm64.sh`.

## Verification

Commands that were run:

```bash
cargo ndk check --features flutter,hwcodec,mediacodec
cargo ndk build --release --features flutter,hwcodec,mediacodec
/home/w0w/flutter/bin/dart format ...
/home/w0w/flutter/bin/flutter build apk --target-platform android-arm64 --release --build-name 2.0.2 --build-number 2202
/home/w0w/android-sdk/build-tools/34.0.0/apksigner verify --verbose ...
/home/w0w/android-sdk/build-tools/34.0.0/aapt dump badging ...
unzip -l ... lib/arm64-v8a/*
git diff --check
```

Result:

- Android APK was built successfully.
- APK signature v1/v2 is valid.
- Package: `io.github.rustadministrator.rustadmin`
- Version name: `2.0.2`
- Version code: `2202`
- Native ABI: `arm64-v8a`
- `git diff --check` was clean.
- Temporary signing files were removed from the working tree after the build.

## Latest APK

File:

```text
/home/w0w/rustadmin-fps-diag/flutter/build/app/outputs/flutter-apk/rustadmin-2.0.2-v2202-arm64-v8a-menu-hostdiag-release-20260620.apk
```

SHA256:

```text
697ce4d60c07113dfe62f0af5ec76b3eeb7d289bfb465e35955d23359098373f
```

## Current Working Tree Status

The main repository contains changes in Android/Flutter UI, diagnostics,
MediaCodec, server host diagnostics, and documentation.

External `/home/w0w/hbb_common` contains this change:

```text
M protos/message.proto
```

Added `TestDelay` fields:

```proto
string host_video_fps = 5;
string host_video_codec = 6;
string host_video_qos = 7;
string host_video_wait = 8;
```

## Important Next Steps

1. Build and install an updated host binary on the remote host.
2. Check Quality Monitor after updating the host:
   - `HostFPS`
   - `HostCodec`
   - `HostQoS`
   - `HostWait`
3. Repeat 2K tests:
   - adaptive FPS;
   - fixed FPS 30;
   - H.264;
   - H.265;
   - VP9;
   - AV1;
   - direct;
   - relay.
4. If `HostFPS/HostWait/HostQoS` shows a limit on the capture/encode/send side,
   optimize the host path next.
5. If the host reliably sends 30 FPS and Android still shows 15 FPS with low
   `DecFPS`, return to the Android texture path.

## Short Technical Conclusion

In the current screenshots, the Android viewer does not look like the primary
bottleneck: `DecFPS` is above target, `Queue 0`, `AutoFPS 30`, `Direct true`.

The current 15 FPS issue most likely needs to be confirmed with host-side
diagnostics. Without an updated host, these fields do not appear in Quality
Monitor because the old host does not send the new `TestDelay` fields.
