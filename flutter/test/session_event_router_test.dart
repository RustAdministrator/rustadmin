import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
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
}
