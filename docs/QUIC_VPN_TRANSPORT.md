# QUIC Transport over VPNs

## Status

Revision 114 with `hbb_common` revision 018 integrates the QUIC transport into direct IP/domain sessions. The default build enables the `quic-transport` feature and selects `quic-preferred` unless the global `Disable UDP` option is enabled.

Implemented and tested:

- Quinn UDP endpoints with QUIC DATAGRAM and independent bidirectional streams
- TLS 1.3 mutual authentication, certificate pinning, and Ed25519 device-key binding
- Fingerprint-validated pairing records and a persistent trusted-peer store
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
- A bounded protobuf adapter that preserves the existing application pipelines while routing video, audio, mouse movement, input, clipboard, files, diagnostics, and control independently
- Reliable `SwitchDisplay` acknowledgement before related video DATAGRAM delivery
- Reliable raw mode for direct port forwarding
- Persistent local TLS identity and signed certificate exchange through backward-compatible optional protobuf fields
- Direct UDP listener startup, pretrusted client connection, dynamic trusted-client refresh, and classified TCP fallback
- Extended Quality Monitor fields for `QUIC/UDP`, path MTU, maximum DATAGRAM size, QUIC RTT, and cumulative lost packets

Release gates still pending are Windows compilation, physical Android-to-Windows VPN testing, packet-loss/reordering/reduced-MTU emulation, controlled in-session reconnect integration, and iOS compilation. `quic-only` should remain a diagnostic mode until those field gates pass.

## Existing Architecture

RustAdmin is a Rust application with a Flutter desktop/mobile UI. `hbb_common` owns framing, TCP/WebSocket helpers, protocol utilities, and shared configuration. The main repository owns rendezvous, direct connection establishment, the client I/O loop, host connection state, capture, codecs, audio, input, clipboard, and file transfer. Windows, Linux, macOS, Android, and iOS share the Rust protocol layer; capture, rendering, audio, and input contain platform-specific implementations.

The legacy transport is framed protobuf over TCP, relay TCP/WebSocket, or KCP. The asynchronous `DuplexStream` writer isolates reads from blocked TCP writes and keeps bounded latest-only video/feedback entries. QUIC is a separate `Stream` variant; the adapter reconstructs the original protobuf messages on receive, so capture, codec, rendering, audio, input injection, clipboard, and file policy remain unchanged.

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

The application adapter parses bounded existing protobuf `Message` values before QUIC encryption, routes them to the appropriate channel, and reconstructs the original bytes on receive. Video and mouse queues are latest-only, audio is bounded and disposable, and each reliable class has an independent writer task. A display-ordering epoch blocks video DATAGRAM transmission until the peer has queued the reliable `SwitchDisplay` update.

## QUIC Library

The implementation pins Quinn 0.11.9. Quinn is maintained, supports QUIC DATAGRAM, Tokio, IPv4/IPv6, stream priorities, congestion control, path MTU discovery, and Windows/Linux/macOS/Android/iOS targets. It uses rustls with the ring provider and TLS 1.3 only in this transport. Quinn is dual licensed under Apache-2.0 and MIT.

Quinn owns congestion control and path MTU discovery. RustAdmin's adaptation layer only adjusts encoder and file-transfer targets; it does not implement a competing network congestion controller.

## Security Model

VPN reachability is not authorization. QUIC requires all of the following:

1. TLS 1.3 mutual certificate validation.
2. Exact SHA-256 pin verification of the peer leaf certificate.
3. An Ed25519 challenge signed by the existing RustAdmin device identity and bound to the TLS exporter, session ID, both nonces, and both identity keys.
4. A trusted peer record created only after explicit fingerprint confirmation, a valid signed direct-pairing proof, or secure pre-enrollment.
5. Session protocol negotiation after authentication, with the complete server offer returned so the client can recompute the result and reject downgrade changes.

Zero-RTT is not used. Clipboard text, keyboard data, file contents, private keys, and authentication material must never be logged.

On Unix, the identity/trust directories use mode 0700 and private files use mode 0600. Records and identity files are written through synchronized temporary files. On Windows these files live below the existing application configuration directory and inherit its ACL; migration to an OS credential vault remains a hardening option.

The first connection to a compatible peer intentionally uses the existing authenticated TCP direct handshake. Both sides exchange an optional signed QUIC certificate bound to the legacy device signing key and ephemeral direct-session key. The production bootstrap stores that identity only after the direct-pairing passphrase proof succeeds or a previously confirmed paired-viewer identity is accepted; a password-only TCP login does not pre-authorize QUIC. Old clients ignore these protobuf fields. Later connections use mTLS and TLS-exporter-bound Ed25519 authentication before the normal RustAdmin login/permission flow.

## Configuration

The current shared option keys are:

