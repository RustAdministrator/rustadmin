# RustAdmin Plans

## Android Video Pipeline Work Without Device Testing

The following Android MediaCodec and rendering work can be implemented and
validated before real-device testing:

1. Instrument the existing RGBA path. Measure MediaCodec input queue, output
   dequeue, YUV-to-RGBA conversion, Flutter handoff, video queue depth, decode
   FPS, render FPS, adaptive FPS, resolution, codec, and direct/relay state.
   Rate-limit diagnostics and expose the active render path in the Extended
   Quality Monitor.
2. Fix statically provable MediaCodec bugs and add defensive validation for
   dimensions, stride, crop, plane offsets, and output-buffer bounds. Do not
   change vendor-specific color-layout assumptions without device evidence.
3. Refactor Android rendering behind an explicit state machine with RGBA,
   texture initialization, active texture, and failed-texture states. Keep the
   existing RGBA implementation intact as the mandatory fallback.
4. Implement the experimental Surface/SurfaceTexture path behind a disabled-by-
   default developer option. Centralize cleanup for disconnect, display switch,
   decoder recreation, and application pause/resume, and log every fallback
   reason.
5. Provide developer controls for RGBA, experimental texture, and forced texture
   failure. Reserve automatic texture selection until real-device validation.
6. Add device-independent tests for MediaFormat and plane-layout validation,
   render-path transitions, initialization/runtime fallback, timing aggregation,
   and diagnostic rate limiting. Cross-compile the Rust library and build the
   Android APK as the final offline checks.

One APK should support testing the existing RGBA path, the experimental texture
path, and forced fallback. Do not make texture rendering the production default
until Qualcomm and MediaTek devices have validated Surface output, lifecycle,
rotation/crop/color correctness, fallback behavior, and actual FPS improvement.

## Advanced Connection Diagnostics and Tuning

Future GUI work should expose advanced, non-default connection tuning for difficult
links such as VPN over LTE:

- Startup-safe video profile: enable/disable and adjust startup duration.
- Startup video limits: initial FPS cap and bitrate/quality cap.
- No-video watchdog: timeout before closing a session that authenticated but never
  received a video packet.
- Host video backpressure: stale-frame drop threshold and diagnostics.
- Optional retry policy: retry direct/relay paths when the video stream never
  starts, when rendezvous/relay infrastructure is configured.

Keep these under an advanced or diagnostics section. Defaults should remain safe
for normal users and should not weaken secure connection or pairing behavior.

## QUIC Transport Roadmap

After the current connection-startup issue is patched on the existing transport,
proper QUIC support is the highest-priority transport project.

Target design:

- Keep an authenticated reliable control stream separate from media. Use it for
  auth state, permissions, keepalive, close reasons, codec negotiation, media
  restart requests, and diagnostics.
- Carry video on QUIC datagrams or a media-specific stream so video stalls do not
  kill the whole authenticated session.
- Keep file transfer, clipboard metadata, terminal, and port-forwarding on
  separate reliable streams where backpressure cannot block control pings.
- Bind QUIC TLS identity to RustAdmin peer identity and existing
  pairing/fingerprint checks. The design must prevent downgrade to weaker
  transport without explicit fallback logging.
- Preserve TCP, WebSocket, and KCP fallbacks until QUIC is proven across direct,
  relay, IPv4, IPv6, and high-loss VPN/LTE paths.

Do not start the QUIC implementation until the current no-video startup handling
is stable and covered by focused tests.
