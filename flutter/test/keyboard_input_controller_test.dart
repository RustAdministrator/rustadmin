import 'dart:async';

import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_input_controller.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_text_policy.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControllerEvent {
  const _ControllerEvent(
    this.kind, {
    this.key,
    this.action,
    this.text,
    this.name,
  });

  final String kind;
  final HidKey? key;
  final KeyboardIntentAction? action;
  final String? text;
  final String? name;
}

class _ControllerHarness {
  bool allowed = true;
  Completer<void>? hidGate;
  final events = <_ControllerEvent>[];
  final rejected = <KeyboardInputRejection>[];

  late final KeyboardInputController controller = KeyboardInputController(
    canDispatch: () => allowed,
    onInputRejected: rejected.add,
    sendHid: ({required key, required action, required lockMask}) async {
      events.add(_ControllerEvent('hid', key: key, action: action));
      await hidGate?.future;
    },
    sendLegacy: ({required name, required down, required modifiers}) async {
      events.add(
        _ControllerEvent(
          'legacy',
          name: name,
          action: down ? KeyboardIntentAction.down : KeyboardIntentAction.up,
        ),
      );
      await hidGate?.future;
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

const _legacyContext = KeyboardRoutingContext(
  keyboardMode: ControllerKeyboardMode.legacy,
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
  test(
    'rejected committed text retains one-shot Shift for the next input',
    () async {
      final h = _ControllerHarness();
      h.controller.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.shift,
          action: SyntheticModifierAction.toggle,
        ),
        _mapContext,
      );
      await h.controller.idle;
      await h.controller.handleAndWait(
        CommittedTextIntent(
          text: List.filled(65537, 'x').join(),
          source: KeyboardInputSource.androidNativeText,
        ),
        _mapContext,
      );
      expect(h.rejected, [KeyboardInputRejection.textTooLarge]);
      expect(h.controller.effectiveModifiers.shift, isTrue);
      expect(h.events.where((event) => event.kind == 'text'), isEmpty);
      await h.controller.handleAndWait(
        const CommittedTextIntent(
          text: 'accepted',
          source: KeyboardInputSource.androidNativeText,
        ),
        _mapContext,
      );
      await h.controller.idle;
      expect(h.controller.effectiveModifiers.shift, isFalse);
      expect(
        h.events.where((event) => event.kind == 'text').single.text,
        'accepted',
      );
    },
  );

  test(
    'rejected text-routed press and release do not consume one-shot Shift',
    () async {
      final h = _ControllerHarness();
      const context = KeyboardRoutingContext(
        keyboardMode: ControllerKeyboardMode.map,
        inputMode: ControllerKeyboardInputMode.text,
        clientKind: KeyboardClientKind.android,
        peerIsAndroid: false,
      );
      h.controller.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.shift,
          action: SyntheticModifierAction.toggle,
        ),
        context,
      );
      final oversized = List.filled(65537, 'x').join();
      for (final action in [
        KeyboardIntentAction.down,
        KeyboardIntentAction.repeat,
        KeyboardIntentAction.up,
      ]) {
        h.controller.handle(
          PhysicalKeyboardIntent(
            key: const HidKey(7, 4),
            action: action,
            textCandidate: oversized,
            source: KeyboardInputSource.androidHardwareKeyboard,
          ),
          context,
        );
      }
      await h.controller.idle;
      expect(h.rejected, isNotEmpty);
      expect(h.controller.effectiveModifiers.shift, isTrue);
      expect(h.events.where((event) => event.kind == 'text'), isEmpty);
      await h.controller.reset(KeyboardResetReason.manual);
    },
  );

  for (final context in [_mapContext, _legacyContext]) {
    test(
      'cancelled unstarted down has no release in ${context.keyboardMode}',
      () async {
        final harness = _ControllerHarness()..hidGate = Completer<void>();
        const blocker = HidKey(0x07, 0x04);
        const skipped = HidKey(0x07, 0x05);
        harness.controller.handle(
          _physical(blocker, KeyboardIntentAction.down),
          context,
        );
        await Future<void>.delayed(Duration.zero);
        harness.controller.handle(
          _physical(skipped, KeyboardIntentAction.down),
          context,
        );
        harness.controller.handle(
          _physical(skipped, KeyboardIntentAction.up),
          context,
        );
        harness.allowed = false;
        final firstReset = harness.controller.reset(
          KeyboardResetReason.focusLoss,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
        final secondReset = harness.controller.reset(
          KeyboardResetReason.focusLoss,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
        harness.hidGate!.complete();
        await Future.wait([firstReset, secondReset]);
        expect(harness.events.map((event) => event.action), [
          KeyboardIntentAction.down,
          KeyboardIntentAction.up,
        ]);
        if (context.keyboardMode == ControllerKeyboardMode.map) {
          expect(harness.events.every((event) => event.key == blocker), isTrue);
        } else {
          expect(harness.events.map((event) => event.name), ['VK_A', 'VK_A']);
        }
      },
    );

    test(
      'retired key-up precedes a fresh press in ${context.keyboardMode}',
      () async {
        final harness = _ControllerHarness()..hidGate = Completer<void>();
        const key = HidKey(0x07, 0x04);
        harness.controller.handle(
          _physical(key, KeyboardIntentAction.down),
          context,
        );
        harness.controller.handle(
          _physical(key, KeyboardIntentAction.up),
          context,
        );
        await Future<void>.delayed(Duration.zero);
        final reset = harness.controller.reset(
          KeyboardResetReason.inputModeChange,
          invalidatePending: true,
          allowBlockedReleases: true,
        );
        harness.controller.handle(
          _physical(key, KeyboardIntentAction.down),
          context,
        );
        harness.hidGate!.complete();
        await reset;
        await harness.controller.idle;
        expect(harness.events.map((event) => event.action), [
          KeyboardIntentAction.down,
          KeyboardIntentAction.up,
          KeyboardIntentAction.down,
        ]);
        harness.controller.handle(
          _physical(key, KeyboardIntentAction.up),
          context,
        );
        await harness.controller.idle;
        expect(harness.events.map((event) => event.action), [
          KeyboardIntentAction.down,
          KeyboardIntentAction.up,
          KeyboardIntentAction.down,
          KeyboardIntentAction.up,
        ]);
      },
    );
  }

  test(
    'a queued one-shot release survives repeated resets exactly once',
    () async {
      final harness = _ControllerHarness()..hidGate = Completer<void>();
      harness.controller.handle(
        const SyntheticModifierIntent(
          modifier: CanonicalModifier.control,
          action: SyntheticModifierAction.toggle,
        ),
        _mapContext,
      );
      await Future<void>.delayed(Duration.zero);
      harness.controller.consumeOneShot();
      harness.allowed = false;
      final first = harness.controller.reset(
        KeyboardResetReason.keyboardHide,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
      final second = harness.controller.reset(
        KeyboardResetReason.keyboardHide,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
      harness.hidGate!.complete();
      await Future.wait([first, second]);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
      ]);
      expect(
        harness.events.every((event) => event.key == HidKey.controlLeft),
        isTrue,
      );
    },
  );

  for (final reason in [
    KeyboardResetReason.focusLoss,
    KeyboardResetReason.keyboardHide,
    KeyboardResetReason.inputModeChange,
    KeyboardResetReason.applicationBackground,
    KeyboardResetReason.sessionClose,
    KeyboardResetReason.permissionRevoked,
  ]) {
    test('queued key-up survives $reason after its down started', () async {
      final harness = _ControllerHarness()..hidGate = Completer<void>();
      const key = HidKey(0x07, 0x04);
      harness.controller.handle(
        _physical(key, KeyboardIntentAction.down),
        _mapContext,
      );
      harness.controller.handle(
        _physical(key, KeyboardIntentAction.up),
        _mapContext,
      );
      await Future<void>.delayed(Duration.zero);
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
      ]);
      harness.allowed = false;
      final reset = harness.controller.reset(
        reason,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
      harness.hidGate!.complete();
      await reset;
      await harness.controller.reset(
        reason,
        invalidatePending: true,
        allowBlockedReleases: true,
      );
      expect(harness.events.map((event) => event.action), [
        KeyboardIntentAction.down,
        KeyboardIntentAction.up,
      ]);
    });
  }

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
