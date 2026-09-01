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

  test('decodes and round-trips a bounded peer info snapshot', () {
    final event =
        decodeTypedSessionEvent({
              'name': 'peer_info',
              'username': 'user',
              'hostname': 'host',
              'platform': 'Windows',
              'sas_enabled': 'true',
              'displays':
                  '[{"x":0,"y":0,"width":1920,"height":1080,"cursor_embedded":0}]',
              'version': '2.0.5',
              'features':
                  '{"privacy_mode":true,"keyboard_v2_physical_key":true}',
              'current_display': '0',
              'resolutions': '[{"width":1920,"height":1080}]',
              'platform_additions': '{"full_version":"2.0.5 rev 112"}',
            })!
            as PeerInfoSessionEvent;

    expect(event.sasEnabled, isTrue);
    expect(event.displays.single.width, 1920);
    expect(event.features.privacyMode, isTrue);
    expect(event.features.keyboardV2PhysicalKey, isTrue);
    expect(event.resolutions.single.height, 1080);
    expect(event.platformAdditions['full_version'], '2.0.5 rev 112');

    final cachedPayload = event.toLegacyPayload(includeResolutions: false);
    final cached = decodeTypedSessionEvent(
      Map<String, dynamic>.from(cachedPayload),
    );
    expect(cached, isA<PeerInfoSessionEvent>());
    expect((cached! as PeerInfoSessionEvent).resolutions, isEmpty);
  });

  test('decodes terminal responses into bounded typed payloads', () {
    final opened =
        decodeTypedSessionEvent({
              'name': 'terminal_response',
              'type': 'opened',
              'terminal_id': '7',
              'success': 'true',
              'message': 'ready',
              'service_id': 'service',
              'persistent_sessions': [1, '2'],
            })!
            as TerminalResponseSessionEvent;
    expect(opened.kind, TerminalResponseKind.opened);
    expect(opened.terminalId, 7);
    expect(opened.success, isTrue);
    expect(opened.persistentSessionIds, [1, 2]);

    final data =
        decodeTypedSessionEvent({
              'name': 'terminal_response',
              'type': 'data',
              'terminal_id': 7,
              'data': 'aGk=',
            })!
            as TerminalResponseSessionEvent;
    expect(data.kind, TerminalResponseKind.data);
    expect(data.data, [104, 105]);

    final closed =
        decodeTypedSessionEvent({
              'name': 'terminal_response',
              'type': 'closed',
              'terminal_id': 7,
              'exit_code': '-1',
            })!
            as TerminalResponseSessionEvent;
    expect(closed.exitCode, -1);
  });

  test('rejects malformed terminal responses', () {
    for (final event in [
      {'name': 'terminal_response', 'type': 'data', 'data': 'aGk='},
      {
        'name': 'terminal_response',
        'type': 'data',
        'terminal_id': 1,
        'data': [0, 256],
      },
      {'name': 'terminal_response', 'type': 'unknown', 'terminal_id': 1},
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
  });

  test('decodes display and platform synchronization payloads', () {
    final sync =
        decodeTypedSessionEvent({
              'name': 'sync_peer_info',
              'displays':
                  '[{"x":0,"y":0,"width":1920,"height":1080,"cursor_embedded":1,"scaled_width":1280}]',
            })!
            as SyncPeerInfoSessionEvent;
    final display = sync.displays!.single;
    expect(display.width, 1920);
    expect(display.cursorEmbedded, isTrue);
    expect(display.scaledWidth, 1280);

    final switched =
        decodeTypedSessionEvent({
              'name': 'switch_display',
              'display': '1',
              'x': '1920',
              'y': 0,
              'width': '2560',
              'height': 1440,
              'cursor_embedded': '1',
              'original_width': '2560',
              'original_height': 1440,
              'resolutions': '{"resolutions":[{"width":2560,"height":1440}]}',
            })!
            as SwitchDisplaySessionEvent;
    expect(switched.displayIndex, 1);
    expect(switched.display.x, 1920);
    expect(switched.display.cursorEmbedded, isTrue);
    expect(switched.resolutions.single.width, 2560);

    final additions =
        decodeTypedSessionEvent({
              'name': 'sync_platform_additions',
              'platform_additions': '{"is_wayland":true,"virtual":[1,2]}',
            })!
            as SyncPlatformAdditionsSessionEvent;
    expect(additions.updates['is_wayland'], isTrue);
    expect(additions.updates['virtual'], [1, 2]);
    expect(() => additions.updates['later'] = true, throwsUnsupportedError);
  });

  test('rejects malformed display and platform synchronization payloads', () {
    for (final event in [
      {'name': 'sync_peer_info', 'displays': '[{"width":"bad"}]'},
      {'name': 'switch_display', 'display': 'bad', 'resolutions': '[]'},
      {
        'name': 'switch_display',
        'display': '64',
        'width': '999999999',
        'resolutions': '[]',
      },
      {'name': 'sync_platform_additions', 'platform_additions': '[1,2]'},
      {'name': 'sync_platform_additions', 'platform_additions': '{"bad":null'},
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
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
      expect(
        decodeTypedSessionEvent({'name': 'peer_info'}),
        isA<InvalidSessionEvent>(),
      );
      expect(decodeTypedSessionEvent({'name': 'legacy_unknown'}), isNull);
    },
  );
}
