# QUIC Direct Transport over Routed UDP

## Status

Revision 118 with `hbb_common` revision 021 integrates QUIC into direct IP/domain and rendezvous-assisted sessions. It does not detect or require a specific VPN implementation: any routed IPv4/IPv6 path, including LANs and VPNs, is eligible. The default build enables `quic-transport` and selects automatic QUIC-first mode unless the global `Disable UDP` option is enabled.

Implemented and tested:

- Quinn UDP endpoints with QUIC DATAGRAM and independent bidirectional streams
- TLS 1.3 mutual authentication, certificate pinning, and Ed25519 device-key binding
- Fingerprint-validated pairing records and a persistent trusted-peer store
- Versioned, fixed-width, big-endian application headers
- Session offer/accept negotiation with downgrade detection
- Video fragmentation and bounded out-of-order reassembly
- ALPN v2/v1 negotiation that preserves the exact five-stream v1 layout for old peers
- A sixth high-priority v2 stream for reliable keyframes while delta frames remain disposable DATAGRAM traffic
- Startup reassembly that preserves a partial keyframe and rate-limits repeated refresh requests
- Version-aware startup gating so a v2 reliable keyframe cannot leave later DATAGRAM deltas blocked in the v1 reassembler state
- Audio packet transport and a bounded jitter buffer with a PLC integration event
- Disposable mouse movement and reliable keyboard/button/wheel representations
- Dedicated reliable input, clipboard, file-transfer, and diagnostics streams
- Clipboard direction policy and loop suppression
- File metadata, bounded chunks, cancellation, resume hash state, SHA-256 verification, and rate limiting
- Bounded reconnect policy, media/input reset actions, adaptation targets, and runtime statistics
- Dynamic QUIC DATAGRAM sizing from Quinn's live path limit, with a conservative VPN-safe PMTUD search ceiling
- A bounded protobuf adapter that preserves the existing application pipelines while routing video, audio, mouse movement, input, clipboard, files, diagnostics, and control independently
- Reliable `SwitchDisplay` acknowledgement before related video DATAGRAM delivery
- Reliable raw mode for direct port forwarding
- Persistent local TLS identity and signed certificate exchange through backward-compatible optional protobuf fields
- A continuously available bounded first-contact listener, exporter-bound provisional identity discovery, dynamic trusted-peer lookup, and classified TCP fallback
- Concurrent QUIC, TCP, and eligible UDP/KCP candidates for normal one-click connection
- First-connection QUIC promotion without requiring a disconnect and reconnect cycle
- Extended Quality Monitor fields for `QUIC/UDP`, ALPN/session version, keyframe mode, path MTU, live and negotiated DATAGRAM limits, QUIC RTT, loss, reassembly drops, and keyframe requests

Release gates still pending are physical Android-to-Windows routed-UDP testing, packet-loss/reordering/reduced-MTU emulation, controlled in-session reconnect integration, and iOS compilation. `quic-only` should remain a diagnostic mode until those field gates pass.

## Existing Architecture

RustAdmin is a Rust application with a Flutter desktop/mobile UI. `hbb_common` owns framing, TCP/WebSocket helpers, protocol utilities, and shared configuration. The main repository owns rendezvous, direct connection establishment, the client I/O loop, host connection state, capture, codecs, audio, input, clipboard, and file transfer. Windows, Linux, macOS, Android, and iOS share the Rust protocol layer; capture, rendering, audio, and input contain platform-specific implementations.

The legacy transport is framed protobuf over TCP, relay TCP/WebSocket, or KCP. The asynchronous `DuplexStream` writer isolates reads from blocked TCP writes and keeps bounded latest-only video/feedback entries. QUIC is a separate `Stream` variant; the adapter reconstructs the original protobuf messages on receive, so capture, codec, rendering, audio, input injection, clipboard, and file policy remain unchanged.

## Application Architecture

One authenticated QUIC connection represents one remote-access session:

| Channel | QUIC primitive | Priority |
| --- | --- | --- |
| Session control and negotiation | Dedicated bidirectional stream | Highest |
| Keyboard, mouse buttons, wheel | Dedicated bidirectional stream | High |
| Mouse movement | DATAGRAM | Disposable |
| Audio | DATAGRAM | Low latency |
| Video delta fragments | DATAGRAM | Disposable |
| Video keyframes (v2) | Dedicated bidirectional stream | High, reliable bootstrap/recovery |
| Clipboard | Dedicated bidirectional stream | Medium |
| File transfer | One or more dedicated streams | Low and rate limited |
| Diagnostics | Dedicated bidirectional stream or DATAGRAM telemetry | Lowest |

