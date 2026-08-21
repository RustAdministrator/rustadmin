import 'package:flutter_hbb/common/peer_trust_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes resettable signing identity mismatch', () {
    expect(
      isResettablePeerTrustError(
        'Handshake failed: peer identity changed (expected old, got new)',
      ),
      isTrue,
    );
  });

  test('recognizes passphrase-gated stale paired trust', () {
    expect(
      isResettablePeerTrustError(
        'Handshake failed: trusted peer key changed or is invalid; '
        'rendezvous pairing passphrase is required to repair trust',
      ),
      isTrue,
    );
    expect(
      isResettablePeerTrustError(
        'Handshake failed: trusted peer key changed or is invalid; '
        'local or rendezvous pairing passphrase is required to repair trust',
      ),
      isTrue,
    );
  });

  test('recognizes resettable QUIC application identity mismatch', () {
    expect(
      isResettablePeerTrustError(
        'QUIC application authentication failed: '
        'server device identity key is not trusted',
      ),
      isTrue,
    );
  });

  test('recognizes resettable promoted QUIC identity mismatch', () {
    expect(
      isResettablePeerTrustError(
        'QUIC identity for peer 328606980 changed; '
        'explicit trust replacement is required',
      ),
      isTrue,
    );
  });

  test('does not offer trust reset for unrelated transport failures', () {
    expect(isResettablePeerTrustError('QUIC connection lost'), isFalse);
    expect(
      isResettablePeerTrustError(
        'QUIC application authentication failed: timeout',
      ),
      isFalse,
    );
  });

  test('does not offer trust reset for live-handshake identity conflicts', () {
    for (final text in [
      'Handshake failed: QUIC upgrade identity does not match the paired TCP identity',
      'Handshake failed: QUIC upgrade identity does not match the paired rendezvous identity',
      'Handshake failed: QUIC peer identity does not match rendezvous identity',
      'Handshake failed: bootstrap trusted peer identity mismatch '
          '(expected old, got new)',
      'Handshake failed: pairing passphrase rejected',
    ]) {
      expect(isResettablePeerTrustError(text), isFalse, reason: text);
    }
  });
}
