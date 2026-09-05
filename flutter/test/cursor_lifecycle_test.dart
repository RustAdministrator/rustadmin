import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_hbb/utils/image.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedFfi implements FFI {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CursorShapeSessionEvent shape(int red) => CursorShapeSessionEvent(
  id: '1',
  hotx: 0,
  hoty: 0,
  width: 1,
  height: 1,
  colors: [red, 0, 0, 255],
);

void main() {
  final ffi = _UnusedFfi();

  testWidgets('cursor disposal clears the published image before reuse', (
    tester,
  ) async {
    final model = CursorModel(WeakReference<FFI>(ffi))..id = '1';
    await tester.runAsync(() => model.updateCursorShape(shape(255)));
    final image = model.image!;
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: model,
        builder: (context, child) => CustomPaint(
          painter: ImagePainter(image: model.image, x: 0, y: 0, scale: 1),
        ),
      ),
    );

    model.disposeImages();
    expect(model.image, isNull);
    expect(model.cache, isNull);
    expect(image.debugDisposed, isFalse);
    await tester.pump();
    expect(image.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => model.updateCursorShape(shape(128)));
    expect(model.image, isNotNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    model.disposeImages();
    await tester.pump();
  });

  testWidgets('cursor decode finishing after disposal cannot republish', (
    tester,
  ) async {
    final model = CursorModel(WeakReference<FFI>(ffi))..id = '1';
    await tester.runAsync(() async {
      final pending = model.updateCursorShape(shape(255));
      model.disposeImages();
      await pending;
    });
    expect(model.image, isNull);
    expect(model.cache, isNull);
    await tester.pump();
  });

  testWidgets('replacement cursor survives disposal of its predecessor', (
    tester,
  ) async {
    final model = CursorModel(WeakReference<FFI>(ffi))..id = '1';
    await tester.runAsync(() => model.updateCursorShape(shape(255)));
    final old = model.image!;
    await tester.runAsync(() => model.updateCursorShape(shape(128)));
    final current = model.image!;
    expect(current, isNot(same(old)));
    expect(old.debugDisposed, isFalse);
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(old.debugDisposed, isTrue);
    expect(current.debugDisposed, isFalse);
    model.disposeImages();
    tester.binding.scheduleFrame();
    await tester.pump();
  });
}
