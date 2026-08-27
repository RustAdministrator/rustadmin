import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single taps arm and disarm one-shot modifiers independently', () {
    final modifiers = MobileModifierState();
    addTearDown(modifiers.dispose);

    modifiers.tap(MobileModifierKey.ctrl);
    modifiers.tap(MobileModifierKey.shift);

    expect(
      modifiers.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.oneShot,
    );
    expect(
      modifiers.modeFor(MobileModifierKey.shift),
      MobileModifierMode.oneShot,
    );

    modifiers.tap(MobileModifierKey.ctrl);

    expect(modifiers.modeFor(MobileModifierKey.ctrl), MobileModifierMode.off);
    expect(modifiers.isActive(MobileModifierKey.shift), isTrue);
  });

  test(
    'non-modifier input consumes one-shot but preserves locked modifiers',
    () {
      final modifiers = MobileModifierState();
      addTearDown(modifiers.dispose);

      modifiers.tap(MobileModifierKey.ctrl);
      modifiers.lock(MobileModifierKey.shift);

      expect(modifiers.consumeOneShot(), isTrue);
      expect(modifiers.modeFor(MobileModifierKey.ctrl), MobileModifierMode.off);
      expect(
        modifiers.modeFor(MobileModifierKey.shift),
        MobileModifierMode.locked,
      );
    },
  );

  test('non-modifier input consumes every armed one-shot modifier', () {
    final modifiers = MobileModifierState();
    addTearDown(modifiers.dispose);

    modifiers.tap(MobileModifierKey.ctrl);
    modifiers.tap(MobileModifierKey.shift);

    expect(modifiers.consumeOneShot(), isTrue);
    expect(modifiers.isActive(MobileModifierKey.ctrl), isFalse);
    expect(modifiers.isActive(MobileModifierKey.shift), isFalse);
  });

  test('double tap locks a modifier and a later single tap disables it', () {
    final modifiers = MobileModifierState();
    addTearDown(modifiers.dispose);

    modifiers.lock(MobileModifierKey.alt);
    expect(modifiers.modeFor(MobileModifierKey.alt), MobileModifierMode.locked);

    modifiers.tap(MobileModifierKey.alt);
    expect(modifiers.modeFor(MobileModifierKey.alt), MobileModifierMode.off);
  });
}
