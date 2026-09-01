import 'dart:async';

import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _KeyboardHarness {
  final events = <String>[];
  final errors = <Object>[];
  final keyEffects = <(String, bool, bool, KeyboardModifiers)>[];
  bool allowDispatch = true;
  bool throwOnKey = false;
  bool throwOnText = false;
  bool failKeyEffect = false;
  Completer<void>? physicalGate;
  int activeEffects = 0;
  int maxActiveEffects = 0;

  Future<void> runEffect(
    String event, {
    void Function()? record,
    Completer<void>? gate,
    bool fail = false,
  }) async {
    activeEffects++;
    if (activeEffects > maxActiveEffects) maxActiveEffects = activeEffects;
    try {
      events.add(event);
      record?.call();
      if (gate != null) await gate.future;
      if (fail) throw StateError('async sink failed');
    } finally {
      activeEffects--;
    }
  }

  late final controller = KeyboardInputController(
    canDispatch: () => allowDispatch,
    sendKey:
        ({required name, required down, required press, required modifiers}) {
          if (throwOnKey) throw StateError('sink failed');
          final fail = failKeyEffect;
          return () => runEffect(
            'key:$name',
            record: () => keyEffects.add((name, down, press, modifiers)),
            fail: fail,
          );
        },
    sendTextEdit:
        ({
          required text,
          required deleteBeforeGraphemes,
          required deleteAfterGraphemes,
        }) {
          if (throwOnText) throw StateError('text sink failed');
          return () async {
            events.add(
              'text:$text:$deleteBeforeGraphemes:$deleteAfterGraphemes',
            );
          };
        },
    sendString: (text) =>
        () async => events.add('string:$text'),
    sendPhysicalKey:
        ({
          required character,
          required usbHid,
          required lockModes,
          required down,
        }) =>
            () => runEffect('physical:$usbHid:$down', gate: physicalGate),
    sendRawKey:
        ({
          required name,
          required platformCode,
          required positionCode,
          required lockModes,
          required down,
        }) =>
            () => runEffect('raw:$platformCode:$positionCode:$down'),
    sendSourceText:
        ({
          required text,
          required sourceLanguageTag,
          required sourceLayoutType,
        }) => () async {},
    onError: (error, _) => errors.add(error),
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

  test('one-shot key emits command then an explicit release', () async {
    final harness = _KeyboardHarness();
    harness.controller.mobileState.tap(MobileModifierKey.ctrl);

    expect(harness.controller.sendKey('VK_A'), isTrue);
    await harness.controller.idle;

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
    final rejected = _KeyboardHarness()..allowDispatch = false;
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

  test('left and right physical modifiers are tracked independently', () {
    final harness = _KeyboardHarness();

    harness.controller.setPhysicalKey(PhysicalModifierKey.altLeft, true);
    harness.controller.setPhysicalKey(PhysicalModifierKey.altRight, true);
    harness.controller.setPhysicalKey(PhysicalModifierKey.altLeft, false);

    expect(harness.controller.physicalModifiers.alt, isTrue);
    harness.controller.setPhysicalKey(PhysicalModifierKey.altRight, false);
    expect(harness.controller.physicalModifiers.alt, isFalse);
  });

  test('pressed keys recover once in reverse dispatch order', () async {
    final harness = _KeyboardHarness();
    harness.controller.sendKey('VK_CONTROL', down: true, press: false);
    harness.controller.sendKey('VK_A', down: true, press: false);
    await harness.controller.idle;
    harness.events.clear();
    harness.keyEffects.clear();

    harness.controller.retirePendingAndRecover(
      harness.controller.clearPhysicalModifiers,
    );
    await harness.controller.idle;

    expect(harness.events, ['key:VK_A', 'key:VK_CONTROL']);
    expect(
      harness.keyEffects.every((effect) => !effect.$2 && !effect.$3),
      isTrue,
    );
  });

  test('pressed-key recovery survives a cleanup callback failure', () async {
    final harness = _KeyboardHarness();
    harness.controller.sendKey('VK_A', down: true, press: false);
    await harness.controller.idle;
    harness.events.clear();

    expect(
      () => harness.controller.retirePendingAndRecover(
        () => throw StateError('cleanup failed'),
      ),
      throwsStateError,
    );
    await harness.controller.idle;

    expect(harness.events, ['key:VK_A']);
    expect(harness.keyEffects.last.$2, isFalse);
  });

  test('raw-key recovery uses the same pressed ledger', () async {
    final harness = _KeyboardHarness();
    await harness.controller.sendRawKey(
      name: 'a',
      platformCode: 65,
      positionCode: 30,
      lockModes: 0,
      down: true,
    );
    await harness.controller.idle;
    harness.events.clear();

    harness.controller.retirePendingAndRecover(
      harness.controller.clearPhysicalModifiers,
    );
    await harness.controller.idle;

    expect(harness.events, ['raw:65:30:false']);
  });

  test(
    'temporary modifier is released only when controller introduced it',
    () async {
      final harness = _KeyboardHarness();

      expect(
        harness.controller.sendWithTemporaryModifier(
          'VK_C',
          MobileModifierKey.ctrl,
        ),
        isTrue,
      );
      await harness.controller.idle;
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
    },
  );

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

  test(
    'async effect failure is reported and does not poison ordering',
    () async {
      final harness = _KeyboardHarness()..failKeyEffect = true;
      harness.controller.sendKey('VK_A');
      harness.failKeyEffect = false;
      harness.controller.sendKey('VK_B');

      await harness.controller.idle;

      expect(harness.events, ['key:VK_A', 'key:VK_B']);
      expect(harness.errors, hasLength(1));
    },
  );

  test('one logical batch never overlaps its FFI effects', () async {
    final harness = _KeyboardHarness()..physicalGate = Completer<void>();
    harness.controller.mobileState.tap(MobileModifierKey.shift);

    final dispatch = harness.controller.sendPhysicalKey(
      character: 'a',
      usbHid: 0x04,
      lockModes: 0,
      down: true,
      consumeOneShot: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.events, ['physical:4:true']);
    expect(harness.maxActiveEffects, 1);
    harness.physicalGate!.complete();
    harness.physicalGate = null;
    await dispatch;
    await harness.controller.idle;

    expect(harness.events, ['physical:4:true', 'key:VK_SHIFT']);
    expect(harness.maxActiveEffects, 1);
  });

  test('accepted text edit consumes one-shot after the text effect', () async {
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
    await harness.controller.idle;

    expect(harness.events, ['text:x:1:0', 'key:VK_MENU']);
    expect(
      harness.controller.mobileState.modeFor(MobileModifierKey.alt),
      MobileModifierMode.off,
    );
  });

  test('rejected or failed text edit preserves one-shot state', () {
    final rejected = _KeyboardHarness()..allowDispatch = false;
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
