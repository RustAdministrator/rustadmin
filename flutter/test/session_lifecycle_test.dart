import 'package:flutter_hbb/models/session_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new starts invalidate callbacks from the previous generation', () {
    final lifecycle = SessionLifecycle();
    final first = lifecycle.beginStart();
    lifecycle.connected(first);
    expect(lifecycle.phase, SessionPhase.connected);

    final second = lifecycle.beginStart();
    expect(lifecycle.accepts(first), isFalse);
    expect(lifecycle.accepts(second), isTrue);

    lifecycle.closed(first);
    expect(lifecycle.phase, SessionPhase.connecting);
    lifecycle.connected(second);
    expect(lifecycle.phase, SessionPhase.connected);
  });

  test('close invalidates callbacks and accepts one matching completion', () {
    final lifecycle = SessionLifecycle();
    final session = lifecycle.beginStart();
    lifecycle.connected(session);

    final close = lifecycle.beginClose();
    expect(lifecycle.accepts(session), isFalse);
    expect(lifecycle.phase, SessionPhase.closing);

    lifecycle.closed(close);
    expect(lifecycle.isClosed, isTrue);
    expect(lifecycle.phase, SessionPhase.closed);
  });

  test('stale failures cannot close a newer session', () {
    final lifecycle = SessionLifecycle();
    final first = lifecycle.beginStart();
    final second = lifecycle.beginStart();

    lifecycle.failed(first);
    expect(lifecycle.accepts(second), isTrue);
    lifecycle.failed(second);
    expect(lifecycle.phase, SessionPhase.failed);
    expect(lifecycle.isClosed, isTrue);
  });
}
