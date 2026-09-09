import 'dart:async';

import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_input_controller.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_text_policy.dart';
import 'package:flutter_test/flutter_test.dart';

KeyboardRoutingContext _context(ControllerKeyboardInputMode mode) =>
    KeyboardRoutingContext(
      keyboardMode: ControllerKeyboardMode.map,
      inputMode: mode,
      clientKind: KeyboardClientKind.android,
      peerIsAndroid: false,
    );

class _Harness {
  final events = <String>[];
  final pairs = <(int, int)>[];
  final rejected = <KeyboardInputRejection>[];
  bool allowed = true;
  Completer<int?>? gate;
  bool fail = false;
  var mode = ControllerKeyboardInputMode.auto;
  late final controller = KeyboardInputController(
    canDispatch: () => allowed,
    composeDeadKey: (accent, base) async {
      pairs.add((accent, base));
      if (fail) throw StateError('test');
      if (gate != null) return gate!.future;
      if (accent == base || base == 0x20) return accent;
      return (accent, base) == (0x5e, 0x65) ? 0xea : 0;
    },
    sendHid: ({required key, required action, required lockMask}) {
      events.add('${key.usage}:${action.name}');
    },
    sendLegacy: ({required name, required down, required modifiers}) {
      events.add('legacy:$name:$down');
    },
    sendText:
        ({
          required text,
          required literal,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
          required sourceLanguageTag,
          required sourceLayoutType,
        }) {
          expect(literal, isTrue);
          events.add('text:$text');
        },
    onInputRejected: rejected.add,
  );

  Future<void> key({
    int usage = 8,
    String? text,
    int? accent,
    KeyboardIntentAction action = KeyboardIntentAction.down,
    KeyboardInputOrigin origin = KeyboardInputOrigin.ime,
    String language = '',
    String layout = '',
  }) => controller.handleAndWait(
    PhysicalKeyboardIntent(
      key: HidKey(7, usage),
      action: action,
      source: KeyboardInputSource.androidHardwareKeyboard,
      origin: origin,
      textCandidate: text,
      deadKeyAccent: accent,
      sourceLanguageTag: language,
      sourceLayoutType: layout,
    ),
    _context(mode),
  );

  Future<void> dead({
    KeyboardInputOrigin origin = KeyboardInputOrigin.ime,
    String language = '',
    String layout = '',
  }) async {
    await key(
      usage: 0x34,
      accent: 0x5e,
      origin: origin,
      language: language,
      layout: layout,
    );
    await key(usage: 0x34, action: KeyboardIntentAction.up, origin: origin);
  }
}

