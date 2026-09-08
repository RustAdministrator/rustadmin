import '../consts.dart';
import '../models/keyboard_text_policy.dart';
import '../models/keyboard_lock_modes.dart';
import '../models/keyboard_intent.dart'
    show PhysicalKeyPressBatchIntent, KeyboardInputOrigin;

bool useAndroidNativeRemoteKeyboard({
  required bool isAndroidClient,
  required bool physicalKeyCapability,
  required String inputMode,
}) =>
    isAndroidClient &&
    physicalKeyCapability &&
    inputMode != kKeyboardInputModeText;

sealed class AndroidRemoteKeyboardEvent {
  const AndroidRemoteKeyboardEvent(this.sessionId);

  final String sessionId;

  static AndroidRemoteKeyboardEvent? tryParse(dynamic arguments) {
    if (arguments is! Map) return null;
    final sessionId = arguments['session_id'];
    final kind = arguments['kind'];
    if (sessionId is! String || sessionId.isEmpty || kind is! String) {
      return null;
    }
    final origin = switch (arguments['origin']) {
      null || 'unknown' => KeyboardInputOrigin.unknown,
      'hardware' => KeyboardInputOrigin.hardware,
      'ime' => KeyboardInputOrigin.ime,
      _ => null,
    };
    if (origin == null) return null;
    switch (kind) {
      case 'physical':
      case 'press_batch':
        final usage = arguments['usb_hid_usage'];
        final lockModes = arguments['lock_modes'] ?? 0;
        final modifiers = arguments['modifier_usages'] ?? const <int>[];
        final candidate = arguments['text_candidate'] ?? '';
        final accent = arguments['dead_key_accent'];
        if (accent != null &&
            (accent is! int ||
                !KeyboardTextPolicy.isPrintableScalar(accent) ||
                candidate != '')) {
          return null;
        }
        if (candidate is! String ||
            candidate.length > 2 ||
            KeyboardTextPolicy.inspect(candidate).rejection != null ||
            candidate.runes.length > 1) {
          return null;
        }
        if (usage is! int ||
            usage < 0x04 ||
            usage > 0xe7 ||
            lockModes is! int ||
            !KeyboardBridgeLockModes.isValid(lockModes) ||
            modifiers is! List ||
            modifiers.length > 8 ||
            modifiers.any(
              (value) => value is! int || value < 0xe0 || value > 0xe7,
            )) {
          return null;
        }
        if (kind == 'press_batch') {
          final count = arguments['count'];
          if (count is! int ||
              count < 1 ||
              count > PhysicalKeyPressBatchIntent.maxCount) {
            return null;
          }
          return AndroidRemotePressBatchEvent(
            sessionId,
            usage,
            count,
            origin: origin,
            textCandidate: candidate.isEmpty ? null : candidate,
            deadKeyAccent: accent as int?,
            sourceLanguageTag: _validatedMetadata(
              arguments['source_language_tag'],
            ),
            sourceLayoutType: _validatedMetadata(
              arguments['source_layout_type'],
            ),
            lockModes: lockModes,
            modifierUsages: modifiers.cast<int>(),
          );
        }
        final down = arguments['down'];
        final repeat = arguments['repeat'] ?? false;
        if (down is! bool || repeat is! bool) return null;
        return AndroidRemotePhysicalKeyEvent(
          sessionId,
          usage,
          down,
          origin: origin,
          textCandidate: candidate.isEmpty ? null : candidate,
          deadKeyAccent: accent as int?,
          sourceLanguageTag: _validatedMetadata(
            arguments['source_language_tag'],
          ),
          sourceLayoutType: _validatedMetadata(arguments['source_layout_type']),
          repeat: repeat,
          lockModes: lockModes,
          modifierUsages: modifiers.cast<int>(),
        );
      case 'text':
        final text = arguments['text'];
        if (text is! String || text.isEmpty) return null;
        final rejection = KeyboardTextPolicy.inspect(text).rejection;
        if (rejection != null) {
          return AndroidRemoteInputRejectedEvent(sessionId, rejection);
        }
        return AndroidRemoteCommittedTextEvent(
          sessionId,
          text,
          origin: origin,
          sourceLanguageTag: _validatedMetadata(
            arguments['source_language_tag'],
          ),
          sourceLayoutType: _validatedMetadata(arguments['source_layout_type']),
        );
      case 'rejected':
        final reason = switch (arguments['reason']) {
          'text_size' => KeyboardInputRejection.textTooLarge,
          'invalid_text' => KeyboardInputRejection.invalidText,
          'press_count' => KeyboardInputRejection.pressCount,
          _ => null,
        };
        return reason == null
            ? null
            : AndroidRemoteInputRejectedEvent(sessionId, reason);
      default:
        return null;
    }
  }

  static String _validatedMetadata(dynamic value) {
    if (value is! String || value.length > 64) return '';
    return RegExp(r'^[A-Za-z0-9_.+\-]*$').hasMatch(value) ? value : '';
  }
}

final class AndroidRemotePhysicalKeyEvent extends AndroidRemoteKeyboardEvent {
  const AndroidRemotePhysicalKeyEvent(
    super.sessionId,
    this.usbHidUsage,
    this.down, {
    this.origin = KeyboardInputOrigin.unknown,
    this.textCandidate,
    this.deadKeyAccent,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
    this.repeat = false,
    this.lockModes = 0,
    this.modifierUsages = const <int>[],
  });

  final int usbHidUsage;
  final bool down;
  final KeyboardInputOrigin origin;
  final String? textCandidate;
  final int? deadKeyAccent;
  final String sourceLanguageTag;
  final String sourceLayoutType;
  final bool repeat;
  final int lockModes;
  final List<int> modifierUsages;
}

final class AndroidRemotePressBatchEvent extends AndroidRemoteKeyboardEvent {
  const AndroidRemotePressBatchEvent(
    super.sessionId,
    this.usbHidUsage,
    this.count, {
    this.origin = KeyboardInputOrigin.unknown,
    this.textCandidate,
    this.deadKeyAccent,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
    this.lockModes = 0,
    this.modifierUsages = const <int>[],
  });
  final int usbHidUsage;
  final int count;
  final KeyboardInputOrigin origin;
  final String? textCandidate;
  final int? deadKeyAccent;
  final String sourceLanguageTag;
  final String sourceLayoutType;
  final int lockModes;
  final List<int> modifierUsages;
}

final class AndroidRemoteInputRejectedEvent extends AndroidRemoteKeyboardEvent {
  const AndroidRemoteInputRejectedEvent(super.sessionId, this.reason);
  final KeyboardInputRejection reason;
}

final class AndroidRemoteCommittedTextEvent extends AndroidRemoteKeyboardEvent {
  const AndroidRemoteCommittedTextEvent(
    super.sessionId,
    this.text, {
    this.origin = KeyboardInputOrigin.unknown,
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
  });

  final String text;
  final KeyboardInputOrigin origin;
  final String sourceLanguageTag;
  final String sourceLayoutType;
}
