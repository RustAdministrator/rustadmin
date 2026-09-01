import 'dart:async';

import 'package:flutter_hbb/models/render_target_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retirement blocks registration before creation completes', () async {
    final lifecycle = RenderTargetLifecycle();
    final creation = Completer<void>();
    lifecycle.trackCreation(creation.future);
    var cleaned = false;

    final retirement = lifecycle.retire(() async {
      cleaned = true;
    });

    expect(lifecycle.mayRegister, isFalse);
    expect(cleaned, isFalse);
    creation.complete();
    await retirement;
    expect(cleaned, isTrue);
  });

  test('concurrent retirement cleans up exactly once', () async {
    final lifecycle = RenderTargetLifecycle();
    lifecycle.trackCreation(Future<void>.value());
    var cleanupCount = 0;

    await Future.wait([
      lifecycle.retire(() async => cleanupCount++),
      lifecycle.retire(() async => cleanupCount++),
    ]);

    expect(cleanupCount, 1);
  });

  test('creation failure still releases the target', () async {
    final lifecycle = RenderTargetLifecycle();
    lifecycle.trackCreation(Future<void>.error(StateError('create failed')));
    var cleaned = false;

    await expectLater(
      lifecycle.retire(() async {
        cleaned = true;
      }),
      throwsStateError,
    );

    expect(cleaned, isTrue);
  });
}