void main() {
  test('held Backspace keeps its physical lease when cancelling an accent', () async {
    final h = _Harness();
    await h.key(usage: 0x2a);
    await h.dead();
    await h.key(usage: 0x2a, action: KeyboardIntentAction.repeat);
    await h.key(usage: 0x2a, action: KeyboardIntentAction.up);
    await h.key(text: 'e');
    expect(h.events, ['42:down', '42:repeat', '42:up', 'text:e']);
  });

  test('physical Shift in Text mode does not discard the pending accent', () async {
    final h = _Harness()..mode = ControllerKeyboardInputMode.text;
    await h.dead(origin: KeyboardInputOrigin.hardware);
    await h.key(usage: 0xe1, origin: KeyboardInputOrigin.hardware);
    await h.key(usage: 0xe1, origin: KeyboardInputOrigin.hardware,
      action: KeyboardIntentAction.repeat);
    await h.key(usage: 0xe1, origin: KeyboardInputOrigin.hardware,
      action: KeyboardIntentAction.up);
    await h.key(text: 'e', origin: KeyboardInputOrigin.hardware);
    expect(h.events, ['225:down', '225:repeat', '225:up', 'text:\u00ea']);
  });

  test('timed out native composition falls back once and releases the queue', () async {
    final h = _Harness()..gate = Completer<int?>();
    await h.dead();
    await h.key(text: 'e');
    h.gate!.complete(0xea);
    await h.key(usage: 9, text: 'f');
    expect(h.events, ['text:^e', 'text:f']);
  });

  test(
    'dead key stays local until a matching base and produces literal text',
    () async {
      final h = _Harness();
      await h.dead();
      expect(h.events, isEmpty);
      await h.key(text: 'e');
      await h.key(action: KeyboardIntentAction.up);
      expect(h.pairs, [(0x5e, 0x65)]);
      expect(h.events, ['text:\u00ea']);
    },
  );

  test(
    'space, repeated accent, unsupported pair and supplementary base survive',
    () async {
      for (final pair in [
        (' ', '^'),
        ('^', '^'),
        ('q', '^q'),
        ('\u{1f642}', '^\u{1f642}'),
      ]) {
        final h = _Harness();
        await h.dead();
        await h.key(text: pair.$1);
        expect(h.events, ['text:${pair.$2}']);
      }
    },
  );

  test(
    'a second dead key is paired, not silently replacing the first',
    () async {
      final h = _Harness();
      await h.dead();
      await h.dead();
      await h.key(text: 'e');
      expect(h.events, ['text:^', 'text:e']);
    },
  );

  test('failed native composition preserves both scalars', () async {
    final h = _Harness()..fail = true;
    await h.dead();
    await h.key(text: 'e');
    expect(h.events, ['text:^e']);
  });

  test(
    'asynchronous composition stays before later physical commands',
    () async {
      final h = _Harness()..gate = Completer<int?>();
      await h.dead();
      final text = h.key(text: 'e');
      final down = h.key(usage: 0x28);
      final up = h.key(usage: 0x28, action: KeyboardIntentAction.up);
      expect(h.events, isEmpty);
      h.gate!.complete(0xea);
      await Future.wait([text, down, up]);
      expect(h.events, ['text:\u00ea', '40:down', '40:up']);
    },
  );

  test(
    'reset retires a composition already awaiting native resolution',
    () async {
      final h = _Harness()..gate = Completer<int?>();
      await h.dead();
      final waiting = h.key(text: 'e');
      final reset = h.controller.reset(
        KeyboardResetReason.focusLoss,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
      h.gate!.complete(0xea);
      await Future.wait([waiting, reset]);
      expect(h.events, isEmpty);
      await h.key(usage: 9, text: 'f');
      expect(h.events, ['text:f']);
    },
  );

  test('permission recheck prevents send after native composition', () async {
    final h = _Harness()..gate = Completer<int?>();
    await h.dead();
    final waiting = h.key(text: 'e');
    h.allowed = false;
    h.gate!.complete(0xea);
    await waiting;
    expect(h.events, isEmpty);
  });

  test('all reset reasons clear a pending accent after its key up', () async {
    for (final reason in KeyboardResetReason.values) {
      final h = _Harness();
      await h.dead();
      await h.controller.reset(reason);
      expect(h.controller.diagnostics.resets, 1);
      await h.key(text: 'e');
      expect(h.events, ['text:e']);
    }
  });

  test(
    'Backspace cancels only the unsent accent and owns its up and repeat',
    () async {
      final h = _Harness();
      await h.dead();
      await h.key(usage: 0x2a);
      await h.key(usage: 0x2a, action: KeyboardIntentAction.repeat);
      await h.key(usage: 0x2a, action: KeyboardIntentAction.up);
      await h.key(text: 'e');
      expect(h.events, ['text:e']);
    },
  );

  test('authoritative commit is not composed twice', () async {
    final h = _Harness();
    await h.dead();
    await h.controller.handleAndWait(
      const CommittedTextIntent(
        text: '\u00ea',
        source: KeyboardInputSource.futureIme,
      ),
      _context(h.mode),
    );
    await h.key(text: 'e');
    expect(h.pairs, isEmpty);
    expect(h.events, ['text:\u00ea', 'text:e']);
  });

  test('origin, layout and mode changes discard pending state', () async {
    for (final change in ['origin', 'language', 'layout', 'mode']) {
      final h = _Harness()..mode = ControllerKeyboardInputMode.text;
      await h.dead();
      if (change == 'mode') h.mode = ControllerKeyboardInputMode.auto;
      await h.key(
        text: 'e',
        origin: change == 'origin'
            ? KeyboardInputOrigin.hardware
            : KeyboardInputOrigin.ime,
        language: change == 'language' ? 'de' : '',
        layout: change == 'layout' ? 'azerty' : '',
      );
      expect(h.pairs, isEmpty, reason: change);
      expect(h.events, ['text:e'], reason: change);
    }
  });

  test('Auto hardware and Physical keep dead keys on HID', () async {
    for (final mode in [
      ControllerKeyboardInputMode.auto,
      ControllerKeyboardInputMode.physical,
    ]) {
      final h = _Harness()..mode = mode;
      final origin = mode == ControllerKeyboardInputMode.auto
          ? KeyboardInputOrigin.hardware
          : KeyboardInputOrigin.ime;
      await h.dead(origin: origin);
      await h.key(text: 'e', origin: origin);
      expect(h.pairs, isEmpty);
      expect(h.events, ['52:down', '52:up', '8:down']);
    }
  });

  test('rejected base leaves the pending accent available for retry', () async {
    final h = _Harness();
    await h.dead();
    await h.key(text: 'x' * KeyboardTextPolicy.maxOperationBytes);
    await h.key(action: KeyboardIntentAction.up);
    expect(h.rejected, [KeyboardInputRejection.textTooLarge]);
    await h.key(text: 'e');
    expect(h.events, ['text:\u00ea']);
  });

  test(
    'held dead-key repeat and complete press batches use the same pairing',
    () async {
      final h = _Harness();
      await h.key(usage: 0x34, accent: 0x5e);
      await h.key(
        usage: 0x34,
        accent: 0x5e,
        action: KeyboardIntentAction.repeat,
      );
      await h.key(usage: 0x34, action: KeyboardIntentAction.up);
      await h.controller.handleAndWait(
        const PhysicalKeyPressBatchIntent(
          key: HidKey(7, 0x34),
          count: 3,
          deadKeyAccent: 0x5e,
          origin: KeyboardInputOrigin.ime,
          source: KeyboardInputSource.androidHardwareKeyboard,
        ),
        _context(h.mode),
      );
      await h.key(text: 'e');
      expect(h.events, ['text:^', 'text:^', 'text:\u00ea']);
    },
  );
}
