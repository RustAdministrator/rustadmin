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

  test('decodes compact text, status, and control events', () {
    final clipboard =
        decodeTypedSessionEvent({'name': 'clipboard', 'content': 'text'})!
            as ClipboardSessionEvent;
    final clientChat =
        decodeTypedSessionEvent({'name': 'chat_client_mode', 'text': 'client'})!
            as ClientChatSessionEvent;
    final serverChat =
        decodeTypedSessionEvent({
              'name': 'chat_server_mode',
              'id': '7',
              'text': 'server',
            })!
            as ServerChatSessionEvent;
    final elevation =
        decodeTypedSessionEvent({'name': 'show_elevation', 'show': true})!
            as ShowElevationSessionEvent;
    final voice =
        decodeTypedSessionEvent({
              'name': 'on_voice_call_closed',
              'reason': 'done',
            })!
            as VoiceCallClosedSessionEvent;
    final fingerprint =
        decodeTypedSessionEvent({'name': 'fingerprint', 'fingerprint': 'abc'})!
            as FingerprintSessionEvent;
    final record =
        decodeTypedSessionEvent({'name': 'record_status', 'start': 'true'})!
            as RecordStatusSessionEvent;

    expect(clipboard.content, 'text');
    expect(clientChat.text, 'client');
    expect(serverChat.id, 7);
    expect(serverChat.text, 'server');
    expect(elevation.show, isTrue);
    expect(voice.reason, 'done');
    expect(fingerprint.fingerprint, 'abc');
    expect(record.start, isTrue);
    expect(
      (decodeTypedSessionEvent({'name': 'on_voice_call_waiting'})!
              as SessionSignalEvent)
          .signal,
      SessionSignal.voiceCallWaiting,
    );
    expect(
      (decodeTypedSessionEvent({'name': 'on_voice_call_started'})!
              as SessionSignalEvent)
          .signal,
      SessionSignal.voiceCallStarted,
    );
    expect(
      (decodeTypedSessionEvent({'name': 'on_voice_call_incoming'})!
              as SessionSignalEvent)
          .signal,
      SessionSignal.voiceCallIncoming,
    );
    expect(
      (decodeTypedSessionEvent({'name': 'exit_relative_mouse_mode'})!
              as SessionSignalEvent)
          .signal,
      SessionSignal.exitRelativeMouseMode,
    );
  });

  test('rejects malformed compact typed events', () {
    for (final event in [
      {'name': 'clipboard'},
      {'name': 'chat_client_mode', 'text': 1},
      {'name': 'chat_server_mode', 'id': 'bad', 'text': 'x'},
      {'name': 'fingerprint', 'fingerprint': 1},
      {'name': 'record_status', 'start': 'sometimes'},
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
  });

  test('preserves tolerant legacy elevation and voice coercion', () {
    final elevation =
        decodeTypedSessionEvent({
              'name': 'show_elevation',
              'show': 'sometimes',
            })!
            as ShowElevationSessionEvent;
    final voice =
        decodeTypedSessionEvent({'name': 'on_voice_call_closed'})!
            as VoiceCallClosedSessionEvent;

    expect(elevation.show, isFalse);
    expect(voice.reason, 'null');
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
