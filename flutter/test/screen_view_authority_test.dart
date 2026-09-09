import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart' hide Display;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/screen_view_authority.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements Rustadmin {
  Completer<String?>? viewStyle;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #translate:
        return invocation.namedArguments[#name] as String;
      case #mainGetUserDefaultOption:
      case #mainGetLocalOption:
      case #getLocalFlutterOption:
      case #mainSupportedInputSource:
      case #mainGetDisplays:
        return '';
      case #isDisableAb:
      case #isDisableAccount:
      case #isDisableGroupPanel:
      case #mainCurrentIsWayland:
      case #mainHasFileClipboard:
      case #sessionGetToggleOptionSync:
        return false;
      case #sessionGetViewStyle:
        return viewStyle?.future ?? Future<String?>.value(null);
      case #sessionGetScrollStyle:
      case #sessionGetOption:
        return Future<String?>.value(null);
      case #sessionGetEdgeScrollEdgeThickness:
        return Future<int?>.value(null);
      case #mainSetOption:
      case #mainSetLocalOption:
      case #setLocalFlutterOption:
      case #mainInitInputSource:
      case #sessionSendMouse:
        return Future<void>.value();
      case #versionToNumber:
        return 0;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = _Bridge();

  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(bridge);
  });

  test('revocation and reconnect reject queued work from old authority', () {
    final authority = ScreenViewAuthority();
    authority.apply(connectionGeneration: 1, generation: 2, allowed: true);
    final oldEpoch = authority.epoch;
    authority.apply(connectionGeneration: 1, generation: 3, allowed: false);
    expect(authority.accepts(oldEpoch), isFalse);
    authority.apply(connectionGeneration: 2, generation: 5, allowed: true);
    expect(authority.accepts(oldEpoch), isFalse);
    expect(
      authority.apply(connectionGeneration: 1, generation: 4, allowed: false),
      isFalse,
    );
    final currentEpoch = authority.epoch;
    expect(
      authority.apply(connectionGeneration: 2, generation: 5, allowed: true),
      isFalse,
    );
    expect(authority.accepts(currentEpoch), isTrue);
  });

  test('authority event validates generation and boolean types', () {
    expect(
      decodeTypedSessionEvent({
        'name': 'screen_view_authority',
        'connection_generation': 1,
        'generation': 3,
        'allowed': false,
      }),
      isA<ScreenViewAuthoritySessionEvent>(),
    );
    for (final invalid in [null, -1, '3', 1.5]) {
      expect(
        decodeTypedSessionEvent({
          'name': 'screen_view_authority',
          'connection_generation': 1,
          'generation': invalid,
          'allowed': false,
        }),
        isA<InvalidSessionEvent>(),
      );
    }
  });

  test('screen revocation immediately hides every desktop texture binding', () {
    final ffi = FFI(null)..id = 'screen-authority-test';
    CurrentDisplayState.init(ffi.id);
    CurrentDisplayState.find(ffi.id).value = 1;
    addTearDown(() => CurrentDisplayState.delete(ffi.id));
    ffi.textureModel.setRgbaTextureId(display: 0, id: 10);
    ffi.textureModel.setGpuTextureId(display: 1, id: 20);
    ffi.textureModel.setTextureType(display: 1, gpuTexture: true);
    final first = ffi.textureModel.getTextureId(0);
    final second = ffi.textureModel.getTextureId(1);
    expect(first.value, 10);
    expect(second.value, 20);

    ffi.applyScreenViewAuthority(
      const ScreenViewAuthoritySessionEvent(
        connectionGeneration: 1,
        generation: 3,
        allowed: false,
      ),
    );
    expect(first.value, -1);
    expect(second.value, -1);
    ffi.textureModel.setRgbaTextureId(display: 0, id: 30);
    expect(first.value, -1);
  });

  test(
    'a decode started before revocation cannot restore cached pixels',
    () async {
      final ffi = FFI(null)..id = 'screen-authority-test';
      ffi.ffiModel.pi.displays.add(
        Display()
          ..width = 1
          ..height = 1,
      );
      final decode = ffi.imageModel.decodeAndUpdate(
        0,
        Uint8List.fromList([255, 0, 0, 255]),
      );
      ffi.revokeScreenContent();
      await decode;
      expect(ffi.imageModel.image, isNull);
      expect(ffi.imageModel.hasRenderableFrame, isFalse);
    },
  );

  test('revocation clears a published image before cleanup awaits', () async {
    final ffi = FFI(null)..id = 'screen-authority-test';
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(1, 1);
    picture.dispose();
    await ffi.imageModel.update(image);
    expect(ffi.imageModel.image, same(image));
    KeyboardEnabledState.init(ffi.id);
    addTearDown(() => KeyboardEnabledState.delete(ffi.id));
    final epoch = ffi.screenViewAuthority.epoch;
    ffi.ffiModel.updatePermissionValues({'keyboard': false}, ffi.id);
    expect(ffi.screenViewAuthority.epoch, epoch);
    expect(ffi.imageModel.image, same(image));
    ffi.revokeScreenContent();
    expect(ffi.imageModel.image, isNull);
  });

  test(
    'revocation during canvas setup rejects the pending image after regrant',
    () async {
      final ffi = FFI(null)..id = 'screen-authority-test';
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1);
      picture.dispose();
      bridge.viewStyle = Completer<String?>();
      final update = ffi.imageModel.update(image);
      ffi.revokeScreenContent();
      ffi.screenViewAuthority.apply(
        connectionGeneration: 2,
        generation: 5,
        allowed: true,
      );
      bridge.viewStyle!.complete(null);
      bridge.viewStyle = null;
      await update;
      expect(ffi.imageModel.image, isNull);
      expect(image.debugDisposed, isTrue);
    },
  );
}
