import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/mobile_modifier_state.dart';
import 'package:flutter_hbb/models/input_model.dart';
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

class _TextEditCall {
  const _TextEditCall({
    required this.text,
    required this.deleteBefore,
    required this.deleteAfter,
  });

  final String text;
  final int deleteBefore;
  final int deleteAfter;
}

class _TestRustadminImpl implements Rustadmin {
  final inputKeyCalls = <_InputKeyCall>[];
  final flutterKeyCalls = <_FlutterKeyCall>[];
  final textEditCalls = <_TextEditCall>[];
  final sourceTextCalls = <String>[];
  final inputStrings = <String>[];
  final pendingFlutterKeyCalls = <Completer<void>>[];
  bool blockFlutterKeyCalls = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #translate) {
      return invocation.namedArguments[#name] as String;
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
      inputKeyCalls.add(
        _InputKeyCall(
          name: invocation.namedArguments[#name] as String,
          down: invocation.namedArguments[#down] as bool,
          press: invocation.namedArguments[#press] as bool,
          alt: invocation.namedArguments[#alt] as bool,
          ctrl: invocation.namedArguments[#ctrl] as bool,
          shift: invocation.namedArguments[#shift] as bool,
          command: invocation.namedArguments[#command] as bool,
        ),
      );
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionInputTextEdit) {
      textEditCalls.add(
        _TextEditCall(
          text: invocation.namedArguments[#value] as String,
          deleteBefore:
              invocation.namedArguments[#deleteBeforeGraphemes] as int,
          deleteAfter: invocation.namedArguments[#deleteAfterGraphemes] as int,
        ),
      );
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionInputTextEditWithSourceLayout) {
      sourceTextCalls.add(invocation.namedArguments[#value] as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionInputString) {
      inputStrings.add(invocation.namedArguments[#value] as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionHandleFlutterKeyEvent) {
      flutterKeyCalls.add(
        _FlutterKeyCall(
          usbHid: invocation.namedArguments[#usbHid] as int,
          down: invocation.namedArguments[#downOrUp] as bool,
        ),
      );
      if (blockFlutterKeyCalls) {
        final completer = Completer<void>();
        pendingFlutterKeyCalls.add(completer);
        return completer.future;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #sessionSendMouse) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestRustadminImpl testImpl;
  late FFI ffi;
  late InputModel inputModel;

  setUpAll(() {
    isTest = true;
    testImpl = _TestRustadminImpl();
    platformFFI.initForTest(testImpl);
  });

  setUp(() {
    testImpl.inputKeyCalls.clear();
    testImpl.flutterKeyCalls.clear();
    testImpl.textEditCalls.clear();
    testImpl.sourceTextCalls.clear();
    testImpl.inputStrings.clear();
    testImpl.pendingFlutterKeyCalls.clear();
    testImpl.blockFlutterKeyCalls = false;
    ffi = FFI(null)..id = 'mobile-modifier-test-peer';
    KeyboardEnabledState.init(ffi.id);
    inputModel = ffi.inputModel;
  });

  tearDown(() {
    inputModel.disposeRelativeMouseMode();
    KeyboardEnabledState.delete(ffi.id);
  });

  test('one-shot Ctrl is explicitly released after Ctrl+A', () async {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(
      inputModel.mobileModifierState.modeFor(MobileModifierKey.ctrl),
      MobileModifierMode.off,
    );
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].name, 'VK_A');
    expect(testImpl.inputKeyCalls[0].press, isTrue);
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].down, isFalse);
    expect(testImpl.inputKeyCalls[1].press, isFalse);
    expect(testImpl.inputKeyCalls[1].ctrl, isFalse);
  });

  test('one-shot release preserves a locked modifier', () async {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);
    inputModel.mobileModifierState.lock(MobileModifierKey.shift);

    inputModel.inputKey('VK_A');
    await inputModel.keyboardDispatchIdle;

    expect(inputModel.ctrl, isFalse);
    expect(inputModel.shift, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(2));
    expect(testImpl.inputKeyCalls[0].ctrl, isTrue);
    expect(testImpl.inputKeyCalls[0].shift, isTrue);
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].shift, isTrue);
  });

  test('locked modifiers are not released after ordinary input', () {
    inputModel.mobileModifierState.lock(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.ctrl, isTrue);
  });

  test('virtual release preserves the same physical modifier', () {
    inputModel.ctrl = true;
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    inputModel.inputKey('VK_A');

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.ctrl, isTrue);
  });

  test('physical modifier sides and AltGraph release independently', () {
    inputModel.handleKeyDownEventModifiers(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.altLeft,
        logicalKey: LogicalKeyboardKey.altLeft,
        timeStamp: Duration.zero,
      ),
    );
    inputModel.handleKeyDownEventModifiers(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.altRight,
        logicalKey: LogicalKeyboardKey.altGraph,
        timeStamp: Duration.zero,
      ),
    );
    inputModel.handleKeyUpEventModifiers(
      KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.altLeft,
        logicalKey: LogicalKeyboardKey.altLeft,
        timeStamp: Duration.zero,
      ),
    );

    expect(inputModel.alt, isTrue);
    inputModel.handleKeyUpEventModifiers(
      KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.altRight,
        logicalKey: LogicalKeyboardKey.altGraph,
        timeStamp: Duration.zero,
      ),
    );
    expect(inputModel.alt, isFalse);
  });

  test('turning off a modifier sends its key-up immediately', () {
    inputModel.mobileModifierState.lock(MobileModifierKey.ctrl);
    testImpl.inputKeyCalls.clear();

    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    expect(inputModel.ctrl, isFalse);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls.single.down, isFalse);
    expect(testImpl.inputKeyCalls.single.press, isFalse);
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
    expect(testImpl.inputKeyCalls[1].name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls[1].ctrl, isFalse);
  });

  test('temporary shortcut does not overwrite a physical modifier', () {
    inputModel.ctrl = true;

    inputModel.inputKeyWithTemporaryMobileModifier(
      'VK_C',
      MobileModifierKey.ctrl,
    );

    expect(inputModel.ctrl, isTrue);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.ctrl, isTrue);
  });

  test('mobile text edit keeps FFI arguments and releases one-shot', () async {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    inputModel.inputMobileTextEdit(
      text: 'text',
      deleteBeforeGraphemes: 2,
      deleteAfterGraphemes: 1,
    );
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.textEditCalls, hasLength(1));
    expect(testImpl.textEditCalls.single.text, 'text');
    expect(testImpl.textEditCalls.single.deleteBefore, 2);
    expect(testImpl.textEditCalls.single.deleteAfter, 1);
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls.single.down, isFalse);
    expect(inputModel.ctrl, isFalse);
  });

  test('permission revocation releases virtual state before denying input', () {
    inputModel.mobileModifierState.lock(MobileModifierKey.ctrl);
    testImpl.inputKeyCalls.clear();

    ffi.ffiModel.updatePermissionValues({'keyboard': false}, ffi.id);

    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_CONTROL');
    expect(testImpl.inputKeyCalls.single.down, isFalse);
    expect(inputModel.ctrl, isFalse);
    inputModel.inputKey('VK_A');
    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(inputModel.inputString('blocked'), isFalse);
    expect(testImpl.inputStrings, isEmpty);
  });

  test('input string uses the model bridge without consuming one-shot', () {
    inputModel.mobileModifierState.tap(MobileModifierKey.ctrl);

    expect(inputModel.inputString('clipboard'), isTrue);

    expect(testImpl.inputStrings, ['clipboard']);
    expect(inputModel.ctrl, isTrue);
  });

  test('Android source text reserves one-shot modifier immediately', () async {
    inputModel.mobileModifierState.tap(MobileModifierKey.shift);

    final dispatch = inputModel.inputAndroidRemoteCommittedText(
      'a',
      sourceLanguageTag: 'en',
      sourceLayoutType: 'qwerty',
    );

    expect(inputModel.shift, isFalse);
    await dispatch;
    await inputModel.keyboardDispatchIdle;
    expect(testImpl.sourceTextCalls, ['a']);
  });

  test('queued Android text rechecks permission before dispatch', () async {
    testImpl.blockFlutterKeyCalls = true;
    final physicalDown = inputModel.inputAndroidRemotePhysicalKey(0xe1, true);
    final physicalUp = inputModel.inputAndroidRemotePhysicalKey(0xe1, false);
    final committedText = inputModel.inputAndroidRemoteCommittedText(
      'blocked',
      sourceLanguageTag: 'en',
      sourceLayoutType: 'qwerty',
    );
    await Future<void>.delayed(Duration.zero);

    ffi.ffiModel.updatePermissionValues({'keyboard': false}, ffi.id);
    ffi.ffiModel.updatePermissionValues({'keyboard': true}, ffi.id);
    testImpl.pendingFlutterKeyCalls.removeAt(0).complete();
    await physicalDown;
    await Future<void>.delayed(Duration.zero);

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0xe1, down: false),
    ]);
    testImpl.pendingFlutterKeyCalls.removeAt(0).complete();
    await Future.wait([
      physicalUp,
      committedText,
      inputModel.keyboardDispatchIdle,
    ]);

    expect(testImpl.sourceTextCalls, isEmpty);
  });

  test('virtual input waits behind Android physical input', () async {
    testImpl.blockFlutterKeyCalls = true;
    final physicalDown = inputModel.inputAndroidRemotePhysicalKey(0xe1, true);
    inputModel.inputKey('VK_A');
    await Future<void>.delayed(Duration.zero);

    expect(testImpl.inputKeyCalls, isEmpty);
    testImpl.pendingFlutterKeyCalls.removeAt(0).complete();
    await physicalDown;
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.inputKeyCalls, hasLength(1));
    expect(testImpl.inputKeyCalls.single.name, 'VK_A');
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
    await inputModel.keyboardDispatchIdle;

    expect(testImpl.flutterKeyCalls, [
      const _FlutterKeyCall(usbHid: 0xe1, down: true),
      const _FlutterKeyCall(usbHid: 0x38, down: true),
      const _FlutterKeyCall(usbHid: 0x38, down: false),
      const _FlutterKeyCall(usbHid: 0xe1, down: false),
    ]);
  });
}
