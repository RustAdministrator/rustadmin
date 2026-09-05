import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_hbb/mobile/mobile_viewport.dart';
import 'package:flutter_hbb/prototyping/mobile_remote_lab_page.dart';
import 'package:flutter_hbb/prototyping/mobile_remote_lab_revision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final monitors = [
    const RemoteLabMonitor(
      name: 'Monitor 1',
      imagePath: '',
      pixelSize: Size(2560, 1440),
      origin: Offset.zero,
    ),
    const RemoteLabMonitor(
      name: 'Monitor 2',
      imagePath: '',
      pixelSize: Size(2560, 1440),
      origin: Offset(2560, 0),
    ),
    const RemoteLabMonitor(
      name: 'Monitor 3',
      imagePath: '',
      pixelSize: Size(2560, 1440),
      origin: Offset(5120, 0),
    ),
  ];

  Future<void> pumpPreview(
    WidgetTester tester, {
    RemoteLabScenario scenario = RemoteLabScenario.windowsFullAccess,
    Size size = const Size(393, 873),
    ThemeData? theme,
    TargetPlatform platform = TargetPlatform.android,
  }) {
    final previewTheme = (theme ?? mobileRemoteLabTheme(Brightness.light))
        .copyWith(platform: platform);
    final preview = SizedBox(
      width: size.width,
      height: size.height,
      child: MobileRemotePreview(monitors: monitors, scenario: scenario),
    );
    return tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: Theme(data: previewTheme, child: preview),
        ),
      ),
    );
  }

  Future<void> pumpLab(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: mobileRemoteLabTheme(Brightness.light),
        home: MobileRemoteLabPage(
          initialScreensDirectory: '',
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          initialMonitors: monitors,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> moveTwoFingers(
    WidgetTester tester,
    Finder target,
    Offset delta,
  ) async {
    final center = tester.getCenter(target);
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 41,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 42,
    );
    final step = delta / 4;
    for (var i = 0; i < 4; i++) {
      await first.moveBy(step);
      await second.moveBy(step);
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }

  Future<void> pinchOut(
    WidgetTester tester,
    Finder target, {
    required int firstPointer,
  }) async {
    final center = tester.getCenter(target);
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: firstPointer,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: firstPointer + 1,
    );
    for (var i = 0; i < 4; i++) {
      await first.moveBy(const Offset(-10, 0));
      await second.moveBy(const Offset(10, 0));
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }

  test('reports the composed RustAdmin release version', () {
    expect(mobileRemoteLabVersion, '2.0.5.011');
    expect(mobileRemoteLabRevisionLabel, '2.0.5.011 · Lab r23');
  });

  test('calculates native-texture fit, zoom, and no-overscan bounds', () {
    const texture = Size(2560, 1440);
    const viewport = Size(393, 873);
    const devicePixelRatio = 3.0;

    expect(
      mobileRemoteLabScaleForMode(
        mode: MobileRemoteLabViewScaleMode.fitAll,
        texture: texture,
        viewport: viewport,
        devicePixelRatio: devicePixelRatio,
      ),
      closeTo(393 / 2560, 0.000001),
    );
    expect(
      mobileRemoteLabScaleForMode(
        mode: MobileRemoteLabViewScaleMode.fitWidth,
        texture: texture,
        viewport: viewport,
        devicePixelRatio: devicePixelRatio,
      ),
      closeTo(393 / 2560, 0.000001),
    );
    expect(
      mobileRemoteLabScaleForMode(
        mode: MobileRemoteLabViewScaleMode.fitHeight,
        texture: texture,
        viewport: viewport,
        devicePixelRatio: devicePixelRatio,
      ),
      closeTo(873 / 1440, 0.000001),
    );
    expect(
      mobileRemoteLabScaleForMode(
        mode: MobileRemoteLabViewScaleMode.oneToOne,
        texture: texture,
        viewport: viewport,
        devicePixelRatio: devicePixelRatio,
      ),
      closeTo(1 / devicePixelRatio, 0.000001),
    );

    final minimum = mobileRemoteLabMinimumCanvasScale(
      texture: texture,
      viewport: viewport,
    );
    expect(minimum, closeTo(393 / 2560, 0.000001));
    expect(
      mobileRemoteLabTextureFilterQuality(logicalScale: 0.2),
      FilterQuality.low,
    );
    expect(
      mobileRemoteLabTextureFilterQuality(logicalScale: 1 / devicePixelRatio),
      FilterQuality.low,
    );
    expect(
      mobileRemoteLabTextureFilterQuality(logicalScale: 1),
      FilterQuality.none,
    );

    const fitHeight = 873 / 1440;
    final leftCorner = mobileRemoteLabClampCanvasOffset(
      proposed: const Offset(99999, 99999),
      texture: texture,
      viewport: viewport,
      scale: fitHeight,
    );
    final rightCorner = mobileRemoteLabClampCanvasOffset(
      proposed: const Offset(-99999, -99999),
      texture: texture,
      viewport: viewport,
      scale: fitHeight,
    );
    expect(leftCorner.dx, closeTo(0, 0.000001));
    expect(leftCorner.dy, closeTo(0, 0.000001));
    expect(
      rightCorner.dx,
      closeTo(viewport.width - texture.width * fitHeight, 0.000001),
    );
    expect(rightCorner.dy, closeTo(0, 0.000001));
  });

  test('calculates four-direction Lab edge scrolling from device edges', () {
    const viewport = Size(393, 873);
    const elapsed = Duration(milliseconds: 100);
    expect(
      mobileRemoteLabEdgeScrollDelta(
        pointerPosition: const Offset(0, 0),
        viewport: viewport,
        edgeThickness: 100,
        elapsed: elapsed,
        accelerated: false,
      ),
      const Offset(-60, -60),
    );
    expect(
      mobileRemoteLabEdgeScrollDelta(
        pointerPosition: const Offset(393, 873),
        viewport: viewport,
        edgeThickness: 100,
        elapsed: elapsed,
        accelerated: true,
      ),
      const Offset(180, 180),
    );
    expect(
      mobileRemoteLabEdgeScrollDelta(
        pointerPosition: const Offset(196.5, 436.5),
        viewport: viewport,
        edgeThickness: 100,
        elapsed: elapsed,
        accelerated: true,
      ),
      Offset.zero,
    );
    expect(
      mobileRemoteLabEdgeScrollDelta(
        pointerPosition: Offset(
          mobileRemoteNeutralCursorRect(
            viewport: viewport,
            edgeThickness: 100,
          ).right,
          viewport.height / 2,
        ),
        viewport: viewport,
        edgeThickness: 100,
        elapsed: elapsed,
        accelerated: false,
      ),
      const Offset(60, 0),
    );
    expect(
      mobileRemoteLabEdgeScrollDelta(
        pointerPosition: const Offset(326.3333333333, 436.5),
        viewport: viewport,
        edgeThickness: 100,
        elapsed: elapsed,
        accelerated: true,
      ).dx,
      closeTo(90, 0.000001),
    );
  });

  testWidgets('switches between individual and combined monitor views', (
    tester,
  ) async {
    await pumpPreview(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'Monitor 1',
    );

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'All'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'All monitors',
    );

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, '3'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'Monitor 3',
    );
  });

  testWidgets(
    'applies Fit Height by default and changes the texture transform',
    (tester) async {
      await pumpPreview(tester);
      await tester.pumpAndSettle();

      final canvas = tester.getRect(
        find.byKey(const Key('mobile-lab-remote-canvas')),
      );
      final texture = find.byKey(const Key('mobile-lab-remote-texture'));
      var textureRect = tester.getRect(texture);
      expect(textureRect.height, closeTo(canvas.height, 0.01));

      await tester.tap(find.byTooltip('Display and session options'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('mobile-remote-options-open-view-style')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fit All'));
      await tester.pumpAndSettle();
      textureRect = tester.getRect(texture);
      expect(textureRect.width, closeTo(canvas.width, 0.01));
      expect(textureRect.height, lessThan(canvas.height));

      await tester.tap(find.text('1:1'));
      await tester.pumpAndSettle();
      textureRect = tester.getRect(texture);
      expect(textureRect.width, closeTo(2560, 0.01));
      expect(textureRect.height, closeTo(1440, 0.01));
    },
  );

  testWidgets('edge modes preserve zoom and scroll only available axes', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
    final texture = find.byKey(const Key('mobile-lab-remote-texture'));
    final canvasRect = tester.getRect(canvas);
    final initialTextureRect = tester.getRect(texture);
    expect(initialTextureRect.height, closeTo(canvasRect.height, 0.01));

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-screen-scrolling')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();

    final edgeTextureRect = tester.getRect(texture);
    expect(edgeTextureRect, initialTextureRect);
    expect(edgeTextureRect.height, closeTo(canvasRect.height, 0.01));

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    final beforeScroll = tester.getRect(texture);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: canvasRect.center);
    await mouse.moveTo(Offset(canvasRect.right - 1, canvasRect.bottom - 1));
    await tester.pump(const Duration(milliseconds: 100));
    final afterScroll = tester.getRect(texture);
    expect(afterScroll.left, lessThan(beforeScroll.left));
    expect(afterScroll.top, closeTo(beforeScroll.top, 0.01));
    await mouse.removePointer();

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-screen-scrolling')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(tester.getRect(texture).height, closeTo(canvasRect.height, 0.01));
  });

  testWidgets('pinch zoom works in Edge and Edge acceleration modes', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
    final texture = find.byKey(const Key('mobile-lab-remote-texture'));

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-screen-scrolling')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    final beforeEdgePinch = tester.getRect(texture);
    await pinchOut(tester, canvas, firstPointer: 51);
    final afterEdgePinch = tester.getRect(texture);
    expect(afterEdgePinch.width, greaterThan(beforeEdgePinch.width));

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-screen-scrolling')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edge acceleration'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    final beforeAccelerationPinch = tester.getRect(texture);
    await pinchOut(tester, canvas, firstPointer: 61);
    expect(
      tester.getRect(texture).width,
      greaterThan(beforeAccelerationPinch.width),
    );
  });

  testWidgets('clamps two-finger viewport panning at remote screen edges', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
    final canvasRect = tester.getRect(canvas);
    final texture = find.byKey(const Key('mobile-lab-remote-texture'));

    await moveTwoFingers(tester, canvas, const Offset(10000, 0));
    var textureRect = tester.getRect(texture);
    expect(textureRect.left, closeTo(canvasRect.left, 0.01));

    await moveTwoFingers(tester, canvas, const Offset(-10000, 0));
    textureRect = tester.getRect(texture);
    expect(textureRect.right, closeTo(canvasRect.right, 0.01));
  });

  testWidgets('two-finger vertical motion increments remote wheel counter', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final counter = find.byKey(const Key('mobile-lab-remote-wheel-counter'));
    expect(
      tester
          .widget<Text>(
            find.descendant(of: counter, matching: find.byType(Text)),
          )
          .data,
      'Remote wheel: 0',
    );

    await moveTwoFingers(
      tester,
      find.byKey(const Key('mobile-lab-remote-canvas')),
      const Offset(0, 80),
    );

    expect(
      tester
          .widget<Text>(
            find.descendant(of: counter, matching: find.byType(Text)),
          )
          .data,
      isNot('Remote wheel: 0'),
    );
  });

  testWidgets('zooms the remote canvas with a mouse wheel', (tester) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
    final canvasRect = tester.getRect(canvas);
    final texture = find.byKey(const Key('mobile-lab-remote-texture'));
    final initialRect = tester.getRect(texture);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(tester.getCenter(canvas)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
    await tester.pumpAndSettle();
    final zoomedInRect = tester.getRect(texture);
    expect(zoomedInRect.width, greaterThan(initialRect.width));
    expect(zoomedInRect.height, greaterThan(initialRect.height));

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 20)));
    await tester.pumpAndSettle();
    final restoredRect = tester.getRect(texture);
    expect(restoredRect.width, closeTo(initialRect.width, 0.01));
    expect(restoredRect.height, closeTo(initialRect.height, 0.01));

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'All'));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(canvas)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 1000000)));
    await tester.pumpAndSettle();
    final combinedAtMinimum = tester.getRect(texture);
    expect(combinedAtMinimum.width, closeTo(canvasRect.width, 0.01));
    expect(combinedAtMinimum.height, lessThan(canvasRect.height));
  });

  testWidgets('keeps a manual canvas transform after its parent rebuilds', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pumpAndSettle();

    final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
    final canvasRect = tester.getRect(canvas);
    final texture = find.byKey(const Key('mobile-lab-remote-texture'));

    await moveTwoFingers(tester, canvas, const Offset(10000, 0));
    expect(tester.getRect(texture).left, closeTo(canvasRect.left, 0.01));

    // A parent rebuild is not a new connection and must not re-apply Fit
    // Height over the user's transform.
    await pumpPreview(tester);
    await tester.pumpAndSettle();
    expect(tester.getRect(texture).left, closeTo(canvasRect.left, 0.01));
  });

  testWidgets('supports disconnect, reconnect, and toolbar collapse', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Session disconnected'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Reconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Session disconnected'), findsNothing);

    await tester.tap(find.byTooltip('Collapse toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show toolbar'), findsOneWidget);

    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Disconnect'), findsOneWidget);
  });

  testWidgets('floating toolbar stays within horizontal and vertical bounds', (
    tester,
  ) async {
    await pumpPreview(tester);

    final preview = find.byType(MobileRemotePreview);
    final horizontalToolbar = find.byKey(
      const Key('mobile-remote-floating-toolbar'),
    );
    final previewRect = tester.getRect(preview);
    final horizontalRect = tester.getRect(horizontalToolbar);
    expect(find.byType(BottomAppBar), findsNothing);
    expect(find.text('H'), findsOneWidget);
    expect(horizontalRect.width <= previewRect.width, isTrue);
    expect(horizontalRect.height <= previewRect.height, isTrue);

    await tester.tap(find.byTooltip('Vertical toolbar'));
    await tester.pumpAndSettle();

    final verticalRect = tester.getRect(horizontalToolbar);
    expect(find.byTooltip('Horizontal toolbar'), findsOneWidget);
    expect(find.text('V'), findsOneWidget);
    expect(verticalRect.width <= previewRect.width, isTrue);
    expect(verticalRect.height <= previewRect.height, isTrue);
    expect(verticalRect.height > verticalRect.width, isTrue);
  });

  testWidgets('floating toolbar uses theme-aware black and white surfaces', (
    tester,
  ) async {
    final toolbar = find.byKey(const Key('mobile-remote-floating-toolbar'));

    await pumpPreview(tester, theme: mobileRemoteLabTheme(Brightness.light));
    expect(tester.widget<Material>(toolbar).color, Colors.white);

    await pumpPreview(tester, theme: mobileRemoteLabTheme(Brightness.dark));
    expect(tester.widget<Material>(toolbar).color, Colors.black);
  });

  testWidgets('vertical toolbar fits a compact landscape phone', (
    tester,
  ) async {
    await pumpPreview(tester, size: const Size(800, 360));

    final preview = find.byType(MobileRemotePreview);
    final toolbar = find.byKey(const Key('mobile-remote-floating-toolbar'));
    final previewRect = tester.getRect(preview);
    expect(tester.getRect(toolbar).width <= previewRect.width, isTrue);

    await tester.tap(find.byTooltip('Vertical toolbar'));
    await tester.pumpAndSettle();

    final verticalRect = tester.getRect(toolbar);
    expect(verticalRect.width <= previewRect.width, isTrue);
    expect(verticalRect.height <= previewRect.height, isTrue);
  });

  testWidgets(
    'floating toolbar can be dragged and remains immediately opaque',
    (tester) async {
      await pumpPreview(tester);

      final toolbar = find.byKey(const Key('mobile-remote-floating-toolbar'));
      final preview = find.byType(MobileRemotePreview);
      await tester.tap(find.byTooltip('Vertical toolbar'));
      await tester.pumpAndSettle();

      final initialRect = tester.getRect(toolbar);
      await tester.drag(toolbar, const Offset(100, -180));
      await tester.pumpAndSettle();

      final movedRect = tester.getRect(toolbar);
      final previewRect = tester.getRect(preview);
      expect(movedRect.left, greaterThan(initialRect.left));
      expect(movedRect.top, lessThan(initialRect.top));
      expect(movedRect.left, greaterThanOrEqualTo(previewRect.left));
      expect(movedRect.top, greaterThanOrEqualTo(previewRect.top));
      expect(movedRect.right, lessThanOrEqualTo(previewRect.right));
      expect(movedRect.bottom, lessThanOrEqualTo(previewRect.bottom));

      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('mobile-remote-toolbar-opacity')),
            )
            .opacity,
        1.0,
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('mobile-remote-toolbar-opacity')),
            )
            .duration,
        Duration.zero,
      );

      await tester.tap(find.byTooltip('Display and session options'));
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('mobile-remote-toolbar-opacity')),
            )
            .opacity,
        1.0,
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('mobile-remote-toolbar-opacity')),
            )
            .duration,
        Duration.zero,
      );
    },
  );

  testWidgets('keyboard controls stay in one horizontally scrollable row', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fn'));
    await tester.pumpAndSettle();

    final keyHelpTools = find.byKey(const Key('mobile-remote-key-help-tools'));
    final scrollable = find.descendant(
      of: keyHelpTools,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    expect(
      tester.widget<Scrollable>(scrollable).axisDirection,
      AxisDirection.right,
    );
    expect(
      find.descendant(of: keyHelpTools, matching: find.byType(Wrap)),
      findsNothing,
    );

    final scrollableState = tester.state<ScrollableState>(scrollable);
    expect(scrollableState.position.pixels, 0);
    expect(find.text('F12'), findsOneWidget);
  });

  testWidgets(
    'keyboard hides toolbar and makes custom-key top the canvas edge',
    (tester) async {
      await pumpPreview(tester);
      await tester.pumpAndSettle();

      final canvas = find.byKey(const Key('mobile-lab-remote-canvas'));
      final texture = find.byKey(const Key('mobile-lab-remote-texture'));
      final fullCanvasRect = tester.getRect(canvas);
      await tester.tap(find.byTooltip('Vertical toolbar'));
      await tester.pumpAndSettle();
      final toolbar = find.byKey(
        const Key('mobile-remote-floating-toolbar'),
      );
      await tester.drag(toolbar, const Offset(-40, -80));
      await tester.pumpAndSettle();
      final toolbarPosition = tester.getTopLeft(toolbar);

      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('mobile-remote-floating-toolbar')),
        findsNothing,
      );
      final keyboardCanvasRect = tester.getRect(canvas);
      final customKeysRect = tester.getRect(
        find.byKey(const Key('mobile-remote-key-help-tools')),
      );
      expect(keyboardCanvasRect.bottom, closeTo(customKeysRect.top, 0.01));
      expect(keyboardCanvasRect.height, lessThan(fullCanvasRect.height));

      await moveTwoFingers(tester, canvas, const Offset(-10000, -10000));
      expect(
        tester.getRect(texture).bottom,
        closeTo(keyboardCanvasRect.bottom, 0.01),
      );

      await tester.tap(find.byTooltip('Hide keyboard'));
      await tester.pumpAndSettle();

      final restoredCanvasRect = tester.getRect(canvas);
      expect(restoredCanvasRect.height, closeTo(fullCanvasRect.height, 0.01));
      expect(
        tester.getRect(texture).bottom,
        closeTo(restoredCanvasRect.bottom, 0.01),
      );
      expect(
        find.byKey(const Key('mobile-remote-floating-toolbar')),
        findsOneWidget,
      );
      expect(find.text('V'), findsOneWidget);
      final restoredToolbarPosition = tester.getTopLeft(toolbar);
      expect(
        restoredToolbarPosition.dx,
        closeTo(toolbarPosition.dx, 0.01),
      );
      expect(
        restoredToolbarPosition.dy,
        closeTo(toolbarPosition.dy, 0.01),
      );
    },
  );

  testWidgets('uses mobile drill-down menus for Lab option and action groups', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    final panelRect = tester.getRect(
      find.byKey(const Key('mobile-lab-bottom-panel')),
    );
    final previewRect = tester.getRect(find.byType(MobileRemotePreview));
    expect(panelRect.height / previewRect.height, closeTo(0.90, 0.01));
    expect(find.byKey(const Key('mobile-remote-options-root')), findsOneWidget);
    expect(find.text('View scale'), findsOneWidget);
    expect(find.text('Screen scrolling'), findsOneWidget);
    expect(find.text('Toolbar opacity under cursor'), findsOneWidget);
    expect(find.text('Cursor inertia time'), findsNothing);
    expect(find.text('Image quality'), findsOneWidget);
    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Capture'), findsOneWidget);
    expect(find.text('Quality monitor'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('Virtual display'), findsOneWidget);
    expect(find.text('Session controls'), findsNothing);
    expect(find.text('Show remote cursor'), findsOneWidget);
    expect(find.text('Privacy mode'), findsOneWidget);
    final showMonitors = find.text('Show monitors in toolbar');
    expect(showMonitors, findsOneWidget);

    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-view-style')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-remote-options-submenu-view-style')),
      findsOneWidget,
    );
    expect(find.text('Fit All'), findsOneWidget);
    expect(find.text('Fit Width'), findsOneWidget);
    expect(find.text('Fit Height'), findsOneWidget);
    expect(find.text('1:1'), findsOneWidget);
    expect(find.text('Scale custom'), findsNothing);
    await tester.tap(find.text('Fit All'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-remote-options-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-remote-options-root')), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-screen-scrolling')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cursor inertia time'), findsOneWidget);
    final inertiaSlider = tester.widget<Slider>(
      find.byKey(const Key('mobile-cursor-inertia-slider')),
    );
    expect(inertiaSlider.min, 100);
    expect(inertiaSlider.max, 1000);
    await tester.tap(find.text('Edge'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-lab-edge-thickness')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-remote-options-back')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-quality-monitor')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Quality monitor details'), findsOneWidget);
    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Extended'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-remote-options-back')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(showMonitors);
    await tester.tap(showMonitors);
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-remote-monitor-0')),
      findsOneWidget,
    );
    final firstMonitorLabel = tester.widget<Text>(
      find.byKey(const ValueKey('mobile-remote-monitor-label-0')),
    );
    expect(firstMonitorLabel.data, '1');
    expect(
      find.byKey(const ValueKey('mobile-remote-monitor--1')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-lab-actions-root')), findsOneWidget);
    final keyboardY = tester
        .getTopLeft(find.byKey(const Key('mobile-lab-actions-open-keyboard')))
        .dy;
    final customizeY = tester
        .getTopLeft(
          find.byKey(const Key('mobile-lab-actions-open-custom-buttons')),
        )
        .dy;
    final firstSessionActionY = tester
        .getTopLeft(
          find.byKey(const Key('mobile-lab-session-action-Request Elevation')),
        )
        .dy;
    expect(keyboardY, lessThan(customizeY));
    expect(customizeY, lessThan(firstSessionActionY));
    await tester.tap(find.byKey(const Key('mobile-lab-actions-open-keyboard')));
    await tester.pumpAndSettle();
    expect(find.text('Legacy mode'), findsOneWidget);
    expect(find.text('Map mode'), findsOneWidget);
    expect(find.text('Translate mode beta'), findsOneWidget);
    expect(find.text('Reverse mouse wheel'), findsOneWidget);
    expect(find.text('Trackpad speed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-lab-actions-back')));
    await tester.pumpAndSettle();
    expect(find.text('Session actions'), findsNothing);
    expect(find.text('OS Password'), findsOneWidget);
    expect(find.text('Locate cursor'), findsOneWidget);
    expect(find.text('Reset canvas'), findsOneWidget);
    expect(find.text('Restart remote device'), findsOneWidget);
    expect(find.text('Start session recording'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Text chat'), findsOneWidget);
    expect(find.text('Voice call'), findsOneWidget);
  });

  testWidgets('matches production-style option availability by Lab scenario', (
    tester,
  ) async {
    await pumpPreview(tester, scenario: RemoteLabScenario.androidPeer);

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    expect(find.text('View scale'), findsOneWidget);
    expect(find.text('Image quality'), findsOneWidget);
    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Quality monitor'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Capture'), findsNothing);
    expect(find.text('Resolution'), findsNothing);
    expect(find.text('Virtual display'), findsNothing);

    await pumpPreview(tester, scenario: RemoteLabScenario.viewOnly);
    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    expect(find.text('Session controls'), findsNothing);
    expect(find.text('View Mode'), findsOneWidget);
    expect(find.text('Show remote cursor'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Session actions'), findsNothing);
    expect(find.text('OS Password'), findsNothing);
    expect(find.text('Send clipboard keystrokes'), findsNothing);
    expect(find.text('Block user input'), findsNothing);
    expect(find.text('Locate cursor'), findsOneWidget);
    expect(find.text('Reset canvas'), findsOneWidget);
    expect(find.text('Copy Fingerprint'), findsOneWidget);
  });

  testWidgets('matches the native mobile chat entry point by client platform', (
    tester,
  ) async {
    await pumpPreview(tester, platform: TargetPlatform.iOS);

    await tester.tap(find.byTooltip('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Text chat'), findsOneWidget);
    expect(find.text('Voice call'), findsNothing);
    expect(find.byKey(const Key('mobile-lab-bottom-panel')), findsOneWidget);
  });

  testWidgets('uses square quick buttons with even strip padding', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pumpAndSettle();

    final strip = tester.getRect(
      find.byKey(const Key('mobile-remote-key-help-tools')),
    );
    final systemKeyboard = tester.getRect(
      find.byKey(const Key('mobile-lab-system-keyboard')),
    );
    expect(strip.bottom, closeTo(systemKeyboard.top, 0.01));
    final stripSurface = tester.widget<Container>(
      find.byKey(const Key('mobile-remote-key-help-strip')),
    );
    expect(stripSurface.color, const Color(0x80FFFFFF));
    final ctrl = tester.getRect(
      find.byKey(const Key('mobile-remote-quick-ctrl')),
    );
    final alt = tester.getRect(
      find.byKey(const Key('mobile-remote-quick-alt')),
    );
    expect(ctrl.width, closeTo(39.6, 0.01));
    expect(ctrl.height, closeTo(39.6, 0.01));
    expect(ctrl.top - strip.top, closeTo(6, 0.01));
    expect(strip.bottom - ctrl.bottom, closeTo(6, 0.01));
    expect(alt.left - ctrl.right, closeTo(4, 0.01));
    expect(find.byIcon(Icons.push_pin), findsNothing);

    final ctrlButton = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const Key('mobile-remote-quick-ctrl')),
        matching: find.byType(Material),
      ),
    );
    final quickButtonContext = tester.element(
      find.byKey(const Key('mobile-remote-quick-ctrl')),
    );
    expect(
      ctrlButton.color,
      mobileRemoteQuickKeyButtonBackgroundColor(quickButtonContext),
    );
    expect(
      (ctrlButton.color!.a * 255).round(),
      0xFF,
    );

    await tester.tap(find.byKey(const Key('mobile-remote-quick-ctrl')));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    final activeCtrlButton = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const Key('mobile-remote-quick-ctrl')),
        matching: find.byType(Material),
      ),
    );
    expect(
      activeCtrlButton.color,
      mobileRemoteToolbarActiveBackgroundColor(quickButtonContext),
    );
    expect(
      activeCtrlButton.color,
      isNot(mobileRemoteAccentActiveColor),
    );

    await pumpPreview(tester, theme: mobileRemoteLabTheme(Brightness.dark));
    await tester.pumpAndSettle();
    final darkStripSurface = tester.widget<Container>(
      find.byKey(const Key('mobile-remote-key-help-strip')),
    );
    expect(darkStripSurface.color, const Color(0x80000000));
  });

  testWidgets('provides the full-screen custom-button reorder placeholder', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('mobile-lab-actions-open-custom-buttons')),
    );
    await tester.tap(
      find.byKey(const Key('mobile-lab-actions-open-custom-buttons')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Customize keyboard buttons'), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-lab-custom-buttons-list')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey(MobileRemoteQuickKey.ctrl)), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-lab-custom-buttons-reset')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('mobile-lab-custom-buttons-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-lab-actions-root')), findsOneWidget);
  });

  testWidgets('reopens inline custom image quality without a popup route', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('mobile-remote-options-open-image-quality')),
    );
    await tester.pumpAndSettle();

    final custom = find.text('Custom');
    await tester.ensureVisible(custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-custom-image-quality-preview')),
      findsOneWidget,
    );
    expect(find.text('FPS mode'), findsOneWidget);
    expect(find.byType(SegmentedButton<String>), findsOneWidget);

    final balanced = find.text('Balanced');
    await tester.ensureVisible(balanced);
    await tester.tap(balanced);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-custom-image-quality-preview')),
      findsNothing,
    );

    await tester.ensureVisible(custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-custom-image-quality-preview')),
      findsOneWidget,
    );
  });

  testWidgets('exposes Android peer controls and action menus', (tester) async {
    await pumpPreview(tester, scenario: RemoteLabScenario.androidPeer);

    expect(find.byTooltip('Android actions'), findsOneWidget);
    await tester.tap(find.byTooltip('Android actions'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Recent apps'), findsOneWidget);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Android device actions'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-lab-actions-open-keyboard')));
    await tester.pumpAndSettle();
    expect(find.text('Legacy mode'), findsOneWidget);
    expect(find.text('Map mode'), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-lab-actions-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mobile-lab-actions-open-android')));
    await tester.pumpAndSettle();
    expect(find.text('Volume up'), findsOneWidget);
    expect(find.text('Power'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-lab-actions-back')));
    await tester.pumpAndSettle();
    expect(find.text('Session actions'), findsNothing);
    expect(find.text('Copy Fingerprint'), findsOneWidget);
  });

  testWidgets('models view-only and connection states', (tester) async {
    await pumpPreview(tester, scenario: RemoteLabScenario.viewOnly);
    expect(find.byTooltip('Keyboard'), findsNothing);
    expect(find.byTooltip('Touch mode'), findsNothing);

    await pumpPreview(tester, scenario: RemoteLabScenario.connecting);
    await tester.pump();
    expect(find.text('Connecting to remote device…'), findsOneWidget);
    expect(find.byTooltip('Disconnect'), findsNothing);

    await pumpPreview(tester, scenario: RemoteLabScenario.disconnected);
    await tester.pump();
    expect(find.text('Session disconnected'), findsOneWidget);
    expect(find.byTooltip('Disconnect'), findsNothing);
  });

  testWidgets('contains phone popup routes and avoids control overflow', (
    tester,
  ) async {
    await pumpLab(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.text('Mobile Remote Lab · $mobileRemoteLabRevisionLabel'),
      findsOneWidget,
    );

    final viewport = find.byKey(const Key('mobile-remote-device-viewport'));
    final viewportRect = tester.getRect(viewport);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('OS Password'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: viewport, matching: find.text('OS Password')),
      findsOneWidget,
    );
    final menuTextRect = tester.getRect(find.text('OS Password'));
    expect(viewportRect.contains(menuTextRect.topLeft), isTrue);
    expect(viewportRect.contains(menuTextRect.bottomRight), isTrue);

    await tester.tapAt(viewportRect.topLeft + const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Chat'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: viewport, matching: find.text('Text chat')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: viewport, matching: find.text('Voice call')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('switches simulated platform and exposes Lab keyboard keys', (
    tester,
  ) async {
    await pumpLab(tester);

    var previewContext = tester.element(find.byType(MobileRemotePreview));
    expect(Theme.of(previewContext).platform, TargetPlatform.android);
    expect(MediaQuery.viewPaddingOf(previewContext).top, 32);

    await tester.tap(find.text('Redmi Note class · Android'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('iPhone 15 class · iOS'));
    await tester.pumpAndSettle();

    previewContext = tester.element(find.byType(MobileRemotePreview));
    expect(Theme.of(previewContext).platform, TargetPlatform.iOS);
    expect(MediaQuery.viewPaddingOf(previewContext).top, 59);

    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-remote-key-help-tools')),
      findsOneWidget,
    );
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_left), findsOneWidget);

    await tester.tap(find.text('Fn'));
    await tester.pumpAndSettle();
    expect(find.text('F1'), findsOneWidget);
    expect(find.text('F12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
