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
