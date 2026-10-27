import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/resource_modes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resource mode presentation keeps the shared config values', () {
    expect(resourceModeChoices.map((choice) => choice.value), [
      kResourceModeNormal,
      kResourceModeLowPower,
      kResourceModeMinimizeGpu,
    ]);
    expect(normalizeResourceMode('unknown'), kResourceModeNormal);
    expect(normalizeResourceMode(' LOW-POWER '), kResourceModeLowPower);
    expect(resourceModeChoice(kResourceModeMinimizeGpu).label, 'Minimize GPU');
  });

  test('remote host visibility follows the peer platform addition', () {
    expect(
      supportsRemoteResourceMode({
        kSupportResourceModePlatformAddition: true,
      }),
      isTrue,
    );
    expect(
      supportsRemoteResourceMode({
        kSupportResourceModePlatformAddition: false,
      }),
      isFalse,
    );
    expect(supportsRemoteResourceMode(const {}), isFalse);
  });

  test('video stays active for recording and ignores window focus', () {
    expect(
      shouldKeepRemoteVideoVisible(
        activeTab: true,
        windowMinimized: false,
        recording: false,
      ),
      isTrue,
    );
    expect(
      shouldKeepRemoteVideoVisible(
        activeTab: false,
        windowMinimized: true,
        recording: true,
      ),
      isTrue,
    );
    expect(
      shouldKeepRemoteVideoVisible(
        activeTab: false,
        windowMinimized: false,
        recording: false,
      ),
      isFalse,
    );
  });

  test('visibility reporter serializes changes and unregisters once', () async {
    final writes = <bool?>[];
    final reporter = VideoVisibilityReporter((visible) async {
      writes.add(visible);
    });

    await reporter.update(true);
    await reporter.update(true);
    await reporter.update(false);
    await reporter.update(null);
    await reporter.update(null);

    expect(writes, [true, false, null]);
    reporter.reset();
    await reporter.update(true);
    expect(writes, [true, false, null, true]);
  });

  testWidgets('shared resource mode radio group presents all choices', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResourceModeRadioGroup(
            groupKey: 'viewer-resource-mode',
            value: kResourceModeLowPower,
            localize: (value) => value,
            onChanged: (value) => selected = value,
          ),
        ),
      ),
    );

    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Low power'), findsOneWidget);
    expect(find.text('Minimize GPU'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('viewer-resource-mode-minimize-gpu')),
    );
    expect(selected, kResourceModeMinimizeGpu);
  });
}
