import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_hbb/models/keyboard_text_policy.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  final gate = Completer<void>();
  final events = <String>[];
  final rejected = <KeyboardInputRejection>[];
  bool allowed = true;
  bool failText = false;
  late final dispatcher = KeyboardDispatcher(
    canDispatch: () => allowed,
    onInputRejected: rejected.add,
    sendHid: ({required key, required action, required lockMask}) {
      events.add('hid:$action');
    },
    sendLegacy: ({required name, required down, required modifiers}) {},
    sendText:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
          required sourceLanguageTag,
          required sourceLayoutType,
          required literal,
        }) async {
          events.add(text);
          await gate.future;
          if (failText) throw StateError('test transport failure');
        },
  );
}

CommittedTextDispatch _text(String value, {int before = 0, int after = 0}) =>
    CommittedTextDispatch(
      text: value,
      source: KeyboardInputSource.androidNativeText,
      deleteBeforeGraphemes: before,
      deleteAfterGraphemes: after,
    );

void main() {
  test('UTF-8 admission preserves exact boundaries and validates scalars', () {
    for (final unit in [
      'a',
      '\u00e9',
      '\u20ac',
      '\u{1f642}',
      'e\u0301',
      '\u{1f469}\u200d\u{1f4bb}',
    ]) {
      final count =
          KeyboardTextPolicy.maxOperationBytes ~/ utf8.encode(unit).length;
      final exact = List.filled(count, unit).join();
      expect(KeyboardTextPolicy.inspect(exact).rejection, isNull);
      expect(
        KeyboardTextPolicy.inspect(exact).bytes,
        utf8.encode(exact).length,
      );
      expect(
        KeyboardTextPolicy.inspect(exact + unit).rejection,
        KeyboardInputRejection.textTooLarge,
      );
    }
    for (final units in [
      [0xd800],
      [0xdc00],
      [0xd800, 0x61],
      [0xd800, 0xd800],
    ]) {
      expect(
        KeyboardTextPolicy.inspect(String.fromCharCodes(units)).rejection,
        KeyboardInputRejection.invalidText,
      );
    }
  });

  test(
    'one whole long operation is delivered before the next operation',
    () async {
      final h = _Harness();
      final first = List.filled(4096, 'a').join();
      final a = h.dispatcher.dispatchAll([_text(first)]);
      final b = h.dispatcher.dispatchAll([_text('last')]);
      expect(h.events, [first]);
      expect(h.dispatcher.pendingTextBytes, 4100);
      h.gate.complete();
      await Future.wait([a, b]);
      await h.dispatcher.idle;
      expect(h.events, [first, 'last']);
      expect(h.dispatcher.pendingTextBytes, 0);
      expect(h.dispatcher.pendingTextOperations, 0);
    },
  );

  test(
    'full text budget rejects atomically but permits owned key-up',
    () async {
      final h = _Harness();
      final lease = KeyboardPhysicalDispatchLease(
        key: const HidKey(7, 4),
        transport: KeyboardPhysicalTransport.hid,
      );
      PhysicalKeyboardDispatch key(KeyboardIntentAction action) =>
          PhysicalKeyboardDispatch(
            lease: lease,
            action: action,
            modifiers: const KeyboardModifiers(),
            source: KeyboardInputSource.androidHardwareKeyboard,
          );
      await h.dispatcher.dispatchAll([key(KeyboardIntentAction.down)]);
      final full = List.filled(65536, 'a').join();
      final accepted = h.dispatcher.tryDispatchAll([_text(full)]);
      expect(accepted.accepted, isTrue);
      final rejected = h.dispatcher.tryDispatchAll([
        key(KeyboardIntentAction.repeat),
        _text('x'),
      ]);
      expect(rejected.accepted, isFalse);
      expect(h.rejected, [KeyboardInputRejection.textQueueFull]);
      h.allowed = false;
      final release = h.dispatcher.dispatchAll([key(KeyboardIntentAction.up)]);
      h.gate.complete();
      await Future.wait([accepted.completion, release]);
      expect(h.events, [
        'hid:KeyboardIntentAction.down',
        full,
        'hid:KeyboardIntentAction.up',
      ]);
      expect(h.dispatcher.pendingTextBytes, 0);
    },
  );

  test('cancellation drops queued text and refunds all reservations', () async {
    final h = _Harness();
    final running = h.dispatcher.dispatchAll([_text('started')]);
    final pending = h.dispatcher.dispatchAll([_text('cancelled', before: 65)]);
    h.dispatcher.invalidatePending();
    h.gate.complete();
    await Future.wait([running, pending]);
    await h.dispatcher.idle;
    expect(h.events, ['started']);
    expect(h.dispatcher.pendingTextBytes, 0);
    expect(h.dispatcher.pendingTextOperations, 0);
    expect(h.dispatcher.pendingEditGraphemes, 0);
    await h.dispatcher.dispatchAll([_text('fresh')]);
    expect(h.events, ['started', 'fresh']);
  });

  test('zero-byte edits have operation and deletion budgets', () async {
    final h = _Harness();
    final accepted = h.dispatcher.tryDispatchAll(
      List.generate(64, (_) => _text('', before: 1)),
    );
    expect(accepted.accepted, isTrue);
    expect(
      h.dispatcher.tryDispatchAll([_text('', before: 1)]).accepted,
      isFalse,
    );
    h.gate.complete();
    await accepted.completion;
    expect(h.dispatcher.pendingTextOperations, 0);
    expect(h.events.length, 64);
    final second = _Harness();
    final bounded = second.dispatcher.tryDispatchAll([
      _text('', before: 65536),
    ]);
    expect(bounded.accepted, isTrue);
    expect(
      second.dispatcher.tryDispatchAll([_text('', after: 1)]).accepted,
      isFalse,
    );
    for (final invalid in [
      _text('', before: -1),
      _text('', before: 65536, after: 1),
    ]) {
      expect(second.dispatcher.tryDispatchAll([invalid]).accepted, isFalse);
      expect(second.rejected.last, KeyboardInputRejection.invalidText);
    }
    second.gate.complete();
    await bounded.completion;
    expect(second.dispatcher.pendingEditGraphemes, 0);
  });

  test('transport failure and permission skips release reservations', () async {
    final h = _Harness()..failText = true;
    final first = h.dispatcher.dispatchAll([_text('fails')]);
    final skipped = h.dispatcher.dispatchAll([_text('skipped')]);
    h.allowed = false;
    h.gate.complete();
    await Future.wait([first, skipped]);
    expect(h.events, ['fails']);
    expect(h.dispatcher.pendingTextBytes, 0);
    expect(h.dispatcher.pendingTextOperations, 0);
  });
}
