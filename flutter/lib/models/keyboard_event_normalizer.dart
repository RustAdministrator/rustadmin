import 'package:flutter/services.dart';

import '../consts.dart';
import 'keyboard_intent.dart';

final Map<String, HidKey> _canonicalHidByLegacyName =
    _buildCanonicalHidByLegacyName();

Map<String, HidKey> _buildCanonicalHidByLegacyName() {
  final result = <String, HidKey>{};
  for (final entry in physicalKeyMap.entries) {
    result.putIfAbsent(
      entry.value.toUpperCase(),
      () => HidKey.fromFlutterUsage(entry.key),
    );
  }
  for (final entry in canonicalLegacyKeyNamesByFlutterUsage.entries) {
    result.putIfAbsent(
      entry.value.toUpperCase(),
      () => HidKey.fromFlutterUsage(entry.key),
    );
  }
  return result;
}

class FlutterKeyboardEventNormalizer {
  const FlutterKeyboardEventNormalizer();

  PhysicalKeyboardIntent? fromKeyEvent(KeyEvent event, {int lockMask = 0}) {
    final action = switch (event) {
      KeyDownEvent() => KeyboardIntentAction.down,
      KeyRepeatEvent() => KeyboardIntentAction.repeat,
      KeyUpEvent() => KeyboardIntentAction.up,
      _ => null,
    };
    if (action == null) return null;
    return _fromFlutterKeys(
      physicalKey: event.physicalKey,
      logicalKey: event.logicalKey,
      action: action,
      source: KeyboardInputSource.flutterKeyEvent,
      character: event.character,
      lockMask: lockMask,
    );
  }

  PhysicalKeyboardIntent? fromRawKeyEvent(
    RawKeyEvent event, {
    int lockMask = 0,
  }) {
    final action = switch (event) {
      RawKeyDownEvent(repeat: true) => KeyboardIntentAction.repeat,
      RawKeyDownEvent() => KeyboardIntentAction.down,
      RawKeyUpEvent() => KeyboardIntentAction.up,
      _ => null,
    };
    if (action == null) return null;
    return _fromFlutterKeys(
      physicalKey: event.physicalKey,
      logicalKey: event.logicalKey,
      action: action,
      source: KeyboardInputSource.flutterRawKeyEvent,
      character: event.character,
      lockMask: lockMask,
    );
  }

  PhysicalKeyboardIntent? _fromFlutterKeys({
    required PhysicalKeyboardKey physicalKey,
    required LogicalKeyboardKey logicalKey,
    required KeyboardIntentAction action,
    required KeyboardInputSource source,
    required String? character,
    required int lockMask,
  }) {
    final usage = physicalKey.usbHidUsage;
    final legacyFallbackName =
        physicalKeyMap[usage] ??
        (character?.isNotEmpty == true
            ? null
            : logicalKeyMap[logicalKey.keyId] ??
                  (logicalKey.keyLabel.isEmpty ? null : logicalKey.keyLabel));
    var key = usage > 0 ? HidKey.fromFlutterUsage(usage) : null;
    if ((key == null || key.usagePage == 0) && legacyFallbackName != null) {
      key = _canonicalHidByLegacyName[legacyFallbackName.toUpperCase()];
    }
    if (key == null) return null;
    return PhysicalKeyboardIntent(
      key: key,
      action: action,
      source: source,
      textCandidate: character?.isEmpty == false ? character : null,
      legacyFallbackName: legacyFallbackName,
      logicalKeyId: logicalKey.keyId,
      lockMask: lockMask,
    );
  }
}

class AndroidHardwareKeyboardNormalizer {
  const AndroidHardwareKeyboardNormalizer();

