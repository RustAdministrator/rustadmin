import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/clipboard_diagnostics.dart';
import 'package:flutter_hbb/common/widgets/clipboard_diagnostics_panel.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var reads = 0;
  final writes = <String>[];

  setUp(() {
    reads = 0;
    writes.clear();
    ClipboardDiagnostics.instance.stopListener();
    ClipboardDiagnostics.instance.setDeviceIdentity('panel-test-device');
    ClipboardDiagnostics.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {
              'text': 'personal clipboard text must not appear in reports',
            };
          }
          if (call.method == 'Clipboard.setData') {
            writes.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    ClipboardDiagnostics.instance.stopListener();
    ClipboardDiagnostics.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> openPanel(WidgetTester tester, {String? session}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClipboardDiagnosticsPanel(
            controller: ClipboardDiagnostics.instance,
            sessionLabel: session,
          ),
        ),
      ),
    );
  }

  testWidgets('opening settings does not read or modify the clipboard', (
    tester,
  ) async {
    await openPanel(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 0);
    expect(writes, isEmpty);
    expect(
      find.byKey(const ValueKey('clipboard-listener-toggle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('clipboard-run-both-directions')),
      findsNothing,
    );
  });

  testWidgets('listener is opt-in and its report omits personal contents', (
    tester,
  ) async {
    await openPanel(tester);
    await tester.tap(find.byKey(const ValueKey('clipboard-listener-toggle')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(ClipboardDiagnostics.instance.listening, isTrue);
    expect(reads, greaterThan(0));
    expect(writes, isEmpty);
    expect(
      ClipboardDiagnostics.instance.exportReport(),
      isNot(contains('personal clipboard text')),
    );
    await tester.tap(find.byKey(const ValueKey('clipboard-listener-toggle')));
    await tester.pump();
    final stoppedReads = reads;
    await tester.pump(const Duration(seconds: 2));
    expect(reads, stoppedReads);
  });

  testWidgets(
    'narrow connection panel exposes both-direction action and coverage',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openPanel(tester, session: 'test-peer');
      final action = find.byKey(
        const ValueKey('clipboard-run-both-directions'),
      );
      await tester.scrollUntilVisible(
        action,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(action, findsOneWidget);
      expect(find.textContaining('clipboard on BOTH devices'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.textContaining('Coverage: plain text'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Not tested: native URL formats'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(reads, 0);
      expect(writes, isEmpty);
    },
  );

  testWidgets('mobile toolbar exposes the optional Debug action', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileRemoteToolbar(
            onDisconnect: () {},
            onOptions: () {},
            onMore: () {},
            onQualityMonitor: () {},
            onDebug: () => opened++,
            showInputControls: false,
            peerIsAndroid: false,
            touchMode: false,
            waitForFirstImage: false,
            qualityMonitorVisible: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Debug'));
    expect(opened, 1);
    expect(reads, 0);
    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
