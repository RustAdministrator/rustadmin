import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart' hide Display;
import 'package:flutter_hbb/mobile/pages/remote_page.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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
  late FFI ffi;
  late bool previousMobile;

  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(bridge);
  });
  setUp(() {
    previousMobile = isMobile;
    isMobile = true;
    ffi = FFI(null)..id = 'mobile-combined-test';
    ffi.ffiModel.pi
      ..isSupportMultiUiSession = true
      ..currentDisplay = kAllDisplayValue;
    ffi.ffiModel.pi.displays.value = [
      Display()
        ..x = -2
        ..y = 0
        ..width = 2
        ..height = 2,
      Display()
        ..x = 0
        ..y = 1
        ..width = 2
        ..height = 2,
    ];
  });
  tearDown(() {
    ffi.imageModel.clearImage();
    ffi.canvasModel.clear();
    ffi.inputModel.disposeRelativeMouseMode();
    isMobile = previousMobile;
  });

  ui.Image frame(int color) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(ui.Color(color), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(2, 2);
    picture.dispose();
    return image;
  }

  test(
    'production mobile monitor list includes All after numbered monitors',
    () {
      final peer = ffi.ffiModel.pi;
      int? selected;
      final monitors = mobileRemoteToolbarMonitors(
        peer: peer,
        showMonitors: true,
        currentDisplay: 0,
        onSelected: (display) => selected = display,
      );
      expect(monitors.map((monitor) => monitor.value), [
        0,
        1,
        kAllDisplayValue,
      ]);
      expect(monitors.last.allDisplays, isTrue);
      monitors.last.onPressed();
      expect(selected, kAllDisplayValue);
      expect(
        mobileRemoteToolbarMonitors(
          peer: peer,
          showMonitors: false,
          currentDisplay: 0,
          onSelected: (_) {},
        ),
        isEmpty,
      );
      peer.isSupportMultiUiSession = false;
      expect(
        mobileRemoteToolbarMonitors(
          peer: peer,
          showMonitors: true,
          currentDisplay: 0,
          onSelected: (_) {},
        ).map((monitor) => monitor.value),
        [0, 1],
      );
      peer.displays.removeLast();
      expect(
        mobileRemoteToolbarMonitors(
          peer: peer,
          showMonitors: true,
          currentDisplay: 0,
          onSelected: (_) {},
        ),
        isEmpty,
      );
    },
  );

  testWidgets('combined canvas retains and positions both display images', (
    tester,
  ) async {
    final first = frame(0xffff0000);
    final second = frame(0xff00ff00);
    await ffi.imageModel.update(first, display: 0);
    await ffi.imageModel.update(second, display: 1);
    expect(ffi.imageModel.imageForDisplay(0), same(first));
    expect(ffi.imageModel.imageForDisplay(1), same(second));
    expect(ffi.imageModel.renderFrameSize, const Size(4, 3));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ImageModel>.value(value: ffi.imageModel),
          ChangeNotifierProvider<CanvasModel>.value(value: ffi.canvasModel),
          ChangeNotifierProvider<FfiModel>.value(value: ffi.ffiModel),
        ],
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ImagePaint(),
        ),
      ),
    );
    final a = tester.getRect(
      find.byKey(const ValueKey('mobile-combined-display-0')),
    );
    final b = tester.getRect(
      find.byKey(const ValueKey('mobile-combined-display-1')),
    );
    expect(b.left - a.left, closeTo(2 * ffi.canvasModel.scale, 0.000001));
    expect(b.top - a.top, closeTo(ffi.canvasModel.scale, 0.000001));
    ffi.revokeScreenContent();
    expect(ffi.imageModel.imageForDisplay(0), isNull);
    expect(ffi.imageModel.imageForDisplay(1), isNull);
    expect(ffi.imageModel.hasRenderableFrame, isFalse);
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(first.debugDisposed, isTrue);
    expect(second.debugDisposed, isTrue);
  });

  testWidgets(
    'new frames replace only their own monitor and teardown releases all',
    (tester) async {
      final first = frame(0xffff0000);
      final second = frame(0xff00ff00);
      final replacement = frame(0xff0000ff);
      await ffi.imageModel.update(first, display: 0);
      await ffi.imageModel.update(second, display: 1);
      await ffi.imageModel.update(replacement, display: 0);
      await tester.pump();
      expect(first.debugDisposed, isTrue);
      expect(second.debugDisposed, isFalse);
      expect(ffi.imageModel.imageForDisplay(0), same(replacement));
      ffi.ffiModel.pi.currentDisplay = 1;
      ffi.imageModel.synchronizeDisplayFrames();
      await tester.pump();
      expect(second.debugDisposed, isTrue);
      expect(replacement.debugDisposed, isTrue);
      expect(ffi.imageModel.imageForDisplay(0), isNull);
      expect(ffi.imageModel.imageForDisplay(1), isNull);
    },
  );

  test('real RGBA decoding retains each display independently', () async {
    await ffi.imageModel.decodeAndUpdate(
      0,
      Uint8List.fromList(List.filled(16, 255)),
    );
    await ffi.imageModel.decodeAndUpdate(
      1,
      Uint8List.fromList(List.filled(16, 128)),
    );
    expect(ffi.imageModel.imageForDisplay(0), isNotNull);
    expect(ffi.imageModel.imageForDisplay(1), isNotNull);
    final retained = ffi.imageModel.imageForDisplay(1);
    await ffi.imageModel.decodeAndUpdate(0, Uint8List(0));
    expect(ffi.imageModel.imageForDisplay(0), isNotNull);
    expect(ffi.imageModel.imageForDisplay(1), same(retained));
  });

  test('selection change during decode rejects the stale display', () async {
    final decoding = ffi.imageModel.decodeAndUpdate(0, Uint8List(16));
    ffi.ffiModel.pi.currentDisplay = 1;
    ffi.imageModel.synchronizeDisplayFrames();
    await decoding;
    expect(ffi.imageModel.imageForDisplay(0), isNull);
    expect(ffi.imageModel.image, isNull);
  });

  testWidgets(
    'topology invalidates changed images but retains unchanged monitors',
    (tester) async {
      final first = frame(0xffff0000);
      final second = frame(0xff00ff00);
      await ffi.imageModel.update(first, display: 0);
      await ffi.imageModel.update(second, display: 1);
      ffi.ffiModel.pi.displays[0].width = 3;
      ffi.imageModel.synchronizeDisplayFrames();
      await tester.pump();
      expect(ffi.imageModel.imageForDisplay(0), isNull);
      expect(first.debugDisposed, isTrue);
      expect(ffi.imageModel.imageForDisplay(1), same(second));
    },
  );
}
