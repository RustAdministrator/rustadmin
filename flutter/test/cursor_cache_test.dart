import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/session_event.dart';
import 'package:flutter_hbb/utils/image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Ffi implements FFI {
  _Ffi() {
    cursorModel = CursorModel(WeakReference<FFI>(this));
  }

  @override
  late final SessionID sessionId = const Uuid().v4obj();

  @override
  late final CursorModel cursorModel;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CursorShapeSessionEvent shape(String id, int red) => CursorShapeSessionEvent(
      id: id,
      hotx: 0,
      hoty: 0,
      width: 1,
      height: 1,
      colors: [red, 0, 0, 255],
    );

void main() {
  // The cursors kept for a session that is handed to another window: one entry per cursor
  // event, the full pixels each time, for as long as the session runs. A host sends a shape
  // again for an id that it had sent before (after a reconnect, a display switch).
  testWidgets('the cached cursors of a session hold one entry per cursor id',
      (tester) async {
    final ffi = _Ffi();
    final model = FfiModel(WeakReference<FFI>(ffi));
    await tester.runAsync(() async {
      for (var round = 0; round < 50; round++) {
        await model.handleCursorShapeEvent(shape('7', round));
      }
    });
    expect(model.cachedPeerData.cursorDataList.length, 1);
    expect(model.cachedPeerData.cursorDataList.single['id'], '7');
  });

  // A painter with the same image and place as the one before repainted every time.
  test('a cursor painter with unchanged fields does not repaint', () {
    final first = ImagePainter(image: null, x: 1, y: 2, scale: 1);
    final same = ImagePainter(image: null, x: 1, y: 2, scale: 1);
    final moved = ImagePainter(image: null, x: 3, y: 2, scale: 1);
    expect(same.shouldRepaint(first), isFalse);
    expect(moved.shouldRepaint(first), isTrue);
  });
}
