import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class _TestRustadminImpl implements Rustadmin {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  setUpAll(() {
    isTest = true;
    platformFFI.initForTest(_TestRustadminImpl());
  });

  testWidgets('quality monitor grip switches details from its context menu',
      (tester) async {
    String? selected;
    DragUpdateDetails? dragUpdate;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: QualityMonitorGrip(
            details: kQualityMonitorDetailsBasic,
            onPanUpdate: (details) => dragUpdate = details,
            onDetailsChanged: (details) async => selected = details,
          ),
        ),
      ),
    ));

    final grip = find.byType(QualityMonitorGrip);
    await tester.tap(grip,
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('Basic'), findsOneWidget);
    expect(find.text('Extended'), findsOneWidget);

    final extendedItem = find.widgetWithText(PopupMenuItem<String>, 'Extended');
    expect(tester.getSize(extendedItem).height, 32);
    await tester.tap(extendedItem);
    await tester.pumpAndSettle();
    expect(selected, kQualityMonitorDetailsExtended);

    await tester.drag(grip, const Offset(8, 6));
    await tester.pumpAndSettle();
    expect(dragUpdate, isNotNull);
  });

  testWidgets('quality monitor fades without blocking remote hover',
      (tester) async {
    var backgroundHoverCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Positioned.fill(
            child: MouseRegion(
              onHover: (_) => backgroundHoverCount++,
              child: const SizedBox.expand(),
            ),
          ),
          const Positioned(
            left: 20,
            top: 20,
            child: QualityMonitorHoverFade(
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ],
      ),
    ));

    AnimatedOpacity opacityWidget() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));

    expect(opacityWidget().opacity, 1.0);
    await tester.pump(QualityMonitorHoverFade.dimDelay);
    expect(opacityWidget().opacity, QualityMonitorHoverFade.dimOpacity);
    expect(opacityWidget().duration, QualityMonitorHoverFade.dimDuration);
    await tester.pump(QualityMonitorHoverFade.dimDuration);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(250, 250));
    await tester.pump();
    backgroundHoverCount = 0;
    await mouse.moveTo(const Offset(50, 50));
    await tester.pump();

    expect(backgroundHoverCount, greaterThan(0));
    expect(opacityWidget().opacity, 1.0);
    expect(opacityWidget().duration, QualityMonitorHoverFade.restoreDuration);

    await mouse.moveTo(const Offset(250, 250));
    await tester.pump();
    await tester.pump(QualityMonitorHoverFade.dimDelay);
    expect(opacityWidget().opacity, QualityMonitorHoverFade.dimOpacity);
  });
}
