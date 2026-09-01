import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _KeyboardHarness {
  final events = <String>[];
  final keyEffects = <(String, bool, bool, KeyboardModifiers)>[];
  bool acceptKeys = true;
  bool acceptText = true;
  bool acceptString = true;
  bool throwOnKey = false;
  bool throwOnText = false;

  late final controller = KeyboardInputController(
    sendKey:
        ({required name, required down, required press, required modifiers}) {
          events.add('key:$name');
          keyEffects.add((name, down, press, modifiers));
          if (throwOnKey) throw StateError('sink failed');
          return acceptKeys;
        },
    sendTextEdit:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
        }) {
          events.add('text:$text:$deleteBeforeGraphemes:$deleteAfterGraphemes');
          if (throwOnText) throw StateError('text sink failed');
          return acceptText;
        },
    sendString: (text) {
      events.add('string:$text');
      return acceptString;
    },
  );
}

void main() {
  test('one-shot release publishes the remaining modifier snapshot', () {
    final releases = <(MobileModifierKey, KeyboardModifiers)>[];
    final controller = MobileKeyboardModifierController(
      onRelease: (key, remaining) => releases.add((key, remaining)),
    );
    controller.state.tap(MobileModifierKey.ctrl);
    controller.state.lock(MobileModifierKey.shift);

    controller.consumeOneShot();

    expect(releases, hasLength(1));
    expect(releases.single.$1, MobileModifierKey.ctrl);
    expect(releases.single.$2.ctrl, isFalse);
    expect(releases.single.$2.shift, isTrue);
    expect(controller.snapshot.shift, isTrue);
  });

  test('reset releases every active virtual modifier once', () {
    final releases = <MobileModifierKey>[];
    final controller = MobileKeyboardModifierController(
      onRelease: (key, _) => releases.add(key),
    );
    controller.state.lock(MobileModifierKey.ctrl);
    controller.state.lock(MobileModifierKey.alt);

    controller.reset();
    controller.reset();

    expect(releases, [MobileModifierKey.ctrl, MobileModifierKey.alt]);
    expect(controller.snapshot.ctrl, isFalse);
    expect(controller.snapshot.alt, isFalse);
  });

  test('physical and virtual snapshots merge without losing either source', () {
    const physical = KeyboardModifiers(ctrl: true);
    const virtual = KeyboardModifiers(shift: true);

    final effective = physical.merge(virtual);

    expect(effective.ctrl, isTrue);
    expect(effective.shift, isTrue);
    expect(effective.alt, isFalse);
  });

  test('one-shot key emits command then an explicit release', () {
    final harness = _KeyboardHarness();
    harness.controller.mobileState.tap(MobileModifierKey.ctrl);

    expect(harness.controller.sendKey('VK_A'), isTrue);

    expect(harness.events, ['key:VK_A', 'key:VK_CONTROL']);
    expect(harness.keyEffects[0].$4.ctrl, isTrue);
    expect(harness.keyEffects[1].$2, isFalse);
    expect(harness.keyEffects[1].$3, isFalse);
    expect(harness.keyEffects[1].$4.ctrl, isFalse);
    expect(
      harness.controller.mobileState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.off,
    );
  });

  test('rejected or failed sink preserves one-shot state', () {
    final rejected = _KeyboardHarness()..acceptKeys = false;
    rejected.controller.mobileState.tap(MobileModifierKey.shift);

    expect(rejected.controller.sendKey('VK_A'), isFalse);
    expect(
      rejected.controller.mobileState.modeFor(MobileModifierKey.shift),
      MobileModifierMode.oneShot,
    );

    final failed = _KeyboardHarness()..throwOnKey = true;
    failed.controller.mobileState.tap(MobileModifierKey.shift);
    expect(() => failed.controller.sendKey('VK_A'), throwsStateError);
    expect(
      failed.controller.mobileState.modeFor(MobileModifierKey.shift),
      MobileModifierMode.oneShot,
    );
  });

  test('physical modifier masks virtual release', () {
    final harness = _KeyboardHarness();
    harness.controller.setPhysical(MobileModifierKey.shift, true);
    harness.controller.mobileState.tap(MobileModifierKey.shift);

    harness.controller.mobileState.tap(MobileModifierKey.shift);

    expect(harness.events, isEmpty);
    expect(harness.controller.effectiveModifiers.shift, isTrue);
  });

  test('temporary modifier is released only when controller introduced it', () {
    final harness = _KeyboardHarness();

    expect(
      harness.controller.sendWithTemporaryModifier(
        'VK_C',
        MobileModifierKey.ctrl,
      ),
      isTrue,
    );
    expect(harness.events, ['key:VK_C', 'key:VK_CONTROL']);
    expect(harness.keyEffects[0].$4.ctrl, isTrue);
    expect(harness.keyEffects[1].$4.ctrl, isFalse);

    harness.events.clear();
    harness.keyEffects.clear();
    harness.controller.mobileState.lock(MobileModifierKey.ctrl);
    harness.controller.sendWithTemporaryModifier(
      'VK_C',
      MobileModifierKey.ctrl,
    );
    expect(harness.events, ['key:VK_C']);
  });

  test('modifier command does not consume an unrelated one-shot', () {
    final harness = _KeyboardHarness();
    harness.controller.mobileState.tap(MobileModifierKey.ctrl);

    harness.controller.sendKey('VK_SHIFT');

    expect(
      harness.controller.mobileState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.oneShot,
    );
    expect(harness.events, ['key:VK_SHIFT']);
  });

  test('accepted text edit consumes one-shot after the text effect', () {
    final harness = _KeyboardHarness();
    harness.controller.mobileState.tap(MobileModifierKey.alt);

    expect(
      harness.controller.sendTextEdit(
        text: 'x',
        deleteBeforeGraphemes: 1,
        deleteAfterGraphemes: 0,
      ),
      isTrue,
    );

    expect(harness.events, ['text:x:1:0', 'key:VK_MENU']);
    expect(
      harness.controller.mobileState.modeFor(MobileModifierKey.alt),
      MobileModifierMode.off,
    );
  });

  test('rejected or failed text edit preserves one-shot state', () {
    final rejected = _KeyboardHarness()..acceptText = false;
    rejected.controller.mobileState.tap(MobileModifierKey.alt);

    expect(
      rejected.controller.sendTextEdit(
        text: 'x',
        deleteBeforeGraphemes: 0,
        deleteAfterGraphemes: 0,
      ),
      isFalse,
    );
    expect(
      rejected.controller.mobileState.modeFor(MobileModifierKey.alt),
      MobileModifierMode.oneShot,
    );

    final failed = _KeyboardHarness()..throwOnText = true;
    failed.controller.mobileState.tap(MobileModifierKey.alt);
    expect(
      () => failed.controller.sendTextEdit(
        text: 'x',
        deleteBeforeGraphemes: 0,
        deleteAfterGraphemes: 0,
      ),
      throwsStateError,
    );
    expect(
      failed.controller.mobileState.modeFor(MobileModifierKey.alt),
      MobileModifierMode.oneShot,
    );
  });

  test('string input preserves legacy one-shot behavior', () {
    final harness = _KeyboardHarness();
    harness.controller.mobileState.tap(MobileModifierKey.ctrl);

    expect(harness.controller.sendString('clipboard'), isTrue);
    expect(harness.events, ['string:clipboard']);
    expect(
      harness.controller.mobileState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.oneShot,
    );
    expect(harness.controller.sendString(''), isFalse);
  });

  test('reset clears physical state before releasing virtual state', () {
    final harness = _KeyboardHarness();
    harness.controller.setPhysical(MobileModifierKey.ctrl, true);
    harness.controller.mobileState.lock(MobileModifierKey.ctrl);

    harness.controller.reset();

    expect(harness.events, ['key:VK_CONTROL']);
    expect(harness.keyEffects.single.$4.ctrl, isFalse);
    expect(harness.controller.effectiveModifiers.ctrl, isFalse);
  });
}
