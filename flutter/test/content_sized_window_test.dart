import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/content_sized_window.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _testWindow({
  required Widget child,
  required double width,
  required double height,
  ContentSizedWindowController? controller,
  EdgeInsets padding = EdgeInsets.zero,
  double additionalWindowHeight = 0,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: ContentSizedWindow(
          controller: controller,
          padding: padding,
          additionalWindowHeight: additionalWindowHeight,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('reports padded content plus native and tab chrome', (
    tester,
  ) async {
    final requests = <Size>[];
    final controller = ContentSizedWindowController(
      onSizeChanged: requests.add,
      nativeChromeHeight: () => 30,
    );

    await tester.pumpWidget(
      _testWindow(
        width: 320,
        height: 500,
        controller: controller,
        padding: const EdgeInsets.only(top: 10, bottom: 14),
        additionalWindowHeight: 28,
        child: const SizedBox(height: 100),
      ),
    );
    await tester.pump();
    await controller.ready;

    expect(requests, hasLength(1));
    expect(requests.single.width, 320);
    expect(requests.single.height, 182);
  });

  testWidgets('caps the native request while retaining a scroll viewport', (
    tester,
  ) async {
    final requests = <Size>[];
    final controller = ContentSizedWindowController(
      onSizeChanged: requests.add,
      availableHeight: () => 210,
    );

    await tester.pumpWidget(
      _testWindow(
        width: 320,
        height: 180,
        controller: controller,
        child: const SizedBox(height: 500),
      ),
    );
    await tester.pump();
    await controller.ready;

    expect(requests.single, const Size(320, 210));
    expect(tester.getSize(find.byType(SingleChildScrollView)).height, 180);
  });

  testWidgets('serializes and coalesces content changes during a resize', (
    tester,
  ) async {
    final requests = <Size>[];
    final firstResizeFinished = Completer<void>();
    var resizeCount = 0;
    final contentHeight = ValueNotifier<double>(100);
    final controller = ContentSizedWindowController(
      onSizeChanged: (size) {
        requests.add(size);
        resizeCount += 1;
        if (resizeCount == 1) return firstResizeFinished.future;
      },
    );
    addTearDown(contentHeight.dispose);

    await tester.pumpWidget(
      _testWindow(
        width: 320,
        height: 500,
        controller: controller,
        child: ValueListenableBuilder<double>(
          valueListenable: contentHeight,
          builder: (context, height, child) => SizedBox(height: height),
        ),
      ),
    );
    await tester.pump();
    expect(requests, [const Size(320, 100)]);

    contentHeight.value = 160;
    await tester.pump();
    await tester.pump();
    expect(requests, [const Size(320, 100)]);

    contentHeight.value = 100;
    await tester.pump();

    firstResizeFinished.complete();
    await tester.pump();
    await tester.pump();

    expect(requests, [const Size(320, 100)]);

    contentHeight.value = 180;
    await tester.pump();
    await tester.pump();
    expect(requests, [const Size(320, 100), const Size(320, 180)]);
  });

  testWidgets('completes readiness when async metrics or resize fail', (
    tester,
  ) async {
    final requests = <Size>[];
    final controller = ContentSizedWindowController(
      onSizeChanged: (size) async {
        requests.add(size);
        throw StateError('test resize failure');
      },
      availableHeight: () async => throw StateError('test metric failure'),
    );

    await tester.pumpWidget(
      _testWindow(
        width: 320,
        height: 240,
        controller: controller,
        child: const SizedBox(height: 100),
      ),
    );
    await tester.pump();
    await expectLater(controller.ready, completes);

    expect(requests, [const Size(320, 100)]);
  });
}
