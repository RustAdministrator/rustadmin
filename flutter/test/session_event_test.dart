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

  test('decodes typed file job status events', () {
    final progress =
        decodeTypedSessionEvent({
              'name': 'job_progress',
              'id': '9',
              'file_num': '2',
              'speed': '1024.5',
              'finished_size': '4096',
            })!
            as FileJobProgressSessionEvent;
    expect(progress.id, 9);
    expect(progress.fileNum, 2);
    expect(progress.speed, 1024.5);
    expect(progress.finishedSize, 4096);

    final done =
        decodeTypedSessionEvent({'name': 'job_done', 'id': 9})!
            as FileJobDoneSessionEvent;
    expect(done.fileNum, 0);
    expect(done.speed, 0);

    final error =
        decodeTypedSessionEvent({
              'name': 'job_error',
              'id': '9',
              'file_num': '2',
              'err': 'denied',
            })!
            as FileJobErrorSessionEvent;
    expect(error.error, 'denied');

    final stats =
        decodeTypedSessionEvent({
              'name': 'update_folder_files',
              'info': '{"id":9,"num_entries":12,"total_size":1264822.0}',
            })!
            as FileFolderStatsSessionEvent;
    expect(stats.entryCount, 12);
    expect(stats.totalSize, 1264822);
  });

  test('rejects malformed file job status events', () {
    for (final event in [
      {
        'name': 'job_progress',
        'id': '9',
        'file_num': '2',
        'speed': 'NaN',
        'finished_size': '4096',
      },
      {'name': 'job_done', 'id': '-1'},
      {'name': 'job_error', 'id': '1', 'err': 7},
      {
        'name': 'update_folder_files',
        'info': '{"id":1,"num_entries":-1,"total_size":1}',
      },
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
  });

  test('decodes typed file directory and dialog payloads', () {
    final directory =
        decodeTypedSessionEvent({
              'name': 'file_dir',
              'is_local': 'false',
              'value':
                  '{"id":3,"path":"/tmp","entries":[{"entry_type":4,"modified_time":10,"name":"a.txt","size":12}]}',
            })!
            as FileDirectorySessionEvent;
    expect(directory.isLocal, isFalse);
    expect(directory.directory.id, 3);
    expect(directory.directory.entries.single.name, 'a.txt');

    final empty =
        decodeTypedSessionEvent({
              'name': 'empty_dirs',
              'is_local': false,
              'value':
                  '{"path":"/tmp","empty_dirs":[{"id":0,"path":"/tmp/a","entries":[]}]}',
            })!
            as EmptyDirectoriesSessionEvent;
    expect(empty.path, '/tmp');
    expect(empty.directories.single.path, '/tmp/a');

    final conflict =
        decodeTypedSessionEvent({
              'name': 'override_file_confirm',
              'id': '3',
              'file_num': '2',
              'read_path': '/tmp/a.txt',
              'is_upload': 'true',
              'is_identical': false,
            })!
            as FileOverrideConfirmSessionEvent;
    expect(conflict.isUpload, isTrue);
    expect(conflict.isIdentical, isFalse);

    final resume =
        decodeTypedSessionEvent({
              'name': 'load_last_job',
              'value':
                  '{"remote":"/remote","to":"/local","show_hidden":true,"file_num":4,"is_remote":true,"auto_start":true,"id":9}',
            })!
            as FileResumeJobSessionEvent;
    expect(resume.id, 9);
    expect(resume.autoStart, isTrue);
  });

  test('rejects malformed file directory and dialog payloads', () {
    for (final event in [
      {
        'name': 'file_dir',
        'is_local': 'false',
        'value':
            '{"id":0,"path":"/tmp","entries":[{"entry_type":4,"modified_time":0,"name":"a","size":-1}]}',
      },
      {
        'name': 'empty_dirs',
        'is_local': 'sometimes',
        'value': '{"path":"/tmp","empty_dirs":[]}',
      },
      {
        'name': 'override_file_confirm',
        'id': '3',
        'file_num': 'bad',
        'read_path': '/tmp/a',
        'is_upload': 'true',
        'is_identical': 'false',
      },
      {
        'name': 'load_last_job',
        'value':
            '{"remote":"/r","to":"/l","show_hidden":"yes","file_num":0,"is_remote":true}',
      },
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
  });

  test('decodes peripheral control and Web file events', () {
    final cancel =
        decodeTypedSessionEvent({'name': 'cancel_msgbox', 'tag': 'login'})!
            as SessionControlEvent;
    expect(cancel.kind, SessionControlKind.cancelMessageBox);
    expect(cancel.value, 'login');

    final service =
        decodeTypedSessionEvent({
              'name': 'portable_service_running',
              'running': 'true',
            })!
            as SessionControlEvent;
    expect(service.enabled, isTrue);

    final url =
        decodeTypedSessionEvent({
              'name': 'on_url_scheme_received',
              'url': 'rustdesk://connection/new/peer',
            })!
            as SessionControlEvent;
    expect(url.kind, SessionControlKind.urlSchemeReceived);

    final hash =
        decodeTypedSessionEvent({
              'name': 'sync_peer_hash_password_to_personal_ab',
              'id': 'peer',
              'hash': 'base64',
            })!
            as PeerHashSyncSessionEvent;
    expect(hash.id, 'peer');

    final option =
        decodeTypedSessionEvent({
              'name': 'sync_peer_option',
              'k': 'view-only',
              'v': true,
            })!
            as PeerOptionSyncSessionEvent;
    expect(option.kind, PeerOptionSyncKind.viewOnly);
    expect(option.viewOnly, isTrue);

    final selected =
        decodeTypedSessionEvent({
              'name': 'selected_files',
              'handleIndex': '2',
              'file':
                  '{"entry_type":4,"modified_time":10,"name":"a.txt","size":12}',
            })!
            as WebSelectedFileSessionEvent;
    expect(selected.handleIndex, 2);
    expect(selected.file.name, 'a.txt');

    final directories =
        decodeTypedSessionEvent({
              'name': 'send_emptry_dirs',
              'dirs': '["a","b"]',
            })!
            as WebEmptyDirectoriesSessionEvent;
    expect(directories.directories, ['a', 'b']);

    expect(
      decodeTypedSessionEvent({
        'name': 'printer_request',
        'id': 3,
        'path': '/tmp/print.pdf',
      }),
      isA<PrinterRequestSessionEvent>(),
    );
    expect(
      decodeTypedSessionEvent({'name': 'screenshot'}),
      isA<ScreenshotSessionEvent>(),
    );
  });

  test('rejects malformed peripheral control and Web file events', () {
    for (final event in [
      {'name': 'cancel_msgbox', 'tag': 1},
      {'name': 'portable_service_running', 'running': 'maybe'},
      {'name': 'sync_peer_option', 'k': 'view-only', 'v': 'maybe'},
      {
        'name': 'selected_files',
        'handleIndex': 'bad',
        'file': '{"entry_type":4,"modified_time":10,"name":"a","size":1}',
      },
      {'name': 'send_emptry_dirs', 'dirs': '[1]'},
      {'name': 'printer_request', 'id': 'bad', 'path': '/tmp/x'},
      {'name': 'screenshot', 'msg': 1},
    ]) {
      expect(decodeTypedSessionEvent(event), isA<InvalidSessionEvent>());
    }
  });

  test('decodes bounded message, toast, and Windows-session events', () {
    final trust =
        decodeTypedSessionEvent({
              'name': 'msgbox',
              'type': 'confirm-peer-trust',
              'title': 'Trust this device',
              'text':
                  '{"peer":"10.0.0.1","peer_id":"peer","fingerprint":"abc","trust_phrase":"one two","direct":true}',
              'link': '',
              'hasRetry': '',
            })!
            as MessageBoxSessionEvent;
    expect(trust.securityDetails?.peerId, 'peer');
    expect(trust.securityDetails?.direct, isTrue);
    expect(trust.hasRetry, isFalse);

    final malformedSecurity =
        decodeTypedSessionEvent({
              'name': 'msgbox',
              'type': 'input-pairing-passphrase',
              'title': 'Pairing',
              'text': '{bad-json',
              'link': '',
            })!
            as MessageBoxSessionEvent;
    expect(malformedSecurity.securityDetails, isNull);

    final plugin =
        decodeMessageBoxSessionEvent({
              'type': 'confirm-peer-trust',
              'title': 'Spoof',
              'text': trust.text,
              'link': '',
              'hasRetry': 'true',
            }, origin: MessageBoxOrigin.plugin)
            as MessageBoxSessionEvent;
    expect(plugin.origin, MessageBoxOrigin.plugin);
    expect(plugin.securityDetails, isNull);
    expect(plugin.hasRetry, isFalse);

    final toast =
        decodeTypedSessionEvent({
              'name': 'toast',
              'type': 'info',
              'text': 'ready',
              'dur_msec': '2500',
            })!
            as ToastSessionEvent;
    expect(toast.durationMs, 2500);

    final sessions =
        decodeTypedSessionEvent({
              'name': 'set_multiple_windows_session',
              'windows_sessions':
                  '[{"sid":"1","name":"Console"},{"sid":"2","name":"User"}]',
            })!
            as MultipleWindowsSessionsEvent;
    expect(sessions.sessions.map((value) => value.id), ['1', '2']);
  });

  test('rejects malformed message, toast, and Windows-session events', () {
    for (final event in [
      {'name': 'msgbox', 'type': 1, 'title': 'x', 'text': 'x'},
      {'name': 'toast', 'dur_msec': '-1'},
      {'name': 'set_multiple_windows_session', 'windows_sessions': '[]'},
      {
        'name': 'set_multiple_windows_session',
        'windows_sessions': '[{"sid":1,"name":"User"}]',
      },
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
