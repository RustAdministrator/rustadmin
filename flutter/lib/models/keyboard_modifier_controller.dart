import '../mobile/mobile_modifier_state.dart';
import 'keyboard_intent.dart';

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

  KeyboardModifiers withValue(MobileModifierKey key, bool value) =>
      KeyboardModifiers(
        alt: key == MobileModifierKey.alt ? value : alt,
        ctrl: key == MobileModifierKey.ctrl ? value : ctrl,
        shift: key == MobileModifierKey.shift ? value : shift,
        command: key == MobileModifierKey.command ? value : command,
      );

  static KeyboardModifiers fromState(MobileModifierState state) =>
      KeyboardModifiers(
        alt: state.isActive(MobileModifierKey.alt),
        ctrl: state.isActive(MobileModifierKey.ctrl),
        shift: state.isActive(MobileModifierKey.shift),
        command: state.isActive(MobileModifierKey.command),
      );
}

class SideSpecificModifierState {
  final Set<HidKey> _pressed = <HidKey>{};

  Set<HidKey> get pressed => Set<HidKey>.unmodifiable(_pressed);

  KeyboardModifiers get snapshot {
    var modifiers = const KeyboardModifiers();
    for (final key in _pressed) {
      final modifier = key.modifier;
      if (modifier == null) continue;
      modifiers = modifiers.withValue(_mobileModifier(modifier), true);
    }
    return modifiers;
  }

  bool isPressed(HidKey key) => _pressed.contains(key);

  bool setPressed(HidKey key, bool pressed) {
    if (!key.isModifier) return false;
    return pressed ? _pressed.add(key) : _pressed.remove(key);
  }

  void setAggregate(MobileModifierKey modifier, bool pressed) {
    setPressed(_leftKey(modifier), pressed);
  }

  void clear() => _pressed.clear();

  static MobileModifierKey _mobileModifier(CanonicalModifier modifier) =>
      switch (modifier) {
        CanonicalModifier.control => MobileModifierKey.ctrl,
        CanonicalModifier.shift => MobileModifierKey.shift,
        CanonicalModifier.alt => MobileModifierKey.alt,
        CanonicalModifier.meta => MobileModifierKey.command,
      };

  static HidKey _leftKey(MobileModifierKey modifier) => switch (modifier) {
    MobileModifierKey.ctrl => HidKey.controlLeft,
    MobileModifierKey.shift => HidKey.shiftLeft,
    MobileModifierKey.alt => HidKey.altLeft,
    MobileModifierKey.command => HidKey.metaLeft,
  };
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

  void reset({bool notifyReleases = true}) {
    _suppressReleases = !notifyReleases;
    try {
      state.reset();
    } finally {
      _suppressReleases = false;
    }
  }

  bool _suppressReleases = false;

  void _sync() {
    final previous = _snapshot;
    final next = KeyboardModifiers.fromState(state);
    _snapshot = next;
    if (_suppressReleases) return;
    for (final key in MobileModifierKey.values) {
      if (previous.isActive(key) && !next.isActive(key)) {
        onRelease(key, next);
      }
    }
  }
}
