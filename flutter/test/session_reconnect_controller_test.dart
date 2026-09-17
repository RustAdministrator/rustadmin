import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_hbb/models/session_reconnect_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('short interruption uses ordinary retry and bounded backoff', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      final retries = <bool>[];
      final controller = SessionReconnectController(
        retry: retries.add,
        onFailure: (error, stack) => fail('$error'),
        now: () => now,
      );
      controller.attachFreshRestart(
        (_, __) async => fail('unexpected fresh restart'),
      );
      now = now.add(const Duration(seconds: 10));
      controller.requestReconnect();
      expect(retries, [false]);
      for (var i = 0; i < 10; i++) {
        expect(controller.nextRetryDelay.inSeconds, lessThanOrEqualTo(30));
        controller.scheduleRetry();
      }
      time.elapse(const Duration(seconds: 30));
      expect(retries, [false, false]);
      controller.resetBackoff();
      expect(controller.nextRetryDelay, const Duration(seconds: 1));
      controller.stop();
      expect(time.pendingTimers, isEmpty);
    });
  });

  for (final retryFirst in [false, true]) {
    test(
      'wake coalesces old retry and activation (retry first: $retryFirst)',
      () {
        fakeAsync((time) {
          var now = DateTime.utc(2026);
          var fresh = 0;
          var retries = 0;
          final gate = Completer<void>();
          final controller = SessionReconnectController(
            retry: (_) => retries++,
            onFailure: (error, stack) => fail('$error'),
            now: () => now,
          );
          controller.attachFreshRestart((_, __) async {
            fresh++;
            await gate.future;
          });
          controller.scheduleRetry();
          now = now.add(const Duration(minutes: 10));
          if (retryFirst) {
            time.elapse(const Duration(seconds: 1));
          } else {
            controller.checkElapsed();
          }
          controller.checkElapsed();
          controller.requestReconnect();
          time.elapse(Duration.zero);
          time.flushMicrotasks();
          expect(fresh, 1);
          expect(retries, 0);
          expect(controller.isRestarting, isTrue);
          time.elapse(const Duration(seconds: 30));
          expect(fresh, 1);
          gate.complete();
          time.flushMicrotasks();
          expect(controller.isRestarting, isFalse);
          controller.requestReconnect();
          expect(retries, 1);
          controller.stop();
        });
      },
    );
  }

  test('periodic clock detects sleep without any lifecycle notification', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      var fresh = 0;
      final controller = SessionReconnectController(
        retry: (_) => fail('ordinary retry after long sleep'),
        onFailure: (error, stack) => fail('$error'),
        now: () => now,
      );
      controller.attachFreshRestart((_, __) async {
        fresh++;
      });
      now = now.add(const Duration(minutes: 5));
      time.elapse(const Duration(seconds: 5));
      time.flushMicrotasks();
      expect(fresh, 1);
      controller.stop();
    });
  });

  test('idle connected session and backward clock do not trigger restart', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      final controller = SessionReconnectController(
        retry: (_) => fail('unexpected retry'),
        onFailure: (error, stack) => fail('$error'),
        now: () => now,
      );
      controller.attachFreshRestart(
        (_, __) async => fail('unexpected restart'),
      );
      for (var i = 0; i < 120; i++) {
        now = now.add(const Duration(seconds: 5));
        time.elapse(const Duration(seconds: 5));
      }
      now = now.subtract(const Duration(hours: 1));
      expect(controller.checkElapsed(), isFalse);
      controller.stop();
    });
  });

  test('cancelling during cleanup prevents subsequent session start', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      final cleanup = Completer<void>();
      var starts = 0;
      final controller = SessionReconnectController(
        retry: (_) => fail('unexpected retry'),
        onFailure: (error, stack) => fail('$error'),
        now: () => now,
      );
      controller.attachFreshRestart((_, isCurrent) async {
        await cleanup.future;
        if (isCurrent()) starts++;
      });
      now = now.add(const Duration(minutes: 10));
      controller.checkElapsed();
      time.elapse(Duration.zero);
      controller.stop();
      cleanup.complete();
      time.flushMicrotasks();
      controller.checkElapsed();
      controller.requestReconnect();
      expect(starts, 0);
      expect(controller.isRestarting, isFalse);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('startup failure is reported and retry keeps the fresh path', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      var attempts = 0;
      final errors = <Object>[];
      final controller = SessionReconnectController(
        retry: (_) => fail('cannot reconnect a missing native session'),
        onFailure: (error, _) => errors.add(error),
        now: () => now,
      );
      controller.attachFreshRestart((_, __) async {
        attempts++;
        if (attempts == 1) throw StateError('failed start');
      });
      now = now.add(const Duration(minutes: 10));
      controller.requestReconnect();
      time.elapse(Duration.zero);
      time.flushMicrotasks();
      expect(errors, hasLength(1));
      expect(controller.isRestarting, isFalse);
      controller.requestReconnect();
      time.elapse(Duration.zero);
      time.flushMicrotasks();
      expect(attempts, 2);
      controller.stop();
    });
  });

  test(
    'late cancelled timers cannot restart and session reuse reenables retry',
    () {
      fakeAsync((time) {
        var retries = 0;
        final controller = SessionReconnectController(
          retry: (_) => retries++,
          onFailure: (error, _) => fail('$error'),
        );
        controller.scheduleRetry();
        controller.stop();
        time.elapse(const Duration(minutes: 1));
        expect(retries, 0);
        controller.sessionStarted();
        controller.requestReconnect();
        expect(retries, 1);
        controller.stop();
      });
    },
  );

  test('offline grace period is time based and resets with success', () {
    var now = DateTime.utc(2026);
    final controller = SessionReconnectController(
      retry: (_) {},
      onFailure: (error, _) => fail('$error'),
      now: () => now,
    );
    expect(controller.shouldRetryOffline(), isTrue);
    now = now.add(const Duration(seconds: 30));
    expect(controller.shouldRetryOffline(), isFalse);
    controller.resetBackoff();
    expect(controller.shouldRetryOffline(), isTrue);
    controller.stop();
  });

  test('fresh work leaves the native event dispatch zone', () {
    fakeAsync((time) {
      var now = DateTime.utc(2026);
      final key = Object();
      Object? observed = 'not started';
      final controller = SessionReconnectController(
        retry: (_) => fail('unexpected retry'),
        onFailure: (error, _) => fail('$error'),
        now: () => now,
      );
      controller.attachFreshRestart((_, __) async {
        observed = Zone.current[key];
      });
      now = now.add(const Duration(minutes: 10));
      runZoned(controller.requestReconnect, zoneValues: {key: 'old event'});
      time.elapse(Duration.zero);
      time.flushMicrotasks();
      expect(observed, isNull);
      controller.stop();
    });
  });
}
