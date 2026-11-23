import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

/// The models the picture of a desktop session reads, without a session behind them.
class _ModelsOnlyFfi implements FFI {
  _ModelsOnlyFfi() {
    sessionId = const Uuid().v4obj();
    ffiModel = FfiModel(WeakReference<FFI>(this));
    imageModel = ImageModel(WeakReference<FFI>(this));
    canvasModel = CanvasModel(WeakReference<FFI>(this));
    cursorModel = CursorModel(WeakReference<FFI>(this));
    inputModel = InputModel(WeakReference<FFI>(this));
  }

  @override
  late SessionID sessionId;
  @override
  String id = 'rebuild-test';
  @override
  late FfiModel ffiModel;
  @override
  late ImageModel imageModel;
  @override
  late CanvasModel canvasModel;
  @override
  late CursorModel cursorModel;
  @override
  late InputModel inputModel;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Audit VID-11: every change of the cursor model (a new position from the
  // peer, a new shape) rebuilt the whole picture of a desktop session, while
  // only the cursor of the mouse region depends on it.
  testWidgets('a cursor change rebuilds the cursor region, not the picture',
      (tester) async {
    final ffi = _ModelsOnlyFfi();
    ffi.canvasModel.updateSize();
    var pictureBuilds = 0;
    await tester.pumpWidget(MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<FfiModel>.value(value: ffi.ffiModel),
          ChangeNotifierProvider<ImageModel>.value(value: ffi.imageModel),
          ChangeNotifierProvider<CanvasModel>.value(value: ffi.canvasModel),
          ChangeNotifierProvider<CursorModel>.value(value: ffi.cursorModel),
        ],
        child: ImagePaint(
          ffi: ffi,
          id: 'rebuild-test',
          zoomCursor: false.obs,
          cursorOverImage: true.obs,
          keyboardEnabled: true.obs,
          remoteCursorMoved: false.obs,
          listenerBuilder: (child) {
            pictureBuilds++;
            return child;
          },
        ),
      ),
    ));
    expect(pictureBuilds, 1);
    final regionBefore = tester.widget<MouseRegion>(find
        .descendant(
            of: find.byType(ImagePaint), matching: find.byType(MouseRegion))
        .first);

    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ffi.cursorModel.notifyListeners();
    await tester.pump();

    final regionAfter = tester.widget<MouseRegion>(find
        .descendant(
            of: find.byType(ImagePaint), matching: find.byType(MouseRegion))
        .first);
    expect(regionAfter, isNot(same(regionBefore)),
        reason: 'the cursor of the mouse region must follow the cursor model');
    expect(pictureBuilds, 1, reason: 'the picture was rebuilt for the cursor');
  });
}
