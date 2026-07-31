# RustAdmin QUIC Application Protocol Version 2

Version 2 extends the version 1 transport without changing the existing
48-byte envelope or protobuf application payloads. All integers remain
big-endian and all version 1 size, session, sequence, channel, and payload
validation rules still apply.

## Negotiation and Compatibility

New endpoints advertise TLS ALPN values in this order:

1. `rustadmin-quic-v2`
2. `rustadmin-quic-v1`

The selected ALPN is authenticated by the TLS 1.3 handshake and determines the
application channel layout before any channel is opened. A version 2 pair sends
session offers with protocol range `2..=2` and capability
`CAP_RELIABLE_KEYFRAMES` (`0x0040`). A connection that negotiates version 1
uses the unchanged version 1 offer and exactly five application streams. It
never sends the new capability, channel, or message type to the old peer.

Compatibility matrix:

| Client | Server | Selected layout |
| --- | --- | --- |
| v2 + v1 | v2 + v1 | v2, six reliable streams |
| v2 + v1 | v1 only | v1, five reliable streams |
| v1 only | v2 + v1 | v1, five reliable streams |

ALPN downgrade is not accepted after negotiation. Certificate, device-key,
pairing, or protocol errors remain fatal and are not converted into a TCP
fallback.

The common message header and reliable stream preface retain framing version 1
for binary compatibility. The negotiated ALPN/session version selects the
channel set and semantics. These two version fields are intentionally distinct.

## Reliable Keyframe Channel

Version 2 adds:

- Channel ID `6`: reliable video.
- Message type `65`: `ReliableVideoFrame`.
- One high-priority bidirectional stream with the normal `RAQS` preface.
- A 32 MiB bounded application payload limit.

Complete encoded keyframe protobuf messages use this stream. Ordinary delta
frames continue to use QUIC DATAGRAM and are never retransmitted by the
application. The keyframe stream is independent from control, input, clipboard,
file transfer, and diagnostics. Its Quinn priority is below critical input but
above clipboard and file transfer.

The existing video-ordering epoch still applies. A reliable keyframe cannot be
sent until the peer has queued and acknowledged the corresponding reliable
`SwitchDisplay` update.

The receiver validates that every `ReliableVideoFrame` payload is a bounded
`VideoFrame` containing a keyframe. A delta frame, wrong protobuf class,
oversized message, changed session ID, or non-monotonic reliable sequence closes
the application transport as a protocol error.

## DATAGRAM Recovery

The version 2 receiver keeps disposable delta-frame semantics but gives an
incomplete startup keyframe a separate bounded 500 ms fragment deadline. Before
the first complete keyframe, completed delta frames are discarded and cannot
mark the partial keyframe obsolete. Missing startup keyframes generate
rate-limited refresh requests. Pending frame count and memory remain bounded;
ordinary delta fragments use a 120 ms deadline.

For a negotiated version 2 session, the reliable keyframe bypasses the
DATAGRAM reassembler, so that reassembler does not impose its version 1
keyframe gate on following delta frames. The application startup gate still
discards any delta delivered before the reliable keyframe reaches the normal
video pipeline and repeats a bounded refresh request. Version 1 retains the
DATAGRAM reassembler gate because its keyframes use DATAGRAM fragments.

The client startup gate repeats a keyframe refresh at a bounded 750 ms interval
while complete delta frames arrive before the first keyframe. Recovery state is
cleared after a valid first keyframe and is never replayed across a new session.

## Packet Sizing

QUIC starts at the standards-compliant 1200-byte UDP payload. Quinn path MTU
discovery remains enabled with a conservative default search ceiling of 1360
bytes to avoid repeatedly probing Ethernet-sized packets through lower-MTU VPN
routes. The negotiated application DATAGRAM ceiling is 1300 bytes in version 2,
but every send also clamps to Quinn's current live
`Connection::max_datagram_size()`. A smaller path therefore stays smaller, and
the sender can use a larger payload only after Quinn proves it safe.

Quality Monitor reports the selected application version, reliable-keyframe
mode, live DATAGRAM maximum, negotiated ceiling, path MTU, lost packets,
reassembly drops, and keyframe-request count.
