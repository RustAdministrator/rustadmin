# RustAdmin QUIC Application Protocol Version 1

All integer fields use network byte order (big endian). Receivers validate the complete fixed-width header before allocating payload memory. Native Rust structs are never deserialized directly from untrusted bytes.

## Common Message Header

Length: 48 bytes.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `0x52415131` (`RAQ1`) |
| 4 | 2 | Protocol version, currently 1 |
| 6 | 2 | Message type |
| 8 | 2 | Flags |
| 10 | 1 | Channel ID |
| 11 | 1 | Reserved, zero |
| 12 | 16 | Nonzero session ID |
| 28 | 8 | Nonzero channel sequence number |
| 36 | 4 | Payload length |
| 40 | 8 | Sender-local monotonic timestamp in microseconds |

Known flags are `ACK_REQUIRED=0x0001` and `RESPONSE=0x0002`. Unknown flags, message types, channels, versions, reserved values, zero IDs, oversized payloads, and length mismatches are rejected.

Channel IDs:

- 1 session control
- 2 reliable input
- 3 clipboard
- 4 file transfer
- 5 diagnostics
- 16 video DATAGRAM
- 17 audio DATAGRAM
- 18 mouse DATAGRAM

## Reliable Stream Preface

Every non-control reliable stream starts with eight bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `0x52415153` (`RAQS`) |
| 4 | 2 | Protocol version |
| 6 | 1 | Reliable channel ID |
| 7 | 1 | Reserved, zero |

Each following message is a four-byte big-endian length followed by one complete common-header message. Input, clipboard, file, and diagnostics use independent streams. The file stream has lower Quinn priority than input, clipboard, and control.

## Control and Authentication

TLS uses ALPN `rustadmin-quic-v1`, TLS 1.3, mutual certificates, and no 0-RTT. The first bidirectional stream is control and receives maximum stream priority.

Client and server hello payloads carry role, Ed25519 public key, random nonces, and signatures. Signatures cover the TLS exporter, session ID, role, nonces, and both device keys. Hello payloads have exact fixed limits.

After authentication:

1. Client sends `SessionOffer`.
2. Server computes the deterministic intersection.
3. Server sends `SessionAccept`, containing its complete offer and the selected agreement.
4. Client recomputes the agreement and requires exact equality.

The offer validates protocol range, ordered codec lists without duplicates, color mask, geometry, FPS, DATAGRAM size, bitrate, latency mode, and directional permissions.

## Video DATAGRAM

The common payload starts with a 28-byte video fragment header:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | Nonzero frame ID |
| 8 | 2 | Fragment index |
| 10 | 2 | Total fragment count |
| 12 | 1 | Codec: H264=1, H265=2, VP8=3, VP9=4, AV1=5 |
| 13 | 1 | Frame flags: keyframe bit 0, codec-config bit 1 |
| 14 | 2 | Reserved, zero |
| 16 | 8 | Presentation timestamp in microseconds |
| 24 | 4 | Complete encoded frame size |

Fragment data follows. Fragment size is derived from Quinn's current maximum DATAGRAM size minus both headers. The receiver allows out-of-order and exact duplicate fragments. It rejects conflicting duplicates and inconsistent metadata. Pending frames, fragment count, frame size, and memory are bounded. Incomplete frames expire, completion of a newer frame removes older incomplete state, and repeated loss produces a rate-limited keyframe-request signal. Ordinary delta fragments are never retransmitted by the application.

## Audio DATAGRAM

The common sequence is the audio packet sequence. The 20-byte audio payload header contains capture timestamp, codec, channel count, reserved field, sample rate, and encoded payload length. Version 1 supports Opus. The receiver rejects duplicates, late packets, invalid formats, oversized packets, and sequence gaps over 4096 packets.

The bounded jitter buffer emits either a decoded packet input or an explicit packet-loss event for the audio pipeline's PLC implementation. Queue depth, bytes, and capture-timestamp span are exposed for clock-drift correction. Peer timestamps are not reported as one-way latency without clock synchronization.

## Input

Mouse movement uses DATAGRAM and includes mode, button-state mask, display ID, X, and Y. The receiver applies only a sequence newer than the last accepted movement.

Keyboard state, mouse buttons, and wheel use the reliable input stream. Events are fixed width and sequence checked. Duplicate state transitions are suppressed. Disconnect handling returns release events for every logically pressed key and mouse button; old events are never replayed after reconnect.

## Clipboard

Clipboard version 1 supports bounded UTF-8 text. The payload contains a 16-byte origin ID, change sequence, format, reserved fields, declared size, and text. Direction permissions are enforced locally. Local-origin and stale peer sequences are ignored to prevent loops. Clipboard contents are never logged.

## File Transfer

Metadata contains transfer ID, size, resume offset, SHA-256, flags, and a bounded UTF-8 file name. Version 1 intentionally accepts one safe basename, not a path. It rejects separators, parent components, drive/ADS colons, NUL, and control characters.

Chunks contain transfer ID, exact offset, declared length, and at most 256 KiB of data. Chunks are sequential on their dedicated reliable stream. Completion requires declared size and SHA-256 equality. Resume requires a matching hash state for existing bytes. Cancellation is explicit. The network layer never executes received files.

## Reconnection

Reconnect uses bounded exponential backoff with jitter. Every new connection performs TLS, device authentication, and negotiation again. Disconnect actions release input, discard old media, request a keyframe, and require file integrity validation before resume. Sequence state is reset; old input is not replayed.

