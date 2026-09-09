import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/widgets/mobile_app_version.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _VersionBridge implements Rustadmin {
  int versionCalls = 0;
  Future<String>? fullVersion;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #mainGetVersion:
        versionCalls++;
        return fullVersion ?? Future.value('2.0.5 rev 145');
      case #translate:
        return invocation.namedArguments[#name] as String;
      case #mainGetLocalOption:
      case #mainGetUserDefaultOption:
      case #getLocalFlutterOption:
        return '';
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final bridge = _VersionBridge();

  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(bridge);
  });

  setUp(() {
    bridge.versionCalls = 0;
    bridge.fullVersion = null;
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform About displays the embedded revision', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: const Scaffold(body: MobileAppVersion()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Version: 2.0.5 rev 145'), findsOneWidget);
      expect(bridge.versionCalls, 1);
    });
  }

  testWidgets('parent rebuilds do not re-request the native version', (
    tester,
  ) async {
    final pending = Completer<String>();
    bridge.fullVersion = pending.future;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(body: MobileAppVersion());
          },
        ),
      ),
    );
    expect(find.text('Version: $version'), findsOneWidget);
    rebuild(() {});
    await tester.pump();
    expect(bridge.versionCalls, 1);
    pending.complete('2.0.5 rev 144');
    await tester.pumpAndSettle();
    expect(find.text('Version: 2.0.5 rev 144'), findsOneWidget);
    rebuild(() {});
    await tester.pump();
    expect(bridge.versionCalls, 1);
  });

  testWidgets(
    'missing native version falls back without inventing a revision',
    (tester) async {
      bridge.fullVersion = Future.value('');
      await tester.pumpWidget(const MaterialApp(home: MobileAppVersion()));
      await tester.pumpAndSettle();
      expect(find.text('Version: $version'), findsOneWidget);
    },
  );

  testWidgets('native version failure keeps About usable', (tester) async {
    final pending = Completer<String>();
    bridge.fullVersion = pending.future;
    await tester.pumpWidget(const MaterialApp(home: MobileAppVersion()));
    pending.completeError(StateError('native version unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Version: $version'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
