import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/gestures.dart';
import 'package:flutter_hbb/common/widgets/mobile_gesture_controller.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_hbb/mobile/mobile_viewport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

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

  test('cursor inertia controller owns ticks and natural stop', () {
    fakeAsync((async) {
      final frames = <MobileCursorInertiaFrame>[];
      var stopped = 0;
      var elapsed = Duration.zero;
      final controller = MobileCursorInertiaController(
        onFrame: (frame) async {
          frames.add(frame);
          return frames.length == 1 ? const Offset(1, 0) : Offset.zero;
        },
        onStopped: () => stopped++,
        elapsedNow: () => elapsed,
      );

      expect(
        controller.start(
          duration: const Duration(milliseconds: 32),
          velocity: const Offset(1000, 0),
          localPosition: const Offset(10, 20),
        ),
        isTrue,
      );
      elapsed = const Duration(milliseconds: 16);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();
      elapsed = const Duration(milliseconds: 32);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();

      expect(frames, hasLength(2));
      expect(frames.first.localPosition, const Offset(22, 20));
      expect(frames.last.localPosition, const Offset(27, 20));
      expect(controller.active, isFalse);
      expect(stopped, 1);
    });
  });

  test('cursor inertia stop invalidates future timer ticks', () {
    fakeAsync((async) {
      final frames = <MobileCursorInertiaFrame>[];
      var elapsed = Duration.zero;
      final controller = MobileCursorInertiaController(
        onFrame: (frame) async {
          frames.add(frame);
          return Offset.zero;
        },
        onStopped: () {},
        elapsedNow: () => elapsed,
      );
      expect(
        controller.start(
          duration: const Duration(milliseconds: 200),
          velocity: const Offset(500, 0),
          localPosition: Offset.zero,
        ),
        isTrue,
      );
      elapsed = const Duration(milliseconds: 16);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();
      controller.stop();
      final count = frames.length;
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(frames, hasLength(count));
      expect(controller.active, isFalse);
    });
  });

  test('old async frame cannot unlock a restarted inertia generation', () {
    fakeAsync((async) {
      final firstFrame = Completer<Offset>();
      final secondFrame = Completer<Offset>();
      var elapsed = Duration.zero;
      var calls = 0;
      final controller = MobileCursorInertiaController(
        onFrame: (_) {
          calls++;
          if (calls == 1) return firstFrame.future;
          if (calls == 2) return secondFrame.future;
          return Future<Offset>.value(Offset.zero);
        },
        onStopped: () {},
        elapsedNow: () => elapsed,
      );

      controller.start(
        duration: const Duration(milliseconds: 100),
        velocity: const Offset(500, 0),
        localPosition: Offset.zero,
      );
      elapsed = const Duration(milliseconds: 16);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();
      expect(calls, 1);

      controller.stop(notify: false);
      elapsed = Duration.zero;
      controller.start(
        duration: const Duration(milliseconds: 100),
        velocity: const Offset(500, 0),
        localPosition: Offset.zero,
      );
      elapsed = const Duration(milliseconds: 16);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();
      expect(calls, 2);

      firstFrame.complete(Offset.zero);
      async.flushMicrotasks();
      elapsed = const Duration(milliseconds: 32);
      async.elapse(const Duration(milliseconds: 16));
      async.flushMicrotasks();
      expect(calls, 2);

      secondFrame.complete(Offset.zero);
      async.flushMicrotasks();
      controller.stop(notify: false);
    });
  });

  test('custom keys block taps in the remote input coordinate space', () {
    const globalRect = Rect.fromLTWH(0, 700, 430, 50);
    const inputRegionGlobalOrigin = Offset(0, 59);
    final inputRect = mobileRemoteInputLocalRect(
      globalRect: globalRect,
      inputRegionGlobalOrigin: inputRegionGlobalOrigin,
    );

    expect(inputRect, const Rect.fromLTWH(0, 641, 430, 50));
    expect(inputRect.contains(const Offset(215, 650)), isTrue);
    expect(globalRect.contains(const Offset(215, 650)), isFalse);
  });

  test('two-finger controller separates wheel, zoom, and viewport pan', () {
    final controller = MobileTwoFingerMotionController();

    controller.start(scale: 1, focalPoint: Offset.zero);
    expect(
      controller
          .update(
            scale: 1.25,
            focalPoint: const Offset(0, 15),
            localFocalPoint: const Offset(0, 15),
            enableRemoteWheel: true,
          )
          .kind,
      MobileTwoFingerMotionKind.pending,
    );
    final wheel = controller.update(
      scale: 1,
      focalPoint: const Offset(0, 30),
      localFocalPoint: const Offset(0, 30),
      enableRemoteWheel: true,
    );
    expect(wheel.kind, MobileTwoFingerMotionKind.remoteWheel);
    expect(wheel.focalPointDelta, const Offset(0, 30));

    controller.reset();
    controller.start(scale: 1, focalPoint: Offset.zero);
    expect(
      controller
          .update(
            scale: 1.25,
            focalPoint: const Offset(-5, 0),
            localFocalPoint: const Offset(-5, 0),
            enableRemoteWheel: true,
          )
          .kind,
      MobileTwoFingerMotionKind.pending,
    );
    final zoom = controller.update(
      scale: 1.5,
      focalPoint: Offset.zero,
      localFocalPoint: Offset.zero,
      enableRemoteWheel: true,
    );
    expect(zoom.kind, MobileTwoFingerMotionKind.viewportZoom);
    expect(zoom.scaleDelta, 1.5);
    expect(
      controller
          .update(
            scale: 1,
            focalPoint: const Offset(0, 30),
            localFocalPoint: const Offset(0, 30),
            enableRemoteWheel: true,
          )
          .kind,
      MobileTwoFingerMotionKind.viewportZoom,
    );

    controller.reset();
    controller.start(scale: 1, focalPoint: Offset.zero);
    final pan = controller.update(
      scale: 1,
      focalPoint: const Offset(30, 0),
      localFocalPoint: const Offset(30, 0),
      enableRemoteWheel: true,
    );
    expect(pan.kind, MobileTwoFingerMotionKind.viewportPan);
  });

  test('wheel accumulator preserves sub-step movement', () {
    final accumulator = MobileWheelAccumulator(logicalPixelsPerStep: 8);
    expect(accumulator.add(3), 0);
    expect(accumulator.add(3), 0);
    expect(accumulator.add(3), 1);
    expect(accumulator.add(-17), -2);
    accumulator.reset();
    expect(accumulator.add(7), 0);
  });

  test('button sequence cancels a request before down is emitted', () async {
    final controller = MobileButtonSequenceController();
    final calls = <String>[];
    final token = controller.beginRequest();

    controller.cancelRequest(token);
    await controller.activate(token, () async => calls.add('down'));
    await controller.release(() async => calls.add('up'));

    expect(calls, isEmpty);
    expect(controller.hasIntent, isFalse);
  });

  test('button release waits for an in-flight down and balances it', () async {
    final controller = MobileButtonSequenceController();
    final downGate = Completer<void>();
    final calls = <String>[];
    final token = controller.beginRequest();
    final down = controller.activate(token, () async {
      calls.add('down-start');
      await downGate.future;
      calls.add('down-end');
    });
    await Future<void>.delayed(Duration.zero);

    final up = controller.release(() async => calls.add('up'));
    expect(calls, ['down-start']);
    downGate.complete();
    await Future.wait([down, up]);

    expect(calls, ['down-start', 'down-end', 'up']);
    expect(controller.hasIntent, isFalse);
  });

  test('button sequence emits at most one up per press', () async {
    final controller = MobileButtonSequenceController();
    final calls = <String>[];
    final token = controller.beginRequest();
    await controller.activate(token, () async => calls.add('down'));

    await controller.release(() async => calls.add('up'));
    await controller.release(() async => calls.add('duplicate-up'));

    expect(calls, ['down', 'up']);
  });

  Future<void> pumpTarget(
    WidgetTester tester, {
    required GestureTapDownCallback onTwoFingerTap,
    required GestureTapDownCallback onTwoFingerHoldStart,
    required GestureTapCancelCallback onTwoFingerHoldEnd,
    required VoidCallback onOrdinaryTap,
    VoidCallback? onOrdinaryLongPress,
    GestureDragStartCallback? onOneFingerPanStart,
    GestureDragEndCallback? onOneFingerPanEnd,
    GestureDragCancelCallback? onOneFingerPanCancel,
    ValueChanged<MobileTwoFingerMotionUpdate>? onTwoFingerZoomUpdate,
    ValueChanged<MobileTwoFingerMotionUpdate>? onTwoFingerWheelUpdate,
    ValueChanged<MobileTwoFingerMotionUpdate>? onTwoFingerPanUpdate,
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
                      () => CustomTouchGestureRecognizer(
                        enableTwoFingerRemoteWheel: true,
                      ),
                      (recognizer) => recognizer
                        ..onOneFingerPanStart = onOneFingerPanStart
                        ..onOneFingerPanEnd = onOneFingerPanEnd
                        ..onOneFingerPanCancel = onOneFingerPanCancel
                        ..onTwoFingerViewportZoomUpdate = onTwoFingerZoomUpdate
                        ..onTwoFingerRemoteWheelUpdate = onTwoFingerWheelUpdate
                        ..onTwoFingerViewportPanUpdate = onTwoFingerPanUpdate,
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

    final first = await tester.startGesture(const Offset(380, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 300),
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

    final first = await tester.startGesture(const Offset(380, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 300),
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

  testWidgets('parallel vertical two-finger motion emits only remote wheel', (
    tester,
  ) async {
    var zoomUpdates = 0;
    var wheelUpdates = 0;
    var panUpdates = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () {},
      onTwoFingerTap: (_) {},
      onTwoFingerHoldStart: (_) {},
      onTwoFingerHoldEnd: () {},
      onTwoFingerZoomUpdate: (_) => zoomUpdates += 1,
      onTwoFingerWheelUpdate: (_) => wheelUpdates += 1,
      onTwoFingerPanUpdate: (_) => panUpdates += 1,
    );

    final first = await tester.startGesture(const Offset(380, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 300),
      pointer: 2,
    );
    await first.moveBy(const Offset(0, 30));
    await second.moveBy(const Offset(0, 30));
    await first.moveBy(const Offset(0, 10));
    await second.moveBy(const Offset(0, 10));
    await tester.pump();
    await first.up();
    await second.up();

    expect(wheelUpdates, greaterThan(0));
    expect(zoomUpdates, 0);
    expect(panUpdates, 0);
  });

  testWidgets('two-finger pinch emits only viewport zoom', (tester) async {
    var zoomUpdates = 0;
    var wheelUpdates = 0;
    var panUpdates = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () {},
      onTwoFingerTap: (_) {},
      onTwoFingerHoldStart: (_) {},
      onTwoFingerHoldEnd: () {},
      onTwoFingerZoomUpdate: (_) => zoomUpdates += 1,
      onTwoFingerWheelUpdate: (_) => wheelUpdates += 1,
      onTwoFingerPanUpdate: (_) => panUpdates += 1,
    );

    final first = await tester.startGesture(const Offset(380, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(420, 300),
      pointer: 2,
    );
    await first.moveBy(const Offset(-12, 0));
    await second.moveBy(const Offset(12, 0));
    await first.moveBy(const Offset(-8, 0));
    await second.moveBy(const Offset(8, 0));
    await first.moveBy(const Offset(-8, 0));
    await second.moveBy(const Offset(8, 0));
    await tester.pump();
    await first.up();
    await second.up();

    expect(zoomUpdates, greaterThan(0));
    expect(wheelUpdates, 0);
    expect(panUpdates, 0);
  });

  testWidgets('adding a second finger ends one-finger cursor ownership', (
    tester,
  ) async {
    var oneFingerStarts = 0;
    var oneFingerEnds = 0;
    await pumpTarget(
      tester,
      onOrdinaryTap: () {},
      onTwoFingerTap: (_) {},
      onTwoFingerHoldStart: (_) {},
      onTwoFingerHoldEnd: () {},
      onOneFingerPanStart: (_) => oneFingerStarts += 1,
      onOneFingerPanEnd: (_) => oneFingerEnds += 1,
      onTwoFingerZoomUpdate: (_) {},
    );

    final first = await tester.startGesture(const Offset(380, 300), pointer: 1);
    await first.moveBy(const Offset(30, 0));
    await first.moveBy(const Offset(10, 0));
    await tester.pump();
    final second = await tester.startGesture(
      const Offset(420, 300),
      pointer: 2,
    );
    await first.moveBy(const Offset(-12, 0));
    await second.moveBy(const Offset(12, 0));
    await tester.pump();
    await first.up();
    await second.up();

    expect(oneFingerStarts, 1);
    expect(oneFingerEnds, 1);
  });
}
