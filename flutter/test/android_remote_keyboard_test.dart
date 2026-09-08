import 'package:flutter_hbb/mobile/android_remote_keyboard.dart';
import 'package:flutter_hbb/models/keyboard_text_policy.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native provenance metadata is bounded and defaults to unknown', () {
    for (final kind in ['physical', 'press_batch']) {
      Map<String, Object> payload() => {
        'session_id': 'session-1',
        'kind': kind,
        'usb_hid_usage': 0x14,
        'down': true,
        'count': 3,
        'text_candidate': '@',
        'source_language_tag': 'de-DE',
        'source_layout_type': 'qwertz',
      };
      for (final name in ['hardware', 'ime', 'unknown']) {
        final event = AndroidRemoteKeyboardEvent.tryParse({
          ...payload(),
          'origin': name,
        });
        if (event is AndroidRemotePhysicalKeyEvent) {
          expect(event.origin.name, name);
          expect(event.textCandidate, '@');
          expect(event.sourceLanguageTag, 'de-DE');
        } else {
          final batch = event as AndroidRemotePressBatchEvent;
          expect(batch.origin.name, name);
          expect(batch.textCandidate, '@');
          expect(batch.sourceLayoutType, 'qwertz');
        }
      }
      for (final invalid in [
        true,
        'ab',
        String.fromCharCode(0xd800),
        List.filled(65537, 'x').join(),
      ]) {
        expect(
          AndroidRemoteKeyboardEvent.tryParse({
            ...payload(),
            'text_candidate': invalid,
          }),
          isNull,
        );
      }
    }
    final old =
        AndroidRemoteKeyboardEvent.tryParse({
              'session_id': 'session-1',
              'kind': 'physical',
              'usb_hid_usage': 0x14,
              'down': true,
            })
            as AndroidRemotePhysicalKeyEvent;
    expect(old.origin, KeyboardInputOrigin.unknown);
    expect(old.textCandidate, isNull);
    final text =
        AndroidRemoteKeyboardEvent.tryParse({
              'session_id': 'session-1',
              'kind': 'text',
              'text': 'committed',
              'origin': 'ime',
            })
            as AndroidRemoteCommittedTextEvent;
    expect(text.origin, KeyboardInputOrigin.ime);
  });

  test('invalid native origin cannot masquerade as a hardware event', () {
    for (final origin in [true, 1, 'hardware-ish', 'toolbar']) {
      expect(
        AndroidRemoteKeyboardEvent.tryParse({
          'session_id': 'session-1',
          'kind': 'physical',
          'usb_hid_usage': 0x04,
          'down': true,
          'origin': origin,
        }),
        isNull,
      );
    }
  });

  test('native text validation reports typed failures without content', () {
    for (final entry in {
      '${List.filled(16384, '\u{1f642}').join()}a':
          KeyboardInputRejection.textTooLarge,
      String.fromCharCode(0xd800): KeyboardInputRejection.invalidText,
    }.entries) {
      final event = AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'text',
        'text': entry.key,
      });
      expect(event, isA<AndroidRemoteInputRejectedEvent>());
      expect((event as AndroidRemoteInputRejectedEvent).reason, entry.value);
    }
    final exact = List.filled(16384, '\u{1f642}').join();
    final event = AndroidRemoteKeyboardEvent.tryParse({
      'session_id': 'session-1',
      'kind': 'text',
      'text': exact,
    });
    expect((event as AndroidRemoteCommittedTextEvent).text, exact);
    for (final reason in ['text_size', 'invalid_text', 'press_count']) {
      expect(
        AndroidRemoteKeyboardEvent.tryParse({
          'session_id': 'session-1',
          'kind': 'rejected',
          'reason': reason,
        }),
        isA<AndroidRemoteInputRejectedEvent>(),
      );
    }
    for (final reason in [null, true, 42, 'arbitrary content']) {
      expect(
        AndroidRemoteKeyboardEvent.tryParse({
          'session_id': 'session-1',
          'kind': 'rejected',
          'reason': reason,
        }),
        isNull,
      );
    }
  });

  test('a native commit larger than a wire packet is preserved whole', () {
    final text = List.filled(4096, 'x').join();
    final event = AndroidRemoteKeyboardEvent.tryParse({
      'session_id': 'session-1',
      'kind': 'text',
      'text': text,
    });
    expect(event, isA<AndroidRemoteCommittedTextEvent>());
    expect((event as AndroidRemoteCommittedTextEvent).text, text);
  });

  test('press batches preserve metadata and reject invalid counts', () {
    Map<String, Object> payload(Object count) => {
      'session_id': 'session-1',
      'kind': 'press_batch',
      'usb_hid_usage': 0x04,
      'count': count,
      'lock_modes': 2,
      'modifier_usages': [0xe5],
    };
    final event =
        AndroidRemoteKeyboardEvent.tryParse(payload(64))
            as AndroidRemotePressBatchEvent;
    expect(event.count, 64);
    expect(event.usbHidUsage, 0x04);
    expect(event.lockModes, 2);
    expect(event.modifierUsages, [0xe5]);
    for (final invalid in <Object>[-1, 0, 65, '3', true]) {
      expect(AndroidRemoteKeyboardEvent.tryParse(payload(invalid)), isNull);
    }
  });

  test('native lock modes retain every bridge bit combination', () {
    for (var locks = 0; locks <= 14; locks += 2) {
      final event =
          AndroidRemoteKeyboardEvent.tryParse({
                'session_id': 'session-1',
                'kind': 'physical',
                'usb_hid_usage': 0x04,
                'down': true,
                'lock_modes': locks,
              })
              as AndroidRemotePhysicalKeyEvent;
      expect(event.lockModes, locks);
    }
    final legacy =
        AndroidRemoteKeyboardEvent.tryParse({
              'session_id': 'session-1',
              'kind': 'physical',
              'usb_hid_usage': 0x04,
              'down': false,
            })
            as AndroidRemotePhysicalKeyEvent;
    expect(legacy.lockModes, 0);
  });

  test(
    'rejects invalid native bridge lock modes instead of accepting wire bits',
    () {
      for (final locks in <Object>[-1, 1, 3, 16, '2', true]) {
        expect(
          AndroidRemoteKeyboardEvent.tryParse({
            'session_id': 'session-1',
            'kind': 'physical',
            'usb_hid_usage': 0x04,
            'down': true,
            'lock_modes': locks,
          }),
          isNull,
        );
      }
    },
  );

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
      'repeat': true,
      'modifier_usages': [0xe0, 0xe6],
    });

    expect(event, isA<AndroidRemotePhysicalKeyEvent>());
    final physical = event! as AndroidRemotePhysicalKeyEvent;
    expect(physical.sessionId, 'session-1');
    expect(physical.usbHidUsage, 0x14);
    expect(physical.down, isTrue);
    expect(physical.repeat, isTrue);
    expect(physical.modifierUsages, [0xe0, 0xe6]);
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

  test('bounds committed text by UTF-8 bytes rather than Dart length', () {
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'text',
        'text': List.filled(16384, '😀').join(),
      }),
      isA<AndroidRemoteCommittedTextEvent>(),
    );
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'text',
        'text': List.filled(21846, '€').join(),
      }),
      isA<AndroidRemoteInputRejectedEvent>(),
    );
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
        'usb_hid_usage': 0x04,
        'down': true,
        'modifier_usages': [0xdf],
      }),
      isNull,
    );
    expect(
      AndroidRemoteKeyboardEvent.tryParse({
        'session_id': 'session-1',
        'kind': 'physical',
        'usb_hid_usage': 0x04,
        'down': true,
        'modifier_usages': List<int>.filled(9, 0xe0),
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
        'text': List.filled(65537, 'x').join(),
      }),
      isA<AndroidRemoteInputRejectedEvent>(),
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
