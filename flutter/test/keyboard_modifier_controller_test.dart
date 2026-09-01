import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
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
}
