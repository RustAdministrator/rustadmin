import 'dart:async';

import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_hbb/models/keyboard_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

class _TransportEvent {
  const _TransportEvent({
    required this.kind,
    this.key,
    this.action,
    this.name,
    this.text,
    this.deleteBeforeGraphemes = 0,
    this.deleteAfterGraphemes = 0,
    this.modifiers = const KeyboardModifiers(),
  });

  final String kind;
  final HidKey? key;
  final KeyboardIntentAction? action;
  final String? name;
  final String? text;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;
  final KeyboardModifiers modifiers;
}

class _Harness {
  final events = <_TransportEvent>[];
  bool allowed = true;
  Completer<void>? hidGate;
  late final KeyboardDispatcher dispatcher = KeyboardDispatcher(
    canDispatch: () => allowed,
    sendHid: ({required key, required action, required lockMask}) async {
      events.add(_TransportEvent(kind: 'hid', key: key, action: action));
      await hidGate?.future;
    },
    sendLegacy: ({required name, required down, required modifiers}) {
      events.add(
        _TransportEvent(
          kind: 'legacy',
          name: name,
          action: down ? KeyboardIntentAction.down : KeyboardIntentAction.up,
          modifiers: modifiers,
        ),
      );
    },
    sendText:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
          required sourceLanguageTag,
          required sourceLayoutType,
        }) {
          events.add(
            _TransportEvent(
              kind: 'text',
              text: text,
              deleteBeforeGraphemes: deleteBeforeGraphemes,
              deleteAfterGraphemes: deleteAfterGraphemes,
            ),
          );
        },
  );
  late final KeyboardStateMachine state = KeyboardStateMachine(
    dispatcher: dispatcher,
  );
}

const _desktopMap = KeyboardRoutingContext(
  keyboardMode: ControllerKeyboardMode.map,
  inputMode: ControllerKeyboardInputMode.auto,
  clientKind: KeyboardClientKind.desktop,
  peerIsAndroid: false,
);

const _desktopLegacy = KeyboardRoutingContext(
  keyboardMode: ControllerKeyboardMode.legacy,
  inputMode: ControllerKeyboardInputMode.auto,
  clientKind: KeyboardClientKind.desktop,
  peerIsAndroid: false,
);

PhysicalKeyboardIntent _physical(
  HidKey key,
  KeyboardIntentAction action, {
  String? text,
  String? legacyFallbackName,
  KeyboardInputSource source = KeyboardInputSource.flutterKeyEvent,
}) => PhysicalKeyboardIntent(
  key: key,
  action: action,
  source: source,
  textCandidate: text,
  legacyFallbackName: legacyFallbackName,
);

