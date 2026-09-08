enum KeyboardIntentAction { down, up, repeat }

enum KeyboardInputSource {
  flutterKeyEvent,
  flutterRawKeyEvent,
  androidHardwareKeyboard,
  androidNativeText,
  mobileToolbar,
  syntheticModifier,
  futureIme,
  unknown,
}

enum KeyboardResetReason {
  focusLoss,
  sessionClose,
  keyboardHide,
  inputModeChange,
  applicationBackground,
  permissionRevoked,
  reconnect,
  relativeMouseExit,
  manual,
}

enum CanonicalModifier { control, shift, alt, meta }

enum SyntheticModifierAction { toggle, lock, release }

const canonicalLegacyKeyNamesByFlutterUsage = <int, String>{
  0x00070046: 'VK_SNAPSHOT',
  0x00070047: 'VK_SCROLL',
  0x00070048: 'VK_PAUSE',
  0x00070065: 'Apps',
  0x0007009b: 'VK_CANCEL', // Break/Cancel, distinct from Pause.
};

class HidKey implements Comparable<HidKey> {
  const HidKey(this.usagePage, this.usage)
    : assert(usagePage >= 0 && usagePage <= 0xffff),
      assert(usage >= 0 && usage <= 0xffff);

  factory HidKey.fromFlutterUsage(int value) =>
      HidKey((value >> 16) & 0xffff, value & 0xffff);

  static const keyboardUsagePage = 0x07;
  static const controlLeft = HidKey(keyboardUsagePage, 0xe0);
  static const shiftLeft = HidKey(keyboardUsagePage, 0xe1);
  static const altLeft = HidKey(keyboardUsagePage, 0xe2);
  static const metaLeft = HidKey(keyboardUsagePage, 0xe3);
  static const controlRight = HidKey(keyboardUsagePage, 0xe4);
  static const shiftRight = HidKey(keyboardUsagePage, 0xe5);
  static const altRight = HidKey(keyboardUsagePage, 0xe6);
  static const metaRight = HidKey(keyboardUsagePage, 0xe7);

  final int usagePage;
  final int usage;

  int get flutterUsage => (usagePage << 16) | usage;

  CanonicalModifier? get modifier => switch ((usagePage, usage)) {
    (keyboardUsagePage, 0xe0) ||
    (keyboardUsagePage, 0xe4) => CanonicalModifier.control,
    (keyboardUsagePage, 0xe1) ||
    (keyboardUsagePage, 0xe5) => CanonicalModifier.shift,
    (keyboardUsagePage, 0xe2) ||
    (keyboardUsagePage, 0xe6) => CanonicalModifier.alt,
    (keyboardUsagePage, 0xe3) ||
    (keyboardUsagePage, 0xe7) => CanonicalModifier.meta,
    _ => null,
  };

  bool get isModifier => modifier != null;

  @override
  int compareTo(HidKey other) {
    final pageOrder = usagePage.compareTo(other.usagePage);
    return pageOrder != 0 ? pageOrder : usage.compareTo(other.usage);
  }

  @override
  bool operator ==(Object other) =>
      other is HidKey && usagePage == other.usagePage && usage == other.usage;

  @override
  int get hashCode => Object.hash(usagePage, usage);
}

sealed class KeyboardIntent {
  const KeyboardIntent(this.source);

  final KeyboardInputSource source;
}

final class PhysicalKeyboardIntent extends KeyboardIntent {
  const PhysicalKeyboardIntent({
    required this.key,
    required this.action,
    required KeyboardInputSource source,
    this.textCandidate,
    this.legacyFallbackName,
    this.logicalKeyId,
    this.synthetic = false,
    this.lockMask = 0,
    this.reportedModifiers = const <HidKey>{},
  }) : super(source);

  final HidKey key;
  final KeyboardIntentAction action;
  final String? textCandidate;
  final String? legacyFallbackName;
  final int? logicalKeyId;
  final bool synthetic;
  final int lockMask;
  final Set<HidKey> reportedModifiers;
}

final class CommittedTextIntent extends KeyboardIntent {
  const CommittedTextIntent({
    required this.text,
    required KeyboardInputSource source,
    this.originatingKey,
    this.repeat = false,
    this.deleteBeforeGraphemes = 0,
    this.deleteAfterGraphemes = 0,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
    this.consumeOneShot = true,
    this.allowMobileShortcut = false,
  }) : super(source);

  final String text;
  final HidKey? originatingKey;
  final bool repeat;
  final int deleteBeforeGraphemes;
  final int deleteAfterGraphemes;
  final String sourceLanguageTag;
  final String sourceLayoutType;
  final bool consumeOneShot;
  // Only direct mobile edits opt in; paste and IME commits stay literal.
  final bool allowMobileShortcut;
}

final class KeyboardResetIntent extends KeyboardIntent {
  const KeyboardResetIntent(this.reason) : super(KeyboardInputSource.unknown);

  final KeyboardResetReason reason;
}

final class SyntheticModifierIntent extends KeyboardIntent {
  const SyntheticModifierIntent({required this.modifier, required this.action})
    : super(KeyboardInputSource.syntheticModifier);

  final CanonicalModifier modifier;
  final SyntheticModifierAction action;
}
