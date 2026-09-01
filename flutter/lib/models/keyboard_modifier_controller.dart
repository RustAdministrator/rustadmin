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

typedef RemoteKeySink =
    bool Function({
      required String name,
      required bool down,
      required bool press,
      required KeyboardModifiers modifiers,
    });

typedef RemoteTextEditSink =
    bool Function({
      required String text,
      required int deleteBeforeGraphemes,
      required int deleteAfterGraphemes,
    });

typedef RemoteStringSink = bool Function(String text);

class KeyboardInputController {
  final RemoteKeySink _sendKey;
  final RemoteTextEditSink _sendTextEdit;
  final RemoteStringSink _sendString;
  late final MobileKeyboardModifierController _mobile;
  KeyboardModifiers _physical = const KeyboardModifiers();

  KeyboardInputController({
    required RemoteKeySink sendKey,
    required RemoteTextEditSink sendTextEdit,
    required RemoteStringSink sendString,
  }) : _sendKey = sendKey,
       _sendTextEdit = sendTextEdit,
       _sendString = sendString {
    _mobile = MobileKeyboardModifierController(
      onRelease: (key, remaining) {
        if (_physical.isActive(key)) return;
        _sendModifierUp(key, _physical.merge(remaining));
      },
    );
  }

  MobileModifierState get mobileState => _mobile.state;
  KeyboardModifiers get physicalModifiers => _physical;
  KeyboardModifiers get effectiveModifiers => _physical.merge(_mobile.snapshot);

  void setPhysical(MobileModifierKey key, bool value) {
    _physical = _physical.withValue(key, value);
  }

  bool sendKey(String name, {bool? down, bool? press}) =>
      _sendKeyWithModifiers(name, effectiveModifiers, down: down, press: press);

  bool sendTextEdit({
    required String text,
    required int deleteBeforeGraphemes,
    required int deleteAfterGraphemes,
  }) {
    if (text.isEmpty &&
        deleteBeforeGraphemes == 0 &&
        deleteAfterGraphemes == 0) {
      return false;
    }
    final accepted = _sendTextEdit(
      text: text,
      deleteBeforeGraphemes: deleteBeforeGraphemes,
      deleteAfterGraphemes: deleteAfterGraphemes,
    );
    if (accepted) _mobile.consumeOneShot();
    return accepted;
  }

  bool sendString(String text) => text.isNotEmpty && _sendString(text);

  bool sendWithTemporaryModifier(String name, MobileModifierKey modifier) {
    final modeBefore = mobileState.modeFor(modifier);
    final before = effectiveModifiers;
    final releaseTemporary = !modeBefore.active && !before.isActive(modifier);
    final accepted = _sendKeyWithModifiers(name, before.withModifier(modifier));
    if (accepted && releaseTemporary) {
      _sendModifierUp(modifier, effectiveModifiers);
    }
    return accepted;
  }

  void consumeOneShot() => _mobile.consumeOneShot();

  void reset() {
    _physical = const KeyboardModifiers();
    _mobile.reset();
  }

  bool _sendKeyWithModifiers(
    String name,
    KeyboardModifiers modifiers, {
    bool? down,
    bool? press,
  }) {
    final effectiveDown = down ?? false;
    final effectivePress = press ?? true;
    final accepted = _sendKey(
      name: name,
      down: effectiveDown,
      press: effectivePress,
      modifiers: modifiers,
    );
    if (accepted &&
        (effectiveDown || effectivePress) &&
        !_isModifierKeyName(name)) {
      _mobile.consumeOneShot();
    }
    return accepted;
  }

  bool _sendModifierUp(
    MobileModifierKey modifier,
    KeyboardModifiers modifiers,
  ) => _sendKey(
    name: switch (modifier) {
      MobileModifierKey.ctrl => 'VK_CONTROL',
      MobileModifierKey.alt => 'VK_MENU',
      MobileModifierKey.shift => 'VK_SHIFT',
      MobileModifierKey.command => 'Meta',
    },
    down: false,
    press: false,
    modifiers: modifiers,
  );

  static bool _isModifierKeyName(String name) => const <String>{
    'VK_CONTROL',
    'VK_SHIFT',
    'VK_MENU',
    'VK_LWIN',
    'VK_RWIN',
    'CONTROL_L',
    'CONTROL_R',
    'SHIFT_L',
    'SHIFT_R',
    'ALT_L',
    'ALT_R',
    'META_L',
    'META_R',
    'SUPER_L',
    'SUPER_R',
  }.contains(name.toUpperCase());
}
