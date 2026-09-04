import 'dart:convert';

import '../consts.dart';

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
    switch (kind) {
      case 'physical':
        final usage = arguments['usb_hid_usage'];
        final down = arguments['down'];
        final repeat = arguments['repeat'] ?? false;
        final modifiers = arguments['modifier_usages'] ?? const <int>[];
        if (usage is! int ||
            usage < 0x04 ||
            usage > 0xe7 ||
            down is! bool ||
            repeat is! bool ||
            modifiers is! List ||
            modifiers.length > 8 ||
            modifiers.any(
              (value) => value is! int || value < 0xe0 || value > 0xe7,
            )) {
          return null;
        }
        return AndroidRemotePhysicalKeyEvent(
          sessionId,
          usage,
          down,
          repeat: repeat,
          modifierUsages: modifiers.cast<int>(),
        );
      case 'text':
        final text = arguments['text'];
        if (text is! String ||
            text.isEmpty ||
            utf8.encode(text).length > 2048) {
          return null;
        }
        return AndroidRemoteCommittedTextEvent(
          sessionId,
          text,
          sourceLanguageTag: _validatedMetadata(
            arguments['source_language_tag'],
          ),
          sourceLayoutType: _validatedMetadata(arguments['source_layout_type']),
        );
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
    this.repeat = false,
    this.modifierUsages = const <int>[],
  });

  final int usbHidUsage;
  final bool down;
  final bool repeat;
  final List<int> modifierUsages;
}

final class AndroidRemoteCommittedTextEvent extends AndroidRemoteKeyboardEvent {
  const AndroidRemoteCommittedTextEvent(
    super.sessionId,
    this.text, {
    this.sourceLanguageTag = '',
    this.sourceLayoutType = '',
  });

  final String text;
  final String sourceLanguageTag;
  final String sourceLayoutType;
}
