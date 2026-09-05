import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/mobile/widgets/remote_text_input.dart';
import 'package:flutter_hbb/mobile/widgets/remote_session_controls.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/keyboard_intent.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _InputKeyCall {
  const _InputKeyCall({
    required this.name,
    required this.down,
    required this.press,
    required this.alt,
    required this.ctrl,
    required this.shift,
    required this.command,
  });

  final String name;
  final bool down;
  final bool press;
  final bool alt;
  final bool ctrl;
  final bool shift;
  final bool command;
}

class _FlutterKeyCall {
  const _FlutterKeyCall({required this.usbHid, required this.down});

  final int usbHid;
  final bool down;

  @override
  bool operator ==(Object other) =>
      other is _FlutterKeyCall && other.usbHid == usbHid && other.down == down;

  @override
  int get hashCode => Object.hash(usbHid, down);
}

class _TestRustadminImpl implements Rustadmin {
  final inputKeyCalls = <_InputKeyCall>[];
  final flutterKeyCalls = <_FlutterKeyCall>[];
  final orderedKeyboardCalls = <String>[];
  int plainTextEdits = 0;
  int sourceLayoutTextEdits = 0;
  int lastDeleteBeforeGraphemes = 0;
  final pendingFlutterKeyCalls = <Completer<void>>[];
  bool blockFlutterKeyCalls = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
    }
    if (invocation.memberName == #mainGetInputSource) {
      return 'Input source 2';
    }
    if (invocation.memberName == #mainGetLocalOption ||
        invocation.memberName == #mainGetUserDefaultOption ||
        invocation.memberName == #getLocalFlutterOption ||
        invocation.memberName == #mainSupportedInputSource ||
        invocation.memberName == #mainGetDisplays) {
      return '';
    }
    if (invocation.memberName == #isDisableAb ||
        invocation.memberName == #isDisableAccount ||
        invocation.memberName == #isDisableGroupPanel ||
        invocation.memberName == #mainCurrentIsWayland ||
        invocation.memberName == #mainHasFileClipboard ||
        invocation.memberName == #sessionGetToggleOptionSync) {
      return false;
    }
    if (invocation.memberName == #sessionInputKey) {
      final name = invocation.namedArguments[#name] as String;
      final down = invocation.namedArguments[#down] as bool;
      inputKeyCalls.add(
        _InputKeyCall(
          name: name,
          down: down,
          press: invocation.namedArguments[#press] as bool,
          alt: invocation.namedArguments[#alt] as bool,
          ctrl: invocation.namedArguments[#ctrl] as bool,
          shift: invocation.namedArguments[#shift] as bool,
          command: invocation.namedArguments[#command] as bool,
        ),
      );
      orderedKeyboardCalls.add('legacy:$name:${down ? 'down' : 'up'}');
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionHandleFlutterKeyEvent) {
      final usbHid = invocation.namedArguments[#usbHid] as int;
      final down = invocation.namedArguments[#downOrUp] as bool;
      flutterKeyCalls.add(_FlutterKeyCall(usbHid: usbHid, down: down));
      orderedKeyboardCalls.add('hid:$usbHid:${down ? 'down' : 'up'}');
      if (blockFlutterKeyCalls) {
        final completer = Completer<void>();
        pendingFlutterKeyCalls.add(completer);
        return completer.future;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionInputTextEdit) {
      plainTextEdits += 1;
      lastDeleteBeforeGraphemes =
          invocation.namedArguments[#deleteBeforeGraphemes] as int;
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionInputTextEditWithSourceLayout) {
      sourceLayoutTextEdits += 1;
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionSendMouse) {
      return Future<void>.value();
    }
    if (invocation.memberName == #setCurSessionId ||
        invocation.memberName == #sessionEnterOrLeave) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _NativeTypingHarness {
  _NativeTypingHarness(this.inputModel) {
    text.addListener(() {
      final returnBaseline = text.returnEchoBaseline;
      if (returnBaseline != null) _previous = returnBaseline;
      final composing = text.value.composing;
      if (composing.isValid && !composing.isCollapsed) return;
      final edit = mobileCommittedTextEdit(_previous, text.text);
      _previous = text.text;
      if (edit.isEmpty) return;
      inputModel.inputMobileTextEdit(
        text: edit.text,
        deleteBeforeGraphemes: edit.deleteBeforeGraphemes,
        deleteAfterGraphemes: edit.deleteAfterGraphemes,
        allowModifierShortcuts: !text.isLiteralEdit,
      );
    });
  }

  final InputModel inputModel;
  final text = MobileRemoteTextEditingController(text: '1111');
  final focus = FocusNode();
  String _previous = '1111';

  Future<void> mount(WidgetTester tester, {required bool isMac}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MobileRemoteTextInput(
                controller: text,
                focusNode: focus,
                onEnter: () => inputModel.inputKey('VK_ENTER'),
              ),
              AnimatedBuilder(
                animation: inputModel.mobileModifierState,
                builder: (context, _) => MobileRemoteKeyHelpTools(
                  ctrlActive: inputModel.ctrl,
                  altActive: inputModel.alt,
                  shiftActive: inputModel.shift,
                  commandActive: inputModel.command,
                  ctrlLocked:
                      inputModel.mobileModifierState.modeFor(
                        MobileModifierKey.ctrl,
                      ) ==
                      MobileModifierMode.locked,
                  shiftLocked:
                      inputModel.mobileModifierState.modeFor(
                        MobileModifierKey.shift,
                      ) ==
                      MobileModifierMode.locked,
                  commandLocked:
                      inputModel.mobileModifierState.modeFor(
                        MobileModifierKey.command,
                      ) ==
                      MobileModifierMode.locked,
                  functionKeysActive: false,
                  moreKeysActive: true,
                  isMac: isMac,
                  showWindowsLinuxKeys: !isMac,
                  quickKeyOrder: mobileRemoteDefaultQuickKeyOrder,
                  onCtrl: () =>
                      inputModel.tapMobileModifier(MobileModifierKey.ctrl),
                  onAlt: () =>
                      inputModel.tapMobileModifier(MobileModifierKey.alt),
                  onShift: () =>
                      inputModel.tapMobileModifier(MobileModifierKey.shift),
                  onCommand: () =>
                      inputModel.tapMobileModifier(MobileModifierKey.command),
                  onCtrlDoubleTap: () =>
                      inputModel.lockMobileModifier(MobileModifierKey.ctrl),
                  onShiftDoubleTap: () =>
                      inputModel.lockMobileModifier(MobileModifierKey.shift),
                  onCommandDoubleTap: () =>
                      inputModel.lockMobileModifier(MobileModifierKey.command),
                  onFunctionKeys: () {},
                  onMoreKeys: () {},
                  onKeyPressed: inputModel.inputKey,
                  onShortcutPressed: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String value) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
    );
    await tester.pump();
    await inputModel.keyboardDispatchIdle;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
    focus.dispose();
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestRustadminImpl testImpl;
  late FFI testFfi;
  late InputModel inputModel;

  setUpAll(() {
    isTest = true;
    testImpl = _TestRustadminImpl();
    platformFFI.initForTest(testImpl);
  });

  setUp(() {
    testImpl.inputKeyCalls.clear();
    testImpl.flutterKeyCalls.clear();
    testImpl.orderedKeyboardCalls.clear();
    testImpl.plainTextEdits = 0;
    testImpl.sourceLayoutTextEdits = 0;
    testImpl.lastDeleteBeforeGraphemes = 0;
    testImpl.pendingFlutterKeyCalls.clear();
    testImpl.blockFlutterKeyCalls = false;
    testFfi = FFI(null)..id = 'mobile-modifier-test-peer';
    KeyboardEnabledState.init(testFfi.id);
    inputModel = testFfi.inputModel;
  });

  tearDown(() {
    inputModel.disposeRelativeMouseMode();
    KeyboardEnabledState.delete(testFfi.id);
  });

  for (final peer in [
    kPeerPlatformMacOS,
    kPeerPlatformWindows,
    kPeerPlatformLinux,
  ]) {
    for (final mode in [
      kKeyboardInputModeAuto,
      kKeyboardInputModeText,
      kKeyboardInputModePhysical,
    ]) {
      for (final (modifier, name, usage) in [
        (MobileModifierKey.ctrl, 'ctrl', 0xe0),
        (MobileModifierKey.shift, 'shift', 0xe1),
        (MobileModifierKey.command, 'command', 0xe3),
      ]) {
        testWidgets('native typing reaches $peer as $name+C in $mode mode', (
          tester,
        ) async {
          testFfi.ffiModel.pi.platform = peer;
          await inputModel.setKeyboardInputMode(mode);
          final harness = _NativeTypingHarness(inputModel);
          try {
            await harness.mount(tester, isMac: peer == kPeerPlatformMacOS);
            await tester.tap(find.byKey(Key('mobile-remote-quick-$name')));
            await tester.pump(
              kDoubleTapTimeout + const Duration(milliseconds: 1),
            );
            await inputModel.keyboardDispatchIdle;
            expect(inputModel.mobileModifierState.isActive(modifier), isTrue);
            await harness.type(tester, '1111c');
            expect(testImpl.plainTextEdits, 0);
            expect(testImpl.orderedKeyboardCalls, [
              'hid:$usage:down',
              'hid:6:down',
              'hid:6:up',
              'hid:$usage:up',
            ]);
            expect(testImpl.inputKeyCalls, isEmpty);
            expect(inputModel.mobileModifierState.isActive(modifier), isFalse);
            expect(harness.focus.hasFocus, isTrue);
            await harness.type(tester, '1111cx');
            expect(testImpl.plainTextEdits, 1);
            expect(testImpl.inputKeyCalls, isEmpty);
          } finally {
            await harness.unmount(tester);
          }
        });
      }
    }
  }

  testWidgets('native typing consumes Cmd but retains locked Shift', (
    tester,
  ) async {
    final harness = _NativeTypingHarness(inputModel);
    try {
      await harness.mount(tester, isMac: true);
      inputModel.tapMobileModifier(MobileModifierKey.command);
      inputModel.lockMobileModifier(MobileModifierKey.shift);
      await harness.type(tester, '1111c');
      expect(testImpl.orderedKeyboardCalls, [
        'hid:227:down',
        'hid:225:down',
        'hid:6:down',
        'hid:6:up',
        'hid:227:up',
      ]);
      expect(inputModel.command, isFalse);
      expect(inputModel.shift, isTrue);
      await harness.type(tester, '1111cz');
      expect(testImpl.orderedKeyboardCalls.sublist(5), [
        'hid:29:down',
        'hid:29:up',
      ]);
      expect(testImpl.plainTextEdits, 0);
      inputModel.tapMobileModifier(MobileModifierKey.shift);
      await inputModel.keyboardDispatchIdle;
      expect(
        testImpl.flutterKeyCalls.last,
        const _FlutterKeyCall(usbHid: 0xe1, down: false),
      );
    } finally {
      await harness.unmount(tester);
    }
  });

  testWidgets('a single-character paste with Cmd armed stays literal', (
    tester,
  ) async {
    final harness = _NativeTypingHarness(inputModel);
    try {
      await harness.mount(tester, isMac: true);
      inputModel.tapMobileModifier(MobileModifierKey.command);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': 'c'};
          return null;
        },
      );
      final editor = tester.state<EditableTextState>(
        find.byWidgetPredicate((widget) => widget is EditableText),
      );
      await editor.pasteText(SelectionChangedCause.toolbar);
      await tester.pump();
      await inputModel.keyboardDispatchIdle;
      expect(testImpl.plainTextEdits, 1);
      expect(testImpl.inputKeyCalls, isEmpty);
      expect(testImpl.orderedKeyboardCalls, ['hid:227:down', 'hid:227:up']);
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await harness.unmount(tester);
    }
  });

  testWidgets('single-letter IME composition confirmation stays literal', (
    tester,
  ) async {
    final harness = _NativeTypingHarness(inputModel);
    try {
      await harness.mount(tester, isMac: true);
      inputModel.tapMobileModifier(MobileModifierKey.command);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1111c',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 4, end: 5),
        ),
      );
      await tester.pump();
      expect(testImpl.plainTextEdits, 0);
      await harness.type(tester, '1111c');
      expect(testImpl.plainTextEdits, 1);
      expect(testImpl.inputKeyCalls, isEmpty);
      expect(testImpl.orderedKeyboardCalls, ['hid:227:down', 'hid:227:up']);
    } finally {
      await harness.unmount(tester);
    }
  });

  test('one-shot Ctrl is explicitly released after Ctrl+A', () async {
    inputModel.tapMobileModifier(MobileModifierKey.ctrl);

    inputModel.inputKey('a');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(
      inputModel.mobileModifierState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.off,
    );
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].name, 'VK_A');
    expect(testImpl.inputKeyCalls[0].down, isTrue);
    expect(testImpl.inputKeyCalls[0].press, isFalse);
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_A');
    expect(testImpl.inputKeyCalls[1].down, isFalse);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    ]);
    expect(testImpl.orderedKeyboardCalls, [
      'hid:224:down',
      'legacy:VK_A:down',
      'legacy:VK_A:up',
      'hid:224:up',
    ]);
  });

  test('one-shot release preserves a locked modifier', () async {
    inputModel.tapMobileModifier(MobileModifierKey.ctrl);
    inputModel.lockMobileModifier(MobileModifierKey.shift);

    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(inputModel.shift, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[0].shift, isTrue);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    ]);
  });

  test('locked modifiers are not released after ordinary input', () async {
    inputModel.lockMobileModifier(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(
      testImpl.inputKeyCalls,
      everyElement(predicate<_InputKeyCall>((call) => call.ctrl)),
    );
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
    ]);
  });

  test('virtual release preserves the same physical modifier', () async {
    inputModel.keyboardMode = kKeyMapMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.controlLeft,
        logicalKey: LogicalKeyboardKey.controlLeft,
        timeStamp: Duration.zero,
      ),
    );
    inputModel.tapMobileModifier(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(
      testImpl.inputKeyCalls,
      everyElement(predicate<_InputKeyCall>((call) => call.ctrl)),
    );
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
    ]);
  });

  test('turning off a modifier sends its key-up immediately', () async {
    inputModel.lockMobileModifier(MobileModifierKey.ctrl);
    await inputModel.keyboardDispatchIdle;
    testImpl.inputKeyCalls.clear();
    testImpl.flutterKeyCalls.clear();
    testImpl.orderedKeyboardCalls.clear();

    inputModel.tapMobileModifier(MobileModifierKey.ctrl);
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.inputKeyCalls, isEmpty);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    ]);
  });

  test('temporary shortcut modifiers are explicitly released', () async {
    inputModel.inputKeyWithTemporaryMobileModifier(
      'VK_C',
      MobileModifierKey.ctrl,
    );
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].name, 'VK_C');
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    ]);
    expect(testImpl.orderedKeyboardCalls, [
      'hid:224:down',
      'legacy:VK_C:down',
      'legacy:VK_C:up',
      'hid:224:up',
    ]);
  });

  test('temporary shortcut does not overwrite a physical modifier', () async {
    inputModel.keyboardMode = kKeyMapMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.controlLeft,
        logicalKey: LogicalKeyboardKey.controlLeft,
        timeStamp: Duration.zero,
      ),
    );

    inputModel.inputKeyWithTemporaryMobileModifier(
      'VK_C',
      MobileModifierKey.ctrl,
    );
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(
      testImpl.inputKeyCalls,
      everyElement(predicate<_InputKeyCall>((call) => call.ctrl)),
    );
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: true),
    ]);
  });

  test('desktop Legacy mode stays on legacy transport', () async {
    inputModel.keyboardMode = kKeyLegacyMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_A');
    expect(testImpl.inputKeyCalls.single.down, isTrue);
    expect(testImpl.flutterKeyCalls, isEmpty);
  });

  test('desktop Map mode uses HID transport', () async {
    inputModel.keyboardMode = kKeyMapMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.inputKeyCalls, isEmpty);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0x04, down: true),
    ]);
  });

  test('Text mode routes mobile Latin and Unicode characters once', () async {
    await inputModel.setKeyboardInputMode(kKeyboardInputModeText);

    inputModel.inputKey('a');
    inputModel.inputKey('ф');
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.plainTextEdits, 2);
    expect(testImpl.inputKeyCalls, isEmpty);
    expect(testImpl.flutterKeyCalls, isEmpty);
  });

  test('mobile media controls retain their explicit HID transport', () async {
    await inputModel.onMobileVolumeUp();

    expect(testImpl.inputKeyCalls, isEmpty);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0x80, down: true),
      const _FlutterKeyCall(usbHid: 0x80, down: false),
    ]);
  });

  test('KeyRepeatEvent remains down and never generates key-up', () async {
    inputModel.keyboardMode = kKeyMapMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    inputModel.handleKeyEvent(
      KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
    );
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0x04, down: true),
      const _FlutterKeyCall(usbHid: 0x04, down: true),
    ]);
  });

  test('focus loss releases tracked modifiers exactly once', () async {
    inputModel.keyboardMode = kKeyMapMode;
    for (final event in [
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
      ),
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftRight,
        logicalKey: LogicalKeyboardKey.shiftRight,
        timeStamp: Duration.zero,
      ),
    ]) {
      inputModel.handleKeyEvent(event);
    }
    await inputModel.resetKeyboard(KeyboardResetReason.focusLoss);
    await inputModel.resetKeyboard(KeyboardResetReason.focusLoss);

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0xe5, down: true),
      const _FlutterKeyCall(usbHid: 0xe1, down: false),
      const _FlutterKeyCall(usbHid: 0xe5, down: false),
    ]);
    expect(inputModel.shift, isFalse);
  });

  test('redundant pointer enter does not release a held modifier', () async {
    inputModel.keyboardMode = kKeyMapMode;
    inputModel.handleKeyEvent(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.shiftLeft,
        logicalKey: LogicalKeyboardKey.shiftLeft,
        timeStamp: Duration.zero,
      ),
    );
    await inputModel.keyboardDispatchIdle;
    testImpl.flutterKeyCalls.clear();

    inputModel.enterOrLeave(true);
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.shift, isTrue);
    expect(testImpl.flutterKeyCalls, isEmpty);
    await inputModel.resetKeyboard(
      KeyboardResetReason.focusLoss,
      invalidatePending: true,
      allowBlockedReleases: true,
    );
  });

  test('Android physical key bridge preserves modifier ordering', () async {
    testImpl.blockFlutterKeyCalls = true;

    final shiftDown = inputModel.inputAndroidRemotePhysicalKey(0xe1, true);
    final slashDown = inputModel.inputAndroidRemotePhysicalKey(0x38, true);
    final slashUp = inputModel.inputAndroidRemotePhysicalKey(0x38, false);
    final shiftUp = inputModel.inputAndroidRemotePhysicalKey(0xe1, false);
    await Future<void>.delayed(Duration.zero);

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
    ]);
    testImpl.pendingFlutterKeyCalls.removeAt(0).complete();
    await shiftDown;
    await Future<void>.delayed(Duration.zero);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0x38, down: true),
    ]);

    while (testImpl.pendingFlutterKeyCalls.isNotEmpty) {
      testImpl.pendingFlutterKeyCalls.removeAt(0).complete();
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait([slashDown, slashUp, shiftUp]);

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0x38, down: true),
      const _FlutterKeyCall(usbHid: 0x38, down: false),
      const _FlutterKeyCall(usbHid: 0xe1, down: false),
    ]);
  });

  test('Android committed text preserves bounded source metadata', () async {
    await inputModel.inputAndroidRemoteCommittedText(
      'текст',
      sourceLanguageTag: 'ru-RU',
      sourceLayoutType: 'qwerty',
    );

    expect(testImpl.plainTextEdits, 0);
    expect(testImpl.sourceLayoutTextEdits, 1);
  });

  test('Android Physical preserves source-layout compatibility path', () async {
    await inputModel.setKeyboardInputMode(kKeyboardInputModePhysical);
    await inputModel.inputAndroidRemoteCommittedText(
      'текст',
      sourceLanguageTag: 'ru-RU',
      sourceLayoutType: 'qwerty',
    );

    expect(testImpl.plainTextEdits, 0);
    expect(testImpl.sourceLayoutTextEdits, 1);
  });

  test('mobile text edit preserves bounds and consumes one-shot', () async {
    inputModel.tapMobileModifier(MobileModifierKey.ctrl);
    inputModel.inputMobileTextEdit(
      text: 'text',
      deleteBeforeGraphemes: 2,
      deleteAfterGraphemes: 1,
    );
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.plainTextEdits, 1);
    expect(testImpl.lastDeleteBeforeGraphemes, 2);
    expect(inputModel.ctrl, isFalse);
    expect(
      testImpl.flutterKeyCalls.last,
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    );
  });

  for (final mode in [
    kKeyboardInputModeAuto,
    kKeyboardInputModeText,
    kKeyboardInputModePhysical,
  ]) {
    testWidgets('software keyboard submit reaches the key bridge in $mode mode',
        (tester) async {
      await inputModel.setKeyboardInputMode(mode);
      final controller = MobileRemoteTextEditingController(text: '1111');
      final focus = FocusNode();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MobileRemoteTextInput(
            controller: controller,
            focusNode: focus,
            onEnter: () => inputModel.inputKey('VK_ENTER'),
          ),
        ),
      ));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await inputModel.keyboardDispatchIdle;

      expect(testImpl.orderedKeyboardCalls, [
        'legacy:VK_ENTER:down',
        'legacy:VK_ENTER:up',
      ]);
      expect(testImpl.plainTextEdits, 0);
      expect(testImpl.sourceLayoutTextEdits, 0);
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }

  test('permission revocation releases state before input is denied', () async {
    inputModel.lockMobileModifier(MobileModifierKey.ctrl);
    await inputModel.keyboardDispatchIdle;
    testImpl.flutterKeyCalls.clear();

    testFfi.ffiModel.updatePermissionValues({'keyboard': false}, testFfi.id);
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe0, down: false),
    ]);
    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;
    expect(testImpl.inputKeyCalls, isEmpty);
  });

  test('clipboard text does not consume a one-shot modifier', () async {
    inputModel.tapMobileModifier(MobileModifierKey.ctrl);

    expect(inputModel.inputString('clipboard'), isTrue);
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.plainTextEdits, 1);
    expect(inputModel.ctrl, isTrue);
  });
}
