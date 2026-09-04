import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/keyboard_event_normalizer.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const normalizer = FlutterKeyboardEventNormalizer();

  test('Flutter KeyEvent and RawKeyEvent A-down normalize identically', () {
    final keyEvent = normalizer.fromKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    final rawEvent = normalizer.fromRawKeyEvent(
      RawKeyDownEvent(
        data: const RawKeyEventDataWindows(
          keyCode: 0x41,
          scanCode: 0x1e,
          characterCodePoint: 0x61,
        ),
        character: 'a',
      ),
    );

    expect(keyEvent?.key, const HidKey(0x07, 0x04));
    expect(rawEvent?.key, keyEvent?.key);
    expect(rawEvent?.action, KeyboardIntentAction.down);
    expect(rawEvent?.textCandidate, keyEvent?.textCandidate);
  });

  test('Flutter KeyEvent and RawKeyEvent A-up normalize identically', () {
    final keyEvent = normalizer.fromKeyEvent(
      KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
    );
    final rawEvent = normalizer.fromRawKeyEvent(
      RawKeyUpEvent(
        data: const RawKeyEventDataWindows(keyCode: 0x41, scanCode: 0x1e),
      ),
    );

    expect(rawEvent?.key, keyEvent?.key);
    expect(rawEvent?.action, KeyboardIntentAction.up);
  });

  test('Flutter KeyEvent and RawKeyEvent A-repeat normalize identically', () {
    final keyEvent = normalizer.fromKeyEvent(
      KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    final rawEvent = normalizer.fromRawKeyEvent(
      RawKeyDownEvent(
        data: const RawKeyEventDataWindows(
          keyCode: 0x41,
          scanCode: 0x1e,
          characterCodePoint: 0x61,
        ),
        character: 'a',
        repeat: true,
      ),
    );

    expect(rawEvent?.key, keyEvent?.key);
    expect(rawEvent?.action, KeyboardIntentAction.repeat);
  });

  test('modifier sides and Android Right Alt retain USB HID identity', () {
    final android = const AndroidHardwareKeyboardNormalizer();
    final rightAlt = android.physical(
      usbHidUsage: 0xe6,
      down: true,
      repeat: true,
      modifierUsages: const [0xe0, 0xe6],
    );

    expect(HidKey.shiftLeft, isNot(HidKey.shiftRight));
    expect(HidKey.controlLeft, isNot(HidKey.controlRight));
    expect(HidKey.altLeft, isNot(HidKey.altRight));
    expect(HidKey.metaLeft, isNot(HidKey.metaRight));
    expect(rightAlt?.key, HidKey.altRight);
    expect(rightAlt?.key.modifier, CanonicalModifier.alt);
    expect(rightAlt?.action, KeyboardIntentAction.repeat);
    expect(rightAlt?.reportedModifiers, {HidKey.controlLeft, HidKey.altRight});
  });

  test('mobile toolbar normalizes named keys without platform keycodes', () {
    final toolbar = MobileToolbarKeyboardNormalizer();
    final intents = toolbar.click('VK_C');
    final down = intents.first as PhysicalKeyboardIntent;
    final up = intents.last as PhysicalKeyboardIntent;

    expect(intents, hasLength(2));
    expect(down.key, const HidKey(0x07, 0x06));
    expect(down.action, KeyboardIntentAction.down);
    expect(up.action, KeyboardIntentAction.up);
    expect(
      intents,
      everyElement(
        predicate<PhysicalKeyboardIntent>((intent) => intent.synthetic),
      ),
    );
    expect(
      (toolbar.click('VK_ENTER').first as PhysicalKeyboardIntent).key,
      const HidKey(0x07, 0x28),
    );
    for (final name in const ['VK_SNAPSHOT', 'VK_SCROLL', 'VK_PAUSE', 'Apps']) {
      expect(toolbar.click(name), hasLength(2), reason: name);
    }
  });

  test('mobile text keeps stable HID identity without guessing layout', () {
    final toolbar = MobileToolbarKeyboardNormalizer();
    final latin = toolbar.click('a');
    final unicode = toolbar.click('ф');

    expect(latin, hasLength(2));
    expect(
      (latin.first as PhysicalKeyboardIntent).key,
      const HidKey(0x07, 0x04),
    );
    expect((latin.first as PhysicalKeyboardIntent).textCandidate, 'a');
    expect(unicode, hasLength(1));
    expect(unicode.single, isA<CommittedTextIntent>());
    expect((unicode.single as CommittedTextIntent).text, 'ф');
  });

  test('mobile synthetic Control remains synthetic canonical state', () {
    final toolbar = MobileToolbarKeyboardNormalizer();
    final intent = toolbar.modifier(
      CanonicalModifier.control,
      action: SyntheticModifierAction.toggle,
    );

    expect(intent, isA<SyntheticModifierIntent>());
    expect(intent.modifier, CanonicalModifier.control);
    expect(intent.action, SyntheticModifierAction.toggle);
    expect(intent.source, KeyboardInputSource.syntheticModifier);
  });

  test('Android native committed text normalizes without a physical key', () {
    const android = AndroidHardwareKeyboardNormalizer();
    final intent = android.text('text', sourceLanguageTag: 'ru-RU');

    expect(intent, isA<CommittedTextIntent>());
    expect(intent?.text, 'text');
    expect(intent?.originatingKey, isNull);
    expect(intent?.source, KeyboardInputSource.androidNativeText);
  });

  test('invalid physical usage recovers a known canonical control HID', () {
    final intent = normalizer.fromKeyEvent(
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0x1100000042),
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      ),
    );

    expect(intent?.key, const HidKey(HidKey.keyboardUsagePage, 0x28));
    expect(intent?.legacyFallbackName, 'VK_ENTER');
    expect(intent?.textCandidate, isNull);
  });

  test('zero physical usage recovers a known canonical control HID', () {
    final intent = normalizer.fromKeyEvent(
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: LogicalKeyboardKey.backspace,
        timeStamp: Duration.zero,
      ),
    );

    expect(intent?.key, const HidKey(HidKey.keyboardUsagePage, 0x2a));
    expect(intent?.legacyFallbackName, 'VK_BACK');
  });
}
