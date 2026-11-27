import 'package:flutter_hbb/models/handoff_start_watch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a handed-over session that fails to start is started again once', () {
    final watch = HandoffStartWatch(handoff: true);
    expect(watch.stuck, isTrue);
    expect(watch.failed(), isTrue);
    expect(watch.stuck, isFalse);
    expect(watch.failed(), isFalse);
  });

  test('a session the tab started itself is not restarted by the watch', () {
    final watch = HandoffStartWatch(handoff: false);
    expect(watch.stuck, isFalse);
    expect(watch.failed(), isFalse);
  });

  test('a handed-over session that started is not stuck', () {
    final watch = HandoffStartWatch(handoff: true);
    watch.started();
    expect(watch.stuck, isFalse);
  });
}
