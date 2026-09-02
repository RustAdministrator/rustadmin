import '../mobile/mobile_modifier_state.dart';
import 'keyboard_command_queue.dart';

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

enum PhysicalModifierKey {
  altLeft(MobileModifierKey.alt),
  altRight(MobileModifierKey.alt),
  ctrlLeft(MobileModifierKey.ctrl),
  ctrlRight(MobileModifierKey.ctrl),
  shiftLeft(MobileModifierKey.shift),
  shiftRight(MobileModifierKey.shift),
  commandLeft(MobileModifierKey.command),
  commandRight(MobileModifierKey.command),
  superKey(MobileModifierKey.command);

  const PhysicalModifierKey(this.modifier);

  final MobileModifierKey modifier;
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

typedef RemoteKeyboardEffect = Future<void> Function();
typedef KeyboardDispatchAllowed = bool Function();

typedef RemoteKeySink =
    RemoteKeyboardEffect Function({
      required String name,
      required bool down,
      required bool press,
      required KeyboardModifiers modifiers,
    });

typedef RemoteTextEditSink =
    RemoteKeyboardEffect Function({
      required String text,
      required int deleteBeforeGraphemes,
      required int deleteAfterGraphemes,
    });

typedef RemoteStringSink = RemoteKeyboardEffect Function(String text);

typedef RemotePhysicalKeySink =
    RemoteKeyboardEffect Function({
      required String character,
      required int usbHid,
      required int lockModes,
      required bool down,
    });

typedef RemoteRawKeySink =
    RemoteKeyboardEffect Function({
      required String name,
      required int platformCode,
      required int positionCode,
      required int lockModes,
      required bool down,
    });

typedef RemoteSourceTextSink =
    RemoteKeyboardEffect Function({
      required String text,
      required String sourceLanguageTag,
      required String sourceLayoutType,
    });

class KeyboardInputController {
  final KeyboardDispatchAllowed _canDispatch;
  final RemoteKeySink _sendKey;
  final RemoteTextEditSink _sendTextEdit;
  final RemoteStringSink _sendString;
  final RemotePhysicalKeySink _sendPhysicalKey;
  final RemoteRawKeySink _sendRawKey;
  final RemoteSourceTextSink _sendSourceText;
  final KeyboardCommandQueue _queue;
  late final MobileKeyboardModifierController _mobile;
  final _physicalKeys = <PhysicalModifierKey>{};
  KeyboardModifiers _physicalOverrides = const KeyboardModifiers();
  final _pressedKeyReleases = <Object, RemoteKeyboardEffect>{};
  List<RemoteKeyboardEffect>? _collectingEffects;
  var _recoveryDepth = 0;
  var _stateGeneration = 0;

  KeyboardInputController({
    required KeyboardDispatchAllowed canDispatch,
    required RemoteKeySink sendKey,
    required RemoteTextEditSink sendTextEdit,
    required RemoteStringSink sendString,
    required RemotePhysicalKeySink sendPhysicalKey,
    required RemoteRawKeySink sendRawKey,
    required RemoteSourceTextSink sendSourceText,
    KeyboardCommandErrorHandler? onError,
  }) : _canDispatch = canDispatch,
       _sendKey = sendKey,
       _sendTextEdit = sendTextEdit,
       _sendString = sendString,
       _sendPhysicalKey = sendPhysicalKey,
       _sendRawKey = sendRawKey,
       _sendSourceText = sendSourceText,
       _queue = KeyboardCommandQueue(onError: onError) {
    _mobile = MobileKeyboardModifierController(
      onRelease: (key, remaining) {
        final physical = physicalModifiers;
        if (physical.isActive(key)) return;
        _scheduleModifierUp(key, physical.merge(remaining));
      },
    );
  }

  MobileModifierState get mobileState => _mobile.state;
  KeyboardModifiers get physicalModifiers {
    var snapshot = _physicalOverrides;
    for (final key in _physicalKeys) {
      snapshot = snapshot.withValue(key.modifier, true);
    }
    return snapshot;
  }

  KeyboardModifiers get effectiveModifiers =>
      physicalModifiers.merge(_mobile.snapshot);

