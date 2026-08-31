import 'package:flutter_hbb/mobile/android_remote_keyboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native fallback editor is limited to capable Android peers', () {
    expect(
      useAndroidNativeRemoteKeyboard(
        isAndroidClient: true,
        physicalKeyCapability: true,
        inputMode: 'auto',
      ),
      isTrue,
    );
    expect(
      useAndroidNativeRemoteKeyboard(
        isAndroidClient: true,
        physicalKeyCapability: true,
        inputMode: 'physical',
      ),
      isTrue,
    );
    expect(
      useAndroidNativeRemoteKeyboard(
        isAndroidClient: true,
        physicalKeyCapability: true,
        inputMode: 'text',
      ),
      isFalse,
    );
    expect(
      useAndroidNativeRemoteKeyboard(
        isAndroidClient: true,
        physicalKeyCapability: false,
        inputMode: 'auto',
      ),
      isFalse,
    );
  });

  test('parses bounded physical keyboard events', () {
    final event = AndroidRemoteKeyboardEvent.tryParse({
      'session_id': 'session-1',
      'kind': 'physical',
      'usb_hid_usage': 0x14,
      'down': true,
    });

    expect(event, isA<AndroidRemotePhysicalKeyEvent>());
    final physical = event! as AndroidRemotePhysicalKeyEvent;
    expect(physical.sessionId, 'session-1');
    expect(physical.usbHidUsage, 0x14);
    expect(physical.down, isTrue);
  });

  test('parses committed text fallback without exposing it to logs', () {
    final event = AndroidRemoteKeyboardEvent.tryParse({
      'session_id': 'session-1',
      'kind': 'text',
      'text': '文字',
      'source_language_tag': 'zh-Hans-CN',
      'source_layout_type': 'qwerty',
    });

    expect(event, isA<AndroidRemoteCommittedTextEvent>());
    final committed = event! as AndroidRemoteCommittedTextEvent;
    expect(committed.text, '文字');
    expect(committed.sourceLanguageTag, 'zh-Hans-CN');
    expect(committed.sourceLayoutType, 'qwerty');
  });

  test('rejects malformed, oversized, and non-keyboard payloads', () {
    expect(AndroidRemoteKeyboardEvent.tryParse(null), isNull);
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': '',
        'kind': 'physical',
        'usb_hid_usage': 0x04,
        'down': true,
      }),
      isNull,
    );
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'physical',
        'usb_hid_usage': 0x100,
        'down': true,
      }),
      isNull,
    );
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'text',
        'text': List.filled(2049, 'x').join(),
      }),
      isNull,
    );
    final sanitized =
        AndroidRemoteKeyboardEvent.tryParse({
              'session_id': 'session-1',
              'kind': 'text',
              'text': 'safe',
              'source_language_tag': 'bad tag',
              'source_layout_type': List.filled(65, 'x').join(),
            })
            as AndroidRemoteCommittedTextEvent;
    expect(sanitized.sourceLanguageTag, isEmpty);
    expect(sanitized.sourceLayoutType, isEmpty);
  });
}