The application adapter parses bounded existing protobuf `Message` values before QUIC encryption, routes them to the appropriate channel, and reconstructs the original bytes on receive. Video and mouse queues are latest-only, audio is bounded and disposable, and each reliable class has an independent writer task. A display-ordering epoch blocks both video DATAGRAM transmission and reliable keyframes until the peer has queued the reliable `SwitchDisplay` update.

New peers negotiate ALPN `rustadmin-quic-v2` and open six reliable streams. If either peer supports only `rustadmin-quic-v1`, TLS selects v1 and both sides retain exactly the previous five-stream layout. See `docs/QUIC_PROTOCOL_V2.md` and `docs/QUIC_PROTOCOL_V1.md`.

## QUIC Library

The implementation pins Quinn 0.11.9. Quinn is maintained, supports QUIC DATAGRAM, Tokio, IPv4/IPv6, stream priorities, congestion control, path MTU discovery, and Windows/Linux/macOS/Android/iOS targets. It uses rustls with the ring provider and TLS 1.3 only in this transport. Quinn is dual licensed under Apache-2.0 and MIT.

Quinn owns congestion control and path MTU discovery. RustAdmin starts at 1200 bytes and limits the default PMTUD search to a 1360-byte UDP payload. The v2 application ceiling is 1300 bytes, but each send remains clamped to Quinn's live DATAGRAM limit. RustAdmin's adaptation layer only adjusts encoder and file-transfer targets; it does not implement a competing network congestion controller.

## Security Model

Network or VPN reachability is not authorization. A previously paired QUIC session requires all of the following:

1. TLS 1.3 with an exact previously pinned peer certificate.
2. Exact SHA-256 pin verification of the peer leaf certificate.
3. An Ed25519 challenge signed by the existing RustAdmin device identity and bound to the TLS exporter, session ID, both nonces, and both identity keys.
4. A trusted peer record created only after explicit fingerprint confirmation, a valid signed direct-pairing proof, or secure pre-enrollment.
5. Session protocol negotiation after authentication, with the complete server offer returned so the client can recompute the result and reject downgrade changes.

Zero-RTT is not used. Clipboard text, keyboard data, file contents, private keys, and authentication material must never be logged.

On Unix, the identity/trust directories use mode 0700 and private files use mode 0600. Records and identity files are written through synchronized temporary files. On Windows these files live below the existing application configuration directory and inherit its ACL; migration to an OS credential vault remains a hardening option.

For first contact, TLS certificate acceptance is provisional and grants no application authorization. Before normal RustAdmin session data is accepted, both peers prove their existing Ed25519 device identities over the TLS exporter. The signed RustAdmin handshake must then bind the same device key and exact TLS certificate, and the existing passphrase/fingerprint pairing must succeed. Only then is the certificate pin persisted. Provisional sessions are bounded and time limited. A changed certificate or device identity is never silently accepted or downgraded to TCP.

Auto mode starts QUIC and legacy direct candidates together. QUIC gets a bounded 1500 ms preference window after a legacy candidate becomes ready. Pairing prompts happen only after a transport has won, so the race cannot cancel an interactive prompt. If an authenticated legacy first contact wins, RustAdmin attempts one bounded QUIC promotion in the same user connection. Old clients ignore the optional signed QUIC fields and continue on the legacy path.

## Configuration

The current shared option keys are:

| Option | Default | Meaning |
| --- | --- | --- |
| `remote-transport` | `quic-preferred` | `tcp`, `quic-preferred` (Auto), or `quic-only` |
| `disable-udp` | off | Emergency kill switch; forces TCP regardless of mode |
| `quic-listen-address` | `0.0.0.0` | UDP bind address |
| `quic-listen-port` | `48100` | UDP listen and peer port |
| `quic-connect-timeout-ms` | `5000` | QUIC connect timeout, 250-60000 ms |
| `quic-keepalive-interval-ms` | `5000` | Liveness interval; 0 disables it |
| `quic-enable-ipv6` | enabled | Set to `N` to disable IPv6 |
| `quic-file-bandwidth-mbps` | `20` | File-transfer cap; 0 disables file bandwidth |

`quic-preferred` falls back for UDP bind failure, unreachable paths, and bounded network timeouts. It does not fall back after certificate, pin, device identity, signed-metadata, pairing, session-negotiation, or application-protocol failure.

Android and Windows expose one `Transport` selector with `Auto (QUIC preferred)`, `QUIC only`, and `TCP only`. It writes a consistent `remote-transport` and legacy `disable-udp` pair. `TCP only` is the emergency UDP kill switch; Auto leaves legacy UDP/KCP candidates eligible.

TCP and UDP use independent ports. Existing direct TCP continues to use the configured direct-access port; QUIC listens on UDP 48100 by default. The Windows installer already authorizes the application executable in both firewall directions, which covers TCP and UDP for installed builds.

