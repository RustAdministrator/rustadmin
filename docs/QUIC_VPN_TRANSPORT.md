# QUIC Transport over VPNs

## Status

Revision 113 with `hbb_common` revision 017 contains the reviewed transport core behind the `quic-transport` Cargo feature. It does not replace the production TCP path by default.

Implemented and tested:

- Quinn UDP endpoints with QUIC DATAGRAM and independent bidirectional streams
- TLS 1.3 mutual authentication, certificate pinning, and Ed25519 device-key binding
- Explicit fingerprint pairing records and a persistent trusted-peer store
- Versioned, fixed-width, big-endian application headers
- Session offer/accept negotiation with downgrade detection
- Video fragmentation and bounded out-of-order reassembly
- Audio packet transport and a bounded jitter buffer with a PLC integration event
- Disposable mouse movement and reliable keyboard/button/wheel representations
- Dedicated reliable input, clipboard, file-transfer, and diagnostics streams
- Clipboard direction policy and loop suppression
- File metadata, bounded chunks, cancellation, resume hash state, SHA-256 verification, and rate limiting
- Bounded reconnect policy, media/input reset actions, adaptation targets, and runtime statistics
- Dynamic QUIC DATAGRAM sizing from Quinn's current path MTU estimate

Pending application integration:

- Map the existing protobuf video/audio/input/clipboard/file services to the new channels.
- Persist or provision the local TLS identity on every supported platform.
- Add the connection-mode control to the Flutter UI.
- Start the host UDP listener and client connector only after trusted-peer material is available.
- Feed QUIC statistics and transport state into the existing quality monitor.
- Run Windows, Android-device, VPN-route-loss, reconnect, and reduced-MTU field tests.

Until those items are complete, use `remote-transport = "tcp"`. The QUIC core is not yet a user-visible connection mode.

## Existing Architecture

RustAdmin is a Rust application with a Flutter desktop/mobile UI. `hbb_common` owns framing, TCP/WebSocket helpers, protocol utilities, and shared configuration. The main repository owns rendezvous, direct connection establishment, the client I/O loop, host connection state, capture, codecs, audio, input, clipboard, and file transfer. Windows, Linux, macOS, Android, and iOS share the Rust protocol layer; capture, rendering, audio, and input contain platform-specific implementations.

The production transport is framed protobuf over TCP, relay TCP/WebSocket, or legacy KCP. The asynchronous `DuplexStream` writer isolates reads from blocked TCP writes and keeps bounded latest-only video/feedback entries. QUIC is added as a separate transport rather than changing capture, codec, or platform code.

## Proposed Application Architecture

One authenticated QUIC connection represents one remote-access session:

| Channel | QUIC primitive | Priority |
| --- | --- | --- |
| Session control and negotiation | Dedicated bidirectional stream | Highest |
| Keyboard, mouse buttons, wheel | Dedicated bidirectional stream | High |
| Mouse movement | DATAGRAM | Disposable |
| Audio | DATAGRAM | Low latency |
| Video fragments | DATAGRAM | Disposable |
| Clipboard | Dedicated bidirectional stream | Medium |
| File transfer | One or more dedicated streams | Low and rate limited |
| Diagnostics | Dedicated bidirectional stream or DATAGRAM telemetry | Lowest |

The application adapter must parse existing protobuf `Message` values before transport encryption, route media and input to the appropriate channel, and reconstruct existing messages on receive. Capture, encoding, decoding, rendering, and input injection remain unchanged.

## QUIC Library

The implementation pins Quinn 0.11.9. Quinn is maintained, supports QUIC DATAGRAM, Tokio, IPv4/IPv6, stream priorities, congestion control, path MTU discovery, and Windows/Linux/macOS/Android/iOS targets. It uses rustls with the ring provider and TLS 1.3 only in this transport. Quinn is dual licensed under Apache-2.0 and MIT.

