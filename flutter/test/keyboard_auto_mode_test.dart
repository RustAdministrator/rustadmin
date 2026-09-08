import 'dart:async';

import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_input_controller.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_test/flutter_test.dart';

const _auto = KeyboardRoutingContext(
  keyboardMode: ControllerKeyboardMode.map,
  inputMode: ControllerKeyboardInputMode.auto,
  clientKind: KeyboardClientKind.android,
  peerIsAndroid: false,
);

class _Harness {
  final events = <String>[];
  final textChoices = <({bool literal, String language, String layout})>[];
  KeyboardRoutingContext context = _auto;
  Completer<void>? hidGate;
  bool allowed = true;
  late final controller = KeyboardInputController(
    canDispatch: () => allowed,
    sendHid: ({required key, required action, required lockMask}) async {
      events.add('${key.usage}:${action.name}');
      await hidGate?.future;
    },
    sendLegacy: ({required name, required down, required modifiers}) {
      events.add('legacy:$name:$down');
    },
    sendText:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
          required sourceLanguageTag,
          required sourceLayoutType,
          required literal,
        }) {
          events.add('text:$text');
          textChoices.add((
            literal: literal,
            language: sourceLanguageTag,
            layout: sourceLayoutType,
          ));
        },
  );

  Future<void> key(
    KeyboardInputOrigin origin,
    KeyboardIntentAction action, {
    int usage = 4,
    String? text = 'a',
    String language = '',
    String layout = '',
    Set<HidKey> modifiers = const {},
  }) => controller.handleAndWait(
    PhysicalKeyboardIntent(
      key: HidKey(7, usage),
      source: KeyboardInputSource.androidHardwareKeyboard,
      origin: origin,
      action: action,
      textCandidate: text,
      sourceLanguageTag: language,
      sourceLayoutType: layout,
      reportedModifiers: modifiers,
    ),
    context,
  );

  Future<void> batch(
    KeyboardInputOrigin origin, {
    String? text = 'a',
    int usage = 4,
  }) => controller.handleAndWait(
    PhysicalKeyPressBatchIntent(
      key: HidKey(7, usage),
      count: 3,
      origin: origin,
      textCandidate: text,
      source: KeyboardInputSource.androidHardwareKeyboard,
    ),
    context,
  );
}

