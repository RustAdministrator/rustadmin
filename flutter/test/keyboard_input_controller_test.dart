import 'dart:async';

import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_input_controller.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControllerEvent {
  const _ControllerEvent(this.kind, {this.key, this.action, this.text});

  final String kind;
  final HidKey? key;
  final KeyboardIntentAction? action;
  final String? text;
}

class _ControllerHarness {
  bool allowed = true;
  Completer<void>? hidGate;
  final events = <_ControllerEvent>[];

  late final KeyboardInputController controller = KeyboardInputController(
    canDispatch: () => allowed,
    sendHid: ({required key, required action, required lockMask}) async {
      events.add(_ControllerEvent('hid', key: key, action: action));
      await hidGate?.future;
    },
    sendLegacy: ({required name, required down, required modifiers}) {
      events.add(
        _ControllerEvent(
          'legacy',
          action: down ? KeyboardIntentAction.down : KeyboardIntentAction.up,
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
          events.add(_ControllerEvent('text', text: text));
        },
  );
}

const _mapContext = KeyboardRoutingContext(
  keyboardMode: ControllerKeyboardMode.map,
  inputMode: ControllerKeyboardInputMode.auto,
  clientKind: KeyboardClientKind.desktop,
  peerIsAndroid: false,
);

PhysicalKeyboardIntent _physical(HidKey key, KeyboardIntentAction action) =>
    PhysicalKeyboardIntent(
      key: key,
      action: action,
      source: KeyboardInputSource.flutterKeyEvent,
    );

void main() {
  test('blocked input cannot create latent key or modifier state', () async {
    final harness = _ControllerHarness()..allowed = false;

    expect(
      harness.controller.handle(
        _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.down),
        _mapContext,
      ),
      isFalse,
    );
    expect(
      harness.controller.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.toggle,
        ),
        _mapContext,
      ),
      isFalse,
    );
    await harness.controller.idle;

    expect(harness.events, isEmpty);
    expect(harness.controller.mobileState.hasActive, isFalse);
    expect(harness.controller.effectiveModifiers.ctrl, isFalse);
  });

  test('permission recovery may bypass the gate only for key-up', () async {
    final harness = _ControllerHarness();
    harness.controller.handle(
      _physical(HidKey.shiftRight, KeyboardIntentAction.down),
      _mapContext,
    );
    await harness.controller.idle;

    harness.allowed = false;
    await harness.controller.reset(
      KeyboardResetReason.permissionRevoked,
      invalidatePending: true,
      allowBlockedReleases: true,
    );

    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
    expect(harness.controller.effectiveModifiers.shift, isFalse);
  });

  test(
    'canonical reset intent releases state through a blocked gate',
    () async {
      final harness = _ControllerHarness();
      harness.controller.handle(
        _physical(HidKey.altRight, KeyboardIntentAction.down),
        _mapContext,
      );
      await harness.controller.idle;

      harness.allowed = false;
      expect(
        harness.controller.handle(
          const KeyboardResetIntent(KeyboardResetReason.sessionClose),
          _mapContext,
        ),
        isTrue,
      );
      await harness.controller.idle;

      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
      ]);
      expect(harness.controller.effectiveModifiers.alt, isFalse);
    },
  );

  test('in-flight down is followed by recovery up in queue order', () async {
    final harness = _ControllerHarness()..hidGate = Completer<void>();
    harness.controller.handle(
      _physical(const HidKey(0x07, 0x04), KeyboardIntentAction.down),
      _mapContext,
    );
    await Future<void>.delayed(Duration.zero);

    harness.allowed = false;
    final reset = harness.controller.reset(
      KeyboardResetReason.sessionClose,
      invalidatePending: true,
      allowBlockedReleases: true,
    );
    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
    ]);

    harness.hidGate!.complete();
    await reset;
    expect(harness.events.map((event) => event.action), [
      KeyboardIntentAction.down,
      KeyboardIntentAction.up,
    ]);
  });

  test(
    'physical and synthetic modifier ownership remain independent',
    () async {
      final harness = _ControllerHarness();
      harness.controller.handle(
        _physical(HidKey.controlRight, KeyboardIntentAction.down),
        _mapContext,
      );
      harness.controller.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.toggle,
        ),
        _mapContext,
      );
      harness.controller.consumeOneShot();

      expect(harness.controller.physicalModifiers.ctrl, isTrue);
      expect(harness.controller.effectiveModifiers.ctrl, isTrue);
      await harness.controller.reset(
        KeyboardResetReason.focusLoss,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
    },
  );
}