| Option | Default | Meaning |
| --- | --- | --- |
| `remote-transport` | `quic-preferred` | `tcp`, `quic-preferred`, or `quic-only` |
| `disable-udp` | off | Emergency kill switch; forces TCP regardless of mode |
| `quic-listen-address` | `0.0.0.0` | UDP bind address |
| `quic-listen-port` | `48100` | UDP listen and peer port |
| `quic-connect-timeout-ms` | `5000` | QUIC connect timeout, 250-60000 ms |
| `quic-keepalive-interval-ms` | `5000` | Liveness interval; 0 disables it |
| `quic-enable-ipv6` | enabled | Set to `N` to disable IPv6 |
| `quic-file-bandwidth-mbps` | `20` | File-transfer cap; 0 disables file bandwidth |

`quic-preferred` falls back for missing pre-enrollment, UDP bind failure, timeout, or pre-authentication path reset. It does not fall back after TLS certificate, pin, device identity, session negotiation, or application protocol failure.

Android and Windows expose `Enable QUIC` in Network settings. Enabling it writes `remote-transport=quic-preferred` and clears `disable-udp`; disabling it writes `remote-transport=tcp` without disabling UDP for legacy rendezvous or KCP traffic. `Disable UDP` remains the separate global TCP-only emergency switch.

TCP and UDP use independent ports. Existing direct TCP continues to use the configured direct-access port; QUIC listens on UDP 48100 by default. The Windows installer already authorizes the application executable in both firewall directions, which covers TCP and UDP for installed builds.

See `docs/quic-vpn.example.toml`.

## Run a Direct VPN Session

1. Configure the VPN normally and verify that each peer can route to the other peer's tunnel IP or domain.
2. Leave `Disable UDP` off. Allow the RustAdmin executable and UDP 48100 on the applicable VPN firewall profile.
3. Enable RustAdmin direct IP access on the host and configure the direct-pairing passphrase (or retain an already confirmed paired viewer).
4. Enter the host VPN IP or domain in the client connection field. The first compatible connection uses TCP and the signed direct-pairing proof to enroll both QUIC identities.
5. Disconnect and connect again. Extended Quality Monitor should show `Path QUIC/UDP`, MTU, Datagram, QUIC RTT, and Lost.

`remote-transport=tcp` forces the legacy path. `remote-transport=quic-only` is intended for diagnostics and fails instead of falling back. No public rendezvous, NAT punch, or relay is used when the user connects to an explicit VPN peer address.

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
  transport::application::tests::protobuf_application_stream_uses_independent_reliable_and_datagram_channels \
  -- --exact --nocapture
```

## Troubleshooting

- `UDP is disabled`: clear `disable-udp` only after confirming local policy permits UDP.
- UDP bind failure: verify the configured local address exists and UDP port 48100 is free.
- Connect timeout: verify the VPN route, peer tunnel address, host firewall, and UDP port. A timeout alone cannot distinguish a dropped firewall packet from an unreachable peer.
- Certificate or identity mismatch: TCP fallback is deliberately refused. Confirm the peer fingerprint and investigate a changed device identity or restored configuration.
- Protocol mismatch: update the older peer; do not bypass negotiation.
- Repeated frame timeouts: inspect current MTU, QUIC loss, DATAGRAM drops, and frame completion metrics. Do not hardcode a 1500-byte datagram.
- Input works but media does not: verify QUIC DATAGRAM was negotiated, `max_datagram_size()` is present, and the Quality Monitor shows a nonzero Datagram value.
- First connection remains TCP: this is expected while signed QUIC identities are enrolled. Complete direct pairing, then reconnect. A password-only login intentionally does not create persistent QUIC trust.
- Port 48100 is blocked: the Quality Monitor remains on `TCP`, and the log contains a classified QUIC reachability fallback. Open UDP 48100 on the VPN interface or configure the matching port at both peers.
- File transfer affects interaction: enforce the dedicated stream priority and rate limiter; do not send file chunks on control or input streams.

## Integration Stages

1. Completed: stabilize the existing TCP writer and collect TCP path diagnostics.
2. Completed: authenticated QUIC endpoint, binary protocol, session negotiation, and channel primitives.
3. Completed: bounded video/audio/mouse DATAGRAM modules and reliable input/clipboard/file modules.
4. Completed: protobuf channel adapter, raw mode, reliable display ordering, and persistent TLS identity lifecycle.
5. Completed: host listener, signed peer enrollment, client mode selection, production negotiation, and classified preferred-mode fallback.
6. Completed: extended Quality Monitor transport, MTU, DATAGRAM, RTT, and loss reporting.
7. In progress: Windows/Android release builds and physical VPN validation.
8. Pending: root-capable packet impairment matrix, in-session reconnect supervisor, iOS build, and optional configuration UI beyond the existing `Disable UDP` kill switch.
