import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/mobile_viewport.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements Rustadmin {
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
        return false;
      case #mainSetOption:
      case #mainSetLocalOption:
      case #setLocalFlutterOption:
      case #mainInitInputSource:
      case #sessionSendMouse:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool previousIsMobile;
  late FFI ffi;

  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_Bridge());
  });

  setUp(() {
    previousIsMobile = isMobile;
    isMobile = true;
    ffi = FFI(null)..id = 'mobile-fit-viewport-test';
  });

  tearDown(() {
    ffi.canvasModel.clear();
    ffi.inputModel.disposeRelativeMouseMode();
    isMobile = previousIsMobile;
  });

  void keyboard(WidgetTester tester, {required bool visible}) {
    tester.view.viewInsets = FakeViewPadding(bottom: visible ? 300 : 0);
    final bar = visible
        ? Rect.fromLTWH(0, tester.view.physicalSize.height - 360, 393, 60)
        : null;
    ffi.cursorModel.keyHelpToolsVisibilityChanged(bar, bar, visible);
  }

  for (final screen in [const Size(393, 873), const Size(873, 393)]) {
    for (final mode in MobileRemoteViewScaleMode.values) {
      testWidgets(
        '${mode.label} ignores keyboard insets after reconnect on $screen',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = screen;
          tester.view.viewPadding = const FakeViewPadding(top: 24);
          tester.view.padding = const FakeViewPadding(top: 24);
          addTearDown(tester.view.reset);
          final canvas = ffi.canvasModel;
          canvas.applyMobileViewScaleMode(mode);
          final fullSize = canvas.size;
          final originalScale = canvas.scale;

          keyboard(tester, visible: true);
          // The background-timeout cleanup clears the canvas, but UIKit/IME
          // metrics can still include the keyboard when the new session fits.
          canvas.clear();
          canvas.requestMobileViewFit(mode: mode);
          await canvas.updateViewStyle();
          expect(canvas.size.height, lessThan(fullSize.height));
          expect(canvas.getSize(includeKeyboardArea: true), fullSize);
          expect(canvas.scale, closeTo(originalScale, 0.000001));

          // Explicit mode selection while typing must use the same full size.
          canvas.applyMobileViewScaleMode(mode);
          expect(canvas.scale, closeTo(originalScale, 0.000001));
          keyboard(tester, visible: false);
          await tester.pump(const Duration(milliseconds: 200));
          expect(canvas.size, fullSize);
          expect(canvas.scale, closeTo(originalScale, 0.000001));
        },
      );
    }
  }

  testWidgets(
    'default reconnect fit and minimum zoom ignore the key-help bar',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(873, 393);
      addTearDown(tester.view.reset);
      final canvas = ffi.canvasModel;
      await canvas.updateViewStyle();
      final defaultScale = canvas.scale;
      canvas.applyMobileViewScaleMode(MobileRemoteViewScaleMode.fitAll);
      final minimumScale = canvas.scale;

      // Cover a stale custom-key bar before the native inset becomes nonzero.
      const bar = Rect.fromLTWH(0, 150, 873, 60);
      ffi.cursorModel.keyHelpToolsVisibilityChanged(bar, bar, true);
      canvas.clear();
      await canvas.updateViewStyle();
      expect(canvas.mobileViewScaleMode, MobileRemoteViewScaleMode.fitHeight);
      expect(canvas.scale, closeTo(defaultScale, 0.000001));
      canvas.update(0, 0, 0.00001);
      await canvas.updateViewStyle();
      expect(canvas.scale, closeTo(minimumScale, 0.000001));
      expect(canvas.size.height, lessThan(200));
    },
  );
}
