import 'dart:async';

import 'package:flutter_hbb/mobile/mobile_session_reconnect_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class ReconnectHarness {
  final resets = <bool>[];
  final events = <String>[];
  final resetBarriers = <bool, Completer<void>>{};
  Completer<void>? prepareBarrier;
  Completer<void>? connectBarrier;
  Object? resetError;
  Object? prepareError;
  Object? connectError;
  Object? startError;

  late final controller = MobileSessionReconnectController(
    resetSession: ({required closeSession}) async {
      resets.add(closeSession);
      final barrier = resetBarriers[closeSession];
      if (barrier != null) await barrier.future;
      if (resetError != null) throw resetError!;
    },
    prepareReconnect: () async {
      events.add('prepare');
      final barrier = prepareBarrier;
      if (barrier != null) await barrier.future;
      if (prepareError != null) throw prepareError!;
    },
    connect: () async {
      events.add('connect');
      final barrier = connectBarrier;
      if (barrier != null) await barrier.future;
      if (connectError != null) throw connectError!;
    },
    onReconnectStarted: () {
      events.add('started');
      if (startError != null) throw startError!;
    },
    onReconnectFailed: (error, _) => events.add('failed:$error'),
    onNotificationDisconnect: () => events.add('notification-disconnect'),
  );
}

void main() {
  test('background close waits before a foreground reconnect', () async {
    final harness = ReconnectHarness();
    final closeBarrier = Completer<void>();
    harness.resetBarriers[true] = closeBarrier;

    final background = harness.controller.enterBackground(
      closeSession: true,
      sessionClosed: false,
    );
    final foreground = harness.controller.enterForeground();
    await Future<void>.delayed(Duration.zero);

    expect(harness.resets, [true]);
    expect(harness.events, ['started']);
    closeBarrier.complete();
    await Future.wait([background, foreground]);

    expect(harness.resets, [true, false]);
    expect(harness.events, ['started', 'prepare', 'connect']);
    expect(harness.controller.phase, MobileSessionReconnectPhase.active);
  });

  test('recoverable close queues in background and reconnects once', () async {
    final harness = ReconnectHarness();
    harness.controller.handleSessionClosed(
      'background-timeout',
      isForeground: false,
    );
    harness.controller.handleSessionClosed(
      'background-native-disconnect',
      isForeground: false,
    );

    expect(harness.controller.reconnectPending, isTrue);
    expect(harness.resets, isEmpty);
    await harness.controller.enterForeground();

    expect(harness.resets, [false]);
    expect(harness.events, ['started', 'prepare', 'connect']);
    expect(harness.controller.phase, MobileSessionReconnectPhase.active);
  });

  test('duplicate foreground close events replace the stale attempt', () async {
    final harness = ReconnectHarness();
    final firstReset = Completer<void>();
    harness.resetBarriers[false] = firstReset;

    harness.controller.handleSessionClosed(
      'foreground-unhealthy',
      isForeground: true,
    );
    await Future<void>.delayed(Duration.zero);
    harness.controller.handleSessionClosed(
      'foreground-service-timeout',
      isForeground: true,
    );
    harness.resetBarriers.remove(false);
    firstReset.complete();
    while (harness.controller.reconnectInProgress) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(harness.resets, [false, false]);
    expect(harness.events, ['started', 'started', 'prepare', 'connect']);
    expect(harness.controller.phase, MobileSessionReconnectPhase.active);
  });

  test('dispose during reconnect prevents later operations', () async {
    final harness = ReconnectHarness();
    final resetBarrier = Completer<void>();
    harness.resetBarriers[false] = resetBarrier;

    harness.controller.handleSessionClosed(
      'foreground-unhealthy',
      isForeground: true,
    );
    await Future<void>.delayed(Duration.zero);
    harness.controller.dispose();
    resetBarrier.complete();
    while (harness.controller.reconnectInProgress) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(harness.events, ['started']);
    expect(harness.controller.phase, MobileSessionReconnectPhase.disposed);
  });

  test('dispose during background close prevents resume reconnect', () async {
    final harness = ReconnectHarness();
    final closeBarrier = Completer<void>();
    harness.resetBarriers[true] = closeBarrier;

    final background = harness.controller.enterBackground(
      closeSession: true,
      sessionClosed: false,
    );
    harness.controller.dispose();
    closeBarrier.complete();
    await background;
    await harness.controller.enterForeground();

    expect(harness.resets, [true]);
    expect(harness.events, isEmpty);
    expect(harness.controller.phase, MobileSessionReconnectPhase.disposed);
  });

  test('backgrounding during reconnect retires the stale attempt', () async {
    final harness = ReconnectHarness();
    final firstReset = Completer<void>();
    harness.resetBarriers[false] = firstReset;
    harness.controller.handleSessionClosed(
      'foreground-unhealthy',
      isForeground: true,
    );
    await Future<void>.delayed(Duration.zero);

    final background = harness.controller.enterBackground(
      closeSession: true,
      sessionClosed: false,
    );
    harness.resetBarriers.remove(false);
    firstReset.complete();
    await background;
    await harness.controller.enterForeground();

    expect(harness.resets, [false, true, false]);
    expect(harness.events, ['started', 'started', 'prepare', 'connect']);
    expect(harness.controller.phase, MobileSessionReconnectPhase.active);
  });

  test('notification disconnect is terminal and never reconnects', () async {
    final harness = ReconnectHarness();
    harness.controller.handleSessionClosed(
      'notification-disconnect',
      isForeground: true,
    );
    await harness.controller.enterForeground();

    expect(harness.events, ['notification-disconnect']);
    expect(harness.resets, isEmpty);
    expect(harness.controller.phase, MobileSessionReconnectPhase.disconnecting);
  });

  test('background close error is reported after foregrounding', () async {
    final harness = ReconnectHarness()..resetError = StateError('close failed');
    await harness.controller.enterBackground(
      closeSession: true,
      sessionClosed: false,
    );
    harness.resetError = null;

    await harness.controller.enterForeground();

    expect(harness.resets, [true]);
    expect(harness.events.first, 'started');
    expect(harness.events.last, contains('close failed'));
    expect(harness.controller.phase, MobileSessionReconnectPhase.disconnecting);
  });

  test('prepare failure terminates without starting a connection', () async {
    final harness = ReconnectHarness()
      ..prepareError = StateError('prepare failed');
    harness.controller.handleSessionClosed(
      'foreground-unhealthy',
      isForeground: true,
    );
    while (harness.controller.reconnectInProgress) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(harness.resets, [false]);
    expect(harness.events, ['started', 'prepare', contains('prepare failed')]);
    expect(harness.controller.phase, MobileSessionReconnectPhase.disconnecting);
  });

  test('reconnect-start callback failure uses the same failure path', () async {
    final harness = ReconnectHarness()..startError = StateError('ui failed');
    harness.controller.handleSessionClosed(
      'foreground-unhealthy',
      isForeground: true,
    );
    while (harness.controller.reconnectInProgress) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(harness.resets, isEmpty);
    expect(harness.events.first, 'started');
    expect(harness.events.last, contains('ui failed'));
    expect(harness.controller.phase, MobileSessionReconnectPhase.disconnecting);
  });

  test('unknown close reason does not change state', () async {
    final harness = ReconnectHarness();
    harness.controller.handleSessionClosed('unrelated', isForeground: true);
    await harness.controller.enterForeground();

    expect(harness.events, isEmpty);
    expect(harness.resets, isEmpty);
    expect(harness.controller.phase, MobileSessionReconnectPhase.active);
  });
}