  PhysicalKeyboardIntent? physical({
    required int usbHidUsage,
    required bool down,
    bool repeat = false,
    Iterable<int> modifierUsages = const <int>[],
    int lockMask = 0,
  }) {
    if (usbHidUsage < 0x04 || usbHidUsage > 0xe7) return null;
    return PhysicalKeyboardIntent(
      key: HidKey(HidKey.keyboardUsagePage, usbHidUsage),
      action: repeat
          ? KeyboardIntentAction.repeat
          : down
          ? KeyboardIntentAction.down
          : KeyboardIntentAction.up,
      source: KeyboardInputSource.androidHardwareKeyboard,
      lockMask: lockMask,
      reportedModifiers: <HidKey>{
        for (final usage in modifierUsages)
          if (usage >= 0xe0 && usage <= 0xe7)
            HidKey(HidKey.keyboardUsagePage, usage),
      },
    );
  }

  CommittedTextIntent? text(
    String value, {
    String sourceLanguageTag = '',
    String sourceLayoutType = '',
  }) {
    if (value.isEmpty) return null;
    return CommittedTextIntent(
      text: value,
      source: KeyboardInputSource.androidNativeText,
      sourceLanguageTag: sourceLanguageTag,
      sourceLayoutType: sourceLayoutType,
    );
  }
}

class MobileToolbarKeyboardNormalizer {
  const MobileToolbarKeyboardNormalizer();

  List<KeyboardIntent> click(String legacyName) {
    final key = _physicalKeyFor(legacyName);
    if (key == null) {
      return _isSingleScalar(legacyName)
          ? <KeyboardIntent>[
              CommittedTextIntent(
                text: legacyName,
                source: KeyboardInputSource.mobileToolbar,
              ),
            ]
          : const <KeyboardIntent>[];
    }
    final textCandidate = _isSingleScalar(legacyName) ? legacyName : null;
    return [
      PhysicalKeyboardIntent(
        key: key,
        action: KeyboardIntentAction.down,
        source: KeyboardInputSource.mobileToolbar,
        textCandidate: textCandidate,
        legacyFallbackName: legacyName,
        synthetic: true,
      ),
      PhysicalKeyboardIntent(
        key: key,
        action: KeyboardIntentAction.up,
        source: KeyboardInputSource.mobileToolbar,
        textCandidate: textCandidate,
        legacyFallbackName: legacyName,
        synthetic: true,
      ),
    ];
  }

  PhysicalKeyboardIntent? event(
    String legacyName, {
    required KeyboardIntentAction action,
  }) {
    final key = _physicalKeyFor(legacyName);
    if (key == null) return null;
    return PhysicalKeyboardIntent(
      key: key,
      action: action,
      source: KeyboardInputSource.mobileToolbar,
      textCandidate: _isSingleScalar(legacyName) ? legacyName : null,
      legacyFallbackName: legacyName,
      synthetic: true,
    );
  }

  PhysicalKeyboardIntent? hidEvent(
    int flutterUsage, {
    required KeyboardIntentAction action,
  }) {
    if (flutterUsage <= 0) return null;
    return PhysicalKeyboardIntent(
      key: HidKey.fromFlutterUsage(flutterUsage),
      action: action,
      source: KeyboardInputSource.mobileToolbar,
      synthetic: true,
    );
  }

  SyntheticModifierIntent modifier(
    CanonicalModifier modifier, {
    required SyntheticModifierAction action,
  }) => SyntheticModifierIntent(modifier: modifier, action: action);

  HidKey? _physicalKeyFor(String value) {
    final normalized = value.toUpperCase();
    return _canonicalHidByLegacyName[normalized] ??
        (_isAsciiLetterOrDigit(normalized)
            ? _canonicalHidByLegacyName['VK_$normalized']
            : null);
  }

  static bool _isAsciiLetterOrDigit(String value) =>
      value.length == 1 &&
      ((value.codeUnitAt(0) >= 0x41 && value.codeUnitAt(0) <= 0x5a) ||
          (value.codeUnitAt(0) >= 0x30 && value.codeUnitAt(0) <= 0x39));

  static bool _isSingleScalar(String value) => value.runes.length == 1;
}
