import 'dart:async';

import 'package:flutter_hbb/models/keyboard_command_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
