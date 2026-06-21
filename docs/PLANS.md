# RustAdmin Plans

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

## Codec Handshake Regression Guard

Codec changes must keep advertised, usable, and selected codecs consistent.
Before considering codec work done, compare both peer logs for:

- Host `SupportedEncoding` and viewer `SupportedDecoding`.
- `usable:` codec calculation and negotiated codec.
- Selected encoder config and whether it came from software, Vulkan, RAM hardware,
  or VRAM hardware.
- First encoded frame, first received frame, and first decoded frame.

Fail closed: if an encoder probe or smoke test is missing, pending, skipped, or
failed, do not advertise that encoder and do not allow explicit peer preference to
select it.

Do not treat a black screen as an H265 decode failure by default. If the viewer
never logs a first received video frame, debug stream delivery, protobuf parsing,
and send queue latency before changing codec priority.

If the viewer never logs a first received video frame, in-place codec fallback on
the same ordered connection is not a valid recovery path. Mark the attempted
codec unsupported and reconnect, or move media to a separate stream in a future
transport design.

## Android MediaCodec FPS Workaround

Android H264/H265 currently decodes through MediaCodec byte buffers, converts
YUV to RGBA on CPU, then sends RGBA into Flutter soft rendering. The measured
`decode_fps` includes that decode, conversion, and Flutter handoff path, so
adaptive FPS can throttle the host to the Android render pipeline speed.

Do not treat codec negotiation changes as the fix for Android 2K FPS caps. The
proper workaround is an Android-only MediaCodec Surface/SurfaceTexture/Flutter
texture path for H264/H265, with automatic fallback to the current RGBA
soft-render path if codec setup, texture registration, frame delivery, or runtime
rendering fails.
