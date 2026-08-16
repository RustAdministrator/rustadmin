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
}
