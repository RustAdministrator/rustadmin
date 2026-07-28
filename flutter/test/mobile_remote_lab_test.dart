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

  testWidgets('switches between individual and combined monitor views', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 393,
          height: 873,
          child: MobileRemotePreview(monitors: monitors),
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'Monitor 1',
    );

    await tester.tap(find.byTooltip('Displays'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'All monitors'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'All monitors',
    );

    await tester.tap(find.byTooltip('Displays'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Monitor 3'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('selected-monitor-label'))).data,
      'Monitor 3',
    );
  });

  testWidgets('supports disconnect, reconnect, and toolbar visibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 393,
          height: 873,
          child: MobileRemotePreview(monitors: monitors),
        ),
      ),
    );

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
}