void main() {
  test(
    'queued text retains its chosen semantic when a later context changes',
    () async {
      final h = _Harness()..hidGate = Completer<void>();
      final key = h.key(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.down,
      );
      final literal = h.controller.handleAndWait(
        const CommittedTextIntent(
          text: 'auto',
          source: KeyboardInputSource.androidNativeText,
          sourceLanguageTag: 'de-DE',
          sourceLayoutType: 'qwertz',
        ),
        _auto,
      );
      final physicalContext = const KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.map,
        inputMode: ControllerKeyboardInputMode.physical,
        clientKind: KeyboardClientKind.android,
        peerIsAndroid: false,
      );
      final compatible = h.controller.handleAndWait(
        const CommittedTextIntent(
          text: 'physical',
          source: KeyboardInputSource.androidNativeText,
          sourceLanguageTag: 'fr-FR',
          sourceLayoutType: 'azerty',
        ),
        physicalContext,
      );
      h.hidGate!.complete();
      await Future.wait([key, literal, compatible]);
      expect(h.textChoices, [
        (literal: true, language: 'de-DE', layout: 'qwertz'),
        (literal: false, language: 'fr-FR', layout: 'azerty'),
      ]);
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
    },
  );

  test(
    'text-routed key pins literal semantics and source metadata on repeat',
    () async {
      final h = _Harness();
      await h.key(
        KeyboardInputOrigin.ime,
        KeyboardIntentAction.down,
        language: 'de-DE',
        layout: 'qwertz',
      );
      h.context = const KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.map,
        inputMode: ControllerKeyboardInputMode.physical,
        clientKind: KeyboardClientKind.android,
        peerIsAndroid: false,
      );
      await h.key(
        KeyboardInputOrigin.ime,
        KeyboardIntentAction.repeat,
        language: 'fr-FR',
        layout: 'azerty',
      );
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      expect(
        h.textChoices,
        List.filled(2, (literal: true, language: 'de-DE', layout: 'qwertz')),
      );
    },
  );

  test(
    'explicit toolbar Shift keeps a native IME key on the command route',
    () async {
      final h = _Harness();
      await h.controller.handleAndWait(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.shift,
          action: SyntheticModifierAction.toggle,
        ),
        _auto,
      );
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.down);
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      await h.controller.idle;
      expect(h.events, ['225:down', '4:down', '4:up', '225:up']);
    },
  );

  test(
    'coalesced legacy owners retain the original transport key name',
    () async {
      final h = _Harness();
      Future<void> send(
        KeyboardInputOrigin origin,
        KeyboardIntentAction action,
        String name,
      ) => h.controller.handleAndWait(
        PhysicalKeyboardIntent(
          key: const HidKey(1, 0x1234),
          action: action,
          source: KeyboardInputSource.flutterKeyEvent,
          origin: origin,
          legacyFallbackName: name,
        ),
        _auto,
      );
      await send(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.down,
        'first',
      );
      await send(KeyboardInputOrigin.ime, KeyboardIntentAction.down, 'second');
      await send(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.up,
        'first',
      );
      await send(KeyboardInputOrigin.ime, KeyboardIntentAction.up, 'second');
      expect(h.events, [
        'legacy:first:true',
        'legacy:first:true',
        'legacy:first:false',
      ]);
    },
  );

  test('explicit Text and Physical keep their existing key routing', () async {
    for (final mode in [
      ControllerKeyboardInputMode.text,
      ControllerKeyboardInputMode.physical,
    ]) {
      for (final origin in KeyboardInputOrigin.values) {
        final h = _Harness()
          ..context = KeyboardRoutingContext(
            keyboardMode: ControllerKeyboardMode.map,
            inputMode: mode,
            clientKind: KeyboardClientKind.android,
            peerIsAndroid: false,
          );
        await h.key(origin, KeyboardIntentAction.down);
        await h.key(origin, KeyboardIntentAction.up);
        expect(
          h.events,
          mode == ControllerKeyboardInputMode.text
              ? ['text:a']
              : ['4:down', '4:up'],
        );
      }
    }
  });

  test(
    'commands and control characters never become printable IME text',
    () async {
      for (final usage in [0x28, 0x2a, 0x2b, 0x3a, 0x50, 0x58]) {
        final h = _Harness();
        await h.key(
          KeyboardInputOrigin.ime,
          KeyboardIntentAction.down,
          usage: usage,
          text: 'x',
        );
        await h.key(
          KeyboardInputOrigin.ime,
          KeyboardIntentAction.up,
          usage: usage,
        );
        expect(h.events, ['$usage:down', '$usage:up']);
      }
      for (final text in ['\n', '\t', '\u007f', '\u2028']) {
        final h = _Harness();
        await h.key(
          KeyboardInputOrigin.ime,
          KeyboardIntentAction.down,
          text: text,
        );
        await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
        expect(h.events, ['4:down', '4:up']);
      }
    },
  );

  test(
    'IME text route stays pinned on repeat and up after context change',
    () async {
      final h = _Harness();
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.down);
      h.context = const KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.map,
        inputMode: ControllerKeyboardInputMode.physical,
        clientKind: KeyboardClientKind.android,
        peerIsAndroid: false,
      );
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.repeat);
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      expect(h.events, ['text:a', 'text:a']);
    },
  );

  test(
    'hardware release does not remove an overlapping IME text owner',
    () async {
      final h = _Harness();
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.down);
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.down);
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.repeat);
      await h.batch(KeyboardInputOrigin.ime);
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      expect(h.events, [
        'text:a',
        '4:down',
        '4:up',
        'text:a',
        'text:a',
        'text:a',
        'text:a',
      ]);
    },
  );

  test('explicit modifier origins share one down and final up', () async {
    final h = _Harness();
    await h.key(
      KeyboardInputOrigin.hardware,
      KeyboardIntentAction.down,
      usage: 0xe1,
    );
    await h.key(
      KeyboardInputOrigin.ime,
      KeyboardIntentAction.down,
      usage: 0xe1,
    );
    await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up, usage: 0xe1);
    expect(h.controller.effectiveModifiers.shift, isTrue);
    expect(h.events, ['225:down']);
    await h.key(
      KeyboardInputOrigin.hardware,
      KeyboardIntentAction.up,
      usage: 0xe1,
    );
    expect(h.events, ['225:down', '225:up']);
  });

  test(
    'IME command report does not release a real hardware Control owner',
    () async {
      final h = _Harness();
      await h.key(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.down,
        usage: 0xe0,
      );
      await h.key(
        KeyboardInputOrigin.ime,
        KeyboardIntentAction.down,
        modifiers: {HidKey.controlLeft},
      );
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      expect(h.controller.effectiveModifiers.ctrl, isTrue);
      await h.key(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.up,
        usage: 0xe0,
      );
      expect(h.events, ['224:down', '4:down', '4:up', '224:up']);
    },
  );

  test('reset of queued overlapping physical owners releases once', () async {
    final h = _Harness()..hidGate = Completer<void>();
    final first = h.key(
      KeyboardInputOrigin.hardware,
      KeyboardIntentAction.down,
      usage: 0x50,
    );
    await Future<void>.delayed(Duration.zero);
    final second = h.key(
      KeyboardInputOrigin.ime,
      KeyboardIntentAction.down,
      usage: 0x50,
      text: null,
    );
    h.allowed = false;
    final reset = h.controller.reset(
      KeyboardResetReason.permissionRevoked,
      invalidatePending: true,
      allowBlockedReleases: true,
    );
    h.hidGate!.complete();
    await Future.wait([first, second, reset]);
    expect(h.events, ['80:down', '80:up']);
  });

  test(
    'duplicate down does not mutate a held owners reported modifiers',
    () async {
      final h = _Harness();
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.down);
      await h.key(
        KeyboardInputOrigin.hardware,
        KeyboardIntentAction.down,
        modifiers: {HidKey.altLeft},
      );
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
      expect(h.events, ['4:down', '4:up']);
    },
  );

  test('Auto uses text only for confirmed printable IME keys', () async {
    for (final origin in [
      KeyboardInputOrigin.hardware,
      KeyboardInputOrigin.ime,
      KeyboardInputOrigin.unknown,
    ]) {
      final h = _Harness();
      await h.key(origin, KeyboardIntentAction.down);
      await h.key(origin, KeyboardIntentAction.repeat);
      await h.key(origin, KeyboardIntentAction.up);
      expect(
        h.events,
        origin == KeyboardInputOrigin.ime
            ? ['text:a', 'text:a']
            : ['4:down', '4:repeat', '4:up'],
      );
    }
  });

  test('Auto IME reported Shift belongs to text and is not injected', () async {
    final h = _Harness();
    await h.key(
      KeyboardInputOrigin.ime,
      KeyboardIntentAction.down,
      text: '?',
      modifiers: {HidKey.shiftLeft},
    );
    await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up, text: null);
    expect(h.events, ['text:?']);
    expect(h.controller.effectiveModifiers.shift, isFalse);
  });

  test(
    'hardware held HID and IME text HID have independent lifetimes',
    () async {
      final h = _Harness();
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.down);
      await h.key(
        KeyboardInputOrigin.ime,
        KeyboardIntentAction.down,
        text: '@',
      );
      await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.repeat);
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
      expect(h.events, ['4:down', 'text:@', '4:repeat', '4:up']);
    },
  );

  test(
    'IME press batch remains text while hardware owns the same HID',
    () async {
      final h = _Harness();
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.down);
      await h.batch(KeyboardInputOrigin.ime, text: '@');
      await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
      expect(h.events, ['4:down', 'text:@', 'text:@', 'text:@', '4:up']);
    },
  );

  test('late IME up after reset cannot release a fresh hardware key', () async {
    final h = _Harness();
    await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.down);
    await h.controller.reset(
      KeyboardResetReason.inputModeChange,
      invalidatePending: true,
      allowBlockedReleases: true,
    );
    await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.down);
    await h.key(KeyboardInputOrigin.ime, KeyboardIntentAction.up);
    expect(h.events, ['text:a', '4:down']);
    await h.key(KeyboardInputOrigin.hardware, KeyboardIntentAction.up);
    expect(h.events.last, '4:up');
  });

  test('IME navigation stays physical and shares hardware ownership', () async {
    final h = _Harness();
    await h.key(
      KeyboardInputOrigin.hardware,
      KeyboardIntentAction.down,
      usage: 0x50,
      text: null,
    );
    await h.key(
      KeyboardInputOrigin.ime,
      KeyboardIntentAction.down,
      usage: 0x50,
      text: null,
    );
    await h.key(
      KeyboardInputOrigin.ime,
      KeyboardIntentAction.up,
      usage: 0x50,
      text: null,
    );
    expect(h.events, ['80:down', '80:repeat']);
    await h.key(
      KeyboardInputOrigin.hardware,
      KeyboardIntentAction.up,
      usage: 0x50,
      text: null,
    );
    expect(h.events.last, '80:up');
  });
}