  void setPhysical(MobileModifierKey key, bool value) {
    _physicalOverrides = _physicalOverrides.withValue(key, value);
  }

  void setPhysicalKey(PhysicalModifierKey key, bool value) {
    if (value) {
      _physicalKeys.add(key);
    } else {
      _physicalKeys.remove(key);
    }
  }

  void clearPhysicalModifiers() {
    _physicalKeys.clear();
    _physicalOverrides = const KeyboardModifiers();
  }

  Future<void> get idle => _queue.idle;

  bool sendKey(String name, {bool? down, bool? press}) {
    if (!_canDispatch()) return false;
    return _sendKeyWithModifiers(
      name,
      effectiveModifiers,
      down: down,
      press: press,
    );
  }

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
    if (!_canDispatch()) return false;
    final effect = _sendTextEdit(
      text: text,
      deleteBeforeGraphemes: deleteBeforeGraphemes,
      deleteAfterGraphemes: deleteAfterGraphemes,
    );
    _scheduleBatch(effect, afterPrepare: _mobile.consumeOneShot);
    return true;
  }

  bool sendString(String text) {
    if (text.isEmpty || !_canDispatch()) return false;
    _scheduleBatch(_sendString(text));
    return true;
  }

  bool sendWithTemporaryModifier(String name, MobileModifierKey modifier) {
    final modeBefore = mobileState.modeFor(modifier);
    final before = effectiveModifiers;
    final releaseTemporary = !modeBefore.active && !before.isActive(modifier);
    if (!_canDispatch()) return false;
    final effect = _prepareKeyEffect(name, before.withModifier(modifier));
    _scheduleBatch(
      effect,
      afterPrepare: releaseTemporary
          ? () => _scheduleModifierUp(modifier, effectiveModifiers)
          : null,
    );
    return true;
  }

  Future<void> sendPhysicalKey({
    required String character,
    required int usbHid,
    required int lockModes,
    required bool down,
    bool consumeOneShot = false,
  }) {
    if (!_canDispatch()) return Future<void>.value();
    final dispatch = _sendPhysicalKey(
      character: character,
      usbHid: usbHid,
      lockModes: lockModes,
      down: down,
    );
    final effect = _trackPressedEffect(
      identity: ('physical', usbHid),
      down: down,
      dispatch: dispatch,
      release: () => _sendPhysicalKey(
        character: '',
        usbHid: usbHid,
        lockModes: lockModes,
        down: false,
      ),
    );
    return _scheduleBatch(
      effect,
      afterPrepare: consumeOneShot ? _mobile.consumeOneShot : null,
    );
  }

  Future<void> sendRawKey({
    required String name,
    required int platformCode,
    required int positionCode,
    required int lockModes,
    required bool down,
    bool consumeOneShot = false,
  }) {
    if (!_canDispatch()) return Future<void>.value();
    final dispatch = _sendRawKey(
      name: name,
      platformCode: platformCode,
      positionCode: positionCode,
      lockModes: lockModes,
      down: down,
    );
    final effect = _trackPressedEffect(
      identity: ('raw', platformCode, positionCode),
      down: down,
      dispatch: dispatch,
      release: () => _sendRawKey(
        name: name,
        platformCode: platformCode,
        positionCode: positionCode,
        lockModes: lockModes,
        down: false,
      ),
    );
    return _scheduleBatch(
      effect,
      afterPrepare: consumeOneShot ? _mobile.consumeOneShot : null,
    );
  }

  Future<void> sendSourceText({
    required String text,
    required String sourceLanguageTag,
    required String sourceLayoutType,
  }) {
    if (text.isEmpty || !_canDispatch()) return Future<void>.value();
    final effect = _sendSourceText(
      text: text,
      sourceLanguageTag: sourceLanguageTag,
      sourceLayoutType: sourceLayoutType,
    );
    return _scheduleBatch(effect, afterPrepare: _mobile.consumeOneShot);
  }