void main() {
  group('desktop mode selection', () {
    test('Legacy and Translate do not enter Map transport', () {
      expect(
        shouldUseDesktopMapMode(
          isDesktop: true,
          isWebDesktop: false,
          keyboardMode: ControllerKeyboardMode.legacy,
        ),
        isFalse,
      );
      expect(
        shouldUseDesktopMapMode(
          isDesktop: true,
          isWebDesktop: false,
          keyboardMode: ControllerKeyboardMode.translate,
        ),
        isFalse,
      );
    });

    test('Map enters Map transport on native and web desktop', () {
      expect(
        shouldUseDesktopMapMode(
          isDesktop: true,
          isWebDesktop: false,
          keyboardMode: ControllerKeyboardMode.map,
        ),
        isTrue,
      );
      expect(
        shouldUseDesktopMapMode(
          isDesktop: false,
          isWebDesktop: true,
          keyboardMode: ControllerKeyboardMode.map,
        ),
        isTrue,
      );
    });
  });

  group('modifier independence', () {
    for (final pair in <(HidKey, HidKey, String)>[
      (HidKey.shiftLeft, HidKey.shiftRight, 'Shift'),
      (HidKey.controlLeft, HidKey.controlRight, 'Control'),
      (HidKey.altLeft, HidKey.altRight, 'Alt'),
      (HidKey.metaLeft, HidKey.metaRight, 'Meta'),
    ]) {
      test('${pair.$3} sides release independently', () async {
        final harness = _Harness();
        harness.state.handle(
          _physical(pair.$1, KeyboardIntentAction.down),
          _desktopMap,
        );
        harness.state.handle(
          _physical(pair.$2, KeyboardIntentAction.down),
          _desktopMap,
        );
        harness.state.handle(
          _physical(pair.$1, KeyboardIntentAction.up),
          _desktopMap,
        );

        expect(harness.state.physicallyPressedKeys, contains(pair.$2));
        expect(
          harness.state.effectiveModifiers.isActive(
            pair.$2.modifier == CanonicalModifier.control
                ? MobileModifierKey.ctrl
                : pair.$2.modifier == CanonicalModifier.shift
                ? MobileModifierKey.shift
                : pair.$2.modifier == CanonicalModifier.alt
                ? MobileModifierKey.alt
                : MobileModifierKey.command,
          ),
          isTrue,
        );

        harness.state.handle(
          _physical(pair.$2, KeyboardIntentAction.up),
          _desktopMap,
        );
        await harness.state.idle;
        expect(harness.state.physicallyPressedKeys, isEmpty);
      });
    }
  });

  test('ignored Meta never leaks into a following legacy key', () async {
    final harness = _Harness();
    const context = KeyboardRoutingContext(
      keyboardMode: ControllerKeyboardMode.legacy,
      inputMode: ControllerKeyboardInputMode.auto,
      clientKind: KeyboardClientKind.desktop,
      peerIsAndroid: false,
      ignoreMeta: true,
    );
    const keyA = HidKey(HidKey.keyboardUsagePage, 0x04);

    harness.state.handle(
      _physical(HidKey.metaLeft, KeyboardIntentAction.down),
      context,
    );
    harness.state.handle(_physical(keyA, KeyboardIntentAction.down), context);
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), context);
    harness.state.handle(
      _physical(HidKey.metaLeft, KeyboardIntentAction.up),
      context,
    );
    await harness.state.idle;

    expect(harness.events.map((event) => event.name), ['VK_A', 'VK_A']);
    expect(harness.events.every((event) => !event.modifiers.command), isTrue);
    expect(harness.state.effectiveModifiers.command, isFalse);
  });

  test('physical route produces down repeat and up without a click', () async {
    final harness = _Harness();
    const keyA = HidKey(0x07, 0x04);
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.down, text: 'a'),
      _desktopMap,
    );
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.repeat, text: 'a'),
      _desktopMap,
    );
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), _desktopMap);
    await harness.state.idle;

    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.repeat,
      KeyboardIntentAction.up,
    ]);
    expect(
      harness.events,
      everyElement(predicate<_TransportEvent>((event) => event.kind == 'hid')),
    );
  });

  test('modifier repeat observed after focus is released normally', () async {
    final harness = _Harness();
    harness.state.handle(
      _physical(HidKey.shiftRight, KeyboardIntentAction.repeat),
      _desktopMap,
    );
    harness.state.handle(
      _physical(HidKey.shiftRight, KeyboardIntentAction.up),
      _desktopMap,
    );
    await harness.state.idle;

    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.repeat,
      KeyboardIntentAction.up,
    ]);
    expect(harness.state.activeRouteCount, 0);
    expect(harness.state.effectiveModifiers.shift, isFalse);
  });

  test(
    'duplicate ordinary down is ignored instead of becoming repeat',
    () async {
      final harness = _Harness();
      const keyA = HidKey(0x07, 0x04);
      harness.state.handle(
        _physical(keyA, KeyboardIntentAction.down),
        _desktopMap,
      );
      harness.state.handle(
        _physical(keyA, KeyboardIntentAction.down),
        _desktopMap,
      );
      harness.state.handle(
        _physical(keyA, KeyboardIntentAction.up),
        _desktopMap,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
      ]);
      expect(harness.state.diagnostics.duplicateDowns, 1);
    },
  );

  test('text route dispatches text once and suppresses physical up', () async {
    final harness = _Harness();
    const textMode = KeyboardRoutingContext(
      keyboardMode: ControllerKeyboardMode.map,
      inputMode: ControllerKeyboardInputMode.text,
      clientKind: KeyboardClientKind.desktop,
      peerIsAndroid: false,
    );
    const keyA = HidKey(0x07, 0x04);
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.down, text: 'a'),
      textMode,
    );
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), _desktopMap);
    await harness.state.idle;

    expect(harness.events, hasLength(1));
    expect(harness.events.single.kind, 'text');
    expect(harness.events.single.text, 'a');
  });

  test('duplicate ordinary down does not duplicate text dispatch', () async {
    final harness = _Harness();
    const textMode = KeyboardRoutingContext(
      keyboardMode: ControllerKeyboardMode.map,
      inputMode: ControllerKeyboardInputMode.text,
      clientKind: KeyboardClientKind.desktop,
      peerIsAndroid: false,
    );
    const keyA = HidKey(0x07, 0x04);
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.down, text: 'a'),
      textMode,
    );
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.down, text: 'a'),
      textMode,
    );
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), textMode);
    await harness.state.idle;

    expect(harness.events.map((event) => event.kind), ['text']);
    expect(harness.state.diagnostics.duplicateDowns, 1);
  });

  test('committed text deletion stays on the ordered text route', () async {
    final harness = _Harness();
    harness.state.handle(
      const CommittedTextIntent(
        text: '',
        source: KeyboardInputSource.androidNativeText,
        deleteBeforeGraphemes: 2,
        deleteAfterGraphemes: 1,
      ),
      _desktopLegacy,
    );
    await harness.state.idle;

    expect(harness.events, hasLength(1));
    expect(harness.events.single.kind, 'text');
    expect(harness.events.single.text, isEmpty);
    expect(harness.events.single.deleteBeforeGraphemes, 2);
    expect(harness.events.single.deleteAfterGraphemes, 1);
  });

  test(
    'key-up retains the original route instead of recalculating mode',
    () async {
      final harness = _Harness();
      const keyA = HidKey(0x07, 0x04);
      harness.state.handle(
        _physical(keyA, KeyboardIntentAction.down),
        _desktopLegacy,
      );
      harness.state.handle(
        _physical(keyA, KeyboardIntentAction.up),
        _desktopMap,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.kind), ['legacy', 'legacy']);
    },
  );

  test(
    'legacy fallback retains framework text for an unmapped physical key',
    () async {
      final harness = _Harness();
      const periodKey = HidKey(0x07, 0x37);
      harness.state.handle(
        _physical(periodKey, KeyboardIntentAction.down, text: '.'),
        _desktopLegacy,
      );
      harness.state.handle(
        _physical(periodKey, KeyboardIntentAction.up),
        _desktopMap,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.name), ['.', '.']);
      expect(harness.events.map((event) => event.kind), ['legacy', 'legacy']);
    },
  );

  test('unknown and duplicate key-up are idempotent', () async {
    final harness = _Harness();
    const keyA = HidKey(0x07, 0x04);
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), _desktopMap);
    harness.state.handle(_physical(keyA, KeyboardIntentAction.up), _desktopMap);
    await harness.state.idle;

    expect(harness.events, isEmpty);
    expect(harness.state.diagnostics.unknownKeyUps, 2);
  });

  test('queued transport rechecks permission before dispatch', () async {
    final harness = _Harness();
    harness.hidGate = Completer<void>();
    harness.state.handle(
      _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.down),
      _desktopMap,
    );
    harness.state.handle(
      _physical(const HidKey(0x07, 0x05), KeyboardIntentAction.down),
      _desktopMap,
    );
    await Future<void>.delayed(Duration.zero);
    harness.allowed = false;
    harness.hidGate!.complete();
    await harness.state.idle;

    expect(harness.events.map((event) => event.key), [
      const HidKey(0x07, 0x04),
    ]);
  });

  test('focus reset releases dispatched keys exactly once', () async {
    final harness = _Harness();
    const keyA = HidKey(0x07, 0x04);
    harness.state.handle(
      _physical(keyA, KeyboardIntentAction.down),
      _desktopMap,
    );
    await harness.state.reset(KeyboardResetReason.focusLoss);
    await harness.state.reset(KeyboardResetReason.focusLoss);
    await harness.state.idle;

    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
    expect(harness.state.activeRouteCount, 0);
  });

  test('text-routed active keys do not emit release during reset', () async {
    final harness = _Harness();
    const textMode = KeyboardRoutingContext(
      keyboardMode: ControllerKeyboardMode.map,
      inputMode: ControllerKeyboardInputMode.text,
      clientKind: KeyboardClientKind.desktop,
      peerIsAndroid: false,
    );
    harness.state.handle(
      _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.down, text: 'a'),
      textMode,
    );
    await harness.state.reset(KeyboardResetReason.inputModeChange);

    expect(harness.events.map((event) => event.kind), ['text']);
    expect(harness.state.activeRouteCount, 0);
  });

  test('synthetic one-shot release does not clear physical modifier', () async {
    final harness = _Harness();
    harness.state.handle(
      _physical(HidKey.shiftLeft, KeyboardIntentAction.down),
      _desktopLegacy,
    );
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.shift,
        action: SyntheticModifierAction.toggle,
      ),
      _desktopLegacy,
    );
    harness.state.handle(
      _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.down),
      _desktopLegacy,
    );
    harness.state.handle(
      _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.up),
      _desktopLegacy,
    );
    await harness.state.idle;

    expect(harness.state.effectiveModifiers.shift, isTrue);
    expect(
      harness.state.mobileModifierState.modeFor(MobileModifierKey.shift),
      MobileModifierMode.off,
    );
  });

  test(
    'reset coalesces matching physical and synthetic modifier release',
    () async {
      final harness = _Harness();
      harness.state.handle(
        _physical(HidKey.controlLeft, KeyboardIntentAction.down),
        _desktopLegacy,
      );
      harness.state.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.lock,
        ),
        _desktopLegacy,
      );

      await harness.state.reset(KeyboardResetReason.focusLoss);

      expect(harness.events.map((event) => event.name), [
        'VK_CONTROL',
        'VK_CONTROL',
      ]);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
      ]);
    },
  );

  test('repeated reset releases a synthetic modifier exactly once', () async {
    final harness = _Harness();
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.alt,
        action: SyntheticModifierAction.lock,
      ),
      _desktopLegacy,
    );

    await harness.state.reset(KeyboardResetReason.keyboardHide);
    await harness.state.reset(KeyboardResetReason.keyboardHide);

    expect(harness.events.map((event) => event.key), [
      HidKey.altLeft,
      HidKey.altLeft,
    ]);
    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
    expect(harness.state.mobileModifierState.hasActive, isFalse);
  });

  test(
    'toolbar shortcut orders modifier down before key and modifier up last',
    () async {
      final harness = _Harness();
      harness.state.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.toggle,
        ),
        _desktopLegacy,
      );
      harness.state.handle(
        _physical(
          const HidKey(0x07, 0x06),
          KeyboardIntentAction.down,
          source: KeyboardInputSource.mobileToolbar,
          legacyFallbackName: 'VK_C',
        ),
        _desktopLegacy,
      );
      harness.state.handle(
        _physical(
          const HidKey(0x07, 0x06),
          KeyboardIntentAction.up,
          source: KeyboardInputSource.mobileToolbar,
          legacyFallbackName: 'VK_C',
        ),
        _desktopLegacy,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.kind), [
        'hid',
        'legacy',
        'legacy',
        'hid',
      ]);
      expect(harness.events.map((event) => event.key), [
        HidKey.controlLeft,
        null,
        null,
        HidKey.controlLeft,
      ]);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
        KeyboardIntentAction.up,
      ]);
    },
  );

  test('synthetic modifier retains a matching physical down', () async {
    final harness = _Harness();
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.control,
        action: SyntheticModifierAction.lock,
      ),
      _desktopLegacy,
    );
    harness.state.handle(
      _physical(HidKey.controlLeft, KeyboardIntentAction.down),
      _desktopLegacy,
    );
    harness.state.handle(
      _physical(HidKey.controlLeft, KeyboardIntentAction.up),
      _desktopLegacy,
    );
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.control,
        action: SyntheticModifierAction.release,
      ),
      _desktopLegacy,
    );
    await harness.state.idle;

    expect(harness.events.map((event) => event.key), [
      HidKey.controlLeft,
      HidKey.controlLeft,
    ]);
    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
    expect(harness.events.map((event) => event.kind), ['hid', 'hid']);
  });

  test('synthetic modifier takes ownership before physical release', () async {
    final harness = _Harness();
    harness.state.handle(
      _physical(HidKey.controlLeft, KeyboardIntentAction.down),
      _desktopLegacy,
    );
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.control,
        action: SyntheticModifierAction.lock,
      ),
      _desktopLegacy,
    );
    harness.state.handle(
      _physical(HidKey.controlLeft, KeyboardIntentAction.up),
      _desktopLegacy,
    );
    harness.state.handle(
      const SyntheticModifierIntent(
        modifier: CanonicalModifier.control,
        action: SyntheticModifierAction.release,
      ),
      _desktopLegacy,
    );
    await harness.state.idle;

    expect(harness.events.map((event) => event.name), [
      'VK_CONTROL',
      'VK_CONTROL',
    ]);
    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
    expect(harness.events.map((event) => event.kind), ['legacy', 'legacy']);
  });

  test(
    'synthetic modifier surrounds Android HID input in queue order',
    () async {
      final harness = _Harness();
      const androidContext = KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.legacy,
        inputMode: ControllerKeyboardInputMode.auto,
        clientKind: KeyboardClientKind.android,
        peerIsAndroid: false,
      );
      const keyA = HidKey(0x07, 0x04);
      harness.state.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.toggle,
        ),
        androidContext,
      );
      harness.state.handle(
        _physical(
          keyA,
          KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
        ),
        androidContext,
      );
      harness.state.handle(
        _physical(
          keyA,
          KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
        ),
        androidContext,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.kind), [
        'hid',
        'hid',
        'hid',
        'hid',
      ]);
      expect(harness.events.map((event) => event.key), [
        HidKey.controlLeft,
        keyA,
        keyA,
        HidKey.controlLeft,
      ]);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
        KeyboardIntentAction.up,
      ]);
    },
  );

  test(
    'Android reported modifiers are owned and ordered by the state machine',
    () async {
      final harness = _Harness();
      const keyA = HidKey(0x07, 0x04);
      harness.state.handle(
        PhysicalKeyboardIntent(
          key: keyA,
          action: KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
          reportedModifiers: <HidKey>{HidKey.shiftLeft},
        ),
        _desktopMap,
      );
      harness.state.handle(
        PhysicalKeyboardIntent(
          key: keyA,
          action: KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
          reportedModifiers: <HidKey>{HidKey.shiftLeft},
        ),
        _desktopMap,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.key), [
        HidKey.shiftLeft,
        keyA,
        keyA,
        HidKey.shiftLeft,
      ]);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
        KeyboardIntentAction.up,
      ]);
    },
  );

  test(
    'reported modifier does not duplicate an explicit modifier owner',
    () async {
      final harness = _Harness();
      const keyA = HidKey(0x07, 0x04);
      harness.state.handle(
        _physical(
          HidKey.shiftLeft,
          KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
        ),
        _desktopMap,
      );
      harness.state.handle(
        PhysicalKeyboardIntent(
          key: keyA,
          action: KeyboardIntentAction.down,
          source: KeyboardInputSource.androidHardwareKeyboard,
          reportedModifiers: <HidKey>{HidKey.shiftLeft},
        ),
        _desktopMap,
      );
      harness.state.handle(
        PhysicalKeyboardIntent(
          key: keyA,
          action: KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
          reportedModifiers: <HidKey>{HidKey.shiftLeft},
        ),
        _desktopMap,
      );
      harness.state.handle(
        _physical(
          HidKey.shiftLeft,
          KeyboardIntentAction.up,
          source: KeyboardInputSource.androidHardwareKeyboard,
        ),
        _desktopMap,
      );
      await harness.state.idle;

      expect(harness.events.map((event) => event.key), [
        HidKey.shiftLeft,
        keyA,
        keyA,
        HidKey.shiftLeft,
      ]);
    },
  );
}
