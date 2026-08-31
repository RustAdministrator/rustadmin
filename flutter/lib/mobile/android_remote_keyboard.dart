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
        if (usage is! int || usage < 0x04 || usage > 0xe7 || down is! bool) {
          return null;
        }
        return AndroidRemotePhysicalKeyEvent(sessionId, usage, down);
      case 'text':
        final text = arguments['text'];
        if (text is! String || text.isEmpty || text.length > 2048) {
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
    this.down,
  );

  final int usbHidUsage;
  final bool down;
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
