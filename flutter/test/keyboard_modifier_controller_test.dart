import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_test/flutter_test.dart';

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

  for (final pair in <(HidKey, HidKey, MobileModifierKey, String)>[
    (HidKey.shiftLeft, HidKey.shiftRight, MobileModifierKey.shift, 'Shift'),
    (
      HidKey.controlLeft,
      HidKey.controlRight,
      MobileModifierKey.ctrl,
      'Control',
    ),
    (HidKey.altLeft, HidKey.altRight, MobileModifierKey.alt, 'Alt'),
    (HidKey.metaLeft, HidKey.metaRight, MobileModifierKey.command, 'Meta'),
  ]) {
    test(
      '${pair.$4} remains active until both physical sides are released',
      () {
        final state = SideSpecificModifierState();
        state.setPressed(pair.$1, true);
        state.setPressed(pair.$2, true);

        state.setPressed(pair.$1, false);
        expect(state.snapshot.isActive(pair.$3), isTrue);

        state.setPressed(pair.$2, false);
        expect(state.snapshot.isActive(pair.$3), isFalse);
      },
    );
  }

  test('Right Alt remains independent from Left Alt', () {
    final state = SideSpecificModifierState();
    state.setPressed(HidKey.altLeft, true);
    state.setPressed(HidKey.altRight, true);
    state.setPressed(HidKey.altLeft, false);

    expect(state.isPressed(HidKey.altRight), isTrue);
    expect(state.snapshot.alt, isTrue);
  });
}
