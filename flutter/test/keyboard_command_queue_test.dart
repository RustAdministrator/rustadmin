import 'dart:async';

import 'package:flutter_hbb/models/keyboard_command_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleanup retains FIFO through repeated cancellation', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final queue = KeyboardCommandQueue();
    final started = queue.enqueue(() async {
      calls.add('started');
      await gate.future;
    });
    final stale = queue.enqueue(() async => calls.add('stale'));
    final cleanup = queue.enqueue(
      () async => calls.add('cleanup'),
      keepOnCancel: true,
    );
    queue.cancelPending();
    queue.cancelPending();
    final fresh = queue.enqueue(() async => calls.add('fresh'));
    gate.complete();
    await Future.wait([started, stale, cleanup, fresh]);
    expect(calls, ['started', 'cleanup', 'fresh']);
  });

  test('commands execute strictly in enqueue order', () async {
    final firstGate = Completer<void>();
    final calls = <String>[];
    final queue = KeyboardCommandQueue();

    final first = queue.enqueue(() async {
      calls.add('first-start');
      await firstGate.future;
      calls.add('first-end');
    });
    final second = queue.enqueue(() async {
      calls.add('second');
    });
    await Future<void>.delayed(Duration.zero);

    expect(calls, ['first-start']);
    firstGate.complete();
    await Future.wait([first, second]);
    expect(calls, ['first-start', 'first-end', 'second']);
  });

  test('a failed command does not poison later commands', () async {
    final errors = <Object>[];
    final calls = <String>[];
    final queue = KeyboardCommandQueue(
      onError: (error, _) => errors.add(error),
    );

    await queue.enqueue(() async => throw StateError('failed'));
    await queue.enqueue(() async => calls.add('after-failure'));

    expect(errors, hasLength(1));
    expect(calls, ['after-failure']);
  });

  test(
    'cancellation skips pending commands but accepts new commands',
    () async {
      final firstGate = Completer<void>();
      final calls = <String>[];
      final queue = KeyboardCommandQueue();

      final first = queue.enqueue(() async {
        calls.add('first');
        await firstGate.future;
      });
      final stale = queue.enqueue(() async => calls.add('stale'));
      await Future<void>.delayed(Duration.zero);
      queue.cancelPending();
      final fresh = queue.enqueue(() async => calls.add('fresh'));
      firstGate.complete();
      await Future.wait([first, stale, fresh]);

      expect(calls, ['first', 'fresh']);
    },
  );
}
