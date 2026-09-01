import 'dart:async';

import 'package:flutter_hbb/models/android_render_target_controller.dart';
import 'package:flutter_test/flutter_test.dart';

const targetA = AndroidTextureTarget(display: 0, width: 1920, height: 1080);
const targetB = AndroidTextureTarget(display: 1, width: 1280, height: 720);

class RenderTargetHarness {
  final creates = <AndroidTextureTarget>[];
  final releases = <(AndroidTextureTarget, int)>[];
  final refreshes = <int>[];
  final errors = <Object>[];
  final createResults = <Completer<int?>>[];
  Completer<void>? releaseBarrier;
  Object? refreshError;
  var changed = 0;

  late final controller = AndroidRenderTargetController(
    create: (target) {
      creates.add(target);
      final result = Completer<int?>();
      createResults.add(result);
      return result.future;
    },
    release: (target, textureId) async {
      releases.add((target, textureId));
      final barrier = releaseBarrier;
      if (barrier != null) await barrier.future;
    },
    refresh: (display) async {
      refreshes.add(display);
      if (refreshError != null) throw refreshError!;
    },
    onChanged: () => changed++,
    onError: (error, _) => errors.add(error),
  );
}

void main() {
  test('stale create completion releases without replacing target', () async {
    final harness = RenderTargetHarness();
    final first = harness.controller.requireTarget(targetA);
    final second = harness.controller.requireTarget(targetB);

    harness.createResults[0].complete(10);
    await first;
    expect(harness.releases, [(targetA, 10)]);
    expect(harness.controller.snapshot.target, targetB);
    expect(
      harness.controller.snapshot.phase,
      AndroidRenderTargetPhase.creating,
    );

    harness.createResults[1].complete(20);
    await second;
    expect(harness.controller.snapshot.textureId, 20);
    expect(harness.refreshes, [1]);
  });

  test('retire waits for stale creation and its release', () async {
    final harness = RenderTargetHarness();
    final releaseBarrier = Completer<void>();
    harness.releaseBarrier = releaseBarrier;
    harness.controller.requireTarget(targetA);

    var retired = false;
    final retirement = harness.controller.retire().then((_) => retired = true);
    harness.createResults.single.complete(11);
    await Future<void>.delayed(Duration.zero);
    expect(retired, isFalse);
    expect(harness.releases, [(targetA, 11)]);

    releaseBarrier.complete();
    await retirement;
    expect(retired, isTrue);
    expect(harness.controller.snapshot.phase, AndroidRenderTargetPhase.none);
  });

  test('identical target intents create once', () async {
    final harness = RenderTargetHarness();
    final requests = List.generate(
      5,
      (_) => harness.controller.requireTarget(targetA),
    );

    expect(harness.creates, [targetA]);
    harness.createResults.single.complete(12);
    await Future.wait(requests);
    expect(harness.controller.snapshot.textureId, 12);
  });

  test('switching back reuses the still-owned target', () async {
    final harness = RenderTargetHarness();
    final first = harness.controller.requireTarget(targetA);
    harness.createResults.single.complete(10);
    await first;

    final stale = harness.controller.requireTarget(targetB);
    await harness.controller.requireTarget(targetA);

    expect(harness.creates, [targetA, targetB]);
    expect(harness.controller.snapshot.textureId, 10);
    harness.createResults[1].complete(20);
    await stale;
    expect(harness.releases, [(targetB, 20)]);
    expect(harness.controller.snapshot.textureId, 10);
  });

  test('replacement and concurrent retirement balance owned handles', () async {
    final harness = RenderTargetHarness();
    final first = harness.controller.requireTarget(targetA);
    harness.createResults.single.complete(10);
    await first;

    final second = harness.controller.requireTarget(targetB);
    harness.createResults[1].complete(20);
    await second;
    expect(harness.releases, [(targetA, 10)]);

    await Future.wait([
      harness.controller.retire(),
      harness.controller.retire(),
    ]);
    expect(harness.releases, [(targetA, 10), (targetB, 20)]);
  });

  test('producer readiness accepts only the current ready target', () async {
    final harness = RenderTargetHarness();
    final creation = harness.controller.requireTarget(targetA);

    expect(
      harness.controller.producerFrame(
        display: 0,
        width: 1920,
        height: 1080,
        active: true,
      ),
      isFalse,
    );
    harness.createResults.single.complete(13);
    await creation;
    expect(
      harness.controller.producerFrame(
        display: 1,
        width: 1280,
        height: 720,
        active: true,
      ),
      isFalse,
    );
    expect(
      harness.controller.producerFrame(
        display: 0,
        width: 1920,
        height: 1080,
        active: true,
      ),
      isTrue,
    );
    expect(harness.controller.snapshot.canRenderTexture, isTrue);

    harness.controller.producerFrame(
      display: 0,
      width: 1920,
      height: 1080,
      active: false,
    );
    expect(harness.controller.snapshot.canRenderTexture, isFalse);
  });

  test('failed creation stays on software fallback', () async {
    final harness = RenderTargetHarness();
    final creation = harness.controller.requireTarget(targetA);
    harness.createResults.single.complete(null);
    await creation;

    expect(harness.controller.snapshot.phase, AndroidRenderTargetPhase.failed);
    expect(harness.controller.snapshot.canRenderTexture, isFalse);
    await harness.controller.requireTarget(targetA);
    expect(harness.creates, [targetA]);
  });

  test('create exception reports failure without escaping', () async {
    final harness = RenderTargetHarness();
    final creation = harness.controller.requireTarget(targetA);
    harness.createResults.single.completeError(StateError('create failed'));

    await creation;

    expect(harness.errors, hasLength(1));
    expect(harness.controller.snapshot.phase, AndroidRenderTargetPhase.failed);
  });

  test(
    'refresh exception reports software fallback without escaping',
    () async {
      final harness = RenderTargetHarness()
        ..refreshError = StateError('refresh failed');
      final creation = harness.controller.requireTarget(targetA);
      harness.createResults.single.complete(15);

      await creation;

      expect(harness.errors, hasLength(1));
      expect(
        harness.controller.snapshot.phase,
        AndroidRenderTargetPhase.failed,
      );
      await harness.controller.retire();
      expect(harness.releases, [(targetA, 15)]);
    },
  );

  test('retire invalidates delayed target intents', () async {
    final harness = RenderTargetHarness();
    final staleEpoch = harness.controller.intentEpoch;

    await harness.controller.retire();
    await harness.controller.requireTarget(targetA, intentEpoch: staleEpoch);

    expect(harness.creates, isEmpty);
    expect(harness.controller.snapshot.phase, AndroidRenderTargetPhase.none);

    final current = harness.controller.requireTarget(
      targetA,
      intentEpoch: harness.controller.intentEpoch,
    );
    await harness.controller.retire(intentEpoch: staleEpoch);
    expect(
      harness.controller.snapshot.phase,
      AndroidRenderTargetPhase.creating,
    );
    harness.createResults.single.complete(14);
    await current;
  });
}
