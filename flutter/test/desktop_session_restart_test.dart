import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements Rustadmin {
  final calls = <String>[];
  final streams = <StreamController<EventToUI>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #sessionAddSync) {
      calls.add('add');
      return '';
    }
    if (name == #sessionStart) {
      calls.add('listen');
      final stream = StreamController<EventToUI>();
      streams.add(stream);
      return stream.stream;
    }
    if (name == #sessionClose) {
      calls.add('close');
      if (streams.isNotEmpty && !streams.last.isClosed) {
        streams.last.add(const EventToUI_Event('close'));
      }
      return Future<void>.value();
    }
    if (name == #getNextTextureKey || name == #getNextRenderTargetToken) {
      return 1;
    }
    if (name == #translate) return invocation.namedArguments[#name] as String;
    if (name == #mainGetLocalOption ||
        name == #mainGetUserDefaultOption ||
        name == #getLocalFlutterOption ||
        name == #mainSupportedInputSource ||
        name == #mainGetInputSource ||
        name == #mainGetDisplays ||
        name == #sessionGetAuditServerSync ||
        name == #sessionGetUseAllMyDisplaysForTheRemoteSession) {
      return '';
    }
    if (name == #isDisableAb ||
        name == #isDisableAccount ||
        name == #isDisableGroupPanel ||
        name == #mainCurrentIsWayland ||
        name == #mainHasFileClipboard ||
        name == #mainHasGpuTextureRender ||
        name == #mainGetUseTextureRender ||
        name == #sessionGetToggleOptionSync) {
      return false;
    }
    if (name == #isSupportMultiUiSession ||
        name == #sessionIsKeyboardModeSupported) {
      return true;
    }
    if (name == #sessionGetViewStyle ||
        name == #sessionGetScrollStyle ||
        name == #sessionGetOption ||
        name == #sessionGetKeyboardMode) {
      return Future<String?>.value(null);
    }
    if (name == #sessionGetTrackpadSpeed) return Future<int?>.value(null);
    if (name == #sessionSendMouse ||
        name == #sessionSetKeyboardMode ||
        name == #sessionSetSize ||
        name == #mainLoadRecentPeers) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const peerId = 'desktop-restart-peer';
  late _Bridge bridge;
  late FFI ffi;
  Completer<void>? textureCloseGate;

  setUp(() {
    isTest = true;
    bridge = _Bridge();
    textureCloseGate = null;
    platformFFI.initForTest(bridge);
    initSharedStates(peerId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('texture_rgba_renderer'),
          (call) async {
            if (call.method == 'createTexture') return -1;
            if (call.method == 'closeTexture') await textureCloseGate?.future;
            return null;
          },
        );
    ffi = FFI(null);
  });

  tearDown(() async {
    if (textureCloseGate?.isCompleted == false) textureCloseGate!.complete();
    await ffi.close(saveCanvasConfig: false);
    for (final stream in bridge.streams) {
      unawaited(stream.close());
    }
    removeSharedStates(peerId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('texture_rgba_renderer'),
          null,
        );
  });

  test(
    'fresh restart waits for revoked texture retirement before native close',
    () async {
      await ffi.start(peerId);
      await Future<void>.delayed(Duration.zero);
      textureCloseGate = Completer<void>();
      var resetDone = false;
      final reset = ffi.resetSessionForReconnect(closeSession: true).then((_) {
        resetDone = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(resetDone, isFalse);
      expect(bridge.calls, isNot(contains('close')));
      textureCloseGate!.complete();
      await reset;
      expect(bridge.calls, contains('close'));
    },
  );

  test(
    'fresh desktop restart retires the handle before adding and listening again',
    () async {
      var firstImageCallbacks = 0;
      ffi.imageModel.addCallbackOnFirstImage((_) => firstImageCallbacks++);
      await ffi.start(peerId);
      expect(bridge.calls, ['add', 'listen']);

      // The old wake path closed Rust alone. That cannot replace a single-use
      // Flutter handle, even once the native close event has been delivered.
      await bind.sessionClose(sessionId: ffi.sessionId);
      await expectLater(ffi.start(peerId), throwsStateError);
      expect(bridge.calls.where((call) => call == 'add'), hasLength(1));

      await ffi.resetSessionForReconnect(closeSession: true);
      expect(ffi.closed, isTrue);
      expect(ffi.ffiModel.waitForFirstImage.value, isTrue);
      await ffi.start(peerId);
      expect(ffi.closed, isFalse);
      expect(bridge.calls.where((call) => call == 'add'), hasLength(2));
      expect(bridge.calls.where((call) => call == 'listen'), hasLength(2));
      expect(ffi.imageModel.callbacksOnFirstImage, hasLength(1));
      ffi.imageModel.callbacksOnFirstImage.single(peerId);
      expect(firstImageCallbacks, 1);
    },
  );
}
