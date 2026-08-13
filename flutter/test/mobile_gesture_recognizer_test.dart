import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/gestures.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cursor inertia integrates a linearly decaying motion vector', () {
    const velocity = Offset(1000, -500);
    final first = mobileCursorInertiaFrameDelta(
      velocityPixelsPerSecond: velocity,
      elapsedBeforeFrame: Duration.zero,
      frameDuration: const Duration(milliseconds: 50),
      totalDuration: const Duration(milliseconds: 100),
    );
    final second = mobileCursorInertiaFrameDelta(
      velocityPixelsPerSecond: velocity,
      elapsedBeforeFrame: const Duration(milliseconds: 50),
      frameDuration: const Duration(milliseconds: 50),
      totalDuration: const Duration(milliseconds: 100),
    );
    expect(first, const Offset(37.5, -18.75));
    expect(second, const Offset(12.5, -6.25));
    expect(first + second, const Offset(50, -25));
  });

  Future<void> pumpTarget(
    WidgetTester tester, {
    required GestureTapDownCallback onTwoFingerTap,
    required GestureTapDownCallback onTwoFingerHoldStart,
    required GestureTapCancelCallback onTwoFingerHoldEnd,
    required VoidCallback onOrdinaryTap,
    VoidCallback? onOrdinaryLongPress,
    GestureScaleUpdateCallback? onTwoFingerScaleUpdate,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 200,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: <Type, GestureRecognizerFactory>{
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      TapGestureRecognizer.new,
                      (recognizer) => recognizer.onTap = onOrdinaryTap,
                    ),
                MobileTapHoldGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      MobileTapHoldGestureRecognizer
                    >(
                      MobileTapHoldGestureRecognizer.new,
                      (recognizer) => recognizer
                        ..onOneFingerHoldStart = (_) {
                          onOrdinaryLongPress?.call();
                        }
                        ..onTwoFingerTap = onTwoFingerTap
                        ..onTwoFingerHoldStart = onTwoFingerHoldStart
                        ..onTwoFingerHoldEnd = onTwoFingerHoldEnd,
                    ),
                CustomTouchGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      CustomTouchGestureRecognizer
                    >(
                      CustomTouchGestureRecognizer.new,
                      (recognizer) => recognizer.onTwoFingerScaleUpdate =
                          onTwoFingerScaleUpdate,
                    ),
              },
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('two-finger tap wins both arenas and reports its centroid', (
    tester,
  ) async {
    var ordinaryTaps = 0;
    var twoFingerTaps = 0;
    Offset? centroid;
    await pumpTarget(
      tester,
      onOrdinaryTap: () => ordinaryTaps += 1,
      onTwoFingerTap: (details) {
        twoFingerTaps += 1;
        centroid = details.localPosition;
      },
      onTwoFingerHoldStart: (_) {},
      onTwoFingerHoldEnd: () {},
    );

    final first = await tester.startGesture(const Offset(380, 280), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 320),
      pointer: 2,
    );
    await first.up();
    await second.up();
    await tester.pump();

    expect(twoFingerTaps, 1);
    expect(ordinaryTaps, 0);
    expect(centroid, const Offset(100, 100));
  });

  testWidgets('two-finger hold sends one down and one up without a tap', (
    tester,
  ) async {
    var ordinaryTaps = 0;
    var twoFingerTaps = 0;
    var holdStarts = 0;
    var holdEnds = 0;
    var ordinaryLongPresses = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () => ordinaryTaps += 1,
      onTwoFingerTap: (_) => twoFingerTaps += 1,
      onTwoFingerHoldStart: (_) => holdStarts += 1,
      onTwoFingerHoldEnd: () => holdEnds += 1,
      onOrdinaryLongPress: () => ordinaryLongPresses += 1,
    );

    final first = await tester.startGesture(const Offset(380, 280), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 320),
      pointer: 2,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    expect(holdStarts, 1);
    expect(twoFingerTaps, 0);

    await first.up();
    await second.up();
    await tester.pump();
    expect(holdEnds, 1);
    expect(twoFingerTaps, 0);
    expect(ordinaryTaps, 0);
    expect(ordinaryLongPresses, 0);
  });

  testWidgets('one-finger hold remains a long press', (tester) async {
    var ordinaryLongPresses = 0;
    var twoFingerHolds = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () {},
      onOrdinaryLongPress: () => ordinaryLongPresses += 1,
      onTwoFingerTap: (_) {},
      onTwoFingerHoldStart: (_) => twoFingerHolds += 1,
      onTwoFingerHoldEnd: () {},
    );

    final finger = await tester.startGesture(
      const Offset(400, 300),
      pointer: 1,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await finger.up();

    expect(ordinaryLongPresses, 1);
    expect(twoFingerHolds, 0);
  });

  testWidgets('two-finger motion cancels tap and hold recognition', (
    tester,
  ) async {
    var twoFingerTaps = 0;
    var holdStarts = 0;
    var scaleUpdates = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () {},
      onTwoFingerTap: (_) => twoFingerTaps += 1,
      onTwoFingerHoldStart: (_) => holdStarts += 1,
      onTwoFingerHoldEnd: () {},
      onTwoFingerScaleUpdate: (_) => scaleUpdates += 1,
    );

    final first = await tester.startGesture(const Offset(380, 280), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 320),
      pointer: 2,
    );
    await first.moveBy(const Offset(40, 0));
    await second.moveBy(const Offset(-20, 0));
    await first.moveBy(const Offset(10, 5));
    await tester.pump();
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 201));

    expect(twoFingerTaps, 0);
    expect(holdStarts, 0);
    expect(scaleUpdates, greaterThan(0));
  });
}
