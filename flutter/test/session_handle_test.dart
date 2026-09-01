import 'dart:async';

import 'package:flutter_hbb/models/session_handle.dart';
import 'package:flutter_hbb/models/session_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

SessionHandle<int> handle({
  required Future<void> Function() closeNative,
  Future<void> Function(int? generation)? releasePlatformLease,
}) {
  return SessionHandle<int>(
    sessionId: Uuid().v4obj(),
    closeNative: closeNative,
    releasePlatformLease: releasePlatformLease,
  );
}

void main() {
  test('legacy flags resolve one typed session kind', () {
    expect(
      SessionKind.fromLegacyFlags(
        isFileTransfer: false,
        isViewCamera: false,
        isPortForward: false,
        isRdp: false,
        isTerminal: false,
      ),
      SessionKind.remoteDesktop,
    );
    expect(
      SessionKind.fromLegacyFlags(
        isFileTransfer: false,
        isViewCamera: false,
        isPortForward: true,
        isRdp: true,
        isTerminal: false,
      ),
      SessionKind.rdp,
    );
    expect(
      () => SessionKind.fromLegacyFlags(
        isFileTransfer: false,
        isViewCamera: true,
        isPortForward: true,
        isRdp: false,
        isTerminal: false,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      SessionKind.fromLegacyFlags(
        isFileTransfer: false,
        isViewCamera: false,
        isPortForward: false,
        isRdp: true,
        isTerminal: false,
      ),
      SessionKind.remoteDesktop,
    );
  });

  test('concurrent close is idempotent and cancels events once', () async {
    var nativeCloseCount = 0;
    var cleanupCount = 0;
    var subscriptionCancelCount = 0;
    final controller = StreamController<int>(
      onCancel: () => subscriptionCancelCount++,
    );
    final session = handle(closeNative: () async => nativeCloseCount++);
    final lease = await session.start(
      addNative: () async {},
      startEvents: () => controller.stream,
    );
    expect(lease, isNotNull);
    await session.bindSubscription(
      lease!.generation,
      lease.events.listen((_) {}),
    );
    session.connected(lease.generation);

    await Future.wait([
      session.close(
        nativeClosePolicy: NativeSessionClosePolicy.requestClose,
        cleanup: () async => cleanupCount++,
      ),
      session.close(
        nativeClosePolicy: NativeSessionClosePolicy.requestClose,
        cleanup: () async => cleanupCount++,
      ),
    ]);

    expect(nativeCloseCount, 1);
    expect(cleanupCount, 1);
    expect(subscriptionCancelCount, 1);
    expect(session.phase, SessionPhase.closed);
    await controller.close();
  });

  test(
    'close during add closes the late native session exactly once',
    () async {
      final add = Completer<void>();
      var nativeCloseCount = 0;
      var cleanupCount = 0;
      final session = handle(closeNative: () async => nativeCloseCount++);
      var addCalled = false;
      final start = session.start(
        addNative: () {
          addCalled = true;
          return add.future;
        },
        startEvents: () => const Stream<int>.empty(),
      );
      expect(addCalled, isTrue);
      final close = session.close(
        nativeClosePolicy: NativeSessionClosePolicy.requestClose,
        cleanup: () async => cleanupCount++,
      );
      add.complete();

      expect(await start, isNull);
      await close;
      expect(nativeCloseCount, 1);
      expect(cleanupCount, 1);
      expect(session.phase, SessionPhase.closed);
    },
  );

  test('remote close cancels events without another native close', () async {
    var nativeCloseCount = 0;
    var subscriptionCancelCount = 0;
    final controller = StreamController<int>(
      onCancel: () => subscriptionCancelCount++,
    );
    final session = handle(closeNative: () async => nativeCloseCount++);
    final lease = await session.start(
      addNative: () async {},
      startEvents: () => controller.stream,
    );
    await session.bindSubscription(
      lease!.generation,
      lease.events.listen((_) {}),
    );
    session.connected(lease.generation);

    await session.remoteClosed(lease.generation);
    await session.close(
      nativeClosePolicy: NativeSessionClosePolicy.requestClose,
      cleanup: () async {},
    );

    expect(nativeCloseCount, 0);
    expect(subscriptionCancelCount, 1);
    expect(session.phase, SessionPhase.closed);
    await controller.close();
  });

  test('remote close releases the platform lease when cancel fails', () async {
    var releaseCount = 0;
    final controller = StreamController<int>(
      onCancel: () async => throw StateError('cancel failed'),
    );
    final session = handle(
      closeNative: () async {},
      releasePlatformLease: (_) async => releaseCount++,
    );
    final lease = await session.start(
      acquirePlatformLease: () async => 19,
      addNative: () async {},
      startEvents: () => controller.stream,
    );
    await session.bindSubscription(
      lease!.generation,
      lease.events.listen((_) {}),
    );

    await expectLater(session.remoteClosed(lease.generation), throwsStateError);

    expect(releaseCount, 1);
    expect(session.phase, SessionPhase.closed);
    await controller.close();
  });

  test('subscription arriving after close is cancelled immediately', () async {
    var subscriptionCancelCount = 0;
    final controller = StreamController<int>(
      onCancel: () => subscriptionCancelCount++,
    );
    final session = handle(closeNative: () async {});
    final lease = await session.start(
      addNative: () async {},
      startEvents: () => controller.stream,
    );

    await session.close(
      nativeClosePolicy: NativeSessionClosePolicy.requestClose,
      cleanup: () async {},
    );
    await session.bindSubscription(
      lease!.generation,
      lease.events.listen((_) {}),
    );

    expect(subscriptionCancelCount, 1);
    expect(session.accepts(lease.generation), isFalse);
    expect(session.phase, SessionPhase.closed);
    await controller.close();
  });

  test(
    'already-closed policy skips native close but still cleans up',
    () async {
      var nativeCloseCount = 0;
      var cleanupCount = 0;
      final session = handle(closeNative: () async => nativeCloseCount++);
      await session.start(
        addNative: () async {},
        startEvents: () => const Stream<int>.empty(),
      );

      await session.close(
        nativeClosePolicy: NativeSessionClosePolicy.alreadyClosed,
        cleanup: () async => cleanupCount++,
      );

      expect(nativeCloseCount, 0);
      expect(cleanupCount, 1);
      expect(session.phase, SessionPhase.closed);
    },
  );

  test('start failure releases a platform lease once', () async {
    var releaseCount = 0;
    int? releasedGeneration;
    final session = handle(
      closeNative: () async {},
      releasePlatformLease: (generation) async {
        releaseCount++;
        releasedGeneration = generation;
      },
    );

    await expectLater(
      session.start(
        acquirePlatformLease: () async => 17,
        addNative: () async => throw StateError('add failed'),
        startEvents: () => const Stream<int>.empty(),
      ),
      throwsStateError,
    );
    expect(session.phase, SessionPhase.failed);
    await session.close(
      nativeClosePolicy: NativeSessionClosePolicy.requestClose,
      cleanup: () async {},
    );

    expect(releaseCount, 1);
    expect(releasedGeneration, 17);
    expect(session.phase, SessionPhase.closed);
  });

  test('one handle cannot be restarted', () async {
    final session = handle(closeNative: () async {});
    await session.start(
      addNative: () async {},
      startEvents: () => const Stream<int>.empty(),
    );

    expect(
      () => session.start(
        addNative: () async {},
        startEvents: () => const Stream<int>.empty(),
      ),
      throwsStateError,
    );
    await session.close(
      nativeClosePolicy: NativeSessionClosePolicy.requestClose,
      cleanup: () async {},
    );
  });

  test('waitForClose serializes a new owner behind active cleanup', () async {
    final cleanup = Completer<void>();
    final session = handle(closeNative: () async {});
    await session.start(
      addNative: () async {},
      startEvents: () => const Stream<int>.empty(),
    );

    final close = session.close(
      nativeClosePolicy: NativeSessionClosePolicy.requestClose,
      cleanup: () => cleanup.future,
    );
    var waitCompleted = false;
    final wait = session.waitForClose().then((_) => waitCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(waitCompleted, isFalse);

    cleanup.complete();
    await Future.wait([close, wait]);
    expect(session.canBeReplaced, isTrue);
  });

  test('cleanup failure is terminal and does not strand the owner', () async {
    final session = handle(closeNative: () async {});
    await session.start(
      addNative: () async {},
      startEvents: () => const Stream<int>.empty(),
    );

    await expectLater(
      session.close(
        nativeClosePolicy: NativeSessionClosePolicy.requestClose,
        cleanup: () async => throw StateError('cleanup failed'),
      ),
      throwsStateError,
    );

    expect(session.phase, SessionPhase.closed);
    expect(session.canBeReplaced, isTrue);
  });
}
