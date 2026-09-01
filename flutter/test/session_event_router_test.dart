import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

class _RouterRustadminImpl implements Rustadmin {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    if (invocation.memberName == #mainGetLocalOption ||
        invocation.memberName == #mainGetUserDefaultOption ||
        invocation.memberName == #getLocalFlutterOption ||
        invocation.memberName == #mainSupportedInputSource ||
        invocation.memberName == #mainGetDisplays) {
      return '';
    }
    if (invocation.memberName == #isDisableAb ||
        invocation.memberName == #isDisableAccount ||
        invocation.memberName == #isDisableGroupPanel ||
        invocation.memberName == #mainCurrentIsWayland ||
        invocation.memberName == #mainHasFileClipboard ||
        invocation.memberName == #sessionGetToggleOptionSync) {
      return false;
    }
    if (invocation.memberName == #sessionSendMouse) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FFI ffi;
  const peerId = 'typed-event-router-peer';

  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_RouterRustadminImpl());
  });

  setUp(() {
    initSharedStates(peerId);
    ffi = FFI(null)..id = peerId;
  });

  tearDown(() {
    ffi.inputModel.disposeRelativeMouseMode();
    removeSharedStates(peerId);
  });

  test(
    'routes typed model events and rejects malformed known events',
    () async {
      final listener = ffi.ffiModel.startEventListener(ffi.sessionId, peerId);

      await listener({'name': 'show_elevation', 'show': 'true'});
      await listener({'name': 'fingerprint', 'fingerprint': 'trusted'});
      await listener({'name': 'on_voice_call_waiting'});

      expect(ffi.serverModel.showElevation, isTrue);
      expect(FingerprintState.find(peerId).value, 'trusted');
      expect(
        ffi.chatModel.voiceCallStatus.value,
        VoiceCallStatus.waitingForResponse,
      );

      await listener({'name': 'on_voice_call_started'});
      expect(ffi.chatModel.voiceCallStatus.value, VoiceCallStatus.connected);
      ffi.chatModel.isConnManager = true;
      await listener({'name': 'on_voice_call_incoming'});
      expect(ffi.chatModel.voiceCallStatus.value, VoiceCallStatus.incoming);

      await listener({'name': 'show_elevation', 'show': 'invalid'});
      await listener({'name': 'fingerprint', 'fingerprint': 7});

      expect(ffi.serverModel.showElevation, isFalse);
      expect(FingerprintState.find(peerId).value, 'trusted');
    },
  );

  test('cursor events validate payloads before model routing', () async {
    final listener = ffi.ffiModel.startEventListener(ffi.sessionId, peerId);

    await listener({'name': 'cursor_id', 'id': 17});
    await listener({'name': 'cursor_position', 'x': '12.5', 'y': -4});

    expect(ffi.ffiModel.cachedPeerData.lastCursorId, {'id': '17'});
    expect(ffi.cursorModel.x, 12.5);
    expect(ffi.cursorModel.y, -4);

    await listener({'name': 'cursor_position', 'x': 'nan', 'y': '1'});
    expect(ffi.cursorModel.x, 12.5);
    expect(ffi.cursorModel.y, -4);
  });

  test('cursor shape decoder enforces dimensions and byte payload', () {
    final valid = decodeTypedSessionEvent({
      'name': 'cursor_data',
      'id': 'cursor-1',
      'hotx': '0',
      'hoty': 1,
      'width': '1',
      'height': 1,
      'colors': '[0, 127, 255, 255]',
    });

    expect(valid, isA<CursorShapeSessionEvent>());
    expect((valid as CursorShapeSessionEvent).colors, [0, 127, 255, 255]);
    expect(
      decodeTypedSessionEvent({
        'name': 'cursor_data',
        'id': 'cursor-1',
        'hotx': 0,
        'hoty': 0,
        'width': 1,
        'height': 1,
        'colors': '[0, 1, 2]',
      }),
      isA<InvalidSessionEvent>(),
    );
    expect(
      decodeTypedSessionEvent({
        'name': 'cursor_data',
        'id': 'cursor-1',
        'hotx': 0,
        'hoty': 0,
        'width': 4096,
        'height': 4096,
        'colors': '[]',
      }),
      isA<InvalidSessionEvent>(),
    );
  });

  test('privacy and render signals reject dynamic payload types', () async {
    final listener = ffi.ffiModel.startEventListener(ffi.sessionId, peerId);

    await listener({'name': 'update_block_input_state', 'input_state': 'on'});
    await listener({'name': 'update_privacy_mode'});

    expect(BlockInputState.find(peerId).value, isTrue);
    expect(PrivacyModeState.find(peerId).value, isEmpty);

    await listener({'name': 'update_block_input_state', 'input_state': 1});
    expect(BlockInputState.find(peerId).value, isTrue);

    final texture = decodeTypedSessionEvent({
      'name': 'use_texture_render',
      'v': 'Y',
    });
    expect(texture, isA<TextureRenderSessionEvent>());
    expect((texture as TextureRenderSessionEvent).enabled, isTrue);
    expect(
      decodeTypedSessionEvent({'name': 'use_texture_render', 'v': true}),
      isA<InvalidSessionEvent>(),
    );

    final follow = decodeTypedSessionEvent({
      'name': 'follow_current_display',
      'display_idx': '2',
    });
    expect(follow, isA<FollowCurrentDisplaySessionEvent>());
    expect((follow as FollowCurrentDisplaySessionEvent).displayIndex, 2);
  });
}
