import 'package:flutter_hbb/models/keyboard_dispatcher.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/keyboard_modifier_controller.dart';
import 'package:flutter_test/flutter_test.dart';

KeyboardDispatcher _dispatcher() => KeyboardDispatcher(
  canDispatch: () => true,
  sendHid: ({required key, required action, required lockMask}) {},
  sendLegacy: ({required name, required down, required modifiers}) {},
  sendText:
      ({
        required text,
        required deleteBeforeGraphemes,
        required deleteAfterGraphemes,
        required sourceLanguageTag,
        required sourceLayoutType,
      }) {},
);

PhysicalKeyboardIntent _key({
  KeyboardInputSource source = KeyboardInputSource.flutterKeyEvent,
  HidKey key = const HidKey(HidKey.keyboardUsagePage, 0x04),
  String? legacyFallbackName,
}) => PhysicalKeyboardIntent(
  key: key,
  action: KeyboardIntentAction.down,
  source: source,
  legacyFallbackName: legacyFallbackName,
);

KeyboardRoutingContext _context({
  required KeyboardClientKind client,
  ControllerKeyboardMode mode = ControllerKeyboardMode.legacy,
  bool peerIsAndroid = false,
}) => KeyboardRoutingContext(
  keyboardMode: mode,
  inputMode: ControllerKeyboardInputMode.auto,
  clientKind: client,
  peerIsAndroid: peerIsAndroid,
);

void main() {
  test('desktop and web use HID only in Map mode', () {
    final dispatcher = _dispatcher();
    for (final client in [
      KeyboardClientKind.desktop,
      KeyboardClientKind.webDesktop,
    ]) {
      expect(
        dispatcher.selectPhysicalTransport(
          _key(),
          _context(client: client, mode: ControllerKeyboardMode.map),
        ),
        KeyboardPhysicalTransport.hid,
      );
      for (final mode in [
        ControllerKeyboardMode.legacy,
        ControllerKeyboardMode.translate,
      ]) {
        expect(
          dispatcher.selectPhysicalTransport(
            _key(),
            _context(client: client, mode: mode),
          ),
          KeyboardPhysicalTransport.legacy,
        );
      }
    }
  });

  test('Android hardware and synthetic modifiers retain HID identity', () {
    final dispatcher = _dispatcher();
    final context = _context(client: KeyboardClientKind.android);

    for (final source in [
      KeyboardInputSource.androidHardwareKeyboard,
      KeyboardInputSource.syntheticModifier,
    ]) {
      expect(
        dispatcher.selectPhysicalTransport(_key(source: source), context),
        KeyboardPhysicalTransport.hid,
      );
    }
  });

  test('toolbar keeps named legacy keys but preserves explicit HID', () {
    final dispatcher = _dispatcher();
    final context = _context(
      client: KeyboardClientKind.desktop,
      mode: ControllerKeyboardMode.map,
    );

    expect(
      dispatcher.selectPhysicalTransport(
        _key(
          source: KeyboardInputSource.mobileToolbar,
          legacyFallbackName: 'VK_A',
        ),
        context,
      ),
      KeyboardPhysicalTransport.legacy,
    );
    expect(
      dispatcher.selectPhysicalTransport(
        _key(
          source: KeyboardInputSource.mobileToolbar,
          key: const HidKey(HidKey.keyboardUsagePage, 0x80),
        ),
        context,
      ),
      KeyboardPhysicalTransport.hid,
    );
    expect(
      dispatcher.selectPhysicalTransport(
        _key(key: const HidKey(0x0c, 0xe9)),
        context,
      ),
      KeyboardPhysicalTransport.legacy,
    );
  });

  test('canonical non-printing HID keeps its legacy name fallback', () async {
    String? dispatchedName;
    final dispatcher = KeyboardDispatcher(
      canDispatch: () => true,
      sendHid: ({required key, required action, required lockMask}) {},
      sendLegacy: ({required name, required down, required modifiers}) {
        dispatchedName = name;
      },
      sendText:
          ({
            required text,
            required deleteBeforeGraphemes,
            required deleteAfterGraphemes,
            required sourceLanguageTag,
            required sourceLayoutType,
          }) {},
    );

    await dispatcher.dispatchAll([
      const PhysicalKeyboardDispatch(
        key: HidKey(HidKey.keyboardUsagePage, 0x46),
        action: KeyboardIntentAction.down,
        transport: KeyboardPhysicalTransport.legacy,
        modifiers: KeyboardModifiers(),
        source: KeyboardInputSource.flutterKeyEvent,
      ),
    ]);

    expect(dispatchedName, 'VK_SNAPSHOT');
  });

  test('mobile physical routing preserves peer compatibility exceptions', () {
    final dispatcher = _dispatcher();
    final androidToDesktop = _context(client: KeyboardClientKind.android);

    expect(
      dispatcher.selectPhysicalTransport(_key(), androidToDesktop),
      KeyboardPhysicalTransport.hid,
    );
    for (final usage in [0x28, 0x2a]) {
      expect(
        dispatcher.selectPhysicalTransport(
          _key(key: HidKey(HidKey.keyboardUsagePage, usage)),
          androidToDesktop,
        ),
        KeyboardPhysicalTransport.legacy,
      );
    }
    expect(
      dispatcher.selectPhysicalTransport(
        _key(),
        _context(client: KeyboardClientKind.android, peerIsAndroid: true),
      ),
      KeyboardPhysicalTransport.legacy,
    );
    expect(
      dispatcher.selectPhysicalTransport(
        _key(),
        _context(client: KeyboardClientKind.ios),
      ),
      KeyboardPhysicalTransport.hid,
    );
    expect(
      dispatcher.selectPhysicalTransport(
        _key(),
        _context(client: KeyboardClientKind.ios, peerIsAndroid: true),
      ),
      KeyboardPhysicalTransport.legacy,
    );
    expect(
      dispatcher.selectPhysicalTransport(
        _key(),
        _context(client: KeyboardClientKind.otherMobile),
      ),
      KeyboardPhysicalTransport.legacy,
    );
  });
}