  void sendKeyUpWithoutModifiers(String name) {
    if (_recoveryDepth == 0 && !_canDispatch()) return;
    _scheduleBatch(
      _prepareKeyEffect(
        name,
        const KeyboardModifiers(),
        down: false,
        press: false,
      ),
    );
  }

  void consumeOneShot() => _mobile.consumeOneShot();

  void reset({bool cancelPending = true, bool clearTrackedKeys = true}) {
    if (cancelPending) _queue.cancelPending();
    if (clearTrackedKeys) {
      _stateGeneration++;
      _pressedKeyReleases.clear();
    }
    clearPhysicalModifiers();
    _mobile.reset();
  }

  void retirePendingAndRecover(void Function() recovery) {
    _queue.cancelPending();
    _recoveryDepth++;
    try {
      recovery();
    } finally {
      try {
        _scheduleBatch(_releaseTrackedKeys);
      } finally {
        _recoveryDepth--;
      }
    }
  }

  Future<void> _releaseTrackedKeys() async {
    final releases = _pressedKeyReleases.values
        .toList(growable: false)
        .reversed;
    _pressedKeyReleases.clear();
    for (final release in releases) {
      await release();
    }
  }

  bool _sendKeyWithModifiers(
    String name,
    KeyboardModifiers modifiers, {
    bool? down,
    bool? press,
  }) {
    final effectiveDown = down ?? false;
    final effectivePress = press ?? true;
    final effect = _prepareKeyEffect(
      name,
      modifiers,
      down: effectiveDown,
      press: effectivePress,
    );
    final consumeOneShot =
        (effectiveDown || effectivePress) && !_isModifierKeyName(name);
    _scheduleBatch(
      effect,
      afterPrepare: consumeOneShot ? _mobile.consumeOneShot : null,
    );
    return true;
  }

  RemoteKeyboardEffect _prepareKeyEffect(
    String name,
    KeyboardModifiers modifiers, {
    bool down = false,
    bool press = true,
  }) {
    final dispatch = _sendKey(
      name: name,
      down: down,
      press: press,
      modifiers: modifiers,
    );
    if (press) return dispatch;
    return _trackPressedEffect(
      identity: ('legacy', name),
      down: down,
      dispatch: dispatch,
      release: () => _sendKey(
        name: name,
        down: false,
        press: false,
        modifiers: const KeyboardModifiers(),
      ),
    );
  }

  RemoteKeyboardEffect _trackPressedEffect({
    required Object identity,
    required bool down,
    required RemoteKeyboardEffect dispatch,
    required RemoteKeyboardEffect Function() release,
  }) {
    final generation = _stateGeneration;
    final releaseEffect = release();
    return () async {
      await dispatch();
      if (generation != _stateGeneration) return;
      if (down) {
        _pressedKeyReleases[identity] = releaseEffect;
      } else {
        _pressedKeyReleases.remove(identity);
      }
    };
  }

  void _scheduleModifierUp(
    MobileModifierKey modifier,
    KeyboardModifiers modifiers,
  ) {
    if (_collectingEffects == null && _recoveryDepth == 0 && !_canDispatch()) {
      return;
    }
    final effect = _prepareKeyEffect(
      switch (modifier) {
        MobileModifierKey.ctrl => 'VK_CONTROL',
        MobileModifierKey.alt => 'VK_MENU',
        MobileModifierKey.shift => 'VK_SHIFT',
        MobileModifierKey.command => 'Meta',
      },
      modifiers,
      down: false,
      press: false,
    );
    final collecting = _collectingEffects;
    if (collecting != null) {
      collecting.add(effect);
    } else {
      _scheduleBatch(effect);
    }
  }

  Future<void> _scheduleBatch(
    RemoteKeyboardEffect first, {
    void Function()? afterPrepare,
  }) {
    final effects = <RemoteKeyboardEffect>[first];
    final previous = _collectingEffects;
    _collectingEffects = effects;
    try {
      afterPrepare?.call();
    } finally {
      _collectingEffects = previous;
    }
    final recovery = _recoveryDepth > 0;
    return _queue.enqueue(() async {
      if (!recovery && !_canDispatch()) return;
      for (final effect in effects) {
        await effect();
      }
    });
  }

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
