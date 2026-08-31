import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes connection readiness with normalized booleans', () {
    final event = decodeTypedSessionEvent({
      'name': 'connection_ready',
      'secure': 'true',
      'direct': false,
      'stream_type': 'QUIC/UDP',
    });

    expect(event, isA<ConnectionReadySessionEvent>());
    final ready = event! as ConnectionReadySessionEvent;
    expect(ready.secure, isTrue);
    expect(ready.direct, isFalse);
    expect(ready.streamType, 'QUIC/UDP');
  });

  test('decodes a permission snapshot without dynamic values', () {
    final event = decodeTypedSessionEvent({
      'name': 'permission',
      'keyboard': 'true',
      'clipboard': false,
    });

    expect(event, isA<PermissionSessionEvent>());
    expect((event! as PermissionSessionEvent).permissions, {
      'keyboard': true,
      'clipboard': false,
    });
  });

  test(
    'rejects malformed known events but leaves unknown events to legacy',
    () {
      expect(
        decodeTypedSessionEvent({
          'name': 'connection_ready',
          'secure': 'sometimes',
          'direct': 'true',
        }),
        isA<InvalidSessionEvent>(),
      );
      expect(
        decodeTypedSessionEvent({'name': 'permission'}),
        isA<InvalidSessionEvent>(),
      );
      expect(decodeTypedSessionEvent({'name': 'peer_info'}), isNull);
    },
  );
}