Quinn owns congestion control and path MTU discovery. RustAdmin's adaptation layer only adjusts encoder and file-transfer targets; it does not implement a competing network congestion controller.

## Security Model

VPN reachability is not authorization. QUIC requires all of the following:

1. TLS 1.3 mutual certificate validation.
2. Exact SHA-256 pin verification of the peer leaf certificate.
3. An Ed25519 challenge signed by the existing RustAdmin device identity and bound to the TLS exporter, session ID, both nonces, and both identity keys.
4. A trusted peer record created only after explicit fingerprint confirmation or secure pre-enrollment.
5. Session protocol negotiation after authentication, with the complete server offer returned so the client can recompute the result and reject downgrade changes.

Zero-RTT is not used. Clipboard text, keyboard data, file contents, private keys, and authentication material must never be logged.

On Unix, the file trusted-peer store creates its directory with mode 0700 and records with mode 0600, then atomically renames a synchronized temporary file. Windows integration still needs an application-owned directory with an explicit ACL or OS credential storage policy.

## Configuration

The current shared option keys are:

| Option | Default | Meaning |
| --- | --- | --- |
| `remote-transport` | `tcp` | `tcp`, `quic-preferred`, or `quic-only` |
| `disable-udp` | off | Emergency kill switch; forces TCP regardless of mode |
| `quic-listen-address` | `0.0.0.0` | UDP bind address |
| `quic-listen-port` | `48100` | UDP listen and peer port |
| `quic-connect-timeout-ms` | `5000` | QUIC connect timeout, 250-60000 ms |
| `quic-keepalive-interval-ms` | `5000` | Liveness interval; 0 disables it |
| `quic-enable-ipv6` | enabled | Set to `N` to disable IPv6 |
| `quic-file-bandwidth-mbps` | `20` | File-transfer cap; 0 disables file bandwidth |

`quic-preferred` must fall back only for a transport reachability failure. It must not fall back after certificate, identity, pairing, or protocol validation fails, because that would turn an authentication error into a downgrade.

See `docs/quic-vpn.example.toml`.

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
  --offline --lib --features flutter,hwcodec,quic-transport
```

The localhost integration test performs mTLS, device authentication, ping, session negotiation, independent input/file streams, fragmented video, audio, and mouse DATAGRAM delivery:

```bash
cargo test --offline --features quic-transport --lib \
  transport::quic::tests::mutual_tls_identity_binding_and_ping_round_trip \
  -- --exact --nocapture
```

## Troubleshooting

- `UDP is disabled`: clear `disable-udp` only after confirming local policy permits UDP.
- UDP bind failure: verify the configured local address exists and UDP port 48100 is free.
- Connect timeout: verify the VPN route, peer tunnel address, host firewall, and UDP port. A timeout alone cannot distinguish a dropped firewall packet from an unreachable peer.
- Certificate or identity mismatch: do not fall back automatically. Confirm the peer fingerprint and investigate a changed device identity.
- Protocol mismatch: update the older peer; do not bypass negotiation.
- Repeated frame timeouts: inspect current MTU, QUIC loss, DATAGRAM drops, and frame completion metrics. Do not hardcode a 1500-byte datagram.
- Input works but media does not: verify QUIC DATAGRAM was negotiated and `max_datagram_size()` is present.
- File transfer affects interaction: enforce the dedicated stream priority and rate limiter; do not send file chunks on control or input streams.

## Integration Stages

1. Completed: stabilize the existing TCP writer and collect TCP path diagnostics.
2. Completed: authenticated QUIC endpoint, binary protocol, session negotiation, and channel primitives.
3. Completed: bounded video/audio/mouse DATAGRAM modules and reliable input/clipboard/file modules.
4. Next: protobuf channel adapter and local TLS identity lifecycle.
5. Next: host listener, client mode selection, safe preferred-mode fallback, and reconnect supervisor.
6. Next: quality-monitor integration and Flutter configuration UI.
7. Next: Windows/Android release builds and VPN network-emulation/field validation.
