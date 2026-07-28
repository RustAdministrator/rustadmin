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
    expect(find.text('Scale original'), findsOneWidget);
    expect(find.text('Good image quality'), findsOneWidget);
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
}