See `docs/quic-vpn.example.toml`; its settings apply to any routed UDP path.

## Run a Direct Routed Session

1. Verify that each peer can route to the other peer's LAN or VPN address. RustAdmin does not inspect the VPN implementation.
2. Select `Auto (QUIC preferred)`. Allow the RustAdmin executable and UDP 48100 on the applicable firewall profile.
3. Enable RustAdmin direct IP access on the host and configure the direct-pairing passphrase (or retain an already confirmed paired viewer).
4. Enter the host routed IP in the normal connection field. QUIC and compatible legacy candidates start during the same connection action.
5. Complete normal pairing if prompted. Extended Quality Monitor should show `Path QUIC/UDP`, `QUIC App v2` for a current pair (or `v1` for compatibility), `Video TX DATAGRAM + reliable KF`, path MTU, DATAGRAM limits, QUIC RTT, loss, and recovery counters when QUIC wins.

`remote-transport=tcp` forces the legacy path. `remote-transport=quic-only` is intended for diagnostics and fails instead of falling back. An explicit routed IP does not require a public relay.

## Build and Test

Linux shared-library checks:

```bash
cargo check --offline --features quic-transport --lib
cargo test --offline --features quic-transport --lib
cargo clippy --offline --features quic-transport --lib
```

Android ARM64 native check:

```bash
export ANDROID_SDK_ROOT=/home/w0w/android-sdk
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/28.2.13676358"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export RUSTADMIN_ANDROID_NATIVE_ROOT=/home/w0w/UBarm/Release
export CMAKE_PREFIX_PATH="$RUSTADMIN_ANDROID_NATIVE_ROOT"

cargo ndk --platform 24 --target aarch64-linux-android check \
  --offline --lib --features flutter,hwcodec,mediacodec
```

The localhost integration test performs mTLS, device authentication, ping, session negotiation, independent input/file streams, fragmented video, audio, and mouse DATAGRAM delivery:

```bash
cargo test --offline --features quic-transport --lib \
  transport::application::tests::protobuf_application_stream_uses_independent_reliable_and_datagram_channels \
  -- --exact --nocapture
```

## Troubleshooting

- `UDP is disabled`: clear `disable-udp` only after confirming local policy permits UDP.
- UDP bind failure: verify the configured local address exists and UDP port 48100 is free.
- Connect timeout: verify the routed peer address, host firewall, and UDP port. A timeout alone cannot distinguish a dropped firewall packet from an unreachable peer.
- Certificate or identity mismatch: TCP fallback is deliberately refused. Confirm the peer fingerprint and investigate a changed device identity or restored configuration.
- Protocol mismatch: update the older peer; do not bypass negotiation.
- Repeated frame timeouts: inspect current MTU, QUIC loss, live/negotiated DATAGRAM limits, reassembly drops, keyframe requests, and whether v2 reliable keyframes are active. Do not hardcode a 1500-byte datagram.
- Input works but media does not: verify QUIC DATAGRAM was negotiated, `max_datagram_size()` is present, and the Quality Monitor shows a nonzero Datagram value.
- First connection remains TCP: inspect the classified QUIC candidate and promotion diagnostics. A network timeout may keep the authenticated legacy session; a certificate, identity, or protocol error must fail instead of downgrading.
- Port 48100 is blocked: the Quality Monitor remains on `TCP`, and the log contains a classified QUIC reachability fallback. Open UDP 48100 on the relevant interface or configure the matching port at both peers.
- File transfer affects interaction: enforce the dedicated stream priority and rate limiter; do not send file chunks on control or input streams.

## Integration Stages

1. Completed: stabilize the existing TCP writer and collect TCP path diagnostics.
2. Completed: authenticated QUIC endpoint, binary protocol, session negotiation, and channel primitives.
3. Completed: bounded video/audio/mouse DATAGRAM modules and reliable input/clipboard/file modules.
4. Completed: protobuf channel adapter, raw mode, reliable display ordering, and persistent TLS identity lifecycle.
5. Completed: host listener, signed peer enrollment, client mode selection, production negotiation, and classified preferred-mode fallback.
6. Completed: extended Quality Monitor transport, MTU, DATAGRAM, RTT, and loss reporting.
7. Completed: VPN-neutral QUIC-first candidate racing, bounded first-contact identity binding, same-session promotion, and unified transport UI.
8. Completed in revision 118: ALPN-compatible reliable keyframe bootstrap, startup reassembly recovery, bounded repeated refresh, Android `ndk` 0.9 MediaCodec status handling, and expanded Quality Monitor truth fields.
9. In progress: Windows/Android release builds and physical routed-UDP validation.
10. Pending: root-capable packet impairment matrix, in-session reconnect supervisor, and iOS build.
