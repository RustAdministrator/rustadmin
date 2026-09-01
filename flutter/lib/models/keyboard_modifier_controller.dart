import '../mobile/mobile_modifier_state.dart';

class KeyboardModifiers {
  const KeyboardModifiers({
    this.alt = false,
    this.ctrl = false,
    this.shift = false,
    this.command = false,
  });

  final bool alt;
  final bool ctrl;
  final bool shift;
  final bool command;

  bool isActive(MobileModifierKey key) => switch (key) {
    MobileModifierKey.ctrl => ctrl,
    MobileModifierKey.alt => alt,
    MobileModifierKey.shift => shift,
    MobileModifierKey.command => command,
  };

  KeyboardModifiers merge(KeyboardModifiers other) => KeyboardModifiers(
    alt: alt || other.alt,
    ctrl: ctrl || other.ctrl,
    shift: shift || other.shift,
    command: command || other.command,
  );

  KeyboardModifiers withModifier(MobileModifierKey key) => KeyboardModifiers(
    alt: alt || key == MobileModifierKey.alt,
    ctrl: ctrl || key == MobileModifierKey.ctrl,
    shift: shift || key == MobileModifierKey.shift,
    command: command || key == MobileModifierKey.command,
  );

  static KeyboardModifiers fromState(MobileModifierState state) =>
      KeyboardModifiers(
        alt: state.isActive(MobileModifierKey.alt),
        ctrl: state.isActive(MobileModifierKey.ctrl),
        shift: state.isActive(MobileModifierKey.shift),
        command: state.isActive(MobileModifierKey.command),
      );
}

typedef MobileModifierRelease =
    void Function(MobileModifierKey key, KeyboardModifiers remaining);

class MobileKeyboardModifierController {
  MobileKeyboardModifierController({required this.onRelease}) {
    state.addListener(_sync);
  }

  final state = MobileModifierState();
  final MobileModifierRelease onRelease;
  KeyboardModifiers _snapshot = const KeyboardModifiers();

  KeyboardModifiers get snapshot => _snapshot;

  void consumeOneShot() => state.consumeOneShot();

  void reset() => state.reset();

  void _sync() {
    final previous = _snapshot;
    final next = KeyboardModifiers.fromState(state);
    _snapshot = next;
    for (final key in MobileModifierKey.values) {
      if (previous.isActive(key) && !next.isActive(key)) {
        onRelease(key, next);
      }
    }
  }
}
