# RustAdmin QUIC Application Protocol Versions 2, 3, and 4

Versions 2, 3, and 4 extend the version 1 transport without changing the existing
48-byte envelope or protobuf application payloads. All integers remain
big-endian and all version 1 size, session, sequence, channel, and payload
validation rules still apply.

## Negotiation and Compatibility

Current endpoints advertise these values in order:

1. `rustadmin-quic-v4`
2. `rustadmin-quic-v3`
3. `rustadmin-quic-v2`
4. `rustadmin-quic-v1`

The selected ALPN is authenticated by the TLS 1.3 handshake and determines the
application channel layout before any channel is opened. Versions 2 through 4
retain the version 2 session offer range `2..=2` and capability
`CAP_RELIABLE_KEYFRAMES` (`0x0040`). Version 3 changes recovery semantics.
Version 4 adds `CAP_RELIABLE_KEYFRAME_BARRIER` (`0x0080`) and the reference
epoch described below.
A connection that negotiates version 1 uses the unchanged version 1 offer and
exactly five application streams. It never sends the new capability, channel,
or message type to the old peer.

Compatibility matrix:

| Client | Server | Selected layout |
| --- | --- | --- |
| v2 + v1 | v2 + v1 | v2, six reliable streams |
| v2 + v1 | v1 only | v1, five reliable streams |
| v1 only | v2 + v1 | v1, five reliable streams |
| v3 + v2 + v1 | v3 + v2 + v1 | v3, six reliable streams with scoped recovery |
| v3 + v2 + v1 | v2 + v1 | v2, six reliable streams |
| v3 + v2 + v1 | v1 only | v1, five reliable streams |
| v4 + v3 + v2 + v1 | v4 + v3 + v2 + v1 | v4, six streams with reliable-keyframe barrier |
| v4 + v3 + v2 + v1 | v3 + v2 + v1 | v3, six streams with scoped recovery |

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
incomplete startup keyframe a separate bounded fragment idle deadline. Before the
first complete keyframe, completed delta frames are discarded and cannot mark
the partial keyframe obsolete. Missing startup keyframes enter the shared,
bounded keyframe-recovery state. Pending frame count and memory remain bounded;
ordinary delta fragments use a 120 ms no-progress deadline. Every unique
fragment advances that deadline, so a large frame is not discarded while it is
still arriving over a bandwidth-constrained path. An independent hard lifetime
of 1 second for delta frames and 3 seconds for keyframes prevents an incomplete
frame from being retained indefinitely.

For a negotiated version 2 session, the reliable keyframe bypasses the
DATAGRAM reassembler, so that reassembler does not impose its version 1
keyframe gate on following delta frames. The application startup gate still
discards any delta delivered before the reliable keyframe reaches the normal
video pipeline and repeats a bounded refresh request. Version 1 retains the
DATAGRAM reassembler gate because its keyframes use DATAGRAM fragments.

Recovery keeps one outstanding request per receiving connection. It sends an
initial request, permits at most three retries after 1, 2, and 4 seconds, then
starts a 10-second recovery-cycle cooldown. A matching newer keyframe clears
the state immediately. Recovery state is never replayed across a new session.

## Scoped Reference Recovery

Version 3 replaces ordinary QUIC DATAGRAM-loss recovery with the reliable
`VideoReferenceRefresh` protobuf. The request carries the display, current
video stream ID, last accepted frame ID, and observed drop count. The host
validates the display and stream ID against its active delivery state, applies a
per-display cooldown, and asks only the selected encoder for a fresh reference.
It does not recreate the shared capture service or assign a new stream ID.

A v3 peer never sends the legacy global `RefreshVideo` request for DATAGRAM
loss. If it has no valid display, stream, and frame context, it waits for fresh
video metadata instead of escalating a loss into a capture restart. A matching
newer keyframe clears the pending scoped request; the host delivery watchdog
remains available as an independent bounded path. V1 and v2 retain their
legacy control message for compatibility, but use the same bounded client retry
schedule.

## Reliable-Keyframe Reference Barrier

Version 4 prevents a delta DATAGRAM from reaching the decoder before the
reliable keyframe that it references. The sender records the source frame ID of
each keyframe accepted by the reliable-video writer and stores that value as the
reference epoch on following delta-frame metadata. This use is limited to v4;
v1 through v3 retain the previous timestamp semantics.

The receiver delivers a reliable keyframe first, opens its reference epoch,
then releases only contiguous completed deltas for that epoch. Complete deltas
that arrive before their keyframe are held in a bounded buffer rather than
being treated as a new source gap. The buffer permits at most 120 frames and
16 MiB per connection, expires held data after two seconds without progress,
handles duplicates and out-of-order arrival, and requests a scoped refresh on
timeout or overflow. Media delivery from the reliable stream and DATAGRAM task
is serialized only for this short handoff; network reads and frame reassembly
remain independent.

This is a zero-round-trip barrier. The sender does not wait for a keyframe ACK,
so ordinary video latency does not acquire an RTT penalty. A v4 endpoint sends
the new capability only after v4 ALPN negotiation. Negotiating v3 or older
retains the former behavior and wire representation.

## Packet Sizing

QUIC starts at the standards-compliant 1200-byte UDP payload. Quinn path MTU
discovery remains enabled with a conservative default search ceiling of 1360
bytes to avoid repeatedly probing Ethernet-sized packets through lower-MTU VPN
routes. The negotiated application DATAGRAM ceiling is 1300 bytes in version 2,
but every send also clamps to Quinn's current live
`Connection::max_datagram_size()`. A smaller path therefore stays smaller, and
the sender can use a larger payload only after Quinn proves it safe. The
negotiated ceiling is not the size used for a send when the live maximum is
lower.

Quality Monitor reports the selected application version, reliable-keyframe
mode, live DATAGRAM maximum, negotiated ceiling, path MTU, lost packets,
reassembly drops, keyframe-request count, and v4 barrier held/released/timeout/
overflow counters.
