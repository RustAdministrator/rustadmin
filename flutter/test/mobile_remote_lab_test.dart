import 'package:flutter/material.dart';
import 'package:flutter_hbb/prototyping/mobile_remote_lab_page.dart';
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
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 393,
          height: 873,
          child: MobileRemotePreview(monitors: monitors, scenario: scenario),
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

  testWidgets('supports disconnect, reconnect, and toolbar visibility', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Session disconnected'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Reconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Session disconnected'), findsNothing);

    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show toolbar'), findsOneWidget);
  });

  testWidgets('exposes production options, chat, and more-action surfaces', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Display and session options'));
    await tester.pumpAndSettle();
    expect(find.text('Scale'), findsOneWidget);
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Image quality'), findsOneWidget);
    expect(find.text('Good image quality'), findsOneWidget);
    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Capture'), findsOneWidget);
    expect(find.text('Quality monitor'), findsOneWidget);
    expect(find.text('Clipboard'), findsOneWidget);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('Virtual display'), findsOneWidget);
    expect(find.text('Show remote cursor'), findsOneWidget);
    expect(find.text('Privacy mode'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('OS Password'), findsOneWidget);
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

  testWidgets('reopens inline custom image quality without a popup route', (
    tester,
  ) async {
    await pumpPreview(tester);

    await tester.tap(find.byTooltip('Display and session options'));
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
    expect(find.text('Volume up'), findsOneWidget);
    expect(find.text('Power'), findsOneWidget);
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

    final viewport = find.byKey(const Key('mobile-remote-device-viewport'));
    final viewportRect = tester.getRect(viewport);

    await tester.tap(find.byTooltip('More actions'));
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

  testWidgets(
    'switches simulated platform and exposes production keyboard keys',
    (tester) async {
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
      expect(find.text('Ctrl '), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      expect(find.text('Ctrl+C'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_left), findsOneWidget);

      await tester.tap(find.text(' Fn '));
      await tester.pumpAndSettle();
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
